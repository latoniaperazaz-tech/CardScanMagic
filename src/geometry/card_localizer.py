"""Locate a full or partially visible playing-card surface in a scene."""

from __future__ import annotations

from itertools import combinations
from math import exp, log
from typing import Any

import cv2
import numpy as np

from src.features.pip_detector import detect_pips

CARD_ASPECT_RATIO = 2.5 / 3.5


def _validate_image(image: np.ndarray) -> None:
    if image is None or not isinstance(image, np.ndarray) or image.size == 0:
        raise ValueError("image must be a non-empty NumPy array")
    if image.ndim not in (2, 3):
        raise ValueError("image must be grayscale or BGR")


def build_card_surface_mask(image: np.ndarray) -> np.ndarray:
    """Return bright, low-saturation surfaces that could be card stock."""

    _validate_image(image)
    bgr = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR) if image.ndim == 2 else image
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    saturation, value = hsv[:, :, 1], hsv[:, :, 2]
    value_floor = int(np.clip(np.percentile(value, 58), 125, 215))
    adaptive = (saturation < 82) & (value >= value_floor)
    neutral_bright = (saturation < 42) & (value >= max(112, value_floor - 24))
    mask = np.where(adaptive | neutral_bright, 255, 0).astype(np.uint8)

    scale = max(1, int(round(min(mask.shape) / 280)))
    close_kernel = cv2.getStructuringElement(
        cv2.MORPH_ELLIPSE,
        (4 * scale + 1, 4 * scale + 1),
    )
    open_kernel = cv2.getStructuringElement(
        cv2.MORPH_RECT,
        (2 * scale + 1, 2 * scale + 1),
    )
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, close_kernel)
    return cv2.morphologyEx(mask, cv2.MORPH_OPEN, open_kernel)


def _candidate_surface_masks(image: np.ndarray) -> list[np.ndarray]:
    """Build relaxed and strict masks so overlapping bright objects can split."""

    bgr = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR) if image.ndim == 2 else image
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    saturation, value = hsv[:, :, 1], hsv[:, :, 2]
    masks = [build_card_surface_mask(image)]
    scale = max(1, int(round(min(value.shape) / 280)))
    close_kernel = cv2.getStructuringElement(
        cv2.MORPH_ELLIPSE,
        (4 * scale + 1, 4 * scale + 1),
    )
    open_kernel = cv2.getStructuringElement(
        cv2.MORPH_RECT,
        (2 * scale + 1, 2 * scale + 1),
    )
    for threshold in (
        max(158, int(np.percentile(value, 66))),
        max(182, int(np.percentile(value, 76))),
    ):
        mask = np.where((saturation < 96) & (value >= threshold), 255, 0).astype(np.uint8)
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, close_kernel)
        masks.append(cv2.morphologyEx(mask, cv2.MORPH_OPEN, open_kernel))
    return masks


def _red_ink_mask(image: np.ndarray) -> np.ndarray:
    bgr = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR) if image.ndim == 2 else image
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    red = cv2.bitwise_or(
        cv2.inRange(hsv, (0, 58, 38), (14, 255, 255)),
        cv2.inRange(hsv, (166, 58, 38), (179, 255, 255)),
    )
    return cv2.morphologyEx(
        red,
        cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)),
    )


def _polygon_mask(shape: tuple[int, int], polygon: np.ndarray) -> np.ndarray:
    mask = np.zeros(shape, dtype=np.uint8)
    cv2.fillConvexPoly(mask, np.rint(polygon).astype(np.int32), 255)
    return mask


