#!/usr/bin/env python3
"""Package the exact CI model and verify a real-input, full-Engine replay.

This helper never recognizes an image. It validates exported metadata and the
output produced by the existing iOS XCTest through RecognitionEngine.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


HASH_ALGORITHM = "sha256(sorted relative UTF-8 path + NUL + file bytes)"


def read_object(path: Path) -> dict:
    if path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError(f"JSON exceeds verification limit: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object: {path}")
    return value


def write_object(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def git(repository: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repository), *args], text=True).strip()


def source_model(repository: Path) -> Path:
    candidates = sorted((repository / "App").rglob("CardDetector.mlpackage"))
    candidates += sorted((repository / "App").rglob("CardDetector.mlmodel"))
    if len(candidates) != 1:
        raise ValueError("Expected exactly one CardDetector.mlpackage or CardDetector.mlmodel in App; restore the replay-model artifact.")
    return candidates[0]


def model_hash(package: Path) -> str:
    """Identical to the existing CI TraceModelSHA256 hashing rule."""
    digest = hashlib.sha256()
    for item in sorted(package.rglob("*")) if package.is_dir() else [package]:
        if item.is_file():
            digest.update((item.relative_to(package).as_posix() if package.is_dir() else item.name).encode())
            digest.update(b"\0")
            digest.update(item.read_bytes())
    return digest.hexdigest()


def package_model(repository: Path, output: Path, revision: str) -> dict:
    if re.fullmatch(r"[0-9a-fA-F]{40,64}", revision) is None:
        raise ValueError("sourceRevision must be the full Git commit hash")
    model = source_model(repository)
    relative = model.relative_to(repository)
    destination = output / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise ValueError(f"Refusing to overwrite an existing replay model: {destination}")
    if model.is_dir():
        shutil.copytree(model, destination)
    else:
        shutil.copy2(model, destination)
    actual_hash = model_hash(model)
    if model_hash(destination) != actual_hash:
        raise ValueError("Copied replay model differs from the model used by the build")
    manifest = {"schemaVersion": 1, "sourceRevision": revision.lower(), "modelSHA256": actual_hash,
                "modelRelativePath": relative.as_posix(), "hashAlgorithm": HASH_ALGORITHM}
    write_object(output / "replay_model_manifest.json", manifest)
    return manifest


def verify_source_and_model(repository: Path, session: dict) -> tuple[str, str]:
    revision, expected_hash = session.get("sourceRevision"), session.get("modelSHA256")
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-fA-F]{40,64}", revision) is None:
        raise ValueError("Session lacks a known sourceRevision; strict source verification cannot continue")
    if not isinstance(expected_hash, str) or re.fullmatch(r"[0-9a-fA-F]{64}", expected_hash) is None:
        raise ValueError("Session lacks a known modelSHA256; strict model verification cannot continue")
    if git(repository, "rev-parse", "HEAD").lower() != revision.lower():
        raise ValueError(f"Checkout must match Session sourceRevision {revision}")
    if git(repository, "diff", "--name-only", "HEAD", "--", "App", "Tests", "project.yml"):
        raise ValueError("Tracked App, Tests or project.yml differs from the recorded source revision")
    untracked = git(repository, "ls-files", "--others", "--exclude-standard", "--", "App", "Tests").splitlines()
    # project.yml intentionally lets XcodeGen create this untracked plist.
    if any(path != "App/Info.plist" and Path(path).suffix.lower() in {".swift", ".m", ".mm", ".h", ".c", ".plist", ".xcconfig"} for path in untracked):
        raise ValueError("Untracked source/build files in App or Tests would change the replay build")
    model = source_model(repository)
    actual_hash = model_hash(model)
    if actual_hash != expected_hash.lower():
        raise ValueError(f"Model hash mismatch: expected {expected_hash}, found {actual_hash}; use the exact CI replay-model artifact")
    artifact_manifest = repository / "replay_model_manifest.json"
    if artifact_manifest.exists():
        recorded = read_object(artifact_manifest)
        if recorded.get("sourceRevision") != revision.lower() or recorded.get("modelSHA256") != actual_hash:
            raise ValueError("replay_model_manifest.json does not describe this Session's source and model")
    return revision.lower(), actual_hash


def file_signature(path: Path) -> dict | None:
    if not path.exists():
        return None
    stat = path.stat()
    return {"mtimeNS": stat.st_mtime_ns, "ctimeNS": stat.st_ctime_ns, "inode": stat.st_ino,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def prepare(repository: Path, recognition: Path, state_file: Path) -> dict:
    session_file = recognition.parent / "session_manifest.json"
    session = read_object(session_file)
    revision, digest = verify_source_and_model(repository, session)
    original = read_object(recognition / "recognition_trace.json")
    expected_path = recognition.name + "/recognition_trace.json"
    records = session.get("recognitions")
    if not isinstance(records, list) or not any(isinstance(record, dict)
            and record.get("traceFile") == expected_path
            and record.get("recognitionID") == original.get("recognitionID") for record in records):
        raise ValueError("Recognition directory is not indexed by the containing Session manifest")
    metadata = read_object(recognition / "recognition_input.json")
    if metadata.get("metadataComplete") is not True or not isinstance(metadata.get("planes"), list):
        raise ValueError("The exported pixel archive is incomplete; strict replay is unavailable")
    if not (recognition / "recognition_input_attachments.plist").is_file():
        raise ValueError("Missing lossless pixel attachments")
    state = {"schemaVersion": 1, "repository": str(repository), "recognitionDirectory": str(recognition),
             "sessionManifest": str(session_file), "sourceRevision": revision, "modelSHA256": digest,
             "inputRecognitionID": original.get("recognitionID"), "previousOutput": file_signature(recognition / "replay_trace.json"),
             "startedAtNS": time.time_ns()}
    write_object(state_file, state)
    return state


def verify_output(state_file: Path) -> dict:
    state = read_object(state_file)
    repository, recognition = Path(state["repository"]), Path(state["recognitionDirectory"])
    revision, digest = verify_source_and_model(repository, read_object(Path(state["sessionManifest"])))
    if revision != state["sourceRevision"] or digest != state["modelSHA256"]:
        raise ValueError("Source/model identity changed during replay")
    output = recognition / "replay_trace.json"
    signature = file_signature(output)
    if signature is None or signature["mtimeNS"] < state["startedAtNS"] or signature == state.get("previousOutput"):
        raise ValueError("No freshly generated replay_trace.json; the XCTest may have been skipped or not selected")
    result, metadata = read_object(output), read_object(recognition / "recognition_input.json")
    entries = result.get("entries")
    if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
        raise ValueError("Replay result lacks valid production Trace entries")
    replay = next((entry for entry in entries if entry.get("stage") == "replay"), {})
    if replay.get("strict") is not True or replay.get("inputKind") != "losslessProductionInput":
        raise ValueError("Replay did not use the strict production pixel archive")
    if replay.get("pixelPlaneHashes") != [plane["sha256"] for plane in metadata["planes"]] or replay.get("attachmentsSHA256") != metadata.get("attachmentsSHA256"):
        raise ValueError("Replay provenance differs from the selected input archive")
    actual_inputs = [entry for entry in entries if entry.get("stage") == "engine.input"]
    final = [entry for entry in entries if entry.get("stage") == "engine.final"]
    if len(actual_inputs) != 1 or len(final) != 1 or final[0].get("status") != "completed" or not isinstance(final[0].get("finalDetections"), list):
        raise ValueError("Replay lacks one completed production RecognitionEngine invocation")
    if any(actual_inputs[0].get(key) != metadata.get(key) for key in ("width", "height", "orientation", "pixelFormat")):
        raise ValueError("RecognitionEngine input dimensions/format/orientation differ from the saved input")
    counts = result.get("callCounts", {})
    if not isinstance(counts, dict) or any(type(counts.get(name)) is not int for name in ("coreML", "extractor", "fusion")) or counts["coreML"] < 1 or counts.get("extractor") != 1 or counts.get("fusion") != 2:
        raise ValueError("Replay did not record the expected actual Core ML / Extractor / Fusion calls")
    if result.get("metadataComplete") is not True:
        raise ValueError("Replay Trace is truncated; complete invocation verification is unavailable")
    receipt = {"schemaVersion": 1, "verified": True, "sourceRevision": revision, "modelSHA256": digest,
               "inputRecognitionID": state["inputRecognitionID"], "replayRecognitionID": result.get("recognitionID"),
               "replayTraceSHA256": signature["sha256"], "callCounts": counts, "verifiedAtNS": time.time_ns(),
               "scope": "matching source/model and fresh full-Engine replay of exact input; simulator hardware may differ from iPhone"}
    write_object(recognition / "replay_verification.json", receipt)
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    package = commands.add_parser("package-model")
    package.add_argument("--repository", type=Path, required=True)
    package.add_argument("--output", type=Path, required=True)
    package.add_argument("--source-revision", required=True)
    start = commands.add_parser("prepare")
    start.add_argument("--repository", type=Path, required=True)
    start.add_argument("--recognition", type=Path, required=True)
    start.add_argument("--state", type=Path, required=True)
    finish = commands.add_parser("verify")
    finish.add_argument("--state", type=Path, required=True)
    field = commands.add_parser("field")
    field.add_argument("--state", type=Path, required=True)
    field.add_argument("--name", choices=["sourceRevision", "modelSHA256"], required=True)
    args = parser.parse_args()
    try:
        if args.command == "package-model":
            result = package_model(args.repository.resolve(), args.output.resolve(), args.source_revision)
        elif args.command == "prepare":
            result = prepare(args.repository.resolve(), args.recognition.resolve(), args.state)
        elif args.command == "verify":
            result = verify_output(args.state)
        else:
            print(read_object(args.state)[args.name])
            return 0
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"Replay verification failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
