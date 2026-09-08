"""Normalized spatial pip layouts for standard French-suited cards.

Coordinates describe the printable card face, not pixels. ``x`` and ``y`` are
both in ``[0, 1]`` with the card's rank corner at the top-left. Orientation is
the clockwise pip rotation in degrees. This makes the templates independent of
image resolution while retaining the full spatial layout needed for partial
matching.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Final, Iterable


@dataclass(frozen=True, slots=True)
class PipTemplate:
    """One pip in normalized card coordinates."""

    x: float
    y: float
    orientation: int = 0
    role: str = ""

    def as_dict(self) -> dict[str, float | int | str]:
        return {
            "x": self.x,
            "y": self.y,
            "orientation": self.orientation,
            "role": self.role,
        }


@dataclass(frozen=True, slots=True)
class CardTemplate:
    """Complete pip layout and derived structural metadata for one rank."""

    rank: str
    pips: tuple[PipTemplate, ...]

    @property
    def count(self) -> int:
        return len(self.pips)

    @property
    def has_center(self) -> bool:
        return any(abs(pip.x - 0.5) < 0.04 and abs(pip.y - 0.5) < 0.04 for pip in self.pips)

    @property
    def row_counts(self) -> tuple[int, ...]:
        return tuple(
            sum(abs(pip.y - row) < 0.035 for pip in self.pips)
            for row in sorted({pip.y for pip in self.pips})
        )

    @property
    def column_counts(self) -> tuple[int, ...]:
        return tuple(
            sum(abs(pip.x - column) < 0.035 for pip in self.pips)
            for column in sorted({pip.x for pip in self.pips})
        )

    def as_dict(self) -> dict[str, object]:
        return {
            "rank": self.rank,
            "width": 1.0,
            "height": 1.0,
            "pips": [pip.as_dict() for pip in self.pips],
            "structure": {
                "count": self.count,
                "has_center": self.has_center,
                "row_counts": self.row_counts,
                "column_counts": self.column_counts,
            },
        }


def _pip(x: float, y: float, orientation: int, role: str) -> PipTemplate:
    return PipTemplate(x=x, y=y, orientation=orientation, role=role)


LEFT: Final = 0.30
CENTER: Final = 0.50
RIGHT: Final = 0.70
TOP: Final = 0.18
UPPER_MIDDLE: Final = 0.34
MIDDLE: Final = 0.50
LOWER_MIDDLE: Final = 0.66
BOTTOM: Final = 0.82


# The slightly denser 9/10 rows match the conventional four-row layouts. Each
# point remains explicit so matching can reason about crop, rows and symmetry.
CARD_TEMPLATES: Final[dict[str, CardTemplate]] = {
    "A": CardTemplate(
        "A",
        (_pip(CENTER, MIDDLE, 0, "center"),),
    ),
    "2": CardTemplate(
        "2",
        (
            _pip(CENTER, TOP, 0, "top_center"),
            _pip(CENTER, BOTTOM, 180, "bottom_center"),
        ),
    ),
    "3": CardTemplate(
        "3",
        (
            _pip(CENTER, TOP, 0, "top_center"),
            _pip(CENTER, MIDDLE, 0, "center"),
            _pip(CENTER, BOTTOM, 180, "bottom_center"),
        ),
    ),
    "4": CardTemplate(
        "4",
        (
            _pip(LEFT, TOP, 0, "top_left"),
            _pip(RIGHT, TOP, 0, "top_right"),
            _pip(LEFT, BOTTOM, 180, "bottom_left"),
            _pip(RIGHT, BOTTOM, 180, "bottom_right"),
        ),
    ),
    "5": CardTemplate(
        "5",
        (
            _pip(LEFT, TOP, 0, "top_left"),
            _pip(RIGHT, TOP, 0, "top_right"),
            _pip(CENTER, MIDDLE, 0, "center"),
            _pip(LEFT, BOTTOM, 180, "bottom_left"),
            _pip(RIGHT, BOTTOM, 180, "bottom_right"),
        ),
    ),
    "6": CardTemplate(
        "6",
        (
            _pip(LEFT, TOP, 0, "top_left"),
            _pip(RIGHT, TOP, 0, "top_right"),
            _pip(LEFT, MIDDLE, 0, "middle_left"),
            _pip(RIGHT, MIDDLE, 0, "middle_right"),
            _pip(LEFT, BOTTOM, 180, "bottom_left"),
            _pip(RIGHT, BOTTOM, 180, "bottom_right"),
        ),
    ),
    "7": CardTemplate(
        "7",
        (
            _pip(LEFT, TOP, 0, "top_left"),
            _pip(RIGHT, TOP, 0, "top_right"),
            _pip(CENTER, UPPER_MIDDLE, 0, "upper_center"),
            _pip(LEFT, MIDDLE, 0, "middle_left"),
            _pip(RIGHT, MIDDLE, 0, "middle_right"),
            _pip(LEFT, BOTTOM, 180, "bottom_left"),
            _pip(RIGHT, BOTTOM, 180, "bottom_right"),
        ),
    ),
    "8": CardTemplate(
        "8",
        (
            _pip(LEFT, TOP, 0, "top_left"),
            _pip(RIGHT, TOP, 0, "top_right"),
            _pip(CENTER, UPPER_MIDDLE, 0, "upper_center"),
            _pip(LEFT, MIDDLE, 0, "middle_left"),
            _pip(RIGHT, MIDDLE, 0, "middle_right"),
            _pip(CENTER, LOWER_MIDDLE, 180, "lower_center"),
            _pip(LEFT, BOTTOM, 180, "bottom_left"),
            _pip(RIGHT, BOTTOM, 180, "bottom_right"),
        ),
    ),
    "9": CardTemplate(
        "9",
        (
            _pip(LEFT, 0.15, 0, "top_left"),
            _pip(RIGHT, 0.15, 0, "top_right"),
            _pip(LEFT, 0.38, 0, "upper_left"),
            _pip(RIGHT, 0.38, 0, "upper_right"),
            _pip(CENTER, MIDDLE, 0, "center"),
            _pip(LEFT, 0.62, 180, "lower_left"),
            _pip(RIGHT, 0.62, 180, "lower_right"),
            _pip(LEFT, 0.85, 180, "bottom_left"),
            _pip(RIGHT, 0.85, 180, "bottom_right"),
        ),
    ),
    "10": CardTemplate(
        "10",
        (
            _pip(LEFT, 0.15, 0, "top_left"),
            _pip(RIGHT, 0.15, 0, "top_right"),
            _pip(CENTER, 0.29, 0, "upper_center"),
            _pip(LEFT, 0.38, 0, "upper_left"),
            _pip(RIGHT, 0.38, 0, "upper_right"),
            _pip(LEFT, 0.62, 180, "lower_left"),
            _pip(RIGHT, 0.62, 180, "lower_right"),
            _pip(CENTER, 0.71, 180, "lower_center"),
            _pip(LEFT, 0.85, 180, "bottom_left"),
            _pip(RIGHT, 0.85, 180, "bottom_right"),
        ),
    ),
}

RANKS: Final[tuple[str, ...]] = tuple(CARD_TEMPLATES)


def get_template(rank: str | int) -> CardTemplate:
    """Return a rank template, accepting ``1`` as the ace alias."""

    key = str(rank).upper()
    if key == "1":
        key = "A"
    try:
        return CARD_TEMPLATES[key]
    except KeyError as exc:
        raise ValueError(f"Unsupported rank {rank!r}; expected A through 10") from exc


def iter_template_points(rank: str | int) -> Iterable[tuple[float, float]]:
    """Yield normalized coordinates without discarding template metadata."""

    for pip in get_template(rank).pips:
        yield pip.x, pip.y

