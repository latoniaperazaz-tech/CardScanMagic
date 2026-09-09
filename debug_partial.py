"""Command-line diagnostic runner for the Partial Card Inference MVP."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from textwrap import wrap
from typing import Any

import cv2
import numpy as np

from src.inference.evidence_fusion import infer_partial_card, infer_partial_card_in_scene


def _read_image(path: Path) -> np.ndarray:
    try:
        encoded = np.fromfile(path, dtype=np.uint8)
    except OSError as exc:
        raise ValueError(f"cannot read image: {path}") from exc
    image = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f"unsupported or invalid image: {path}")
    return image


def _write_image(path: Path, image: np.ndarray) -> None:
    suffix = path.suffix.lower() if path.suffix else ".jpg"
    success, encoded = cv2.imencode(suffix, image)
    if not success:
        raise ValueError(f"OpenCV could not encode debug image as {suffix}")
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded.tofile(path)


def _percent(value: float) -> str:
    return f"{100.0 * value:.1f}%"


def _draw_debug(image: np.ndarray, result: dict[str, Any]) -> np.ndarray:
    overlay = image.copy()
    detections = result["detections"]
    visible = detections["visible_region"]
    source = result.get("source_geometry", {"x": 0, "y": 0})
    offset_x, offset_y = int(source.get("x", 0)), int(source.get("y", 0))

    localization = result.get("localization")
    if localization:
        scene_candidates = result.get("scene_candidates", [])
        selected_bbox = scene_candidates[0]["bbox"] if scene_candidates else None
        for candidate in localization.get("candidates", []):
            polygon = np.asarray(candidate.get("polygon", []), dtype=np.int32)
            if len(polygon) < 3:
                continue
            x, y, width, height = candidate["bbox"]
            is_selected = selected_bbox == candidate["bbox"]
            color = (60, 220, 90) if is_selected else (60, 180, 255)
            cv2.polylines(overlay, [polygon], True, color, 2, cv2.LINE_AA)
            cv2.putText(
                overlay,
                f"card {candidate['score']:.2f}",
                (max(2, int(x)), max(18, int(y) + 18)),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.48,
                color,
                1,
                cv2.LINE_AA,
            )

    polygon = visible.get("card_polygon")
    if polygon and len(polygon) >= 3:
        shifted_polygon = np.asarray(polygon, dtype=np.int32) + np.array(
            [offset_x, offset_y], dtype=np.int32
        )
        cv2.polylines(
            overlay,
            [shifted_polygon],
            True,
            (60, 220, 90),
            2,
            cv2.LINE_AA,
        )
    for x1, y1, x2, y2 in visible.get("lines", []):
        cv2.line(
            overlay,
            (x1 + offset_x, y1 + offset_y),
            (x2 + offset_x, y2 + offset_y),
            (40, 180, 255),
            1,
            cv2.LINE_AA,
        )

    radius = max(5, int(round(min(image.shape[:2]) * 0.015)))
    for index, pip in enumerate(detections["pips"], start=1):
        x, y = (int(round(value)) for value in pip["center_px"])
        x += offset_x
        y += offset_y
        cv2.circle(overlay, (x, y), radius, (255, 80, 220), 2, cv2.LINE_AA)
        cv2.circle(overlay, (x, y), 2, (255, 255, 255), -1, cv2.LINE_AA)
        cv2.putText(
            overlay,
            str(index),
            (x + radius + 2, y - radius),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.45,
            (255, 80, 220),
            1,
            cv2.LINE_AA,
        )

    panel_width = max(330, min(440, image.shape[1]))
    canvas_height = max(image.shape[0], 680)
    canvas = np.full((canvas_height, image.shape[1] + panel_width, 3), 24, dtype=np.uint8)
    canvas[: image.shape[0], : image.shape[1]] = overlay
    x = image.shape[1] + 20
    y = 34

    def put(text: str, color: tuple[int, int, int] = (232, 232, 232), scale: float = 0.58) -> None:
        nonlocal y
        cv2.putText(canvas, text, (x, y), cv2.FONT_HERSHEY_SIMPLEX, scale, color, 1, cv2.LINE_AA)
        y += 27

    put("PARTIAL CARD INFERENCE", (80, 220, 255), 0.62)
    if localization:
        put(
            f"Card ROI: {localization['reason']}",
            (80, 220, 120) if localization["found"] else (80, 160, 255),
            0.48,
        )
        scene_candidates = result.get("scene_candidates", [])
        if scene_candidates:
            put(
                f"ROI source: {scene_candidates[0]['source']}  "
                f"{_percent(result.get('scene_score', 0.0))}",
                (80, 220, 120),
                0.48,
            )
    color_group = result["evidence"].get("color_group")
    if color_group:
        put(f"Color group: {color_group}", (120, 190, 255), 0.52)
    put(f"Pips: {len(detections['pips'])}")
    put(
        f"Region: {visible['region']}  {_percent(visible['confidence'])}",
        (80, 220, 120),
    )
    y += 8
    put("Suit candidates", (120, 190, 255))
    for suit, probability in list(result["suit_candidates"].items())[:4]:
        put(f"  {suit:<8} {_percent(probability)}", scale=0.54)
    y += 8
    put("Rank candidates", (120, 190, 255))
    for rank, probability in list(result["rank_candidates"].items())[:5]:
        put(f"  {rank:<3} {_percent(probability)}", scale=0.54)
    y += 8
    put(f"Final: {result['suit']} {result['rank']}", (80, 235, 120), 0.66)
    put(f"Confidence: {_percent(result['confidence'])}", (80, 235, 120), 0.58)
    y += 8
    put("Why top rank", (120, 190, 255))
    for reason in result["evidence"].get("reasons", [])[:4]:
        for line in wrap(str(reason), width=42):
            put(f"  {line}", (205, 205, 205), 0.45)
    return canvas


def _print_report(result: dict[str, Any]) -> None:
    localization = result.get("localization")
    if localization:
        print(
            f"Card localization: {'found' if localization['found'] else 'unknown'} "
            f"({_percent(localization['confidence'])})"
        )
        scene_candidates = result.get("scene_candidates", [])
        if scene_candidates:
            print(
                f"Selected ROI: {scene_candidates[0]['source']} "
                f"({_percent(result.get('scene_score', 0.0))})"
            )
    color_group = result["evidence"].get("color_group")
    if color_group:
        print(f"Color group: {color_group}")
    print(f"Detected pips: {len(result['detections']['pips'])}")
    visible = result["detections"]["visible_region"]
    print(f"Visible region: {visible['region']} ({_percent(visible['confidence'])})")
    print("\nSuit:")
    for suit, probability in list(result["suit_candidates"].items())[:4]:
        print(f"  {suit:<8} {_percent(probability)}")
    print("\nRank:")
    for rank, probability in list(result["rank_candidates"].items())[:5]:
        print(f"  {rank:<3} {_percent(probability)}")
    print(f"\nFinal: {result['suit']} {result['rank']}")
    print(f"Confidence: {_percent(result['confidence'])}")
    reasons = result["evidence"].get("reasons", [])
    if reasons:
        print("Why:")
        for reason in reasons:
            print(f"  - {reason}")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Inspect partial-card suit and pip-layout evidence")
    parser.add_argument("--image", required=True, type=Path, help="input card image")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "outputs",
        help="directory for debug_<image>.jpg",
    )
    parser.add_argument("--show", action="store_true", help="open an OpenCV preview window")
    parser.add_argument("--json", action="store_true", help="also print the complete JSON result")
    parser.add_argument(
        "--localize",
        action="store_true",
        help="locate a card ROI in a wider scene before running inference",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        image = _read_image(args.image)
        result = infer_partial_card_in_scene(image) if args.localize else infer_partial_card(image)
        debug_image = _draw_debug(image, result)
        safe_stem = re.sub(r"[^A-Za-z0-9_.-]+", "_", args.image.stem).strip("._") or "image"
        output_path = args.output_dir / f"debug_{safe_stem}.jpg"
        _write_image(output_path, debug_image)
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    _print_report(result)
    if args.json:
        print("\nJSON:")
        print(json.dumps(result, indent=2, ensure_ascii=True))
    print(f"\nDebug image: {output_path.resolve()}")
    if args.show:
        cv2.imshow("Partial Card Inference", debug_image)
        cv2.waitKey(0)
        cv2.destroyAllWindows()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
