#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import lyrics_writer


SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lyrics_writer.py")

SYNCED_LINES = [
    {"time": 12345, "text": "原文", "translation": "译文", "romanization": "romaji"},
    {"time": -1, "text": "plain unsynced line"},
]


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def run_cli(request, workdir):
    """Write the request file next to the target directory and run the script."""
    request_path = os.path.join(workdir, "request.json")
    with open(request_path, "w", encoding="utf-8") as handle:
        json.dump(request, handle, ensure_ascii=False)
    return subprocess.run(
        [sys.executable, SCRIPT, "--request", request_path],
        capture_output=True,
        text=True,
        check=False,
    )


class SanitizeBaseTest(unittest.TestCase):
    def test_replaces_separators_and_control_characters(self):
        self.assertEqual(
            lyrics_writer.sanitize_base("AC/DC - Back\\Slash\x00\x1f"),
            "AC_DC - Back_Slash__",
        )

    def test_collapses_whitespace_and_strips_spaces_and_dots(self):
        self.assertEqual(
            lyrics_writer.sanitize_base("  ..Foo \t  Bar..  "),
            "Foo Bar",
        )

    def test_caps_long_names_at_150_characters(self):
        self.assertEqual(lyrics_writer.sanitize_base("a" * 400), "a" * 150)

    def test_caps_multibyte_names_on_a_character_boundary(self):
        # 150 CJK characters are 450 UTF-8 bytes, over the 255-byte limit that
        # most filesystems put on one path component, so the byte cap wins and
        # only whole characters survive.
        capped = lyrics_writer.sanitize_base("あ" * 200)

        self.assertEqual(capped, "あ" * 66)
        self.assertEqual(len(capped.encode("utf-8")), 198)

    def test_falls_back_to_lyrics_when_nothing_is_left(self):
        self.assertEqual(lyrics_writer.sanitize_base(""), "lyrics")
        self.assertEqual(lyrics_writer.sanitize_base("  ..  "), "lyrics")
        self.assertEqual(lyrics_writer.sanitize_base(None), "lyrics")


class FormatTimestampTest(unittest.TestCase):
    def test_formats_milliseconds_as_centisecond_brackets(self):
        cases = {
            0: "[00:00.00]",
            1000: "[00:01.00]",
            59999: "[00:59.99]",
            60000: "[01:00.00]",
            600000: "[10:00.00]",
            3599999: "[59:59.99]",
        }

        for milliseconds, expected in cases.items():
            with self.subTest(milliseconds=milliseconds):
                self.assertEqual(lyrics_writer.format_timestamp(milliseconds), expected)


class BuildLrcTest(unittest.TestCase):
    def test_stacks_translation_and_romanization_under_the_original(self):
        lines = [{"time": 12345, "text": "原文", "translation": "译文", "romanization": "romaji"}]

        self.assertEqual(
            lyrics_writer.build_lrc(lines),
            "[00:12.34]原文\n[00:12.34]译文\n[00:12.34]romaji\n",
        )

    def test_unsynced_only_lines_produce_no_brackets(self):
        lines = [
            {"time": -1, "text": "first"},
            {"text": "second"},
            {"time": "soon", "text": "third"},
            {"time": None, "text": "fourth"},
        ]

        rendered = lyrics_writer.build_lrc(lines)

        self.assertNotIn("[", rendered)
        self.assertEqual(rendered, "first\nsecond\nthird\nfourth\n")

    def test_unsynced_line_in_a_synced_file_stays_plain(self):
        lines = [{"time": 1000, "text": "timed"}, {"time": -1, "text": "untimed"}]

        self.assertEqual(lyrics_writer.build_lrc(lines), "[00:01.00]timed\nuntimed\n")

    def test_skips_blank_texts(self):
        lines = [
            {"time": 0, "text": "", "translation": "译文", "romanization": "   "},
            {"time": 0, "text": "text"},
        ]

        self.assertEqual(lyrics_writer.build_lrc(lines), "[00:00.00]译文\n[00:00.00]text\n")

    def test_no_usable_lines_renders_nothing(self):
        self.assertEqual(lyrics_writer.build_lrc([]), "")
        self.assertEqual(lyrics_writer.build_lrc(None), "")
        self.assertEqual(lyrics_writer.build_lrc([{"time": 0, "text": ""}]), "")


