"""Rank A-10 by matching partial pip layouts under geometric transforms."""

from __future__ import annotations

from dataclasses import dataclass
from itertools import combinations
from math import atan2, cos, exp, sin
from typing import Any, Sequence

import cv2
import numpy as np

from src.rules.card_templates import CARD_TEMPLATES, CardTemplate

CARD_WIDTH_TO_HEIGHT = 2.5 / 3.5
MATCH_TOLERANCE = 0.055


@dataclass(frozen=True, slots=True)
class Observation:
    point: np.ndarray
    quality: float
    source_index: int


@dataclass(frozen=True, slots=True)
class Transform:
    matrix: np.ndarray
    kind: str
    plausibility: float = 1.0

    def apply(self, points: np.ndarray) -> np.ndarray:
        homogeneous = np.column_stack((points, np.ones(len(points), dtype=np.float64)))
        return homogeneous @ self.matrix.T


def _template_points(template: CardTemplate) -> np.ndarray:
    return np.array(
        [[pip.x * CARD_WIDTH_TO_HEIGHT, pip.y] for pip in template.pips],
        dtype=np.float64,
    )


def _coerce_observations(
    pips: Sequence[dict[str, Any] | Sequence[float]],
    image_shape: Sequence[int] | None,
) -> tuple[list[Observation], tuple[float, float]]:
    if image_shape is not None:
        image_height, image_width = int(image_shape[0]), int(image_shape[1])
        coordinate_scale = float(max(image_height, image_width))
        viewport = (image_width / coordinate_scale, image_height / coordinate_scale)
    else:
        image_height = image_width = 1
        coordinate_scale = 1.0
        viewport = (1.0, 1.0)

    observations: list[Observation] = []
    for index, pip in enumerate(pips):
        if isinstance(pip, dict):
            if image_shape is not None and "center_px" in pip:
                x = float(pip["center_px"][0]) / coordinate_scale
                y = float(pip["center_px"][1]) / coordinate_scale
            else:
                x = float(pip["cx"]) * viewport[0]
                y = float(pip["cy"]) * viewport[1]
            quality = float(np.clip(pip.get("shape_score", 0.72), 0.05, 1.0))
        else:
            x, y = float(pip[0]), float(pip[1])
            quality = 0.75
        if np.isfinite(x) and np.isfinite(y):
            observations.append(Observation(np.array((x, y), dtype=np.float64), quality, index))

    observations.sort(key=lambda observation: observation.quality, reverse=True)
    return observations[:14], viewport


def _similarity_transform(
    source_a: np.ndarray,
    source_b: np.ndarray,
    target_a: np.ndarray,
    target_b: np.ndarray,
) -> Transform | None:
    source_delta = source_b - source_a
    target_delta = target_b - target_a
    source_length = float(np.linalg.norm(source_delta))
    target_length = float(np.linalg.norm(target_delta))
    if source_length < 0.045 or target_length < 0.025:
        return None
    scale = target_length / source_length
    if not 0.16 <= scale <= 6.0:
        return None
    angle = atan2(target_delta[1], target_delta[0]) - atan2(source_delta[1], source_delta[0])
    linear = scale * np.array([[cos(angle), -sin(angle)], [sin(angle), cos(angle)]])
    translation = target_a - linear @ source_a
    matrix = np.column_stack((linear, translation))
    scale_plausibility = exp(-0.08 * abs(np.log(max(scale, 1e-6))))
    return Transform(matrix=matrix, kind="similarity", plausibility=scale_plausibility)


def _single_point_transforms(source: np.ndarray, target: np.ndarray) -> list[Transform]:
    transforms: list[Transform] = []
    for scale in (0.55, 0.85, 1.15, 1.65, 2.4):
        for angle_degrees in (0.0, 15.0, -15.0, 90.0, 180.0, 270.0):
            angle = np.radians(angle_degrees)
            linear = scale * np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]])
            translation = target - linear @ source
            transforms.append(
                Transform(
                    matrix=np.column_stack((linear, translation)),
                    kind="single_point",
                    plausibility=0.52,
                )
            )
    return transforms


def _greedy_assignment(
    observed: np.ndarray,
    transformed_template: np.ndarray,
    tolerance: float,
) -> list[tuple[int, int, float]]:
    distances = np.linalg.norm(observed[:, None, :] - transformed_template[None, :, :], axis=2)
    pairs: list[tuple[int, int, float]] = []
    used_observed: set[int] = set()
    used_template: set[int] = set()
    for flat_index in np.argsort(distances, axis=None):
        observed_index, template_index = np.unravel_index(flat_index, distances.shape)
        distance = float(distances[observed_index, template_index])
        if distance > tolerance:
            break
        if observed_index in used_observed or template_index in used_template:
            continue
        used_observed.add(observed_index)
        used_template.add(template_index)
        pairs.append((observed_index, template_index, distance))
    return pairs


