"""Fuse classical and optional model evidence without forcing a card label."""

from __future__ import annotations

from math import exp, log, sqrt
from typing import Any, Mapping, Sequence

import numpy as np

from src.adapters.pretrained_model import ModelEvidence, PretrainedModelAdapter, UnavailablePretrainedModel
from src.features.pip_detector import detect_pips
from src.features.suit_detector import SUITS, detect_suit
from src.geometry.card_localizer import crop_card_candidate, localize_cards
from src.geometry.visible_region import estimate_visible_region
from src.inference.partial_rank_inference import infer_partial_rank
from src.rules.card_templates import RANKS


def _normalized(distribution: Mapping[str, float], labels: tuple[str, ...]) -> dict[str, float]:
    values = {label: max(0.0, float(distribution.get(label, 0.0))) for label in labels}
    total = sum(values.values())
    if total <= 0.0:
        return {label: 1.0 / len(labels) for label in labels}
    return {label: value / total for label, value in values.items()}


def _geometric_fusion(
    base: Mapping[str, float],
    labels: tuple[str, ...],
    extras: list[tuple[Mapping[str, float], float]],
) -> dict[str, float]:
    if not extras:
        return _normalized(base, labels)
    base_distribution = _normalized(base, labels)
    logits = {label: 0.72 * log(max(base_distribution[label], 1e-7)) for label in labels}
    total_weight = 0.72
    for distribution, weight in extras:
        if weight <= 0.0 or not distribution:
            continue
        normalized = _normalized(distribution, labels)
        for label in labels:
            logits[label] += weight * log(max(normalized[label], 1e-7))
        total_weight += weight
    logits = {label: value / total_weight for label, value in logits.items()}
    maximum = max(logits.values())
    exponentials = {label: exp(value - maximum) for label, value in logits.items()}
    total = sum(exponentials.values())
    return {label: value / total for label, value in exponentials.items()}


def _corner_distributions(corner_evidence: Mapping[str, Any] | None) -> tuple[dict[str, float], dict[str, float], float]:
    if not corner_evidence:
        return {}, {}, 0.0
    confidence = float(np.clip(corner_evidence.get("confidence", 0.0), 0.0, 1.0))
    ranks = dict(corner_evidence.get("rank_candidates", {}))
    suits = dict(corner_evidence.get("suit_candidates", {}))
    if not ranks and corner_evidence.get("rank") in RANKS:
        ranks[str(corner_evidence["rank"])] = 1.0
    if not suits and corner_evidence.get("suit") in SUITS:
        suits[str(corner_evidence["suit"])] = 1.0
    return ranks, suits, confidence


def _model_evidence(
    image: np.ndarray,
    model: PretrainedModelAdapter | None,
) -> ModelEvidence:
    adapter = model or UnavailablePretrainedModel()
    try:
        return adapter.predict(image)
    except Exception as exc:  # Optional evidence must never break the baseline.
        return ModelEvidence(
            available=False,
            source=type(adapter).__name__,
            metadata={"reason": f"adapter failed: {exc}"},
        )


