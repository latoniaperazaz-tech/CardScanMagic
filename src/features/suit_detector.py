"""Traditional color-and-contour playing-card suit detector."""

from __future__ import annotations

from functools import lru_cache
from math import exp
from typing import Any

import cv2
import numpy as np

SUITS = ("diamond", "heart", "club", "spade")
RED_SUITS = frozenset(("diamond", "heart"))
BLACK_SUITS = frozenset(("club", "spade"))


def _validate_image(image: np.ndarray) -> None:
    if image is None or not isinstance(image, np.ndarray) or image.size == 0:
        raise ValueError("image must be a non-empty NumPy array")
    if image.ndim not in (2, 3):
        raise ValueError("image must be grayscale or BGR")


def build_ink_masks(image: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Return permissive red and dark ink masks.

    Multiple thresholds are intentionally combined. A blurred red pip may lose
    saturation at its boundary, while a black pip can become gray; the later
    contour filters remove broad background regions.
    """

    _validate_image(image)
    bgr = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR) if image.ndim == 2 else image
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)

    red_low = cv2.inRange(hsv, (0, 42, 28), (16, 255, 255))
    red_high = cv2.inRange(hsv, (164, 42, 28), (179, 255, 255))
    red_mask = cv2.bitwise_or(red_low, red_high)

    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    otsu_value, otsu_mask = cv2.threshold(
        blurred, 0, 255, cv2.THRESH_BINARY_INV | cv2.THRESH_OTSU
    )
    percentile_threshold = float(np.percentile(blurred, 32))
    dark_threshold = int(np.clip(max(otsu_value, percentile_threshold), 52, 155))
    _, dark_mask = cv2.threshold(blurred, dark_threshold, 255, cv2.THRESH_BINARY_INV)

    scale = max(1, int(round(min(gray.shape) / 320)))
    open_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * scale + 1,) * 2)
    close_width = 2 * scale + 3
    close_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (close_width, 2 * scale + 1))
    red_mask = cv2.morphologyEx(red_mask, cv2.MORPH_OPEN, open_kernel)
    dark_mask = cv2.morphologyEx(dark_mask, cv2.MORPH_OPEN, open_kernel)
    red_mask = cv2.morphologyEx(red_mask, cv2.MORPH_CLOSE, close_kernel)
    dark_mask = cv2.morphologyEx(dark_mask, cv2.MORPH_CLOSE, close_kernel)
    return red_mask, dark_mask


def _draw_reference_suit(suit: str, size: int = 128) -> np.ndarray:
    mask = np.zeros((size, size), dtype=np.uint8)
    center = size // 2

    if suit == "diamond":
        points = np.array(
            [[center, 12], [size - 20, center], [center, size - 12], [20, center]],
            dtype=np.int32,
        )
        cv2.fillConvexPoly(mask, points, 255)
    elif suit == "heart":
        radius = size // 5
        cv2.circle(mask, (center - radius, 43), radius, 255, -1)
        cv2.circle(mask, (center + radius, 43), radius, 255, -1)
        points = np.array([[18, 45], [size - 18, 45], [center, size - 10]], dtype=np.int32)
        cv2.fillConvexPoly(mask, points, 255)
    elif suit == "club":
        radius = size // 5
        cv2.circle(mask, (center, 32), radius, 255, -1)
        cv2.circle(mask, (center - 24, 60), radius, 255, -1)
        cv2.circle(mask, (center + 24, 60), radius, 255, -1)
        cv2.rectangle(mask, (center - 9, 60), (center + 9, 111), 255, -1)
        points = np.array([[center - 27, 114], [center + 27, 114], [center, 86]], dtype=np.int32)
        cv2.fillConvexPoly(mask, points, 255)
    elif suit == "spade":
        radius = size // 5
        cv2.circle(mask, (center - radius, 70), radius, 255, -1)
        cv2.circle(mask, (center + radius, 70), radius, 255, -1)
        points = np.array([[18, 70], [size - 18, 70], [center, 10]], dtype=np.int32)
        cv2.fillConvexPoly(mask, points, 255)
        cv2.rectangle(mask, (center - 8, 70), (center + 8, 111), 255, -1)
        foot = np.array([[center - 25, 114], [center + 25, 114], [center, 91]], dtype=np.int32)
        cv2.fillConvexPoly(mask, foot, 255)
    else:
        raise ValueError(f"Unknown suit {suit!r}")
    return mask


@lru_cache(maxsize=1)
def _reference_contours() -> dict[str, np.ndarray]:
    references: dict[str, np.ndarray] = {}
    for suit in SUITS:
        contours, _ = cv2.findContours(
            _draw_reference_suit(suit), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )
        references[suit] = max(contours, key=cv2.contourArea)
    return references


def _softmax(logits: dict[str, float]) -> dict[str, float]:
    maximum = max(logits.values())
    exponentials = {key: exp(value - maximum) for key, value in logits.items()}
    total = sum(exponentials.values())
    return {key: value / total for key, value in exponentials.items()}


def classify_suit_contour(
    contour: np.ndarray,
    color_group: str = "unknown",
) -> dict[str, float]:
    """Classify one contour using Hu-moment shape similarity and color."""

    if contour is None or len(contour) < 3:
        return {suit: 0.25 for suit in SUITS}

    distances: dict[str, float] = {}
    logits: dict[str, float] = {}
    for suit, reference in _reference_contours().items():
        distance = float(cv2.matchShapes(contour, reference, cv2.CONTOURS_MATCH_I1, 0.0))
        distances[suit] = distance
        logits[suit] = -3.2 * min(distance, 3.0)

    if color_group == "red":
        for suit in RED_SUITS:
            logits[suit] += 2.4
        for suit in BLACK_SUITS:
            logits[suit] -= 2.4
    elif color_group == "black":
        for suit in BLACK_SUITS:
            logits[suit] += 2.0
        for suit in RED_SUITS:
            logits[suit] -= 2.0

    perimeter = cv2.arcLength(contour, True)
    approximation = cv2.approxPolyDP(contour, 0.045 * perimeter, True) if perimeter else contour
    hull = cv2.convexHull(contour)
    area = max(float(cv2.contourArea(contour)), 1.0)
    solidity = area / max(float(cv2.contourArea(hull)), area)
    red_shape_gap = distances["heart"] - distances["diamond"]
    if (
        color_group == "red"
        and len(approximation) == 4
        and solidity > 0.985
        and red_shape_gap > 0.015
        and distances["diamond"] < 0.12
    ):
        logits["diamond"] += 1.0
    elif color_group == "red" and (
        solidity < 0.96
        or len(approximation) > 4
        or red_shape_gap < -0.025
    ):
        # The heart's upper notch makes it measurably non-convex even after a
        # modest motion blur. If that notch is lost, shape evidence remains
        # deliberately ambiguous rather than forcing heart or diamond.
        logits["heart"] += 0.85
    elif color_group == "red" and len(approximation) == 4 and solidity > 0.96:
        # A blurred heart can collapse to a convex quadrilateral. When Hu
        # moments cannot separate it from a diamond, flatten that tiny shape
        # difference and let the caller report red/unknown ambiguity.
        shared_shape = max(logits["diamond"], logits["heart"])
        logits["diamond"] = shared_shape
        logits["heart"] = shared_shape
    if solidity < 0.82:
        logits["heart"] += 0.15
        logits["club"] += 0.35
        logits["spade"] += 0.20
    return _softmax(logits)


def _candidate_contours(image: np.ndarray) -> list[tuple[np.ndarray, str, float]]:
    red_mask, dark_mask = build_ink_masks(image)
    combined = cv2.bitwise_or(red_mask, dark_mask)
    # Pips can be nested inside a dark table/background contour. RETR_LIST
    # keeps those inner contours; the geometric filters below discard the
    # enclosing background and card border.
    contours, _ = cv2.findContours(combined, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    image_area = float(image.shape[0] * image.shape[1])
    candidates: list[tuple[np.ndarray, str, float]] = []

    for contour in contours:
        area = float(cv2.contourArea(contour))
        if not max(10.0, image_area * 0.00006) <= area <= image_area * 0.09:
            continue
        x, y, width, height = cv2.boundingRect(contour)
        if width < 3 or height < 3:
            continue
        extent = area / max(float(width * height), 1.0)
        if extent < 0.10:
            continue

        contour_mask = np.zeros(combined.shape, dtype=np.uint8)
        cv2.drawContours(contour_mask, [contour], -1, 255, -1)
        colored = cv2.countNonZero(cv2.bitwise_and(red_mask, contour_mask))
        filled = max(cv2.countNonZero(contour_mask), 1)
        color_group = "red" if colored / filled > 0.16 else "black"
        candidates.append((contour, color_group, area))
    return sorted(candidates, key=lambda item: item[2], reverse=True)[:16]


def detect_suit(image: np.ndarray, *, return_details: bool = False) -> dict[str, Any]:
    """Return calibrated suit probabilities; ambiguity is assigned to unknown."""

    _validate_image(image)
    candidates = _candidate_contours(image)
    if not candidates:
        probabilities = {suit: 0.04 for suit in SUITS}
        probabilities["unknown"] = 0.84
        return {"probabilities": probabilities, "contours_used": 0} if return_details else probabilities

    accumulated = {suit: 0.0 for suit in SUITS}
    total_weight = 0.0
    contour_details: list[dict[str, Any]] = []
    largest_area = candidates[0][2]
    for contour, color_group, area in candidates:
        scores = classify_suit_contour(contour, color_group)
        weight = 0.35 + 0.65 * min(1.0, area / max(largest_area, 1.0))
        for suit in SUITS:
            accumulated[suit] += weight * scores[suit]
        total_weight += weight
        if return_details:
            contour_details.append(
                {
                    "color": color_group,
                    "area": area,
                    "scores": scores,
                    "bbox": list(cv2.boundingRect(contour)),
                }
            )

    averaged = {suit: value / total_weight for suit, value in accumulated.items()}
    ordered = sorted(averaged.values(), reverse=True)
    separation = ordered[0] - ordered[1]
    strength = min(1.0, len(candidates) / 2.0) * min(1.0, 0.55 + separation * 1.8)
    unknown = float(np.clip(0.50 * (1.0 - strength), 0.03, 0.50))
    suit_total = sum(averaged.values())
    probabilities = {
        suit: (1.0 - unknown) * averaged[suit] / suit_total for suit in SUITS
    }
    probabilities["unknown"] = unknown

    if return_details:
        return {
            "probabilities": probabilities,
            "contours_used": len(candidates),
            "contours": contour_details,
        }
    return probabilities