def _region_contains(region: str, pip_x: float, pip_y: float) -> bool:
    if region == "full" or region == "unknown":
        return True
    if region == "center":
        return 0.23 <= pip_x <= 0.77 and 0.23 <= pip_y <= 0.77
    horizontal_ok = True
    vertical_ok = True
    if "left" in region:
        horizontal_ok = pip_x <= 0.60
    elif "right" in region:
        horizontal_ok = pip_x >= 0.40
    if "top" in region:
        vertical_ok = pip_y <= 0.60
    elif "bottom" in region:
        vertical_ok = pip_y >= 0.40
    return horizontal_ok and vertical_ok


def _dominant_region(visible_region: dict[str, Any] | None) -> tuple[str, float, float]:
    if not visible_region:
        return "unknown", 0.0, 0.0
    probabilities = visible_region.get("probabilities", {})
    region = str(visible_region.get("region", "unknown"))
    confidence = float(visible_region.get("confidence", probabilities.get(region, 0.0)))
    full_probability = float(probabilities.get("full", confidence if region == "full" else 0.0))
    return region, confidence, full_probability


def _symmetry_score(template: CardTemplate, matched_template: set[int], visible_template: set[int]) -> float:
    coordinate_to_index = {
        (round(pip.x, 3), round(pip.y, 3)): index for index, pip in enumerate(template.pips)
    }
    pairs: list[tuple[int, int]] = []
    for index, pip in enumerate(template.pips):
        mirror = coordinate_to_index.get((round(1.0 - pip.x, 3), round(pip.y, 3)))
        if mirror is not None and index < mirror:
            pairs.append((index, mirror))
    relevant = [(left, right) for left, right in pairs if left in visible_template and right in visible_template]
    if not relevant:
        return 0.60
    complete = sum(left in matched_template and right in matched_template for left, right in relevant)
    partial = sum((left in matched_template) != (right in matched_template) for left, right in relevant)
    return float(np.clip((complete + 0.35 * partial) / len(relevant), 0.0, 1.0))


def _score_transform(
    template: CardTemplate,
    template_points: np.ndarray,
    observations: list[Observation],
    viewport: tuple[float, float],
    transform: Transform,
    visible_region: dict[str, Any] | None,
) -> dict[str, Any]:
    observed = np.array([observation.point for observation in observations])
    transformed = transform.apply(template_points)
    tolerance = MATCH_TOLERANCE
    pairs = _greedy_assignment(observed, transformed, tolerance)
    matched_observed = {pair[0] for pair in pairs}
    matched_template = {pair[1] for pair in pairs}
    qualities = np.array([observation.quality for observation in observations])
    total_quality = max(float(qualities.sum()), 1e-8)
    matched_quality = sum(qualities[index] for index in matched_observed)

    margin = tolerance * 0.40
    visible_template = {
        index
        for index, point in enumerate(transformed)
        if -margin <= point[0] <= viewport[0] + margin and -margin <= point[1] <= viewport[1] + margin
    }
    region, region_confidence, full_probability = _dominant_region(visible_region)
    crop_missing = len(visible_template - matched_template)
    all_missing = template.count - len(matched_template)
    effective_missing = (1.0 - full_probability) * crop_missing + full_probability * all_missing
    expected_visible = (1.0 - full_probability) * len(visible_template) + full_probability * template.count

    observation_coverage = matched_quality / total_quality
    unexpected_score = exp(-1.15 * (len(observations) - len(matched_observed)))
    distance_score = (
        float(np.mean([exp(-((distance / tolerance) ** 2)) for _, _, distance in pairs]))
        if pairs
        else 0.0
    )
    visible_coverage = float(np.clip(1.0 - effective_missing / max(expected_visible, 1.0), 0.0, 1.0))
    count_score = exp(-abs(len(observations) - expected_visible) / max(1.25, expected_visible * 0.48))
    support_score = min(1.0, len(pairs) / 3.0)

    matched_roles = {template.pips[index].role for index in matched_template}
    center_matched = "center" in matched_roles
    middle_matched = any("middle" in role or "center" in role for role in matched_roles)
    center_score = 0.70
    if template.has_center:
        center_score = 1.0 if center_matched else (0.45 if crop_missing else 0.20)
    elif center_matched:
        center_score = 0.0
    middle_score = 1.0 if middle_matched else (0.58 if len(pairs) >= 2 else 0.35)
    symmetry_score = _symmetry_score(template, matched_template, visible_template)

    if region_confidence > 0.0 and region not in {"unknown", "full"} and matched_template:
        compatible = sum(
            _region_contains(region, template.pips[index].x, template.pips[index].y)
            for index in matched_template
        ) / len(matched_template)
        region_score = (1.0 - region_confidence) * 0.65 + region_confidence * compatible
    else:
        region_score = 0.70

    raw_score = (
        0.22 * observation_coverage
        + 0.12 * unexpected_score
        + 0.15 * distance_score
        + 0.16 * visible_coverage
        + 0.08 * count_score
        + 0.08 * support_score
        + 0.055 * center_score
        + 0.035 * middle_score
        + 0.055 * symmetry_score
        + 0.055 * region_score
    ) * transform.plausibility

    return {
        "raw_score": float(np.clip(raw_score, 0.0, 1.0)),
        "matched_count": len(pairs),
        "observed_count": len(observations),
        "expected_visible_count": float(expected_visible),
        "missing_visible_count": float(effective_missing),
        "unexpected_count": len(observations) - len(matched_observed),
        "mean_match_distance": float(np.mean([pair[2] for pair in pairs])) if pairs else None,
        "matched_pairs": pairs,
        "components": {
            "distance": distance_score,
            "observed_coverage": observation_coverage,
            "unexpected_positions": unexpected_score,
            "crop_explained_missing": visible_coverage,
            "count": count_score,
            "center": center_score,
            "middle_positions": middle_score,
            "left_right_symmetry": symmetry_score,
            "visible_region": region_score,
        },
        "transform": {
            "kind": transform.kind,
            "matrix": transform.matrix.tolist(),
            "plausibility": transform.plausibility,
        },
    }


