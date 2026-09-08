"""Permissive traditional-vision detector for visible suit pips."""

from __future__ import annotations

from math import exp, log
from typing import Any

import cv2
import numpy as np

from .suit_detector import SUITS, build_ink_masks, classify_suit_contour


def _split_projection(component: np.ndarray) -> list[tuple[int, int, int, int]]:
    """Split a lightly joined component at a strong internal projection valley."""

    height, width = component.shape
    horizontal = width > height * 1.65
    vertical = height > width * 1.9
    if not horizontal and not vertical:
        return [(0, 0, width, height)]

    projection = np.count_nonzero(component, axis=0 if horizontal else 1).astype(np.float32)
    if len(projection) < 12:
        return [(0, 0, width, height)]
    projection = np.convolve(projection, np.ones(5, dtype=np.float32) / 5.0, mode="same")
    low = len(projection) // 4
    high = len(projection) * 3 // 4
    split = low + int(np.argmin(projection[low:high]))
    left_peak = float(np.max(projection[:split])) if split else 0.0
    right_peak = float(np.max(projection[split:])) if split < len(projection) else 0.0
    if projection[split] > 0.48 * min(left_peak, right_peak):
        return [(0, 0, width, height)]

    if horizontal:
        return [(0, 0, split, height), (split, 0, width - split, height)]
    return [(0, 0, width, split), (0, split, width, height - split)]


def _shape_score(contour: np.ndarray) -> float:
    area = float(cv2.contourArea(contour))
    perimeter = float(cv2.arcLength(contour, True))
    if area <= 0.0 or perimeter <= 0.0:
        return 0.0
    x, y, width, height = cv2.boundingRect(contour)
    hull_area = max(float(cv2.contourArea(cv2.convexHull(contour))), area)
    solidity = area / hull_area
    circularity = min(1.0, 4.0 * np.pi * area / (perimeter * perimeter) / 0.72)
    aspect = max(width, height) / max(1.0, min(width, height))
    aspect_score = exp(-0.72 * abs(log(aspect)))
    extent = min(1.0, area / max(float(width * height), 1.0) / 0.52)
    return float(np.clip(0.30 * solidity + 0.24 * circularity + 0.24 * aspect_score + 0.22 * extent, 0.0, 1.0))


def _contour_from_component(component: np.ndarray, offset_x: int, offset_y: int) -> np.ndarray | None:
    contours, _ = cv2.findContours(component, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    contour = max(contours, key=cv2.contourArea).copy()
    contour[:, 0, 0] += offset_x
    contour[:, 0, 1] += offset_y
    return contour


def _deduplicate(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    retained: list[dict[str, Any]] = []
    for candidate in sorted(candidates, key=lambda item: (item["shape_score"], item["area"]), reverse=True):
        cx, cy = candidate["cx"], candidate["cy"]
        if any((cx - other["cx"]) ** 2 + (cy - other["cy"]) ** 2 < 0.00045 for other in retained):
            continue
        retained.append(candidate)
    return sorted(retained[:18], key=lambda item: (item["cy"], item["cx"]))


def detect_pips(image: np.ndarray) -> list[dict[str, Any]]:
    """Detect possible pip centers without assuming the card's true rank.

    Centers are normalized to the supplied image. Area is kept in pixels and as
    an image ratio so callers can draw diagnostics without losing scale.
    """

    red_mask, dark_mask = build_ink_masks(image)
    combined = cv2.bitwise_or(red_mask, dark_mask)
    height, width = combined.shape
    image_area = float(width * height)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(combined, connectivity=8)
    candidates: list[dict[str, Any]] = []

    for label in range(1, count):
        x, y, component_width, component_height, pixel_area = [int(value) for value in stats[label]]
        if pixel_area < max(12, int(image_area * 0.00005)) or pixel_area > image_area * 0.10:
            continue
        component = np.where(labels[y : y + component_height, x : x + component_width] == label, 255, 0).astype(np.uint8)
        sections = _split_projection(component)
        merged = len(sections) > 1

        for section_x, section_y, section_width, section_height in sections:
            if section_width < 3 or section_height < 3:
                continue
            section = component[
                section_y : section_y + section_height,
                section_x : section_x + section_width,
            ]
            section_area = int(cv2.countNonZero(section))
            if section_area < max(10, int(image_area * 0.00004)):
                continue
            absolute_x, absolute_y = x + section_x, y + section_y
            contour = _contour_from_component(section, absolute_x, absolute_y)
            if contour is None:
                continue
            contour_area = float(cv2.contourArea(contour))
            extent = contour_area / max(float(section_width * section_height), 1.0)
            score = _shape_score(contour)
            if extent < 0.10 or score < 0.28:
                continue

            section_mask = np.zeros_like(combined)
            cv2.drawContours(section_mask, [contour], -1, 255, -1)
            red_pixels = cv2.countNonZero(cv2.bitwise_and(red_mask, section_mask))
            filled_pixels = max(cv2.countNonZero(section_mask), 1)
            color_group = "red" if red_pixels / filled_pixels > 0.16 else "black"
            suit_scores = classify_suit_contour(contour, color_group)
            suit, suit_score = max(suit_scores.items(), key=lambda item: item[1])
            if suit_score < 0.36:
                suit = "unknown"

            moments = cv2.moments(contour)
            if abs(moments["m00"]) > 1e-8:
                center_x = moments["m10"] / moments["m00"]
                center_y = moments["m01"] / moments["m00"]
            else:
                center_x = absolute_x + section_width / 2.0
                center_y = absolute_y + section_height / 2.0

            candidates.append(
                {
                    "cx": float(center_x / width),
                    "cy": float(center_y / height),
                    "center_px": [float(center_x), float(center_y)],
                    "area": section_area,
                    "area_ratio": float(section_area / image_area),
                    "shape_score": score,
                    "suit_guess": suit if suit in SUITS else "unknown",
                    "suit_scores": suit_scores,
                    "color": color_group,
                    "bbox": [absolute_x, absolute_y, section_width, section_height],
                    "merged_component": merged,
                }
            )
    return _deduplicate(candidates)

