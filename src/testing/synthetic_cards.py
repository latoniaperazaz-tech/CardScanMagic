"""Small deterministic card renderer used by tests and debug experiments."""

from __future__ import annotations

import cv2
import numpy as np

from src.rules.card_templates import get_template


def _symbol_mask(suit: str, size: int) -> np.ndarray:
    size = max(18, int(size))
    mask = np.zeros((size, size), dtype=np.uint8)
    c = size // 2
    if suit == "diamond":
        cv2.fillConvexPoly(
            mask,
            np.array([[c, 1], [size - 2, c], [c, size - 2], [1, c]], dtype=np.int32),
            255,
        )
    elif suit == "heart":
        radius = max(2, size // 5)
        cv2.circle(mask, (c - radius, size // 3), radius, 255, -1)
        cv2.circle(mask, (c + radius, size // 3), radius, 255, -1)
        cv2.fillConvexPoly(
            mask,
            np.array([[2, size // 3], [size - 2, size // 3], [c, size - 2]], dtype=np.int32),
            255,
        )
    elif suit == "club":
        radius = max(2, size // 5)
        cv2.circle(mask, (c, size // 4), radius, 255, -1)
        cv2.circle(mask, (c - size // 5, c), radius, 255, -1)
        cv2.circle(mask, (c + size // 5, c), radius, 255, -1)
        cv2.rectangle(mask, (c - size // 14, c), (c + size // 14, size - 3), 255, -1)
        cv2.fillConvexPoly(
            mask,
            np.array([[c - size // 4, size - 2], [c + size // 4, size - 2], [c, size * 2 // 3]], dtype=np.int32),
            255,
        )
    elif suit == "spade":
        radius = max(2, size // 5)
        cv2.circle(mask, (c - radius, size * 3 // 5), radius, 255, -1)
        cv2.circle(mask, (c + radius, size * 3 // 5), radius, 255, -1)
        cv2.fillConvexPoly(
            mask,
            np.array([[2, size * 3 // 5], [size - 2, size * 3 // 5], [c, 1]], dtype=np.int32),
            255,
        )
        cv2.rectangle(mask, (c - size // 14, size * 3 // 5), (c + size // 14, size - 3), 255, -1)
    else:
        raise ValueError(f"Unknown suit {suit!r}")
    return mask


def _paste_symbol(
    image: np.ndarray,
    center: tuple[int, int],
    suit: str,
    size: int,
    orientation: int,
) -> None:
    mask = _symbol_mask(suit, size)
    if orientation == 180:
        mask = cv2.rotate(mask, cv2.ROTATE_180)
    x0 = center[0] - mask.shape[1] // 2
    y0 = center[1] - mask.shape[0] // 2
    x1, y1 = x0 + mask.shape[1], y0 + mask.shape[0]
    color = np.array((20, 30, 205) if suit in {"diamond", "heart"} else (20, 20, 20), dtype=np.uint8)
    roi = image[y0:y1, x0:x1]
    roi[mask > 0] = color


def render_card(
    rank: str,
    suit: str = "diamond",
    *,
    width: int = 360,
    height: int = 520,
    border: int = 18,
) -> np.ndarray:
    """Render a cornerless card so tests cannot accidentally rely on OCR."""

    if width < 120 or height < 180:
        raise ValueError("synthetic card dimensions are too small")
    canvas = np.full((height + 2 * border, width + 2 * border, 3), 48, dtype=np.uint8)
    cv2.rectangle(canvas, (border, border), (border + width - 1, border + height - 1), (248, 248, 248), -1)
    cv2.rectangle(canvas, (border, border), (border + width - 1, border + height - 1), (184, 184, 184), 2)
    symbol_size = max(24, int(width * 0.13))
    template = get_template(rank)
    for pip in template.pips:
        center = (border + int(round(pip.x * width)), border + int(round(pip.y * height)))
        _paste_symbol(canvas, center, suit, symbol_size, pip.orientation)
    return canvas


def apply_motion_blur(image: np.ndarray, length: int = 13, angle: float = 0.0) -> np.ndarray:
    length = max(3, int(length) | 1)
    kernel = np.zeros((length, length), dtype=np.float32)
    cv2.line(kernel, (0, length // 2), (length - 1, length // 2), 1.0, 1)
    matrix = cv2.getRotationMatrix2D((length / 2.0 - 0.5, length / 2.0 - 0.5), angle, 1.0)
    kernel = cv2.warpAffine(kernel, matrix, (length, length))
    kernel /= max(float(kernel.sum()), 1e-8)
    return cv2.filter2D(image, -1, kernel)


def rotate_image(image: np.ndarray, angle: float, border_value: int = 48) -> np.ndarray:
    height, width = image.shape[:2]
    matrix = cv2.getRotationMatrix2D((width / 2.0, height / 2.0), angle, 1.0)
    return cv2.warpAffine(
        image,
        matrix,
        (width, height),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(border_value, border_value, border_value),
    )