def _pip_like_component_count(
    image: np.ndarray,
    polygon_mask: np.ndarray,
    polygon_area: float,
    red_mask: np.ndarray,
) -> tuple[int, float, float]:
    bgr = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR) if image.ndim == 2 else image
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    inside = polygon_mask > 0
    if not np.any(inside):
        return 0, 0.0, 0.0

    local_gray = gray[inside]
    white_level = float(np.percentile(local_gray, 72))
    dark_threshold = int(np.clip(white_level - 42.0, 38, 165))
    dark = np.where(
        (gray <= dark_threshold) & (hsv[:, :, 1] < 125) & inside,
        255,
        0,
    ).astype(np.uint8)
    ink = cv2.bitwise_or(cv2.bitwise_and(red_mask, polygon_mask), dark)
    ink = cv2.morphologyEx(
        ink,
        cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)),
    )

    count, _, stats, _ = cv2.connectedComponentsWithStats(ink, connectivity=8)
    minimum = max(8, int(polygon_area * 0.00020))
    maximum = max(minimum + 1, int(polygon_area * 0.085))
    component_areas = [
        int(stats[label, cv2.CC_STAT_AREA])
        for label in range(1, count)
        if minimum <= int(stats[label, cv2.CC_STAT_AREA]) <= maximum
    ]
    red_density = cv2.countNonZero(cv2.bitwise_and(red_mask, polygon_mask)) / max(polygon_area, 1.0)
    ink_density = cv2.countNonZero(ink) / max(polygon_area, 1.0)
    return min(len(component_areas), 20), float(red_density), float(ink_density)


def _foreign_color_density(image: np.ndarray, polygon_mask: np.ndarray) -> float:
    """Measure saturated non-red colors, which are unusual on card stock."""

    bgr = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR) if image.ndim == 2 else image
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    hue, saturation, value = cv2.split(hsv)
    red_hue = (hue <= 18) | (hue >= 160)
    foreign = (saturation >= 65) & (value >= 45) & ~red_hue & (polygon_mask > 0)
    return float(np.count_nonzero(foreign) / max(cv2.countNonZero(polygon_mask), 1))


def _bbox_iou(first: list[int], second: list[int]) -> float:
    ax, ay, aw, ah = first
    bx, by, bw, bh = second
    x0, y0 = max(ax, bx), max(ay, by)
    x1, y1 = min(ax + aw, bx + bw), min(ay + ah, by + bh)
    intersection = max(0, x1 - x0) * max(0, y1 - y0)
    union = aw * ah + bw * bh - intersection
    return intersection / union if union > 0 else 0.0