class BuildTxtTest(unittest.TestCase):
    def test_keeps_order_without_any_brackets(self):
        lines = [
            {"time": 1000, "text": "a", "translation": "b", "romanization": "c"},
            {"time": -1, "text": "d"},
        ]

        rendered = lyrics_writer.build_txt(lines)

        self.assertNotIn("[", rendered)
        self.assertEqual(rendered, "a\nb\nc\nd\n")

    def test_skips_blank_texts(self):
        lines = [{"time": 1000, "text": "a", "translation": ""}, {"text": "b"}]

        self.assertEqual(lyrics_writer.build_txt(lines), "a\nb\n")


class WriteLyricsTest(unittest.TestCase):
    def test_writes_both_files_and_creates_missing_directories(self):
        with tempfile.TemporaryDirectory() as workdir:
            target = os.path.join(workdir, "a", "b", "lyrics")

            result = lyrics_writer.write_lyrics({
                "directory": target,
                "track": {"artist": "A", "title": "T"},
                "lines": SYNCED_LINES,
            })

            self.assertEqual(result["type"], "written")
            self.assertEqual(result["directory"], os.path.abspath(target))
            self.assertEqual(result["base"], "A - T")
            self.assertEqual(result["lines"], 2)
            self.assertEqual(result["files"], [
                os.path.join(target, "A - T.lrc"),
                os.path.join(target, "A - T.txt"),
            ])
            self.assertEqual(read_bytes(result["files"][0]),
                             lyrics_writer.build_lrc(SYNCED_LINES).encode("utf-8"))
            self.assertEqual(read_bytes(result["files"][1]),
                             lyrics_writer.build_txt(SYNCED_LINES).encode("utf-8"))

    def test_expands_a_leading_tilde_in_the_directory(self):
        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {"HOME": home}):
            result = lyrics_writer.write_lyrics({
                "directory": "~/lyrics",
                "track": {"artist": "A", "title": "T"},
                "lines": SYNCED_LINES,
            })

            self.assertEqual(result["type"], "written")
            self.assertEqual(result["directory"], os.path.join(home, "lyrics"))
            self.assertEqual(result["files"][0], os.path.join(home, "lyrics", "A - T.lrc"))
            self.assertTrue(os.path.isfile(result["files"][0]))

    def test_an_explicit_base_name_wins_over_the_track_metadata(self):
        with tempfile.TemporaryDirectory() as workdir:
            result = lyrics_writer.write_lyrics({
                "directory": workdir,
                "track": {"artist": "LiSA", "title": "一番の宝物 (Yui Ver.)"},
                # The cached audio file's stem, which is what ncmpcpp looks up.
                "baseName": "LiSA_VISUAL ARTS _ Key - 一番の宝物 (Yui Ver.)",
                "lines": SYNCED_LINES,
            })

            self.assertEqual(result["type"], "written")
            self.assertEqual(result["base"], "LiSA_VISUAL ARTS _ Key - 一番の宝物 (Yui Ver.)")
            self.assertEqual(result["files"], [
                os.path.join(workdir, "LiSA_VISUAL ARTS _ Key - 一番の宝物 (Yui Ver.).lrc"),
                os.path.join(workdir, "LiSA_VISUAL ARTS _ Key - 一番の宝物 (Yui Ver.).txt"),
            ])

    def test_an_explicit_base_name_is_sanitized_and_blank_falls_back(self):
        with tempfile.TemporaryDirectory() as workdir:
            dirty = lyrics_writer.write_lyrics({
                "directory": workdir,
                "track": {"artist": "A", "title": "T"},
                "baseName": "AC/DC - Back\\in Black",
                "lines": SYNCED_LINES,
            })
            self.assertEqual(dirty["base"], "AC_DC - Back_in Black")

            blank = lyrics_writer.write_lyrics({
                "directory": workdir,
                "track": {"artist": "A", "title": "T"},
                "baseName": "   ",
                "lines": SYNCED_LINES,
            })
            self.assertEqual(blank["base"], "A - T")

    def test_derives_the_file_name_from_artist_and_title(self):
        cases = [
            ({"artist": "Red Hot Chili Peppers", "title": "Can't Stop"},
             "Red Hot Chili Peppers - Can't Stop"),
            ({"artist": "Artist Only"}, "Artist Only"),
            ({"title": "Title Only"}, "Title Only"),
            ({}, "lyrics"),
            ({"artist": " ", "title": ""}, "lyrics"),
        ]

        for track, expected in cases:
            with self.subTest(track=track), tempfile.TemporaryDirectory() as workdir:
                result = lyrics_writer.write_lyrics({
                    "directory": workdir,
                    "track": track,
                    "lines": [{"time": 0, "text": "x"}],
                })

                self.assertEqual(result["base"], expected)
                self.assertEqual(sorted(os.listdir(workdir)),
                                 sorted([f"{expected}.lrc", f"{expected}.txt"]))

    def test_empty_lines_write_nothing(self):
        empty_payloads = [
            [],
            None,
            "no lines here",
            [{"time": 1000, "text": ""}],
            [{"time": -1}],
        ]

        for lines in empty_payloads:
            with self.subTest(lines=lines), tempfile.TemporaryDirectory() as workdir:
                result = lyrics_writer.write_lyrics({
                    "directory": workdir,
                    "track": {"artist": "A", "title": "T"},
                    "lines": lines,
                })

                self.assertEqual(result, {"type": "empty", "reason": "no lines"})
                self.assertEqual(os.listdir(workdir), [])

    def test_missing_directory_reports_error(self):
        result = lyrics_writer.write_lyrics({"lines": [{"time": 0, "text": "x"}]})

        self.assertEqual(result["type"], "error")

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores file modes")
    def test_unwritable_directory_reports_error(self):
        with tempfile.TemporaryDirectory() as workdir:
            locked = os.path.join(workdir, "locked")
            os.mkdir(locked)
            os.chmod(locked, 0o500)
            try:
                result = lyrics_writer.write_lyrics({
                    "directory": locked,
                    "lines": [{"time": 0, "text": "x"}],
                })
            finally:
                os.chmod(locked, 0o700)

        self.assertEqual(result["type"], "error")
        self.assertTrue(result["reason"])

    def test_directory_path_that_is_a_file_reports_error(self):
        with tempfile.TemporaryDirectory() as workdir:
            blocker = os.path.join(workdir, "blocker")
            with open(blocker, "w", encoding="utf-8") as handle:
                handle.write("not a directory")

            result = lyrics_writer.write_lyrics({
                "directory": blocker,
                "lines": [{"time": 0, "text": "x"}],
            })

        self.assertEqual(result["type"], "error")


