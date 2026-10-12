#!/usr/bin/env python3
"""Update VHDL file headers to the THALES project template.

By default the tool previews changes only. Pass --write to update files.
"""

from __future__ import annotations

import argparse
import os
import re
import tempfile
import textwrap
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

SKIP_DIRS = {
    ".git",
    ".runs",
    ".venv",
    ".xil",
    "cache",
    "ip_user_files",
    "notes",
    "sim",
    "vivado",
    "work",
}
HEADER_LINE_RE = re.compile(r"^\s*--")
DESCRIPTION_RE = re.compile(
    r"^\s*--\s*Description\s*:\s*(?P<text>.*)$", re.IGNORECASE
)
PURPOSE_RE = re.compile(r"^\s*--\s*Purpose\s*:\s*(?P<text>.*)$", re.IGNORECASE)
CONTINUATION_RE = re.compile(r"^\s*--\s+:\s?(?P<text>.*)$")
FIELD_RE = re.compile(r"^\s*--\s*[A-Za-z][A-Za-z0-9 _-]*\s*:")
CREATION_DATE_RE = re.compile(
    r"^\s*--\s*Creation\s+Date\s*:\s*(?P<value>.*?)\s*$", re.IGNORECASE
)
CREATED_BY_RE = re.compile(
    r"^\s*--\s*Created\s+by\s*:\s*(?P<value>.*?)\s*$", re.IGNORECASE
)
PURPOSE_PREFIX = "--Purpose                : "
PURPOSE_CONTINUATION_PREFIX = "--                         "


@dataclass(frozen=True)
class HeaderInfo:
    lines: list[str]
    end: int
    description: list[str] | None


def _header_info(lines: list[str]) -> HeaderInfo:
    """Find the leading comment block and its Description or Purpose text."""
    header_end = 0
    for line in lines:
        if line.strip() and not HEADER_LINE_RE.match(line):
            break
        header_end += 1

    header = lines[:header_end]
    description: list[str] | None = None
    field_match = None
    for index, line in enumerate(header):
        match = DESCRIPTION_RE.match(line)
        if match:
            field_match = (index, match.group("text"))
            break
    if field_match is None:
        for index, line in enumerate(header):
            match = PURPOSE_RE.match(line)
            if match:
                field_match = (index, match.group("text"))
                break

    if field_match is not None:
        field_index, first_text = field_match
        description = [first_text.strip()]
        for line in header[field_index + 1 :]:
            continuation = CONTINUATION_RE.match(line)
            if continuation:
                description.append(continuation.group("text").rstrip())
            elif line.strip() == "--":
                break
            elif FIELD_RE.match(line):
                break
            elif HEADER_LINE_RE.match(line):
                break
            else:
                break

        while description and not description[-1].strip():
            description.pop()
        if not any(part.strip() for part in description):
            description = None

    return HeaderInfo(header, header_end, description)


def _extract_thales_metadata(path: Path) -> tuple[str, str] | None:
    """Return (user, date) when the leading header has concrete THALES data."""
    try:
        text = path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError):
        return None

    info = _header_info(text.splitlines())
    user = None
    date = None
    for line in info.lines:
        user_match = CREATED_BY_RE.match(line)
        date_match = CREATION_DATE_RE.match(line)
        if user_match:
            user = user_match.group("value").strip()
        if date_match:
            date = date_match.group("value").strip()

    if not user or not date or _is_placeholder(user) or _is_placeholder(date):
        return None
    if not any("THALES" in line.upper() for line in info.lines):
        return None
    return user, date


def _is_placeholder(value: str) -> bool:
    return bool(re.search(r"<[^>]+>", value))


def _creation_date(path: Path) -> str:
    """Use filesystem birth time where available, otherwise creation time."""
    stat = path.stat()
    timestamp = getattr(stat, "st_birthtime", stat.st_ctime)
    return datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d")


def _is_placeholder_template(path: Path, info: HeaderInfo) -> bool:
    """Avoid turning a literal header template into a concrete source header."""
    if path.name.lower() == "template.vhd":
        return True
    for line in info.lines:
        if ("Filename" in line or "Purpose" in line) and _is_placeholder(line):
            return True
    return False


def _wrap_description(description: list[str]) -> list[str]:
    """Wrap description text while retaining paragraph and bullet boundaries."""
    output: list[str] = []
    first_line = True
    for source_line in description:
        content = source_line.strip()
        if not content:
            output.append("--")
            continue
        prefix = PURPOSE_PREFIX if first_line else PURPOSE_CONTINUATION_PREFIX
        wrapped = textwrap.wrap(
            content,
            width=80,
            initial_indent=prefix,
            subsequent_indent=PURPOSE_CONTINUATION_PREFIX,
            break_long_words=False,
            break_on_hyphens=False,
        )
        output.extend(wrapped or [prefix.rstrip()])
        first_line = False
    return output