def _score_contour(
    image: np.ndarray,
    surface_mask: np.ndarray,
    red_mask: np.ndarray,
    contour: np.ndarray,
) -> dict[str, Any] | None:
    height, width = surface_mask.shape
    image_area = float(height * width)
    area = float(cv2.contourArea(contour))
    if area < image_area * 0.010:
        return None

    rect = cv2.minAreaRect(contour)
    rect_width, rect_height = rect[1]
    if rect_width < 12 or rect_height < 12:
        return None
    rect_area = float(rect_width * rect_height)
    if rect_area <= 0.0:
        return None

    polygon = cv2.boxPoints(rect)
    polygon_mask = _polygon_mask((height, width), polygon)
    polygon_pixels = max(cv2.countNonZero(polygon_mask), 1)
    x, y, box_width, box_height = cv2.boundingRect(np.rint(polygon).astype(np.int32))
    x = max(0, x)
    y = max(0, y)
    box_width = min(width - x, box_width)
    box_height = min(height - y, box_height)
    if box_width <= 0 or box_height <= 0:
        return None

    hull_area = max(float(cv2.contourArea(cv2.convexHull(contour))), area)
    rectangularity = float(np.clip(area / rect_area, 0.0, 1.0))
    solidity = float(np.clip(area / hull_area, 0.0, 1.0))
    ratio = min(rect_width, rect_height) / max(rect_width, rect_height)
    aspect_score = exp(-((log(max(ratio, 1e-5) / CARD_ASPECT_RATIO) / 0.62) ** 2))
    surface_coverage = cv2.countNonZero(cv2.bitwise_and(surface_mask, polygon_mask)) / polygon_pixels
    area_fraction = min(1.0, rect_area / image_area)
    area_score = float(np.clip((area_fraction - 0.008) / 0.17, 0.0, 1.0))

    bgr = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR) if image.ndim == 2 else image
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    inside = polygon_mask > 0
    mean_value = float(np.mean(hsv[:, :, 2][inside])) / 255.0
    mean_saturation = float(np.mean(hsv[:, :, 1][inside])) / 255.0
    stock_score = float(np.clip(0.72 * mean_value + 0.28 * (1.0 - mean_saturation), 0.0, 1.0))

    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(cv2.GaussianBlur(gray, (5, 5), 0), 55, 150)
    edge_density = cv2.countNonZero(cv2.bitwise_and(edges, polygon_mask)) / polygon_pixels
    texture_score = exp(-max(0.0, edge_density - 0.045) * 8.0)
    pip_like_count, red_density, ink_density = _pip_like_component_count(
        image,
        polygon_mask,
        rect_area,
        red_mask,
    )
    foreign_color_density = _foreign_color_density(image, polygon_mask)
    ink_presence = 1.0 - exp(-max(0.0, ink_density - 0.004) / 0.035)
    red_ink_support = 1.0 - exp(-red_density / 0.025)
    ink_support = float(np.clip(max(red_ink_support, 0.65 * ink_presence), 0.0, 1.0))
    color_purity = exp(-7.0 * foreign_color_density)
    contamination_penalty = 0.5 + 0.5 * exp(
        -10.0 * max(0.0, foreign_color_density - 0.04)
    )

    touches = {
        "left": x <= max(2, int(width * 0.008)),
        "right": x + box_width >= width - max(2, int(width * 0.008)),
        "top": y <= max(2, int(height * 0.008)),
        "bottom": y + box_height >= height - max(2, int(height * 0.008)),
    }
    boundary_count = sum(touches.values())
    boundary_penalty = 1.0 if boundary_count <= 2 else 0.84

    geometry_score = (
        0.22 * aspect_score
        + 0.16 * rectangularity
        + 0.10 * solidity
        + 0.16 * surface_coverage
        + 0.15 * area_score
        + 0.11 * stock_score
        + 0.10 * texture_score
    )
    evidence_factor = 0.38 + 0.40 * ink_support + 0.22 * color_purity
    raw_score = boundary_penalty * geometry_score * evidence_factor * contamination_penalty
    confidence = float(np.clip((raw_score - 0.48) / 0.32, 0.0, 1.0))
    reasons: list[str] = []
    if aspect_score >= 0.72:
        reasons.append("card-like aspect ratio")
    if rectangularity >= 0.68 and solidity >= 0.80:
        reasons.append("solid rectangular bright surface")
    if ink_support >= 0.60:
        reasons.append(f"{pip_like_count} ink component(s) inside surface")
    if foreign_color_density >= 0.08:
        reasons.append("candidate contains saturated non-card colors")
    if boundary_count:
        reasons.append("candidate is partially clipped by image boundary")

    perimeter = cv2.arcLength(contour, True)
    surface_polygon = cv2.approxPolyDP(
        contour,
        max(1.0, 0.006 * perimeter),
        True,
    ).reshape(-1, 2)

    return {
        "source": "surface",
        "bbox": [int(x), int(y), int(box_width), int(box_height)],
        "polygon": np.rint(polygon).astype(int).tolist(),
        "surface_polygon": surface_polygon.astype(int).tolist(),
        "score": confidence,
        "raw_score": float(raw_score),
        "features": {
            "area_fraction": area_fraction,
            "aspect_ratio": float(ratio),
            "aspect_score": float(aspect_score),
            "rectangularity": rectangularity,
            "solidity": solidity,
            "surface_coverage": float(surface_coverage),
            "stock_score": stock_score,
            "edge_density": float(edge_density),
            "pip_like_components": pip_like_count,
            "red_ink_density": red_density,
            "ink_density": ink_density,
            "ink_support": ink_support,
            "foreign_color_density": foreign_color_density,
            "color_purity": float(color_purity),
            "contamination_penalty": float(contamination_penalty),
        },
        "touches_image_boundary": touches,
        "reasons": reasons,
    }