class CliTest(unittest.TestCase):
    def test_end_to_end_writes_exact_bytes(self):
        with tempfile.TemporaryDirectory() as workdir:
            target = os.path.join(workdir, "out")
            request = {
                "directory": target,
                "track": {
                    "title": "Can't Stop",
                    "artist": "Red Hot Chili Peppers",
                    "album": "By the Way",
                    "duration": 290.0,
                },
                "source": "netease",
                "lines": SYNCED_LINES,
            }

            completed = run_cli(request, workdir)

            self.assertEqual(completed.returncode, 0)
            self.assertEqual(completed.stdout.count("\n"), 1)
            payload = json.loads(completed.stdout)
            self.assertEqual(payload["type"], "written")
            self.assertEqual(payload["directory"], target)
            self.assertEqual(payload["base"], "Red Hot Chili Peppers - Can't Stop")
            self.assertEqual(payload["lines"], 2)
            lrc_path = os.path.join(target, "Red Hot Chili Peppers - Can't Stop.lrc")
            txt_path = os.path.join(target, "Red Hot Chili Peppers - Can't Stop.txt")
            self.assertEqual(payload["files"], [lrc_path, txt_path])
            self.assertEqual(
                read_bytes(lrc_path),
                "[00:12.34]原文\n[00:12.34]译文\n[00:12.34]romaji\nplain unsynced line\n".encode("utf-8"),
            )
            self.assertEqual(
                read_bytes(txt_path),
                "原文\n译文\nromaji\nplain unsynced line\n".encode("utf-8"),
            )
            self.assertNotIn(b"\r", read_bytes(lrc_path) + read_bytes(txt_path))

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores file modes")
    def test_unwritable_directory_exits_zero_with_error_object(self):
        with tempfile.TemporaryDirectory() as workdir:
            locked = os.path.join(workdir, "locked")
            os.mkdir(locked)
            os.chmod(locked, 0o500)
            try:
                completed = run_cli({"directory": locked, "lines": [{"time": 0, "text": "x"}]}, workdir)
            finally:
                os.chmod(locked, 0o700)

        self.assertEqual(completed.returncode, 0)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["type"], "error")
        self.assertTrue(payload["reason"])

    def test_missing_request_file_exits_zero_with_error_object(self):
        with tempfile.TemporaryDirectory() as workdir:
            completed = subprocess.run(
                [sys.executable, SCRIPT, "--request", os.path.join(workdir, "absent.json")],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(json.loads(completed.stdout)["type"], "error")


if __name__ == "__main__":
    unittest.main()
