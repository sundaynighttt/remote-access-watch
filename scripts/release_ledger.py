#!/usr/bin/env python3
"""Validate and synchronize a project's release ledger into its root README."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any


START_MARKER = "<!-- project-release-ledger:start -->"
END_MARKER = "<!-- project-release-ledger:end -->"
ALLOWED_STAGES = {
    "planned",
    "candidate",
    "local_verified",
    "external_processed",
    "installed_smoke",
    "released",
    "superseded",
    "failed",
    "abandoned",
}
ALLOWED_STATUSES = {
    "planned",
    "pending",
    "active",
    "passed",
    "historical",
    "superseded",
    "failed",
    "abandoned",
}
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
KEY_PATTERN = re.compile(r"^[a-z][a-z0-9_]*$")


class LedgerError(Exception):
    """Expected validation or synchronization failure."""


def require_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise LedgerError(f"{field}: non-empty string required")
    return value.strip()


def validate_date(value: Any, field: str) -> str:
    text = require_string(value, field)
    if not DATE_PATTERN.fullmatch(text):
        raise LedgerError(f"{field}: YYYY-MM-DD required")
    try:
        dt.date.fromisoformat(text)
    except ValueError as exc:
        raise LedgerError(f"{field}: invalid calendar date {text}") from exc
    return text


def inside_project(project_root: Path, candidate: Path) -> bool:
    try:
        candidate.resolve().relative_to(project_root.resolve())
        return True
    except ValueError:
        return False


def validate_evidence(project_root: Path, value: Any, field: str) -> str:
    evidence = require_string(value, field)
    if evidence.startswith("https://"):
        return evidence
    if evidence.startswith("git:"):
        ref = evidence.removeprefix("git:").strip()
        if not ref:
            raise LedgerError(f"{field}: git ref is empty")
        result = subprocess.run(
            ["git", "-C", str(project_root), "rev-parse", "--verify", ref],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode != 0:
            raise LedgerError(f"{field}: git ref does not exist: {ref}")
        return evidence
    if "://" in evidence:
        raise LedgerError(f"{field}: only https:// external evidence is allowed")

    path_text = evidence.split("#", 1)[0]
    path = Path(path_text)
    if path.is_absolute():
        raise LedgerError(f"{field}: local evidence must be repo-relative")
    candidate = project_root / path
    if not inside_project(project_root, candidate):
        raise LedgerError(f"{field}: evidence escapes project root")
    if not candidate.is_file():
        raise LedgerError(f"{field}: evidence file does not exist: {path_text}")
    return evidence


def load_and_validate(project_root: Path, ledger_path: Path) -> dict[str, Any]:
    try:
        data = json.loads(ledger_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise LedgerError(f"ledger not found: {ledger_path}") from exc
    except json.JSONDecodeError as exc:
        raise LedgerError(f"invalid JSON in {ledger_path}: {exc}") from exc

    if not isinstance(data, dict):
        raise LedgerError("ledger root must be an object")
    if data.get("schemaVersion") != 1:
        raise LedgerError("schemaVersion must be 1")
    require_string(data.get("project"), "project")
    validate_date(data.get("updatedAt"), "updatedAt")

    releases = data.get("releases")
    if not isinstance(releases, list) or not releases:
        raise LedgerError("releases: non-empty array required")

    release_ids: set[str] = set()
    version_builds: set[tuple[str, str]] = set()
    expected_sequences = list(range(1, len(releases) + 1))
    actual_sequences: list[int] = []

    for index, release in enumerate(releases):
        prefix = f"releases[{index}]"
        if not isinstance(release, dict):
            raise LedgerError(f"{prefix}: object required")
        release_id = require_string(release.get("id"), f"{prefix}.id")
        if release_id in release_ids:
            raise LedgerError(f"{prefix}.id: duplicate id {release_id}")
        release_ids.add(release_id)

        sequence = release.get("sequence")
        if not isinstance(sequence, int) or isinstance(sequence, bool):
            raise LedgerError(f"{prefix}.sequence: integer required")
        actual_sequences.append(sequence)

        version = require_string(release.get("version"), f"{prefix}.version")
        build_value = release.get("build", "")
        if build_value is None:
            build_value = ""
        if not isinstance(build_value, (str, int)) or isinstance(build_value, bool):
            raise LedgerError(f"{prefix}.build: string or integer required")
        build = str(build_value).strip()
        version_build = (version, build)
        if version_build in version_builds:
            display = f"{version} ({build})" if build else version
            raise LedgerError(f"{prefix}: duplicate version/build {display}")
        version_builds.add(version_build)

        validate_date(release.get("date"), f"{prefix}.date")
        stage = require_string(release.get("stage"), f"{prefix}.stage")
        if stage not in ALLOWED_STAGES:
            raise LedgerError(f"{prefix}.stage: unsupported value {stage}")
        status = require_string(release.get("status"), f"{prefix}.status")
        if status not in ALLOWED_STATUSES:
            raise LedgerError(f"{prefix}.status: unsupported value {status}")
        require_string(release.get("summary"), f"{prefix}.summary")

        evidence = release.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            raise LedgerError(f"{prefix}.evidence: non-empty array required")
        for evidence_index, item in enumerate(evidence):
            validate_evidence(project_root, item, f"{prefix}.evidence[{evidence_index}]")

    if actual_sequences != expected_sequences:
        raise LedgerError(
            "releases[].sequence must be ordered consecutive integers 1..N; "
            f"got {actual_sequences}"
        )

    pointers = data.get("pointers")
    if not isinstance(pointers, list) or not pointers:
        raise LedgerError("pointers: non-empty array required")
    pointer_keys: set[str] = set()
    for index, pointer in enumerate(pointers):
        prefix = f"pointers[{index}]"
        if not isinstance(pointer, dict):
            raise LedgerError(f"{prefix}: object required")
        key = require_string(pointer.get("key"), f"{prefix}.key")
        if not KEY_PATTERN.fullmatch(key):
            raise LedgerError(f"{prefix}.key: snake_case identifier required")
        if key in pointer_keys:
            raise LedgerError(f"{prefix}.key: duplicate key {key}")
        pointer_keys.add(key)
        require_string(pointer.get("label"), f"{prefix}.label")
        release_id = require_string(pointer.get("releaseId"), f"{prefix}.releaseId")
        if release_id not in release_ids:
            raise LedgerError(f"{prefix}.releaseId: unknown release id {release_id}")

    return data


def markdown_escape(value: Any) -> str:
    return str(value).replace("|", "\\|").replace("\r", " ").replace("\n", " ").strip()


def release_display(release: dict[str, Any]) -> str:
    version = markdown_escape(release["version"])
    build = release.get("build")
    if build is None or str(build).strip() == "":
        return version
    return f"{version} ({markdown_escape(build)})"


def evidence_markdown(evidence: list[str]) -> str:
    rendered: list[str] = []
    for item in evidence:
        if item.startswith("https://"):
            rendered.append(f"[외부 근거]({item})")
        elif item.startswith("git:"):
            rendered.append(f"`{markdown_escape(item)}`")
        else:
            label = Path(item.split("#", 1)[0]).name or item
            rendered.append(f"[{markdown_escape(label)}]({item})")
    return "<br>".join(rendered)


def render_block(data: dict[str, Any], ledger_relative: str) -> str:
    by_id = {release["id"]: release for release in data["releases"]}
    lines = [
        START_MARKER,
        "## 릴리스 기준과 전체 버전 흐름",
        "",
        (
            f"> 자동 관리 원장: [`{markdown_escape(ledger_relative)}`]({ledger_relative}) · "
            f"갱신일: `{markdown_escape(data['updatedAt'])}`"
        ),
        "",
        "### 현재 기준선",
        "",
        "| 기준 | 버전 | 단계 | 상태 | 요약 | 근거 |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for pointer in data["pointers"]:
        release = by_id[pointer["releaseId"]]
        lines.append(
            "| "
            + " | ".join(
                [
                    f"{markdown_escape(pointer['label'])}<br>`{markdown_escape(pointer['key'])}`",
                    f"**`{release_display(release)}`**",
                    f"`{markdown_escape(release['stage'])}`",
                    f"`{markdown_escape(release['status'])}`",
                    markdown_escape(release["summary"]),
                    evidence_markdown(release["evidence"]),
                ]
            )
            + " |"
        )

    lines.extend(
        [
            "",
            "### 전체 버전 흐름",
            "",
            "| 순서 | 날짜 | 버전 | 단계 | 상태 | 요약 | 근거 |",
            "| ---: | --- | --- | --- | --- | --- | --- |",
        ]
    )
    for release in data["releases"]:
        lines.append(
            "| "
            + " | ".join(
                [
                    str(release["sequence"]),
                    markdown_escape(release["date"]),
                    f"`{release_display(release)}`",
                    f"`{markdown_escape(release['stage'])}`",
                    f"`{markdown_escape(release['status'])}`",
                    markdown_escape(release["summary"]),
                    evidence_markdown(release["evidence"]),
                ]
            )
            + " |"
        )
    lines.extend([END_MARKER, ""])
    return "\n".join(lines)


def marker_counts(readme: str) -> tuple[int, int]:
    return readme.count(START_MARKER), readme.count(END_MARKER)


def replace_or_insert(readme: str, block: str) -> str:
    start_count, end_count = marker_counts(readme)
    if start_count != end_count or start_count > 1:
        raise LedgerError(
            "README managed markers are missing or duplicated; inspect manually before syncing"
        )
    if start_count == 1:
        start = readme.index(START_MARKER)
        end = readme.index(END_MARKER, start) + len(END_MARKER)
        prefix = readme[:start].rstrip()
        suffix = readme[end:].lstrip("\n")
        result = f"{prefix}\n\n{block.rstrip()}\n"
        if suffix:
            result += f"\n{suffix}"
        return result.rstrip() + "\n"

    first_h2 = re.search(r"(?m)^##\s+", readme)
    if first_h2:
        prefix = readme[: first_h2.start()].rstrip()
        suffix = readme[first_h2.start() :].lstrip()
        return f"{prefix}\n\n{block.rstrip()}\n\n{suffix.rstrip()}\n"
    return f"{readme.rstrip()}\n\n{block.rstrip()}\n"


def extract_block(readme: str) -> str:
    start_count, end_count = marker_counts(readme)
    if start_count != 1 or end_count != 1:
        raise LedgerError("README must contain exactly one complete managed block")
    start = readme.index(START_MARKER)
    end = readme.index(END_MARKER, start) + len(END_MARKER)
    return readme[start:end] + "\n"


def ensure_block_is_first_h2(readme: str) -> None:
    marker_index = readme.index(START_MARKER)
    first_h2 = re.search(r"(?m)^##\s+", readme)
    if first_h2 and first_h2.start() < marker_index:
        raise LedgerError("README managed block must appear before the first ordinary H2 section")


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    existing_mode = path.stat().st_mode & 0o7777 if path.exists() else 0o644
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.fchmod(fd, existing_mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def resolve_repo_path(project_root: Path, value: str, field: str) -> Path:
    relative = Path(value)
    if relative.is_absolute():
        raise LedgerError(f"{field} must be repo-relative")
    resolved = project_root / relative
    if not inside_project(project_root, resolved):
        raise LedgerError(f"{field} escapes project root")
    return resolved


def run(args: argparse.Namespace) -> int:
    project_root = Path(args.project_root).expanduser().resolve()
    if not project_root.is_dir():
        raise LedgerError(f"project root not found: {project_root}")
    ledger_path = resolve_repo_path(project_root, args.ledger, "ledger path")
    readme_path = resolve_repo_path(project_root, args.readme, "README path")
    data = load_and_validate(project_root, ledger_path)
    block = render_block(data, args.ledger)

    if args.command == "render":
        sys.stdout.write(block)
        return 0

    try:
        readme = readme_path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise LedgerError(f"README not found: {readme_path}") from exc

    if args.command == "sync":
        updated = replace_or_insert(readme, block)
        if updated == readme:
            print(f"UNCHANGED {readme_path}")
        else:
            atomic_write(readme_path, updated)
            print(f"UPDATED {readme_path}")
        return 0

    actual_block = extract_block(readme)
    ensure_block_is_first_h2(readme)
    if actual_block != block:
        raise LedgerError("README managed block is stale; run the sync command and review the diff")
    print(
        "PASS project-release-ledger: "
        f"{len(data['releases'])} releases, {len(data['pointers'])} pointers"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate and synchronize a release ledger into a root README."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("render", "sync", "check"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--project-root", required=True)
        subparser.add_argument(
            "--ledger", default="docs/releases/release-ledger.json"
        )
        subparser.add_argument("--readme", default="README.md")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return run(args)
    except LedgerError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