def _affine_refinement(
    template_points: np.ndarray,
    observations: list[Observation],
    score: dict[str, Any],
) -> Transform | None:
    pairs = score["matched_pairs"]
    if len(pairs) < 3:
        return None
    source = np.float32([template_points[template_index] for _, template_index, _ in pairs])
    target = np.float32([observations[observed_index].point for observed_index, _, _ in pairs])
    matrix, inliers = cv2.estimateAffine2D(
        source,
        target,
        method=cv2.RANSAC,
        ransacReprojThreshold=MATCH_TOLERANCE * 0.8,
        maxIters=800,
        confidence=0.97,
        refineIters=10,
    )
    if (
        matrix is None
        or inliers is None
        or int(inliers.sum()) < 3
        or not np.all(np.isfinite(matrix))
    ):
        return None
    singular_values = np.linalg.svd(matrix[:, :2], compute_uv=False)
    if singular_values[-1] < 1e-6:
        return None
    anisotropy = float(singular_values[0] / singular_values[-1])
    if anisotropy > 2.0:
        return None
    plausibility = exp(-0.38 * (anisotropy - 1.0)) * 0.98
    return Transform(matrix=np.asarray(matrix, dtype=np.float64), kind="affine_ransac", plausibility=plausibility)


def _best_template_score(
    template: CardTemplate,
    observations: list[Observation],
    viewport: tuple[float, float],
    visible_region: dict[str, Any] | None,
) -> dict[str, Any]:
    template_points = _template_points(template)
    observed_points = [observation.point for observation in observations]
    transforms: list[Transform] = []

    if len(observations) >= 2:
        for template_a, template_b in combinations(range(template.count), 2):
            for observed_a, observed_b in combinations(range(len(observations)), 2):
                direct = _similarity_transform(
                    template_points[template_a],
                    template_points[template_b],
                    observed_points[observed_a],
                    observed_points[observed_b],
                )
                reverse = _similarity_transform(
                    template_points[template_a],
                    template_points[template_b],
                    observed_points[observed_b],
                    observed_points[observed_a],
                )
                if direct is not None:
                    transforms.append(direct)
                if reverse is not None:
                    transforms.append(reverse)
    elif observations:
        for template_point in template_points:
            transforms.extend(_single_point_transforms(template_point, observed_points[0]))

    if not transforms:
        return {
            "raw_score": 0.0,
            "matched_count": 0,
            "observed_count": len(observations),
            "expected_visible_count": 0.0,
            "missing_visible_count": 0.0,
            "unexpected_count": len(observations),
            "mean_match_distance": None,
            "matched_pairs": [],
            "components": {},
            "transform": None,
        }

    scored = [
        _score_transform(template, template_points, observations, viewport, transform, visible_region)
        for transform in transforms
    ]
    top_similarity = sorted(scored, key=lambda item: item["raw_score"], reverse=True)[:8]
    for score in top_similarity:
        refined = _affine_refinement(template_points, observations, score)
        if refined is not None:
            scored.append(
                _score_transform(template, template_points, observations, viewport, refined, visible_region)
            )
    return max(scored, key=lambda item: item["raw_score"])


