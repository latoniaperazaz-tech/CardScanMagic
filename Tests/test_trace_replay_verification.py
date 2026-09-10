from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess

import pytest

from scripts.verify_recognition_trace_replay import (
    model_hash, package_model, prepare, verify_output, verify_source_and_model, write_object,
)


@pytest.fixture
def replay_case(tmp_path: Path):
    repo = tmp_path / "repository"
    (repo / "App" / "Recognition").mkdir(parents=True)
    (repo / "App" / "Recognition" / "Engine.swift").write_text("// Source identity fixture only\n")
    (repo / "project.yml").write_text("name: Fixture\n")
    (repo / ".gitignore").write_text("App/Models/\n")
    for args in (["init", "-q"], ["add", "."], ["-c", "user.name=Trace Tests", "-c", "user.email=trace@example.test", "commit", "-qm", "fixture"]):
        subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)
    revision = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    model = repo / "App" / "Models" / "CardDetector.mlpackage"
    (model / "Data").mkdir(parents=True)
    (model / "Manifest.json").write_text('{"model": "fixture"}\n')
    (model / "Data" / "weights.bin").write_bytes(b"same model bytes")
    recognition = tmp_path / "Session-test" / "Recognition-1"
    recognition.mkdir(parents=True)
    session = {"sourceRevision": revision, "modelSHA256": model_hash(model),
               "recognitions": [{"recognitionID": "1", "traceFile": "Recognition-1/recognition_trace.json"}]}
    write_object(recognition.parent / "session_manifest.json", session)
    write_object(recognition / "recognition_trace.json", {"recognitionID": "1"})
    metadata = {"metadataComplete": True, "width": 64, "height": 96, "orientation": 6, "pixelFormat": 1111970369,
                "planes": [{"sha256": "a" * 64}], "attachmentsSHA256": "b" * 64}
    write_object(recognition / "recognition_input.json", metadata)
    (recognition / "recognition_input_attachments.plist").write_bytes(b"fixture archive checked by Swift")
    return repo, recognition, tmp_path / "state.json", session, metadata


def completed_trace(metadata: dict) -> dict:
    return {"recognitionID": "fresh-replay", "metadataComplete": True,
            "callCounts": {"coreML": 3, "extractor": 1, "fusion": 2},
            "entries": [
                {"stage": "replay", "strict": True, "inputKind": "losslessProductionInput",
                 "pixelPlaneHashes": [item["sha256"] for item in metadata["planes"]], "attachmentsSHA256": metadata["attachmentsSHA256"]},
                {"stage": "engine.input", **{name: metadata[name] for name in ("width", "height", "orientation", "pixelFormat")}},
                {"stage": "engine.final", "status": "completed", "finalDetections": []}]}


def fresh_output(recognition: Path, state: dict, result: dict) -> None:
    output = recognition / "replay_trace.json"
    write_object(output, result)
    # Filesystem timestamp precision varies on Windows/macOS; choose an explicit
    # later time in this verifier-only fixture, without claiming to run iOS here.
    newer = state["startedAtNS"] + 1_000_000
    os.utime(output, ns=(newer, newer))


def test_model_artifact_uses_existing_hash_rule_and_preserves_package(replay_case, tmp_path: Path):
    repo, _, _, session, _ = replay_case
    model = repo / "App" / "Models" / "CardDetector.mlpackage"
    expected = hashlib.sha256()
    for item in sorted(model.rglob("*")):
        if item.is_file():
            expected.update(item.relative_to(model).as_posix().encode())
            expected.update(b"\0")
            expected.update(item.read_bytes())
    artifact = tmp_path / "artifact"
    manifest = package_model(repo, artifact, session["sourceRevision"])
    assert manifest["modelSHA256"] == expected.hexdigest() == session["modelSHA256"]
    assert manifest["modelRelativePath"] == "App/Models/CardDetector.mlpackage"
    assert model_hash(artifact / manifest["modelRelativePath"]) == session["modelSHA256"]
    assert json.loads((artifact / "replay_model_manifest.json").read_text()) == manifest


def test_single_mlmodel_hash_preserves_filename_rule(tmp_path: Path):
    model = tmp_path / "CardDetector.mlmodel"
    model.write_bytes(b"raw model")
    assert model_hash(model) == hashlib.sha256(b"CardDetector.mlmodel\0raw model").hexdigest()


def test_prepare_checks_actual_source_model_and_session_membership(replay_case):
    repo, recognition, state_file, session, _ = replay_case
    state = prepare(repo, recognition, state_file)
    assert state["sourceRevision"] == session["sourceRevision"]
    assert state["modelSHA256"] == session["modelSHA256"]
    wrong = dict(session, recognitions=[])
    write_object(recognition.parent / "session_manifest.json", wrong)
    with pytest.raises(ValueError, match="not indexed"):
        prepare(repo, recognition, state_file)


@pytest.mark.parametrize("change", ["revision", "model", "tracked_source", "untracked_source"])
def test_mismatched_or_modified_build_cannot_be_called_strict(replay_case, change):
    repo, _, _, session, _ = replay_case
    if change == "revision":
        session = dict(session, sourceRevision="0" * 40)
    elif change == "model":
        (repo / "App" / "Models" / "CardDetector.mlpackage" / "Data" / "weights.bin").write_bytes(b"changed")
    elif change == "tracked_source":
        (repo / "App" / "Recognition" / "Engine.swift").write_text("// changed\n")
    else:
        (repo / "App" / "Recognition" / "New.swift").write_text("// untracked extra source\n")
    with pytest.raises(ValueError):
        verify_source_and_model(repo, session)


def test_expected_xcodegen_info_plist_does_not_block_verification(replay_case):
    repo, _, _, session, _ = replay_case
    (repo / "App" / "Info.plist").write_text("generated by XcodeGen")
    assert verify_source_and_model(repo, session)[0] == session["sourceRevision"]


@pytest.mark.parametrize("previous", [False, True])
def test_skip_or_stale_replay_file_is_never_success(replay_case, previous):
    repo, recognition, state_file, _, metadata = replay_case
    if previous:
        write_object(recognition / "replay_trace.json", completed_trace(metadata))
    prepare(repo, recognition, state_file)
    with pytest.raises(ValueError, match="freshly generated"):
        verify_output(state_file)


def test_fresh_full_engine_output_gets_verification_receipt(replay_case):
    repo, recognition, state_file, session, metadata = replay_case
    state = prepare(repo, recognition, state_file)
    fresh_output(recognition, state, completed_trace(metadata))
    result = verify_output(state_file)
    assert result["verified"] is True
    assert result["modelSHA256"] == session["modelSHA256"]
    assert result["callCounts"]["coreML"] == 3
    assert (recognition / "replay_verification.json").is_file()


@pytest.mark.parametrize("change", ["image_only", "wrong_planes", "wrong_orientation", "missing_final", "missing_model_call", "truncated"])
def test_fresh_but_incomplete_or_different_replay_is_rejected(replay_case, change):
    repo, recognition, state_file, _, metadata = replay_case
    state = prepare(repo, recognition, state_file)
    result = completed_trace(metadata)
    if change == "image_only":
        result["entries"][0]["strict"] = False
    elif change == "wrong_planes":
        result["entries"][0]["pixelPlaneHashes"] = ["different"]
    elif change == "wrong_orientation":
        result["entries"][1]["orientation"] = 1
    elif change == "missing_final":
        result["entries"].pop()
    elif change == "missing_model_call":
        result["callCounts"]["coreML"] = 0
    else:
        result["metadataComplete"] = False
    fresh_output(recognition, state, result)
    with pytest.raises(ValueError):
        verify_output(state_file)
