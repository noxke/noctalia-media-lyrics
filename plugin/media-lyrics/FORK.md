# Fork notes

This directory is a local fork of the community plugin **`h465855hgg/lyrics` 1.5.5** (MIT). Upstream
is a lyrics widget: it shows the current line in the bar and, when several matches are found, offers a
panel to pick one. This fork keeps all of that and adds:

- **lyric files on disk** — the lyrics it is already showing are written to a configurable directory
  as a timestamped `.lrc` plus a timestamp-free `.txt`, so MPD clients such as ncmpcpp can display
  them without talking to the plugin;
- **a music-only gate** — films and web videos are not written out;
- **media-widget behaviour** — the widget carries the settings, rendering rules and gestures of
  Noctalia's built-in `media` item (art, one text line, inline progress, hide rules), with the lyric
  line in place of the track text; the panel is a now-playing panel with transport controls, the full
  lyrics and the lyric-source picker.

- Origin: <https://github.com/h465855hgg/lyrics>, tag `1.5.5` (the release Noctalia's community source
  materializes for the plugin id `h465855hgg/lyrics`).
- This directory is the source of truth; the installed copy under
  `${XDG_DATA_HOME:-~/.local/share}/noctalia/plugins/media-lyrics/` is a copy of it.
- Design and usage: [`README.md`](README.md); the problems behind the changes:
  [`../../docs/engineering-notes.md`](../../docs/engineering-notes.md).
- Name: **MediaLyrics** (`noxke/media-lyrics`), because this plugin is meant to be the media widget —
  Noctalia's built-in `media` widget extended with lyrics — rather than a lyrics plugin alone.

## Differences from upstream 1.5.5

| Change | Where |
| --- | --- |
| Plugin id `h465855hgg/lyrics` → `noxke/media-lyrics` | `plugin.toml`, the panel references at `media.luau` and `shortcut.luau`, and `README.md` |
| `author` → `noxke`, `name` → `MediaLyrics` | `plugin.toml` header |
| Entries renamed to media-first names: `lyrics.luau` → `media.luau`, `lyrics_selector.luau` → `panel.luau`, `lyrics_service.luau` → `service.luau`, `lyrics_shortcut.luau` → `shortcut.luau`; ids `lyrics`/`selector`/`service`/`open_selector` → `media`/`panel`/`service`/`open_panel` | `plugin.toml` |
| Community-store assets not carried over: `.cache/`, `screenshots/` | — |
| `FORK.md` and `LICENSE` added | — |
| **Lyric files**: `.lrc` (timed, translation/romanization interleaved) + `.txt` (no timestamps) written to a configurable directory | `lyrics_writer.py`, `service.luau`, `plugin.toml` |
| **Songs only** (`music_only`): a track with no artist tag is a video — no lyrics searched or written | `service.luau`, `plugin.toml` |
| **Media widget**: the built-in `media` widget's twelve settings and its layout, minus `rotate_album_art` (the plugin API has no rotation), plus `show_lyrics` | `media.luau`, `plugin.toml` |
| **Media panel**: cover, title/artist/album, progress with position/duration, prev/play-pause/next buttons, the full lyrics with the current line highlighted, plus upstream's lyric-source picker | `panel.luau`, `plugin.toml` |
| Gesture defaults declared in the manifest (`left` panel, `right` play/pause, `back`/`forward` skip); presentation settings of 1.5.5 dropped | `plugin.toml`, `translations/` |
| Version `1.5.5` → `2.7.0`, `plugin_api` → `22` | `plugin.toml` header |

## What this fork adds

**A lyrics directory setting.** `lyrics_directory` decides where the lyric files go, and it starts
empty. With a directory set, every track whose lyrics the bar knows about is written there by
`lyrics_writer.py` as `<artist> - <title>.lrc` — timestamped `[mm:ss.xx]` lines, with each Chinese
translation and romanization repeated under its original line at the same timestamp — and
`<artist> - <title>.txt`, the same lines with every timestamp removed, which is the form ncmpcpp's
lyrics screen wants. Left empty, nothing is written or run and the lyrics stay in the service's
memory, which is what the bar and the panel read.