def _candidate_explanation(rank: str, score: dict[str, Any]) -> list[str]:
    components = score["components"]
    reasons = [
        f"matched {score['matched_count']}/{score['observed_count']} observed pips",
    ]
    if score["missing_visible_count"] < 0.05:
        reasons.append("no expected visible pips are missing")
    elif score["missing_visible_count"] < 0.55:
        reasons.append("missing template pips are explained by crop/visibility")
    elif score["missing_visible_count"] > 1.45:
        reasons.append(f"{score['missing_visible_count']:.1f} expected visible pips are missing")
    if components.get("center", 0.0) > 0.9:
        reasons.append("center-pip structure is compatible")
    if components.get("left_right_symmetry", 0.0) > 0.85:
        reasons.append("left/right structure is compatible")
    if score["unexpected_count"]:
        reasons.append(f"{score['unexpected_count']} observation(s) fall outside rank {rank}")
    return reasons


def infer_partial_rank(
    pips: Sequence[dict[str, Any] | Sequence[float]],
    visible_region: dict[str, Any] | None = None,
    *,
    image_shape: Sequence[int] | None = None,
) -> dict[str, Any]:
    """Rank every A-10 template and retain ambiguity/unknown evidence."""

    observations, viewport = _coerce_observations(pips, image_shape)
    scores: list[dict[str, Any]] = []
    for rank, template in CARD_TEMPLATES.items():
        score = _best_template_score(template, observations, viewport, visible_region)
        score["rank"] = rank
        scores.append(score)

    if not observations:
        uniform = 1.0 / len(scores)
        candidates = [
            {
                "rank": score["rank"],
                "probability": uniform,
                "raw_score": 0.0,
                "explanation": ["no pip observations"],
                "details": score,
            }
            for score in scores
        ]
        return {
            "rank": "unknown",
            "confidence": 0.0,
            "unknown_probability": 1.0,
            "observed_pips": 0,
            "candidates": candidates,
            "rank_candidates": {candidate["rank"]: candidate["probability"] for candidate in candidates},
        }

    maximum = max(score["raw_score"] for score in scores)
    temperature = 0.065 if len(observations) >= 4 else 0.085
    weights = [exp((score["raw_score"] - maximum) / temperature) for score in scores]
    total_weight = sum(weights)
    probabilities = [weight / total_weight for weight in weights]
    order = np.argsort(probabilities)[::-1]
    candidates: list[dict[str, Any]] = []
    for index in order:
        score = scores[int(index)]
        candidates.append(
            {
                "rank": score["rank"],
                "probability": float(probabilities[int(index)]),
                "raw_score": score["raw_score"],
                "explanation": _candidate_explanation(score["rank"], score),
                "details": score,
            }
        )

    best = candidates[0]
    second_probability = candidates[1]["probability"] if len(candidates) > 1 else 0.0
    ambiguity_margin = best["probability"] - second_probability
    support = min(1.0, len(observations) / 3.0)
    region, region_confidence, _ = _dominant_region(visible_region)
    single_full_ace = (
        len(observations) == 1
        and best["rank"] == "A"
        and region == "full"
        and region_confidence >= 0.65
        and best["details"]["missing_visible_count"] < 0.1
    )
    if single_full_ace:
        support = 0.75
    confidence = float(
        np.clip(
            support
            * (0.52 * best["raw_score"] + 0.30 * best["probability"] + 0.18 * min(1.0, ambiguity_margin * 4.0)),
            0.0,
            1.0,
        )
    )
    unknown_probability = float(np.clip(1.0 - support * best["raw_score"], 0.02, 0.96))
    resolved_rank = best["rank"]
    if not single_full_ace and (
        confidence < 0.34 or (len(observations) < 3 and best["probability"] < 0.42)
    ):
        resolved_rank = "unknown"

    return {
        "rank": resolved_rank,
        "confidence": confidence,
        "unknown_probability": unknown_probability,
        "observed_pips": len(observations),
        "candidates": candidates,
        "rank_candidates": {candidate["rank"]: candidate["probability"] for candidate in candidates},
    }
