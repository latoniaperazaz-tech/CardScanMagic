from __future__ import annotations

import cv2
import numpy as np

from src.geometry.card_localizer import crop_card_candidate, localize_cards
from src.testing.synthetic_cards import apply_motion_blur, render_card


def _cluttered_scene() -> np.ndarray:
    scene = np.full((720, 720, 3), (40, 48, 44), dtype=np.uint8)
    for row in range(5):
        for column in range(10):
            x = 18 + column * 68
            y = 420 + row * 54
            cv2.rectangle(scene, (x, y), (x + 50, y + 35), (174, 184, 180), -1)
            cv2.rectangle(scene, (x + 3, y + 32), (x + 47, y + 38), (40, 210, 175), -1)
    cv2.rectangle(scene, (210, 60), (719, 145), (172, 165, 174), -1)
    return scene


def _place_card(scene: np.ndarray, x: int, y: int, *, blur: bool = False) -> tuple[np.ndarray, list[int]]:
    card = render_card("5", "heart", width=270, height=390, border=12)[12:-12, 12:-12]
    if blur:
        card = apply_motion_blur(card, length=13, angle=8.0)
    output = scene.copy()
    source_x0 = max(0, -x)
    source_y0 = max(0, -y)
    destination_x0 = max(0, x)
    destination_y0 = max(0, y)
    visible_width = min(card.shape[1] - source_x0, output.shape[1] - destination_x0)
    visible_height = min(card.shape[0] - source_y0, output.shape[0] - destination_y0)
    output[
        destination_y0 : destination_y0 + visible_height,
        destination_x0 : destination_x0 + visible_width,
    ] = card[
        source_y0 : source_y0 + visible_height,
        source_x0 : source_x0 + visible_width,
    ]
    return output, [destination_x0, destination_y0, visible_width, visible_height]


def _iou(first: list[int], second: list[int]) -> float:
    ax, ay, aw, ah = first
    bx, by, bw, bh = second
    x0, y0 = max(ax, bx), max(ay, by)
    x1, y1 = min(ax + aw, bx + bw), min(ay + ah, by + bh)
    intersection = max(0, x1 - x0) * max(0, y1 - y0)
    union = aw * ah + bw * bh - intersection
    return intersection / union


def test_localizer_finds_card_on_keyboard_like_clutter() -> None:
    scene, expected = _place_card(_cluttered_scene(), 330, 105)
    result = localize_cards(scene)

    assert result["found"]
    assert _iou(result["best"]["bbox"], expected) > 0.80


def test_localizer_finds_blurred_partial_card_touching_left_edge() -> None:
    scene, expected = _place_card(_cluttered_scene(), -105, 120, blur=True)
    result = localize_cards(scene, minimum_confidence=0.34)

    assert result["found"]
    assert result["best"]["touches_image_boundary"]["left"]
    assert _iou(result["best"]["bbox"], expected) > 0.70


def test_localizer_rejects_keyboard_and_wide_monitor_without_card() -> None:
    result = localize_cards(_cluttered_scene())
    assert not result["found"]
    assert result["best"] is None


def test_candidate_crop_stays_inside_source_image() -> None:
    scene, _ = _place_card(_cluttered_scene(), -80, 90)
    result = localize_cards(scene, minimum_confidence=0.34)
    crop, geometry = crop_card_candidate(scene, result["best"], padding=0.05)

    assert crop.size > 0
    assert geometry["x"] == 0
    assert geometry["width"] == crop.shape[1]
    assert geometry["height"] == crop.shape[0]


def test_localizer_can_seed_region_from_four_around_one_pip_layout() -> None:
    image = np.full((1280, 720, 3), (200, 200, 200), dtype=np.uint8)
    points = ((428, 288), (678, 423), (481, 898), (508, 1110), (379, 1125))
    for x, y in points:
        cv2.ellipse(image, (x, y), (48, 68), 12, 0, 360, (35, 35, 190), -1)

    result = localize_cards(image, minimum_confidence=0.34, max_candidates=5)

    pip_candidates = [
        candidate for candidate in result["candidates"] if candidate["source"] == "pip_cluster"
    ]
    assert pip_candidates
    assert pip_candidates[0]["features"]["pip_like_components"] == 5
