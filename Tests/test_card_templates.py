from __future__ import annotations

import pytest

from src.rules.card_templates import CARD_TEMPLATES, RANKS, get_template


def test_templates_cover_ace_through_ten_with_complete_counts() -> None:
    assert RANKS == ("A", "2", "3", "4", "5", "6", "7", "8", "9", "10")
    assert {rank: template.count for rank, template in CARD_TEMPLATES.items()} == {
        "A": 1,
        "2": 2,
        "3": 3,
        "4": 4,
        "5": 5,
        "6": 6,
        "7": 7,
        "8": 8,
        "9": 9,
        "10": 10,
    }


@pytest.mark.parametrize("rank", RANKS)
def test_every_pip_has_unique_normalized_spatial_metadata(rank: str) -> None:
    template = get_template(rank)
    positions = {(pip.x, pip.y) for pip in template.pips}

    assert len(positions) == template.count
    assert all(0.0 < pip.x < 1.0 and 0.0 < pip.y < 1.0 for pip in template.pips)
    assert all(pip.orientation in {0, 180} for pip in template.pips)
    assert all(pip.role for pip in template.pips)


@pytest.mark.parametrize("rank", ("4", "5", "6", "7", "8", "9", "10"))
def test_multi_column_templates_are_horizontally_symmetric(rank: str) -> None:
    positions = {(round(pip.x, 2), round(pip.y, 2)) for pip in get_template(rank).pips}

    for x, y in positions:
        if x != 0.50:
            assert (round(1.0 - x, 2), y) in positions


def test_five_keeps_corner_and_center_structure() -> None:
    five = get_template("5")

    assert five.has_center
    assert set(five.row_counts) == {1, 2}
    assert five.column_counts == (2, 1, 2)
    assert {pip.role for pip in five.pips} == {
        "top_left",
        "top_right",
        "center",
        "bottom_left",
        "bottom_right",
    }


def test_unknown_rank_is_rejected() -> None:
    with pytest.raises(ValueError, match="expected A through 10"):
        get_template("K")
