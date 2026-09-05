#!/usr/bin/env python3
"""Export the upstream French-card YOLO weight as an iOS Core ML package."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

UPSTREAM_WEIGHT_URL = (
    "https://raw.githubusercontent.com/cdpcre/french_cards_detector_pytorch/"
    "main/deployment_hf/best.pt"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--weights",
        type=Path,
        default=Path("models/best.pt"),
        help="Path to best.pt. Used after --download has saved it.",
    )
    parser.add_argument(
        "--download",
        action="store_true",
        help="Download the upstream deployment_hf/best.pt weight first.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("App/Models/CardDetector.mlpackage"),
        help="Destination Core ML package. The destination must not already exist.",
    )
    parser.add_argument("--image-size", type=int, default=640)
    parser.add_argument("--confidence", type=float, default=0.62)
    parser.add_argument("--iou", type=float, default=0.45)
    parser.add_argument(
        "--no-fp16",
        dest="fp16",
        action="store_false",
        help="Export full precision instead of FP16. FP16 is recommended on iPhone.",
    )
    parser.set_defaults(fp16=True)
    return parser.parse_args()


def download_weight(destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading upstream model to {destination} ...")
    try:
        urllib.request.urlretrieve(UPSTREAM_WEIGHT_URL, destination)
    except Exception as error:
        raise RuntimeError(f"Could not download {UPSTREAM_WEIGHT_URL}: {error}") from error


def output_descriptions(model_path: Path) -> list[dict[str, object]]:
    import coremltools as ct

    spec = ct.utils.load_spec(str(model_path))
    descriptions: list[dict[str, object]] = []
    for output in spec.description.output:
        descriptions.append(
            {
                "name": output.name,
                "type": output.type.WhichOneof("Type"),
                "shortDescription": output.shortDescription,
            }
        )
    return descriptions


def main() -> int:
    args = parse_args()
    if args.download:
        download_weight(args.weights)

    if not args.weights.is_file():
        print(
            f"Weight not found: {args.weights}. Run with --download or pass --weights.",
            file=sys.stderr,
        )
        return 2
    if args.output.exists():
        print(
            f"Refusing to overwrite existing output: {args.output}. Remove it deliberately first.",
            file=sys.stderr,
        )
        return 2

    from ultralytics import YOLO

    model = YOLO(str(args.weights))
    exported_path = Path(
        model.export(
            format="coreml",
            imgsz=args.image_size,
            half=args.fp16,
            nms=True,
            conf=args.confidence,
            iou=args.iou,
        )
    )

    if not exported_path.is_dir() or exported_path.suffix != ".mlpackage":
        raise RuntimeError(f"Expected an .mlpackage directory, got {exported_path}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(exported_path, args.output)
    metadata = {
        "source": UPSTREAM_WEIGHT_URL,
        "weights": str(args.weights),
        "exportedAtUtc": datetime.now(UTC).isoformat(),
        "imageSize": args.image_size,
        "fp16": args.fp16,
        "nms": True,
        "confidence": args.confidence,
        "iou": args.iou,
        "outputs": output_descriptions(args.output),
    }
    info_path = args.output.parent / "CardDetectorInfo.json"
    info_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    print(f"Created {args.output}")
    print(f"Model interface written to {info_path}")
    print("Run 'xcodegen generate' before opening the project in Xcode.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
