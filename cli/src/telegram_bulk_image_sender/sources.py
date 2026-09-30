"""Input sources: manifest files (CSV/JSON) for One-by-One mode.

The manifest is the ordered queue (spec 2.1 ordering by manifest-row).
Schema, enforced with row-accurate errors:
  CSV  : header line with at least the columns "file" and "recipient";
         optional "caption" column; every other column is a custom template
         field.
  JSON : a top-level list of objects with the same keys.

"file" may be absolute or relative to the manifest's directory. "recipient"
references an allowlist entry by name or by chat_id (resolved by the
planner, which owns the allowlist).
"""

from __future__ import annotations

import csv
import json
from dataclasses import dataclass, field
from pathlib import Path

from .discovery import IMAGE_EXTENSIONS
from .errors import ValidationError
from .model import OrderKey
from .ordering import natural_key

COLUMN_FILE = "file"
COLUMN_RECIPIENT = "recipient"
COLUMN_CAPTION = "caption"


@dataclass(frozen=True)
class ManifestRow:
    row_number: int  # 1-based, as printed in errors
    file_value: str  # as written in the manifest
    resolved_path: str  # absolute path after resolving relative to manifest
    recipient_ref: str
    caption: str | None
    custom: dict[str, str] = field(default_factory=dict)


def read_manifest(manifest_path: str, *, order: OrderKey, reverse: bool) -> list[ManifestRow]:
    path = Path(manifest_path)
    if not path.is_file():
        raise ValidationError([f"manifest not found: {manifest_path}"])
    suffix = path.suffix.lower()
    if suffix == ".csv":
        raw_rows = _read_csv(path)
    elif suffix == ".json":
        raw_rows = _read_json(path)
    else:
        raise ValidationError([f"manifest must be .csv or .json, got {path.name}"])

    issues: list[str] = []
    rows: list[ManifestRow] = []
    for row_number, record in raw_rows:
        file_value = record.get(COLUMN_FILE, "")
        recipient_ref = record.get(COLUMN_RECIPIENT, "")
        if not file_value:
            issues.append(f"manifest row {row_number}: 'file' is missing or empty")
            continue
        if not recipient_ref:
            issues.append(f"manifest row {row_number}: 'recipient' is missing or empty")
            continue
        resolved = Path(file_value)
        if not resolved.is_absolute():
            resolved = path.parent / resolved
        if not resolved.is_file():
            issues.append(f"manifest row {row_number}: file not found: {resolved}")
            continue
        if resolved.suffix.lower() not in IMAGE_EXTENSIONS:
            issues.append(
                f"manifest row {row_number}: unsupported file type "
                f"{resolved.suffix or '(none)'}: {file_value}"
            )
            continue
        caption = record.get(COLUMN_CAPTION)
        custom = {
            k: v
            for k, v in record.items()
            if k not in (COLUMN_FILE, COLUMN_RECIPIENT, COLUMN_CAPTION)
        }
        rows.append(
            ManifestRow(
                row_number=row_number,
                file_value=file_value,
                resolved_path=str(resolved),
                recipient_ref=recipient_ref,
                caption=caption,
                custom=custom,
            )
        )
    if issues:
        raise ValidationError(issues)

    if order in (OrderKey.NAME, OrderKey.MTIME):
        if order is OrderKey.NAME:
            keyed = [(natural_key(Path(r.resolved_path).name), r.row_number, r) for r in rows]
        else:
            keyed = [(Path(r.resolved_path).stat().st_mtime_ns, r.row_number, r) for r in rows]
        keyed.sort(key=lambda t: t[:2])
        rows = [t[2] for t in keyed]
    if reverse:
        rows.reverse()
    return rows


def _read_csv(path: Path) -> list[tuple[int, dict[str, str]]]:
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames is None:
            raise ValidationError([f"manifest {path}: file is empty"])
        missing = [c for c in (COLUMN_FILE, COLUMN_RECIPIENT) if c not in reader.fieldnames]
        if missing:
            raise ValidationError(
                [f"manifest {path}: missing required column(s): {', '.join(missing)}"]
            )
        rows: list[tuple[int, dict[str, str]]] = []
        for i, record in enumerate(reader, start=2):  # header is line 1
            cleaned = {k: (v or "").strip() for k, v in record.items() if k is not None}
            rows.append((i, cleaned))
        return rows


def _read_json(path: Path) -> list[tuple[int, dict[str, str]]]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ValidationError([f"manifest {path}: not valid JSON: {exc}"]) from exc
    if not isinstance(raw, list) or any(not isinstance(item, dict) for item in raw):
        raise ValidationError([f"manifest {path}: top level must be a list of objects"])
    rows: list[tuple[int, dict[str, str]]] = []
    for i, item in enumerate(raw):
        row_number = i + 1
        record: dict[str, str] = {}
        for key, value in item.items():
            if not isinstance(key, str):
                raise ValidationError([f"manifest {path} row {row_number}: keys must be strings"])
            record[key] = "" if value is None else str(value)
        rows.append((row_number, record))
    return rows
