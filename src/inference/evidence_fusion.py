"""Fuse classical and optional model evidence without forcing a card label."""

from __future__ import annotations

from math import exp, log, sqrt
from typing import Any, Mapping

import numpy as np

from src.adapters.pretrained_model import ModelEvidence, PretrainedModelAdapter, UnavailablePretrainedModel
from src.features.pip_detector import detect_pips
from src.features.suit_detector import SUITS, detect_suit
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
) -> dict[str, Any]:
    """Run the complete MVP and return evidence, candidates, and unknowns."""

    if image is None or not isinstance(image, np.ndarray) or image.size == 0:
        raise ValueError("image must be a non-empty NumPy array")

    visible = estimate_visible_region(image)
    pips = detect_pips(image)
    suit_details = detect_suit(image, return_details=True)
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
    if best_suit_probability < 0.50 or suit_unknown >= best_suit_probability:
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
