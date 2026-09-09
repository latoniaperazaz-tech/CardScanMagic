from __future__ import annotations

import cv2
import numpy as np

from src.inference.evidence_fusion import infer_partial_card_in_scene
from src.testing.synthetic_cards import apply_motion_blur, render_card


def _scene() -> np.ndarray:
    image = np.full((720, 720, 3), (40, 48, 44), dtype=np.uint8)
    cv2.rectangle(image, (0, 430), (719, 650), (170, 182, 177), -1)
    for row in range(4):
        for column in range(10):
            x, y = 20 + 69 * column, 445 + 48 * row
            cv2.rectangle(image, (x, y), (x + 48, y + 30), (195, 200, 198), -1)
            cv2.line(image, (x + 2, y + 29), (x + 46, y + 29), (40, 205, 170), 3)
    cv2.rectangle(image, (205, 45), (719, 125), (185, 180, 188), -1)
    return image


def _place_five(image: np.ndarray, x: int, y: int, *, blurred: bool = False) -> np.ndarray:
    card = render_card("5", "diamond", width=270, height=390, border=12)[12:-12, 12:-12]
    if blurred:
        card = apply_motion_blur(card, length=13, angle=8.0)
    output = image.copy()
    source_x = max(0, -x)
    target_x = max(0, x)
    visible_width = min(card.shape[1] - source_x, output.shape[1] - target_x)
    visible_height = min(card.shape[0], output.shape[0] - y)
    output[y : y + visible_height, target_x : target_x + visible_width] = card[
        :visible_height,
        source_x : source_x + visible_width,
    ]
    return output


def test_scene_inference_selects_card_over_keyboard_and_monitor() -> None:
    result = infer_partial_card_in_scene(_place_five(_scene(), 330, 120))

    assert result["rank"] == "5"
    assert result["rank_candidates"]["5"] == max(result["rank_candidates"].values())
    assert result["suit"] in {"diamond", "unknown"}
    assert result["scene_candidates"]
    assert result["source_geometry"]["x"] > 250


def test_scene_inference_handles_blurred_card_clipped_by_left_edge() -> None:
    result = infer_partial_card_in_scene(_place_five(_scene(), -100, 120, blurred=True))

    assert result["rank"] == "5"
    assert result["rank_candidates"]["5"] == max(result["rank_candidates"].values())
    assert result["source_geometry"]["x"] == 0


def test_scene_inference_does_not_invent_card_in_clutter() -> None:
    result = infer_partial_card_in_scene(_scene())

    assert result["rank"] == "unknown"
    assert result["suit"] == "unknown"
    assert result["confidence"] == 0.0


def test_scene_inference_uses_main_pip_scale_on_dim_blurred_ace() -> None:
    image = np.full((720, 720, 3), (42, 48, 45), dtype=np.uint8)
    cv2.rectangle(image, (330, 120), (570, 470), (126, 118, 128), -1)
    cv2.fillConvexPoly(
        image,
        np.array([[450, 250], [485, 295], [450, 340], [415, 295]], dtype=np.int32),
        (55, 48, 170),
    )
    cv2.fillConvexPoly(
        image,
        np.array([[352, 145], [360, 155], [352, 165], [344, 155]], dtype=np.int32),
        (55, 48, 170),
    )
    image = cv2.GaussianBlur(image, (9, 9), 2)

    result = infer_partial_card_in_scene(image)

    assert result["rank"] == "A"
    assert result["evidence"]["visible_region"] == "full"
    assert result["evidence"]["color_group"] == "red"
    assert len(result["detections"]["pips"]) == 1
