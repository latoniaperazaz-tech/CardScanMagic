#!/usr/bin/env python3
"""Prepare the card detector as an iOS Core ML model.

The default path exports the known-good upstream PyTorch weight.  An already
converted ``.mlpackage`` (or a zip containing one) can be supplied for an A/B
test without changing the app's runtime model name.  The app expects Vision's
recognized-object interface, so a raw ONNX file is deliberately rejected here:
it must first be converted with NMS and its 52 labels preserved.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import urllib.request
import zipfile
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
        "--weights-url",
        default=UPSTREAM_WEIGHT_URL,
        help=(
            "URL used with --download. The default is the MIT upstream "
            "cdpcre/french_cards_detector_pytorch weight."
        ),
    )
    parser.add_argument(
        "--coreml-source",
        type=Path,
        help=(
            "Use an existing .mlpackage or a zip containing one instead of "
            "exporting PyTorch. This is the safe A/B path for an external model."
        ),
    )
    parser.add_argument(
        "--model-id",
        default="cdpcre-french-cards",
        help="Human-readable model identifier written to CardDetectorInfo.json.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("App/Models/CardDetector.mlpackage"),
        help="Destination Core ML package. The destination must not already exist.",
    )
    parser.add_argument("--image-size", type=int, default=640)
    # Keep lower-confidence candidates so the Swift tracker can confirm them
    # across multiple sharp frames instead of dropping motion-blurred cards
    # before tracking gets a chance to stabilize them.
    parser.add_argument("--confidence", type=float, default=0.45)
    parser.add_argument("--iou", type=float, default=0.45)
    parser.add_argument(
        "--no-fp16",
        dest="fp16",
        action="store_false",
        help="Export full precision instead of FP16. FP16 is recommended on iPhone.",
    )
    parser.set_defaults(fp16=True)
    return parser.parse_args()


def download_weight(destination: Path, url: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading model to {destination} ...")
    try:
        urllib.request.urlretrieve(url, destination)
    except Exception as error:
        raise RuntimeError(f"Could not download {url}: {error}") from error


def _safe_extract(zip_path: Path, destination: Path) -> None:
    """Extract a model archive without allowing paths to escape temp storage."""

    destination = destination.resolve()
    with zipfile.ZipFile(zip_path) as archive:
        for member in archive.infolist():
            # Symlinks can escape the destination after extraction even when
            # their archive name itself is inside it. Core ML packages do not
            # need links, so reject them rather than trusting the archive.
            unix_mode = (member.external_attr >> 16) & 0o170000
            if unix_mode == 0o120000:
                raise RuntimeError(f"Refusing symlink in model archive: {member.filename}")
            target = (destination / member.filename).resolve()
            if target != destination and destination not in target.parents:
                raise RuntimeError(f"Refusing unsafe model archive entry: {member.filename}")
        archive.extractall(destination)


def _find_coreml_source(source: Path, temp_dir: Path) -> Path:
    """Return one Core ML model package from a path or a zip archive."""

    if source.is_dir() and source.suffix.lower() == ".mlpackage":
        return source

    if source.is_file() and source.suffix.lower() in {".mlmodel", ".mlpackage"}:
        # A package is a directory; a standalone .mlmodel is accepted too and
        # will be compiled by Xcode under the same CardDetector model name.
        return source

    if source.is_file() and source.suffix.lower() == ".onnx":
        raise RuntimeError(
            "Raw ONNX is not accepted by this iOS pipeline. Convert it to a "
            ".mlpackage with Vision-compatible NMS and the 52 card labels first, "
            "then pass that package via --coreml-source."
        )

    if source.is_file() and zipfile.is_zipfile(source):
        extract_dir = temp_dir / "external-coreml"
        extract_dir.mkdir(parents=True, exist_ok=True)
        _safe_extract(source, extract_dir)
        package_dirs = list(extract_dir.rglob("*.mlpackage"))
        model_files = list(extract_dir.rglob("*.mlmodel"))
        if len(package_dirs) + len(model_files) != 1:
            raise RuntimeError(
                "External archive must contain exactly one .mlpackage or .mlmodel "
                f"(found {len(package_dirs)} packages and {len(model_files)} models)."
            )
        return package_dirs[0] if package_dirs else model_files[0]

    raise RuntimeError(
        f"Unsupported external model source: {source}. Use a .mlpackage, .mlmodel, "
        "or a zip containing exactly one of them."
    )


def copy_coreml_source(source: Path, output: Path, temp_dir: Path) -> tuple[Path, str]:
    """Copy an external Core ML source and return its output path and source kind."""

    resolved_source = _find_coreml_source(source, temp_dir)
    if resolved_source.suffix.lower() == ".mlpackage":
        destination = output
        if destination.suffix.lower() != ".mlpackage":
            destination = destination.with_suffix(".mlpackage")
        if destination.exists():
            raise RuntimeError(f"Refusing to overwrite existing output: {destination}")
        shutil.copytree(resolved_source, destination)
    else:
        destination = output.with_suffix(".mlmodel")
        conflicting_package = destination.with_suffix(".mlpackage")
        if destination.exists() or conflicting_package.exists():
            raise RuntimeError(
                "Refusing to overwrite an existing Core ML resource: "
                f"{destination} or {conflicting_package}"
            )
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(resolved_source, destination)
    return destination, "external-coreml"


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
    if args.coreml_source and args.download:
        print("Use either --coreml-source or --download, not both.", file=sys.stderr)
        return 2

    if args.coreml_source:
        with tempfile.TemporaryDirectory(prefix="cardscan-coreml-") as temp_dir:
            try:
                output_path, source_kind = copy_coreml_source(
                    args.coreml_source,
                    args.output,
                    Path(temp_dir),
                )
                metadata = {
                    "modelId": args.model_id,
                    "sourceKind": source_kind,
                    "source": str(args.coreml_source),
                    "exportedAtUtc": datetime.now(UTC).isoformat(),
                    "outputs": output_descriptions(output_path),
                }
            except (OSError, RuntimeError, zipfile.BadZipFile) as error:
                print(str(error), file=sys.stderr)
                return 2
        info_path = output_path.parent / "CardDetectorInfo.json"
        info_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        print(f"Copied {output_path}")
        print(f"Model interface written to {info_path}")
        print("Run 'xcodegen generate' before opening the project in Xcode.")
        return 0

    if args.download:
        download_weight(args.weights, args.weights_url)

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
        "modelId": args.model_id,
        "sourceKind": "ultralytics-weights",
        "source": args.weights_url if args.download else str(args.weights),
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
