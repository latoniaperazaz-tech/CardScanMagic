from __future__ import annotations

from math import cos, radians, sin

import cv2
import numpy as np
import pytest

from src.features.pip_detector import detect_pips
from src.features.suit_detector import detect_suit
from src.inference.evidence_fusion import infer_partial_card
from src.inference.partial_rank_inference import infer_partial_rank
from src.rules.card_templates import get_template
from src.testing.synthetic_cards import apply_motion_blur, render_card


CARD_WIDTH = 357
CARD_HEIGHT = 500


def _visible(region: str, confidence: float = 0.9) -> dict[str, object]:
    probabilities = {region: confidence, "unknown": 1.0 - confidence}
    return {"region": region, "confidence": confidence, "probabilities": probabilities}


def _observations(
    rank: str,
    *,
    crop: tuple[float, float, float, float] = (0.0, 0.0, 1.0, 1.0),
    roles: set[str] | None = None,
    angle: float = 0.0,
) -> tuple[list[dict[str, object]], tuple[int, int]]:
    x0, y0, x1, y1 = crop
    crop_x = x0 * CARD_WIDTH
    crop_y = y0 * CARD_HEIGHT
    image_width = max(1, round((x1 - x0) * CARD_WIDTH))
    image_height = max(1, round((y1 - y0) * CARD_HEIGHT))
    center_x, center_y = image_width / 2.0, image_height / 2.0
    theta = radians(angle)
    observations: list[dict[str, object]] = []
    for pip in get_template(rank).pips:
        if not (x0 <= pip.x <= x1 and y0 <= pip.y <= y1):
            continue
        if roles is not None and pip.role not in roles:
            continue
        x = pip.x * CARD_WIDTH - crop_x
        y = pip.y * CARD_HEIGHT - crop_y
        if angle:
            shifted_x, shifted_y = x - center_x, y - center_y
            x = center_x + cos(theta) * shifted_x - sin(theta) * shifted_y
            y = center_y + sin(theta) * shifted_x + cos(theta) * shifted_y
        observations.append(
            {
                "cx": x / image_width,
                "cy": y / image_height,
                "center_px": [x, y],
                "shape_score": 0.92,
            }
        )
    return observations, (image_height, image_width)


def _top_rank(
    rank: str,
    *,
    crop: tuple[float, float, float, float] = (0.0, 0.0, 1.0, 1.0),
    roles: set[str] | None = None,
    angle: float = 0.0,
    region: str = "full",
) -> tuple[str, dict[str, object]]:
    observations, image_shape = _observations(rank, crop=crop, roles=roles, angle=angle)
    result = infer_partial_rank(observations, _visible(region), image_shape=image_shape)
    return result["candidates"][0]["rank"], result


def test_complete_five_is_first_candidate() -> None:
    top, _ = _top_rank("5")
    assert top == "5"


def test_five_with_right_side_cropped_is_first_candidate() -> None:
    top, _ = _top_rank("5", crop=(0.0, 0.0, 0.56, 1.0), region="left")
    assert top == "5"


def test_five_with_top_cropped_is_first_candidate() -> None:
    top, _ = _top_rank("5", crop=(0.0, 0.35, 1.0, 1.0), region="bottom")
    assert top == "5"


def test_five_with_only_center_and_left_structure_is_first_candidate() -> None:
    roles = {"top_left", "center", "bottom_left"}
    top, _ = _top_rank("5", roles=roles, region="unknown")
    assert top == "5"


def test_five_rotated_fifteen_degrees_is_first_candidate() -> None:
    top, _ = _top_rank("5", angle=15.0)
    assert top == "5"