def infer_partial_card(
    image: np.ndarray,
    *,
    corner_evidence: Mapping[str, Any] | None = None,
    pretrained_model: PretrainedModelAdapter | None = None,
    detected_pips: Sequence[dict[str, Any]] | None = None,
    visible_region: Mapping[str, Any] | None = None,
    suit_evidence: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Run the complete MVP and return evidence, candidates, and unknowns."""

    if image is None or not isinstance(image, np.ndarray) or image.size == 0:
        raise ValueError("image must be a non-empty NumPy array")

    visible = dict(visible_region) if visible_region is not None else estimate_visible_region(image)
    pips = list(detected_pips) if detected_pips is not None else detect_pips(image)
    suit_details = dict(suit_evidence) if suit_evidence is not None else detect_suit(image, return_details=True)
    rank_result = infer_partial_rank(pips, visible, image_shape=image.shape[:2])
    model_evidence = _model_evidence(image, pretrained_model)
    corner_ranks, corner_suits, corner_confidence = _corner_distributions(corner_evidence)

    rank_extras: list[tuple[Mapping[str, float], float]] = []
    suit_extras: list[tuple[Mapping[str, float], float]] = []
    if corner_ranks:
        rank_extras.append((corner_ranks, 0.65 * corner_confidence))
    if corner_suits:
        suit_extras.append((corner_suits, 0.65 * corner_confidence))
    if model_evidence.available and model_evidence.rank_probabilities:
        rank_extras.append((model_evidence.rank_probabilities, 0.45 * model_evidence.confidence))
    if model_evidence.available and model_evidence.suit_probabilities:
        suit_extras.append((model_evidence.suit_probabilities, 0.45 * model_evidence.confidence))

    fused_ranks = _geometric_fusion(rank_result["rank_candidates"], RANKS, rank_extras)
    fused_suits = _geometric_fusion(suit_details["probabilities"], SUITS, suit_extras)
    ordered_ranks = sorted(fused_ranks.items(), key=lambda item: item[1], reverse=True)
    ordered_suits = sorted(fused_suits.items(), key=lambda item: item[1], reverse=True)
    best_rank, best_rank_probability = ordered_ranks[0]
    best_suit, best_suit_probability = ordered_suits[0]
    second_suit_probability = ordered_suits[1][1] if len(ordered_suits) > 1 else 0.0
    suit_unknown = float(suit_details["probabilities"].get("unknown", 0.0))

    rank_certainty = float(
        np.clip(0.58 * rank_result["confidence"] + 0.42 * best_rank_probability, 0.0, 1.0)
    )
    resolved_rank = best_rank
    if rank_result["rank"] == "unknown" and not rank_extras:
        resolved_rank = "unknown"
    ace_with_full_card = best_rank == "A" and visible["region"] == "full"
    minimum_rank_certainty = 0.29 if ace_with_full_card else 0.34
    if resolved_rank != "unknown" and (
        rank_certainty < minimum_rank_certainty or best_rank_probability < 0.18
    ):
        resolved_rank = "unknown"

    resolved_suit = best_suit
    suit_margin = best_suit_probability - second_suit_probability
    if (
        best_suit_probability < 0.50
        or suit_unknown >= best_suit_probability
        or (suit_margin < 0.40 and suit_unknown > 0.18)
    ):
        resolved_suit = "unknown"

    if resolved_rank != "unknown" and resolved_suit != "unknown":
        confidence = sqrt(rank_certainty * best_suit_probability)
    elif resolved_rank != "unknown":
        confidence = 0.72 * rank_certainty
    elif resolved_suit != "unknown":
        confidence = 0.45 * best_suit_probability
    else:
        confidence = 0.0

    rank_detail_by_name = {candidate["rank"]: candidate for candidate in rank_result["candidates"]}
    rank_candidates = {
        rank: probability for rank, probability in ordered_ranks
    }
    suit_candidates = {
        suit: probability for suit, probability in ordered_suits
    }
    top_rank_details = rank_detail_by_name.get(best_rank, {})

    return {
        "rank": resolved_rank,
        "suit": resolved_suit,
        "confidence": float(np.clip(confidence, 0.0, 1.0)),
        "candidates": [[rank, probability] for rank, probability in ordered_ranks],
        "evidence": {
            "suit": best_suit_probability,
            "pip_layout": rank_result["confidence"],
            "visible_region": visible["region"],
            "visible_region_confidence": visible["confidence"],
            "corner": dict(corner_evidence) if corner_evidence else None,
            "pretrained_model": model_evidence.as_dict(),
            "reasons": top_rank_details.get("explanation", []),
        },
        "rank_candidates": rank_candidates,
        "suit_candidates": suit_candidates,
        "unknown": {
            "rank": rank_result["unknown_probability"],
            "suit": suit_unknown,
        },
        "detections": {
            "pips": pips,
            "visible_region": visible,
            "suit": suit_details,
        },
    }


def _scene_candidate_score(
    localization_score: float,
    inference: Mapping[str, Any],
) -> float:
    rank_candidates = inference.get("rank_candidates", {})
    suit_candidates = inference.get("suit_candidates", {})
    top_rank = max((float(value) for value in rank_candidates.values()), default=0.0)
    top_suit = max((float(value) for value in suit_candidates.values()), default=0.0)
    pip_layout = float(inference.get("evidence", {}).get("pip_layout", 0.0))
    pip_count = len(inference.get("detections", {}).get("pips", []))
    support_factor = 1.0 if pip_count >= 2 else 0.62 if pip_count == 1 else 0.30
    score = (
        0.55 * float(localization_score)
        + 0.20 * pip_layout
        + 0.15 * top_rank
        + 0.10 * top_suit
    )
    return float(np.clip(score * support_factor, 0.0, 1.0))


def _unknown_visible_region(reason: str) -> dict[str, Any]:
    regions = (
        "top", "bottom", "left", "right", "center", "top_left",
        "top_right", "bottom_left", "bottom_right", "full", "unknown",
    )
    return {
        "region": "unknown",
        "confidence": 1.0,
        "probabilities": {region: 1.0 if region == "unknown" else 0.0 for region in regions},
        "card_polygon": None,
        "card_bbox": None,
        "lines": [],
        "visible_card_fraction": 0.0,
        "reason": reason,
    }


def _layout_scale_pips(pips: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    """Drop much smaller corner marks when a main pip scale is evident."""

    retained = list(pips)
    if len(retained) < 2:
        return retained
    by_area = sorted(retained, key=lambda pip: float(pip.get("area", 0.0)), reverse=True)
    for index in range(len(by_area) - 1):
        larger = float(by_area[index].get("area", 0.0))
        smaller = max(float(by_area[index + 1].get("area", 0.0)), 1.0)
        if larger / smaller >= 4.0:
            main_scale = {id(pip) for pip in by_area[: index + 1]}
            return [pip for pip in retained if id(pip) in main_scale]
    return retained


def _localized_visible_region(
    candidate: Mapping[str, Any],
    geometry: Mapping[str, int],
) -> dict[str, Any] | None:
    """Translate a strong localized card surface into visibility evidence."""

    features = candidate.get("features", {})
    if (
        float(features.get("rectangularity", 0.0)) < 0.72
        or float(features.get("solidity", 0.0)) < 0.84
        or float(features.get("aspect_score", 0.0)) < 0.76
        or float(features.get("surface_coverage", 0.0)) < 0.64
    ):
        return None

    touches = {
        side: bool(candidate.get("touches_image_boundary", {}).get(side, False))
        for side in ("left", "right", "top", "bottom")
    }
    touched = [side for side, present in touches.items() if present]
    rectangularity = float(features.get("rectangularity", 0.0))
    aspect_score = float(features.get("aspect_score", 0.0))
    nearly_complete = len(touched) == 1 and rectangularity >= 0.80 and aspect_score >= 0.88
    if not touched or nearly_complete:
        region = "full"
        confidence = 0.90 if not touched else 0.72
        visible_fraction = 0.96 if not touched else 0.84
    else:
        vertical = "bottom" if touches["top"] else "top" if touches["bottom"] else ""
        horizontal = "right" if touches["left"] else "left" if touches["right"] else ""
        region = "_".join(part for part in (vertical, horizontal) if part) or "unknown"
        confidence = 0.70 if region != "unknown" else 0.58
        visible_fraction = 0.62 if len(touched) == 1 else 0.46

    regions = (
        "top", "bottom", "left", "right", "center", "top_left",
        "top_right", "bottom_left", "bottom_right", "full", "unknown",
    )
    probabilities = {name: 0.0 for name in regions}
    probabilities[region] = confidence
    probabilities["unknown"] += 1.0 - confidence
    offset = np.array([int(geometry["x"]), int(geometry["y"])], dtype=np.int32)
    polygon = np.asarray(candidate.get("polygon", []), dtype=np.int32)
    local_polygon = (polygon - offset).tolist() if len(polygon) >= 3 else None
    width, height = int(geometry["width"]), int(geometry["height"])
    lines: list[list[int]] = []
    if local_polygon:
        for start, end in zip(local_polygon, local_polygon[1:] + local_polygon[:1]):
            lines.append([int(start[0]), int(start[1]), int(end[0]), int(end[1])])
    return {
        "region": region,
        "confidence": confidence,
        "probabilities": probabilities,
        "card_polygon": local_polygon,
        "card_bbox": [0, 0, width, height],
        "lines": lines,
        "visible_card_fraction": visible_fraction,
        "touches_image_boundary": touches,
        "reason": "visibility inherited from localized card surface",
    }


def _suit_evidence_from_pips(pips: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    accumulated = {suit: 0.0 for suit in SUITS}
    total_weight = 0.0
    for pip in pips:
        scores = pip.get("suit_scores", {})
        weight = float(np.clip(pip.get("shape_score", 0.5), 0.1, 1.0))
        for suit in SUITS:
            accumulated[suit] += weight * float(scores.get(suit, 0.0))
        total_weight += weight
    if total_weight <= 0.0:
        probabilities = {suit: 0.0 for suit in SUITS}
        probabilities["unknown"] = 1.0
        return {"probabilities": probabilities, "contours_used": 0}
    averaged = {suit: value / total_weight for suit, value in accumulated.items()}
    ordered = sorted(averaged.values(), reverse=True)
    separation = ordered[0] - ordered[1]
    unknown = float(np.clip(0.48 - 0.60 * separation, 0.10, 0.48))
    known_total = max(sum(averaged.values()), 1e-8)
    probabilities = {
        suit: (1.0 - unknown) * averaged[suit] / known_total for suit in SUITS
    }
    probabilities["unknown"] = unknown
    return {"probabilities": probabilities, "contours_used": len(pips)}


def _pips_in_crop(
    pips: Sequence[Mapping[str, Any]],
    geometry: Mapping[str, int],
) -> list[dict[str, Any]]:
    translated: list[dict[str, Any]] = []
    width, height = int(geometry["width"]), int(geometry["height"])
    for pip in pips:
        item = dict(pip)
        center_x = float(pip["center_px"][0]) - int(geometry["x"])
        center_y = float(pip["center_px"][1]) - int(geometry["y"])
        item["center_px"] = [center_x, center_y]
        item["cx"] = center_x / max(width, 1)
        item["cy"] = center_y / max(height, 1)
        if "bbox" in pip:
            x, y, box_width, box_height = (int(value) for value in pip["bbox"])
            item["bbox"] = [
                x - int(geometry["x"]),
                y - int(geometry["y"]),
                box_width,
                box_height,
            ]
        translated.append(item)
    return translated


def infer_partial_card_in_scene(
    image: np.ndarray,
    *,
    corner_evidence: Mapping[str, Any] | None = None,
    pretrained_model: PretrainedModelAdapter | None = None,
    minimum_localization_confidence: float = 0.34,
) -> dict[str, Any]:
    """Locate card-like regions, then infer only inside the strongest ROI.

    All plausible surfaces remain available in ``scene_candidates``. The
    selected crop is based on both surface geometry and downstream pip-layout
    evidence so a bright rectangular background is not trusted on shape alone.
    """

    localization = localize_cards(
        image,
        max_candidates=5,
        minimum_confidence=minimum_localization_confidence,
    )
    candidates: list[dict[str, Any]] = []
    for candidate in localization["candidates"]:
        if candidate["score"] < minimum_localization_confidence:
            continue
        is_pip_cluster = candidate.get("source") == "pip_cluster"
        crop, geometry = crop_card_candidate(
            image,
            candidate,
            mask_background=not is_pip_cluster,
        )
        if is_pip_cluster:
            translated_pips = _pips_in_crop(candidate.get("pips", []), geometry)
            inference = infer_partial_card(
                crop,
                corner_evidence=corner_evidence,
                pretrained_model=pretrained_model,
                detected_pips=translated_pips,
                visible_region=_unknown_visible_region("card extent inferred from pip cluster"),
                suit_evidence=_suit_evidence_from_pips(translated_pips),
            )
        else:
            layout_pips = _layout_scale_pips(detect_pips(crop))
            inference = infer_partial_card(
                crop,
                corner_evidence=corner_evidence,
                pretrained_model=pretrained_model,
                detected_pips=layout_pips,
                visible_region=_localized_visible_region(candidate, geometry),
                suit_evidence=_suit_evidence_from_pips(layout_pips),
            )
        candidates.append(
            {
                "localization": candidate,
                "crop": geometry,
                "scene_score": _scene_candidate_score(candidate["score"], inference),
                "inference": inference,
            }
        )

    if not candidates:
        uniform_rank = 1.0 / len(RANKS)
        visible = _unknown_visible_region("no localized card surface")
        rank_candidates = {rank: uniform_rank for rank in RANKS}
        suit_candidates = {suit: 1.0 / len(SUITS) for suit in SUITS}
        model_evidence = _model_evidence(image, pretrained_model)
        result = {
            "rank": "unknown",
            "suit": "unknown",
            "confidence": 0.0,
            "candidates": [[rank, uniform_rank] for rank in RANKS],
            "evidence": {
                "suit": 0.0,
                "pip_layout": 0.0,
                "visible_region": "unknown",
                "visible_region_confidence": 1.0,
                "corner": dict(corner_evidence) if corner_evidence else None,
                "pretrained_model": model_evidence.as_dict(),
                "reasons": ["no card-like surface passed localization"],
            },
            "rank_candidates": rank_candidates,
            "suit_candidates": suit_candidates,
            "unknown": {"rank": 1.0, "suit": 1.0},
            "detections": {
                "pips": [],
                "visible_region": visible,
                "suit": {
                    "probabilities": {**suit_candidates, "unknown": 1.0},
                    "contours_used": 0,
                },
            },
        }
        result["localization"] = localization
        result["source_geometry"] = {
            "x": 0,
            "y": 0,
            "width": int(image.shape[1]),
            "height": int(image.shape[0]),
        }
        result["scene_candidates"] = []
        return result

    candidates.sort(key=lambda item: item["scene_score"], reverse=True)
    selected = candidates[0]
    result = selected["inference"]
    selected_source = selected["localization"].get("source", "surface")
    if selected_source == "pip_cluster":
        result["evidence"]["color_group"] = selected["localization"]["features"].get(
            "color", "unknown"
        )
    else:
        color_weights = {"red": 0.0, "black": 0.0}
        for pip in result["detections"]["pips"]:
            color = pip.get("color")
            if color in color_weights:
                color_weights[color] += float(pip.get("area", 1.0))
        if sum(color_weights.values()) > 0.0:
            result["evidence"]["color_group"] = max(color_weights, key=color_weights.get)
    if not result["detections"]["pips"]:
        result["rank"] = "unknown"
        result["suit"] = "unknown"
        result["confidence"] = 0.0
        result["evidence"]["reasons"] = ["localized surface has no usable pip evidence"]
    result["localization"] = localization
    result["source_geometry"] = selected["crop"]
    result["scene_score"] = selected["scene_score"]
    result["scene_candidates"] = [
        {
            "source": item["localization"].get("source", "surface"),
            "bbox": item["localization"]["bbox"],
            "localization_score": item["localization"]["score"],
            "scene_score": item["scene_score"],
            "rank": item["inference"]["rank"],
            "suit": item["inference"]["suit"],
            "rank_candidates": item["inference"]["rank_candidates"],
        }
        for item in candidates
    ]
    return result
