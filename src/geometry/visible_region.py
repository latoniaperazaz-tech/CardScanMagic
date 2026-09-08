"""Estimate which normalized portion of a playing card is visible."""

from __future__ import annotations

from typing import Any

import cv2
import numpy as np

REGIONS = (
    "top",
    "bottom",
    "left",
    "right",
    "center",
    "top_left",
    "top_right",
    "bottom_left",
    "bottom_right",
    "full",
    "unknown",
)


def _normalize(values: dict[str, float]) -> dict[str, float]:
    total = sum(max(0.0, value) for value in values.values())
    if total <= 0.0:
        return {region: 1.0 if region == "unknown" else 0.0 for region in REGIONS}
    return {region: max(0.0, values.get(region, 0.0)) / total for region in REGIONS}


def _base_probabilities() -> dict[str, float]:
    return {region: 0.0 for region in REGIONS}


def _card_mask(image: np.ndarray) -> np.ndarray:
    bgr = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR) if image.ndim == 2 else image
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    saturation, value = hsv[:, :, 1], hsv[:, :, 2]
    value_floor = int(np.clip(np.percentile(value, 58), 125, 215))
    mask = np.where((saturation < 78) & (value >= value_floor), 255, 0).astype(np.uint8)
    scale = max(1, int(round(min(mask.shape) / 280)))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (4 * scale + 1, 4 * scale + 1))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    mask = cv2.morphologyEx(
        mask,
        cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (2 * scale + 1, 2 * scale + 1)),
    )
    return mask


def _long_lines(image: np.ndarray) -> list[list[int]]:
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if image.ndim == 3 else image
    edges = cv2.Canny(cv2.GaussianBlur(gray, (5, 5), 0), 45, 135)
    minimum = max(24, int(min(gray.shape) * 0.28))
    raw = cv2.HoughLinesP(
        edges,
        1,
        np.pi / 180.0,
        threshold=max(20, minimum // 3),
        minLineLength=minimum,
        maxLineGap=max(8, minimum // 7),
    )
    if raw is None:
        return []
    ranked = sorted(
        (line[0].tolist() for line in raw),
        key=lambda line: (line[2] - line[0]) ** 2 + (line[3] - line[1]) ** 2,
        reverse=True,
    )
    retained: list[list[int]] = []
    for line in ranked:
        angle = np.degrees(np.arctan2(line[3] - line[1], line[2] - line[0])) % 180.0
        midpoint = ((line[0] + line[2]) / 2.0, (line[1] + line[3]) / 2.0)
        duplicate = False
        for other in retained:
            other_angle = np.degrees(np.arctan2(other[3] - other[1], other[2] - other[0])) % 180.0
            other_midpoint = ((other[0] + other[2]) / 2.0, (other[1] + other[3]) / 2.0)
            angle_delta = abs(angle - other_angle)
            angle_delta = min(angle_delta, 180.0 - angle_delta)
            if angle_delta < 5.0 and np.hypot(
                midpoint[0] - other_midpoint[0], midpoint[1] - other_midpoint[1]
            ) < 10.0:
                duplicate = True
                break
        if not duplicate:
            retained.append(line)
        if len(retained) == 12:
            break
    return retained


def _region_from_touches(touches: dict[str, bool]) -> str | None:
    horizontal = (touches["left"], touches["right"])
    vertical = (touches["top"], touches["bottom"])
    lookup = {
        ((False, True), (False, False)): "left",
        ((True, False), (False, False)): "right",
        ((False, False), (False, True)): "top",
        ((False, False), (True, False)): "bottom",
        ((False, True), (False, True)): "top_left",
        ((True, False), (False, True)): "top_right",
        ((False, True), (True, False)): "bottom_left",
        ((True, False), (True, False)): "bottom_right",
    }
    return lookup.get((horizontal, vertical))


def estimate_visible_region(image: np.ndarray) -> dict[str, Any]:
    """Return visible-region hypotheses plus card edges usable by debug tools."""

    if image is None or not isinstance(image, np.ndarray) or image.size == 0:
        raise ValueError("image must be a non-empty NumPy array")
    height, width = image.shape[:2]
    image_area = float(width * height)
    mask = _card_mask(image)
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    lines = _long_lines(image)

    if not contours:
        probabilities = _base_probabilities()
        probabilities["unknown"] = 0.78
        probabilities["center"] = 0.12
        probabilities["full"] = 0.10
        return {
            "region": "unknown",
            "confidence": probabilities["unknown"],
            "probabilities": probabilities,
            "card_polygon": None,
            "card_bbox": None,
            "lines": lines,
            "visible_card_fraction": 0.0,
            "reason": "no reliable bright card surface",
        }

    contour = max(contours, key=cv2.contourArea)
    area = float(cv2.contourArea(contour))
    area_fraction = area / image_area
    x, y, box_width, box_height = cv2.boundingRect(contour)
    margin_x = max(3, int(width * 0.012))
    margin_y = max(3, int(height * 0.012))
    touches = {
        "left": x <= margin_x,
        "right": x + box_width >= width - margin_x,
        "top": y <= margin_y,
        "bottom": y + box_height >= height - margin_y,
    }

    perimeter = cv2.arcLength(contour, True)
    approximation = cv2.approxPolyDP(contour, 0.018 * perimeter, True)
    if 4 <= len(approximation) <= 8:
        polygon = approximation.reshape(-1, 2).astype(int).tolist()
    else:
        rotated_box = cv2.boxPoints(cv2.minAreaRect(contour))
        polygon = np.rint(rotated_box).astype(int).tolist()

    probabilities = _base_probabilities()
    touches_count = sum(touches.values())
    inferred = _region_from_touches(touches)
    boundary_support = min(1.0, len(lines) / 3.0)

    if area_fraction < 0.10:
        probabilities["unknown"] = 0.68
        probabilities["full"] = 0.17
        probabilities["center"] = 0.15
        reason = "bright region is too small to establish card crop"
    elif touches_count == 0:
        full_weight = 0.72 + 0.16 * boundary_support
        probabilities["full"] = full_weight
        probabilities["unknown"] = 0.18 - 0.08 * boundary_support
        probabilities["center"] = 1.0 - probabilities["full"] - probabilities["unknown"]
        reason = "card surface is bounded on all image sides"
    elif inferred is not None:
        probabilities[inferred] = 0.68 + 0.12 * boundary_support
        probabilities["unknown"] = 0.17 - 0.06 * boundary_support
        axis_fallback = "left" if "left" in inferred else "right" if "right" in inferred else "top" if "top" in inferred else "bottom"
        probabilities[axis_fallback] += 0.09
        probabilities["center"] += 0.06
        reason = f"card surface is clipped at {', '.join(side for side, hit in touches.items() if hit)} image boundary"
    else:
        # A uniformly bright image can be an interior card crop, but without a
        # physical edge its absolute location is unknowable.
        probabilities["unknown"] = 0.56
        probabilities["center"] = 0.27
        probabilities["full"] = 0.07
        remaining = 0.10 / 8.0
        for region in REGIONS[:4] + REGIONS[5:9]:
            probabilities[region] = remaining
        reason = "card fills the crop; no physical side identifies absolute region"

    probabilities = _normalize(probabilities)
    region = max(probabilities, key=probabilities.get)
    return {
        "region": region,
        "confidence": probabilities[region],
        "probabilities": probabilities,
        "card_polygon": polygon,
        "card_bbox": [x, y, box_width, box_height],
        "lines": lines,
        "visible_card_fraction": area_fraction,
        "touches_image_boundary": touches,
        "reason": reason,
    }