def _five_pip_layout_candidates(image: np.ndarray) -> list[dict[str, Any]]:
    """Return conservative card regions seeded by a four-around-one layout."""

    height, width = image.shape[:2]
    image_area = float(height * width)
    pips = detect_pips(image)
    candidates: list[dict[str, Any]] = []
    for color in ("red", "black"):
        colored = [pip for pip in pips if pip["color"] == color]
        if not colored:
            continue
        largest_area = max(float(pip["area"]) for pip in colored)
        minimum_area = max(image_area * 0.0005, largest_area * 0.05)
        strong = [
            pip
            for pip in colored
            if float(pip["area"]) >= minimum_area and float(pip["shape_score"]) >= 0.65
        ]
        if not 5 <= len(strong) <= 7:
            continue
        color_candidates: list[dict[str, Any]] = []
        for subset_tuple in combinations(strong, 5):
            subset = list(subset_tuple)
            points = np.float32([pip["center_px"] for pip in subset])
            hull = cv2.convexHull(points, returnPoints=False)
            if hull is None or len(hull) != 4:
                continue
            areas = np.array([float(pip["area"]) for pip in subset], dtype=np.float64)
            area_consistency = float(np.min(areas) / max(np.median(areas), 1.0))
            if area_consistency < 0.35:
                continue

            point_x, point_y, point_width, point_height = cv2.boundingRect(points)
            normalized_spans = (point_width / width, point_height / height)
            if max(normalized_spans) < 0.18 or min(normalized_spans) < 0.06:
                continue
            pad_x = max(
                int(round(point_width * 0.34)),
                max(int(pip["bbox"][2]) for pip in subset) // 2,
            )
            pad_y = max(
                int(round(point_height * 0.22)),
                max(int(pip["bbox"][3]) for pip in subset) // 2,
            )
            x0 = max(0, point_x - pad_x)
            y0 = max(0, point_y - pad_y)
            x1 = min(width, point_x + point_width + pad_x)
            y1 = min(height, point_y + point_height + pad_y)
            if x1 <= x0 or y1 <= y0:
                continue
            polygon = [[x0, y0], [x1 - 1, y0], [x1 - 1, y1 - 1], [x0, y1 - 1]]
            mean_shape = float(np.mean([pip["shape_score"] for pip in subset]))
            confidence = float(
                np.clip(0.72 + 0.12 * area_consistency + 0.08 * mean_shape, 0.0, 0.94)
            )
            color_candidates.append({
                "source": "pip_cluster",
                "bbox": [x0, y0, x1 - x0, y1 - y0],
                "polygon": polygon,
                "surface_polygon": polygon,
                "score": confidence,
                "raw_score": confidence,
                "features": {
                    "pip_like_components": 5,
                    "pip_area_consistency": area_consistency,
                    "mean_pip_shape_score": mean_shape,
                    "color": color,
                    "foreign_color_density": 0.0,
                },
                "touches_image_boundary": {
                    "left": x0 == 0,
                    "right": x1 == width,
                    "top": y0 == 0,
                    "bottom": y1 == height,
                },
                "reasons": [
                    "five similarly sized same-color ink components",
                    "four-point hull surrounds one interior component",
                ],
                "pips": subset,
            })
        if color_candidates:
            candidates.append(max(color_candidates, key=lambda candidate: candidate["score"]))
    return candidates


