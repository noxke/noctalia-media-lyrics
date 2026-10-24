#!/usr/bin/env python3
"""Write a lyric request as a matching pair of .lrc and .txt files.

The plugin service calls this script with a JSON request file:

    python3 lyrics_writer.py --request /path/to/request.json

The request holds `directory`, `track` ({title, artist, ...}), `lines`
({time, text, translation?, romanization?}) and the optional `baseName`. When
`baseName` is present (the cached audio file's stem) it becomes the file name,
so MPD and ncmpcpp find the lyrics next to the audio file they belong to;
otherwise the stem is derived from `track`.

One JSON object is printed on stdout and the exit status is always 0, so the
caller reads the object instead of inspecting the process.
"""

import argparse
import json
import os
import re
import sys

MAX_BASE_CHARS = 150
#: Most filesystems cap one path component at 255 bytes, which a 150-character
#: CJK name exceeds, so the stem is limited by both counts.
MAX_BASE_BYTES = 200
FALLBACK_BASE = "lyrics"
TEXT_FIELDS = ("text", "translation", "romanization")

# Whitespace collapses to one space, except the controls that read as whitespace
# only in Unicode (\x1c-\x1f, \x85), which _UNSAFE_RE keeps as underscores instead.
_WHITESPACE_RE = re.compile(r"[^\S\x1c-\x1f\x7f-\x9f]+")
# Path separators and C0/C1 control characters are invalid in file names.
_UNSAFE_RE = re.compile(r"[/\\\x00-\x1f\x7f-\x9f]")
# A request field holds one lyric line, so embedded breaks become spaces.
_FIELD_BREAK_RE = re.compile(r"[\r\n]+")


def sanitize_base(name: str) -> str:
    """Reduce a track name to a file name stem safe on every platform."""
    text = _WHITESPACE_RE.sub(" ", name if isinstance(name, str) else "")
    text = _UNSAFE_RE.sub("_", text).strip(" .")
    # Python slices by code point, so a multi-byte character is never split...
    text = text[:MAX_BASE_CHARS]
    encoded = text.encode("utf-8")
    if len(encoded) > MAX_BASE_BYTES:
        # ...and the byte cap decodes back only complete characters.
        text = encoded[:MAX_BASE_BYTES].decode("utf-8", "ignore")
    return text.strip(" .") or FALLBACK_BASE


def format_timestamp(milliseconds: int) -> str:
    """Format a start offset as an LRC timestamp with two-digit minutes."""
    total = max(0, int(milliseconds))
    minutes, rest = divmod(total, 60_000)
    seconds, millis = divmod(rest, 1000)
    return f"[{minutes:02d}:{seconds:02d}.{millis // 10:02d}]"


def line_time(line: object) -> int | None:
    """Return the line start in milliseconds, or None when the line is unsynced."""
    if not isinstance(line, dict):
        return None
    value = line.get("time")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not value >= 0:  # NaN fails the comparison and is unsynced
        return None
    return int(value)


def _text(value: object) -> str:
    """Return one lyric string; missing, blank and non-string values become ""."""
    if not isinstance(value, str):
        return ""
    return _FIELD_BREAK_RE.sub(" ", value).strip()


def usable_lines(lines: object) -> list[tuple[int | None, list[str]]]:
    """Pair each source line with its texts: original, translation, romanization."""
    entries: list[tuple[int | None, list[str]]] = []
    if not isinstance(lines, list):
        return entries
    for line in lines:
        if not isinstance(line, dict):
            continue
        texts = [text for field in TEXT_FIELDS if (text := _text(line.get(field)))]
        if texts:
            entries.append((line_time(line), texts))
    return entries


def build_lrc(lines: object) -> str:
    """Render the .lrc body; timestamps appear once any line carries a start time."""
    entries = usable_lines(lines)
    timed = any(time is not None for time, _ in entries)
    rows = [
        f"{format_timestamp(time)}{text}" if timed and time is not None else text
        for time, texts in entries
        for text in texts
    ]
    return "".join(f"{row}\n" for row in rows)


def build_txt(lines: object) -> str:
    """Render the .txt body: the same texts in the same order without timestamps."""
    rows = [text for _, texts in usable_lines(lines) for text in texts]
    return "".join(f"{row}\n" for row in rows)


def _base_source(track: object, base_name: object = None) -> str:
    """Stem for the file names: an explicit base name wins over artist/title.

    MPD and ncmpcpp look a lyric file up by the audio file's own stem, so the
    plugin passes the cached audio file's name here whenever it knows one.
    """
    explicit = _text(base_name)
    if explicit:
        return explicit
    if not isinstance(track, dict):
        return ""
    artist = _text(track.get("artist"))
    title = _text(track.get("title"))
    if artist and title:
        return f"{artist} - {title}"
    return artist or title


def _write_file(path: str, content: str) -> None:
    """Write UTF-8 text with LF line endings."""
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(content)


def write_lyrics(request: object) -> dict:
    """Write both lyric files for one request and describe what happened."""
    if not isinstance(request, dict):
        return {"type": "error", "reason": "request must be a JSON object"}
    directory = request.get("directory")
    if not isinstance(directory, str) or not directory.strip():
        return {"type": "error", "reason": "directory is required"}
    # The plugin passes the configured path verbatim (it may start with "~"),
    # so the shell-free expansion happens here where HOME is known.
    directory = os.path.expanduser(directory.strip())
    entries = usable_lines(request.get("lines"))
    if not entries:
        return {"type": "empty", "reason": "no lines"}
    try:
        base = sanitize_base(_base_source(request.get("track"), request.get("baseName")))
        os.makedirs(directory, exist_ok=True)
        root = os.path.abspath(directory)
        lrc_path = os.path.join(root, f"{base}.lrc")
        txt_path = os.path.join(root, f"{base}.txt")
        _write_file(lrc_path, build_lrc(request.get("lines")))
        _write_file(txt_path, build_txt(request.get("lines")))
    except OSError as exc:
        return {"type": "error", "reason": str(exc)}
    except Exception as exc:  # noqa: BLE001 - every failure becomes one JSON object
        return {"type": "error", "reason": f"{type(exc).__name__}: {exc}"}
    return {
        "type": "written",
        "directory": root,
        "base": base,
        "files": [lrc_path, txt_path],
        "lines": len(entries),
    }


def main(argv: list[str] | None = None) -> int:
    """Read the request file, write the lyric files and print one JSON object."""
    parser = argparse.ArgumentParser(description="Write lyric files as .lrc and .txt.")
    parser.add_argument("--request", required=True, help="Path to the JSON request file.")
    try:
        args = parser.parse_args(argv)
        with open(args.request, encoding="utf-8") as handle:
            result = write_lyrics(json.load(handle))
    except SystemExit:
        result = {"type": "error", "reason": "invalid arguments"}
    except Exception as exc:  # noqa: BLE001 - every failure becomes one JSON object
        result = {"type": "error", "reason": f"{type(exc).__name__}: {exc}"}
    sys.stdout.write(json.dumps(result) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