The base name is `<artist> - <title>` sanitised for ncmpcpp (`/`, `\` and control characters become
`_`, whitespace collapses, 150 characters), so a lyric file matches a song file that carries the same
`<artist> - <title>` stem. ncmpcpp searches either the song's own directory
(`store_lyrics_in_song_dir = yes`) or a single flat `lyrics_directory`, so point it at this setting.

**Songs only.** MPRIS reports films, series and web videos exactly like songs, so the plugin asks "is
this a song?" before it does anything with lyrics: a track whose `artist` tag is non-empty is a song,
one without is a video. A video gets no lyrics searched, none written, and no lyric line in the bar —
its title is shown instead. Turning the `music_only` setting off treats every track as a song.

**Media widget behaviour.** The bar item renders its own tree through `barWidget.render`: album art (or
a `disc` glyph with a player, `music-off` without one) and one text line holding the current lyric line,
or `artist - title` when `show_lyrics` is off or the track has no lyrics, and an inline `ui.progress`
bar after the text with `show_progress`. `hide_when_no_media` and `hide_when_idle` drive
`barWidget.setVisible`.

The settings, their defaults and their interactions are the built-in widget's: `album_art_only`,
`hide_album_art`, `hide_artist`, `artist_first`, `min_length` 80, `max_length` 220, `art_size` 16,
`title_scroll` (`none`/`always`/`on_hover`), `show_progress`, `hide_when_no_media`, `hide_when_idle`
and the fork's `show_lyrics`. `rotate_album_art` is not carried over: the plugin API exposes no
rotation. A bar entry lays out a measured tree, so the progress bar follows the text instead of being
painted behind it, as the built-in widget does with a canvas.

Gestures are manifest defaults rather than runtime callbacks, which needs an API level of at least
14; the entries that draw playback share one clock in `progress.luau`, and an entry can only require
another file from level 22, so the manifest declares `plugin_api` 22:

```toml
[widget.actions]
left = "panel-toggle noxke/media-lyrics:panel"
right = "media toggle"
back = "media previous"
forward = "media next"
```

Any of them is rebindable per bar item under `[widget.<instance>.actions]`, and `none` leaves the
gesture free.

**Media panel.** Left click, the `open_panel` shortcut or the panel toggle command opens a now-playing
panel: cover, title, artist/album, the lyric source and the saved file name, a progress bar with
position and duration, previous/play-pause/next buttons (run through `playerctl` against the player the
service tracks) and the full lyrics with the current line highlighted and pinned above the list.
Upstream's candidate picker appears below when more than one lyric match was found.

**No audio cache.** An earlier revision of this fork downloaded the playing track from NetEase into a
cache directory. It was removed on purpose: a browser-side capture knows the exact song id and stream
URL and can do that download better, and the batch writer in [`../../tools/`](../../tools) is what
actually makes lyrics reachable for songs already in the library.

## Checking it by hand

```bash
cd plugin/media-lyrics
python3 -W error::ResourceWarning -m unittest test_lyric_sources.py test_lyrics_writer.py
noctalia plugins lint .
```

`lyrics_writer.py --request <path>` prints exactly one JSON object on stdout and exits 0 even on
failure; its request/result contract is documented in the module docstring.

The widget and panel are inside the `.luau` entries; the lyric fetching and file writing paths are
upstream plus the fork's writer hook.

## Install

```bash
tools/install-plugin.sh install     # rsync + lint + enable, from the workspace root
```

Bar placement is a Settings UI action; `~/.local/state/noctalia/settings.toml` is GUI-owned. The
bar entry must point at `noxke/media-lyrics:media`; after the rename the old `...:lyrics` entry no
longer resolves.
