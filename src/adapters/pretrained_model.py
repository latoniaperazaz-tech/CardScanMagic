"""Neutral interface for future 52-class or corner-model evidence."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable

import numpy as np


@dataclass(slots=True)
class ModelEvidence:
    """Optional model output; empty probabilities are valid when unavailable."""

    available: bool
    source: str
    rank_probabilities: dict[str, float] = field(default_factory=dict)
    suit_probabilities: dict[str, float] = field(default_factory=dict)
    confidence: float = 0.0
    metadata: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "available": self.available,
            "source": self.source,
            "rank_probabilities": self.rank_probabilities,
            "suit_probabilities": self.suit_probabilities,
            "confidence": self.confidence,
            "metadata": self.metadata,
        }


@runtime_checkable
class PretrainedModelAdapter(Protocol):
    """Implemented by a future CoreML, ONNX, or PyTorch evidence provider."""

    @property
    def available(self) -> bool: ...

    def predict(self, image: np.ndarray) -> ModelEvidence: ...


class UnavailablePretrainedModel:
    """Default adapter that keeps the classical MVP fully standalone."""

    def __init__(self, reason: str = "no pretrained model configured") -> None:
        self.reason = reason

    @property
    def available(self) -> bool:
        return False

    def predict(self, image: np.ndarray) -> ModelEvidence:
        return ModelEvidence(
            available=False,
            source="none",
            metadata={"reason": self.reason},
        )