def test_five_under_strong_perspective_is_first_candidate() -> None:
    source_corners = np.float32(
        [[0, 0], [CARD_WIDTH, 0], [CARD_WIDTH, CARD_HEIGHT], [0, CARD_HEIGHT]]
    )
    target_corners = np.float32([[260, 80], [700, 190], [560, 1220], [180, 1100]])
    homography = cv2.getPerspectiveTransform(source_corners, target_corners)
    source_pips = np.float32(
        [[[pip.x * CARD_WIDTH, pip.y * CARD_HEIGHT] for pip in get_template("5").pips]]
    )
    projected = cv2.perspectiveTransform(source_pips, homography)[0]
    observations = [
        {
            "cx": float(x / 720),
            "cy": float(y / 1280),
            "center_px": [float(x), float(y)],
            "shape_score": 0.86,
        }
        for x, y in projected
    ]

    result = infer_partial_rank(
        observations,
        _visible("unknown"),
        image_shape=(1280, 720),
    )

    assert result["candidates"][0]["rank"] == "5"
    assert result["candidates"][0]["details"]["transform"]["kind"] == "homography"


@pytest.mark.parametrize("rank", ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10"])
def test_complete_number_layouts_rank_first(rank: str) -> None:
    top, _ = _top_rank(rank)
    assert top == rank


def test_full_card_with_one_center_pip_can_resolve_ace_cautiously() -> None:
    result = infer_partial_card(render_card("A", "spade"))
    assert result["rank"] == "A"
    assert result["confidence"] < 0.60


@pytest.mark.parametrize(
    ("rank", "confuser"),
    [("4", "5"), ("5", "9"), ("6", "8"), ("6", "7"), ("8", "10")],
)
def test_confusable_complete_layouts_score_truth_above_neighbor(rank: str, confuser: str) -> None:
    _, result = _top_rank(rank)
    probabilities = result["rank_candidates"]
    assert probabilities[rank] > probabilities[confuser]


def test_no_pips_returns_unknown_without_fabricating_rank() -> None:
    result = infer_partial_rank([], _visible("unknown"), image_shape=(500, 357))
    assert result["rank"] == "unknown"
    assert result["confidence"] == 0.0
    assert result["unknown_probability"] == 1.0


def test_pip_detector_keeps_five_pips_under_motion_blur() -> None:
    image = apply_motion_blur(render_card("5", "diamond"), length=15, angle=12.0)
    pips = detect_pips(image)
    assert len(pips) == 5
    assert all(pip["shape_score"] >= 0.28 for pip in pips)


def test_pip_detector_keeps_red_pip_on_dim_masked_card() -> None:
    image = np.full((427, 326, 3), 255, dtype=np.uint8)
    card_polygon = np.array(
        [[20, 20], [325, 25], [325, 310], [260, 370], [210, 420], [20, 405]],
        dtype=np.int32,
    )
    cv2.fillConvexPoly(image, card_polygon, (120, 112, 124))
    cv2.ellipse(image, (180, 215), (35, 23), -8, 0, 360, (70, 55, 150), -1)
    image = cv2.GaussianBlur(image, (9, 9), 2)

    pips = detect_pips(image)

    red_pips = [pip for pip in pips if pip["color"] == "red"]
    assert red_pips
    assert np.linalg.norm(np.asarray(red_pips[0]["center_px"]) - (180, 215)) < 12


@pytest.mark.parametrize("suit", ["diamond", "heart", "club", "spade"])
def test_suit_detector_ranks_synthetic_blurred_suit_first(suit: str) -> None:
    image = apply_motion_blur(render_card("6", suit), length=11, angle=8.0)
    probabilities = detect_suit(image)
    ranked = max((name for name in probabilities if name != "unknown"), key=probabilities.get)
    assert ranked == suit


def test_end_to_end_partial_blurred_five_remains_first() -> None:
    complete = render_card("5", "heart")
    partial = complete[:, :220]
    image = apply_motion_blur(partial, length=15, angle=10.0)
    result = infer_partial_card(image)
    assert len(result["detections"]["pips"]) == 3
    assert result["detections"]["visible_region"]["region"] == "left"
    assert next(iter(result["rank_candidates"])) == "5"
    assert result["rank"] == "5"
    assert result["suit"] == "heart"
    assert result["candidates"][0][0] == "5"


def test_blank_image_returns_unknown_instead_of_card() -> None:
    blank = render_card("A")
    blank[:] = 245
    result = infer_partial_card(blank)
    assert result["rank"] == "unknown"
    assert result["suit"] == "unknown"