def _make_header(filename: str, date: str, user: str,
                 description: list[str]) -> list[str]:
    header = [
        "-----------------------------------------------------------------------",
        "--Classification         : Unclassified",
        "--",
        "-----------------------------------------------------------------------",
        "--Copyright (C) 2026 by THALES. All rights reserved.",
        "--Project                : TNOR-ip-library (Unclassified)",
        "--Company                : THALES",
        f"--Filename               : {filename}",
        f"--Creation Date          : {date}",
    ]
    header.extend(_wrap_description(description))
    header.extend(
        [
            "--",
            "--",
            f"--Created by             : {user}",
            "--Tools & tools versions : Xilinx Vivado 2023.2 ->",
            "--VHDL version           : 2008",
            "-----------------------------------------------------------------------",
        ]
    )
    return header


def _read_text(path: Path) -> tuple[str, str, bool, bool]:
    """Read UTF-8 text and return text, newline, BOM, and final-newline state."""
    raw = path.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig")
    newline = "\r\n" if "\r\n" in text else "\n"
    has_final_newline = text.endswith(("\n", "\r"))
    return text, newline, bom, has_final_newline


def _atomic_write(path: Path, text: str, bom: bool, mode: int) -> None:
    """Replace a file atomically while preserving its mode and UTF-8 BOM."""
    payload = text.encode("utf-8")
    if bom:
        payload = b"\xef\xbb\xbf" + payload
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp_path = Path(temp_name)
    try:
        with os.fdopen(descriptor, "wb") as temp_file:
            temp_file.write(payload)
        os.chmod(temp_path, mode)
        temp_path.replace(path)
    finally:
        temp_path.unlink(missing_ok=True)


def _iter_vhdl_files(root: Path):
    for directory, dirnames, filenames in os.walk(root):
        dirnames[:] = [name for name in dirnames if name.lower() not in SKIP_DIRS]
        directory_path = Path(directory)
        for filename in filenames:
            path = directory_path / filename
            if path.suffix.lower() in {".vhd", ".vhdl"}:
                yield path


def update_headers(destination: Path, source: Path | None, write: bool) -> int:
    updated = 0
    skipped = 0
    files = sorted(_iter_vhdl_files(destination))

    for path in files:
        relative = path.relative_to(destination)
        try:
            text, newline, bom, has_final_newline = _read_text(path)
        except (OSError, UnicodeError) as exc:
            print(f"SKIP {relative}: cannot read UTF-8 text ({exc})")
            skipped += 1
            continue

        lines = text.splitlines()
        info = _header_info(lines)
        if _is_placeholder_template(path, info):
            print(f"SKIP {relative}: placeholder template")
            skipped += 1
            continue
        if info.description is None:
            print(f"SKIP {relative}: no Description or Purpose in leading header")
            skipped += 1
            continue

        metadata = None
        metadata_source = "fallback"
        if source is not None:
            source_file = source / relative
            if source_file.is_file():
                metadata = _extract_thales_metadata(source_file)
                if metadata is not None:
                    metadata_source = f"source:{source_file.relative_to(source)}"

        if metadata is None:
            metadata = ("a9322", _creation_date(path))

        user, date = metadata
        new_header = _make_header(path.name, date, user, info.description)
        body = lines[info.end:]
        new_lines = new_header + body
        updated_text = newline.join(new_lines)
        if has_final_newline:
            updated_text += newline

        if updated_text == text:
            print(f"UNCHANGED {relative}")
            continue

        action = "WRITE" if write else "UPDATE"
        print(f"{action} {relative} (user={user}, date={date}, {metadata_source})")
        if write:
            _atomic_write(path, updated_text, bom, path.stat().st_mode)
        updated += 1

    mode = "updated" if write else "would update"
    print(f"Summary: {len(files)} VHDL files scanned, {updated} {mode}, {skipped} skipped.")
    return updated


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Preview or update VHDL headers using the THALES template."
    )
    parser.add_argument(
        "--destination",
        type=Path,
        default=None,
        help="destination repository root (default: current working directory)",
    )
    parser.add_argument(
        "--source",
        type=Path,
        help="optional source repository root used to copy THALES user/date metadata",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="write changes; without this option, only preview them",
    )
    args = parser.parse_args()

    if args.destination is None:
        args.destination = Path.cwd()
    args.destination = args.destination.resolve()
    if not args.destination.is_dir():
        parser.error(f"destination repository does not exist: {args.destination}")
    if args.source is not None:
        args.source = args.source.resolve()
        if not args.source.is_dir():
            parser.error(f"source repository does not exist: {args.source}")
    return args


def main() -> int:
    args = parse_args()
    update_headers(args.destination, args.source, args.write)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