def localize_cards(
    image: np.ndarray,
    *,
    max_candidates: int = 3,
    minimum_confidence: float = 0.42,
) -> dict[str, Any]:
    """Find probable card surfaces and keep ambiguity as ranked candidates."""

    _validate_image(image)
    red_mask = _red_ink_mask(image)
    scored: list[dict[str, Any]] = []
    for surface_mask in _candidate_surface_masks(image):
        contours, _ = cv2.findContours(surface_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        scored.extend(
            candidate
            for contour in contours
            if (candidate := _score_contour(image, surface_mask, red_mask, contour)) is not None
        )
    scored.extend(_five_pip_layout_candidates(image))
    retained: list[dict[str, Any]] = []
    for candidate in sorted(scored, key=lambda item: item["score"], reverse=True):
        if any(
            candidate.get("source") == other.get("source")
            and _bbox_iou(candidate["bbox"], other["bbox"]) > 0.68
            for other in retained
        ):
            continue
        retained.append(candidate)
        if len(retained) >= max(1, max_candidates):
            break

    accepted = [candidate for candidate in retained if candidate["score"] >= minimum_confidence]
    return {
        "found": bool(accepted),
        "confidence": accepted[0]["score"] if accepted else 0.0,
        "best": accepted[0] if accepted else None,
        "candidates": retained,
        "reason": (
            "card-like surface found"
            if accepted
            else "no candidate passed the card-surface confidence threshold"
        ),
    }


def crop_card_candidate(
    image: np.ndarray,
    candidate: dict[str, Any],
    *,
    padding: float = 0.025,
    mask_background: bool = False,
) -> tuple[np.ndarray, dict[str, int]]:
    """Crop an axis-aligned working ROI around a localized candidate."""

    _validate_image(image)
    x, y, width, height = (int(value) for value in candidate["bbox"])
    pad_x = int(round(width * max(0.0, padding)))
    pad_y = int(round(height * max(0.0, padding)))
    x0 = max(0, x - pad_x)
    y0 = max(0, y - pad_y)
    x1 = min(image.shape[1], x + width + pad_x)
    y1 = min(image.shape[0], y + height + pad_y)
    if x1 <= x0 or y1 <= y0:
        raise ValueError("candidate bounding box does not overlap the image")
    crop = image[y0:y1, x0:x1].copy()
    if mask_background:
        if candidate.get("source") == "pip_cluster":
            isolated = np.full_like(crop, 255)
            for pip in candidate.get("pips", []):
                pip_x, pip_y, pip_width, pip_height = (int(value) for value in pip["bbox"])
                margin = max(3, int(round(max(pip_width, pip_height) * 0.06)))
                source_x0 = max(x0, pip_x - margin)
                source_y0 = max(y0, pip_y - margin)
                source_x1 = min(x1, pip_x + pip_width + margin)
                source_y1 = min(y1, pip_y + pip_height + margin)
                isolated[
                    source_y0 - y0 : source_y1 - y0,
                    source_x0 - x0 : source_x1 - x0,
                ] = image[source_y0:source_y1, source_x0:source_x1]
            crop = isolated
        else:
            polygon = candidate.get("surface_polygon") or candidate.get("polygon")
            if not polygon or len(polygon) < 3:
                polygon = None
        if candidate.get("source") != "pip_cluster" and polygon is not None:
            local_polygon = np.asarray(polygon, dtype=np.int32) - np.array(
                [x0, y0], dtype=np.int32
            )
            mask = np.zeros(crop.shape[:2], dtype=np.uint8)
            cv2.fillPoly(mask, [local_polygon], 255)
            expansion = max(1, int(round(min(crop.shape[:2]) * 0.006)))
            mask = cv2.dilate(
                mask,
                cv2.getStructuringElement(
                    cv2.MORPH_ELLIPSE,
                    (2 * expansion + 1, 2 * expansion + 1),
                ),
            )
            crop[mask == 0] = 255
    return crop, {
        "x": x0,
        "y": y0,
        "width": x1 - x0,
        "height": y1 - y0,
    }
