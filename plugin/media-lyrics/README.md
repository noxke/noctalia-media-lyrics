# MediaLyrics 2.7.0 (fork of Noctalia Lyrics)

A media item for the Noctalia bar: album art, a single text line and an inline progress bar, with the
current lyric line replacing `artist - title` while a track plays. A panel carries the transport
controls, the full lyrics and the lyric-source picker.

This directory is a local fork of the community plugin `h465855hgg/lyrics` 1.5.5 (MIT). The widget
follows the settings, rendering rules and gestures of Noctalia's built-in `media` widget, so it can
replace that item instead of sitting beside it. On top of that it can write every track's lyrics to disk.
See [FORK.md](FORK.md) for the file-by-file differences and [CHANGELOG.md](CHANGELOG.md) for the
versions.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noxke/media-lyrics` |
| Version | 2.7.0 (`plugin_api` 22) |
| Entries | Bar widget `media`, panel `panel`, service `service`, shortcut `open_panel` |

## Requirements

Install these commands on `PATH`:

- `playerctl`: read and control MPRIS players.
- `python3`: run the unified lyric-source adapter and the lyric writer.
- `cp`: preserve local MPRIS artwork in the plugin cache.
- `chmod`: secures the temporary request directory before credentials are written.
- `timeout`: bounds each `playerctl` metadata poll during startup and runtime.

## Install

This directory is a Noctalia local plugin, not a catalogue entry. Noctalia scans
`$XDG_DATA_HOME/noctalia/plugins` (usually `~/.local/share/noctalia/plugins`), so it has to be copied
there under a directory whose name matches the plugin part of the id:

```sh
git clone https://github.com/noxke/noctalia-media-lyrics
dest="${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins/media-lyrics"
mkdir -p "$dest"
tar -C noctalia-media-lyrics/plugin/media-lyrics --exclude=.cache -cf - . | tar -C "$dest" -xf -
noctalia plugins lint "$dest"
noctalia msg plugins enable noxke/media-lyrics
```

From a checkout of this repository, `tools/install-plugin.sh install` runs those four commands.
Then add the widget: Settings → Bar → Add widget → **MediaLyrics**.

The `.cache` directory inside the installed copy holds artwork and the request scratch space; leave
it in place when updating and only the source files need to be replaced.

## Usage

Enable `noxke/media-lyrics`, let its `service` start, and add the `media` widget to a bar. The widget
shows the album art (or a glyph when the track has none), the current lyric line — `artist - title`
when the track has no lyrics, `title - artist` with `artist_first` — and, with `show_progress`, a
progress bar after the text. It hides itself according to `hide_when_no_media` and `hide_when_idle`.

Gestures and their defaults:

| Gesture | Action |
| --- | --- |
| Left click | `panel-toggle noxke/media-lyrics:panel` |
| Right click | `media toggle` (play / pause) |
| Back / forward (mouse thumb buttons) | `media previous` / `media next` |

The manifest declares those as `[widget.actions]` defaults. Rebind them per bar item under
`[widget.<instance>.actions]` in `~/.local/state/noctalia/settings.toml`, or leave a gesture unbound
with `none`; a binding wins over the script's own callback.

Noctalia's plugin API exposes no rotation transform, so the built-in widget's `rotate_album_art` has no
counterpart here. Its other eleven settings do, with the same names and defaults.

Bind the `open_panel` shortcut to a key combination in Noctalia's shortcut settings, or open the panel
directly:

```sh
noctalia msg panel-toggle noxke/media-lyrics:panel
```

The panel shows the cover, title, artist/album, the lyric source and the saved file, a draggable
seek bar with position and duration, previous / play-pause / next buttons, the full lyrics with the
current line highlighted, and the source picker when several lyric matches were found. Dragging the
bar moves the player when it is released; the arrow keys move it one second at a time, and Page
Up / Page Down ten, while it has keyboard focus.

## Settings

Plugin-wide settings cover source selection and order, translation language, timing offset, MPRIS
polling, player filters, the lyrics directory and credentials.

| Setting | Default | Meaning |
| --- | --- | --- |
| `lyrics_source` | `auto` | A single source, or `auto` to walk `lyrics_sources` |
| `lyrics_sources` | `lrclib`, `netease`, `splayer`, `qqmusic`, `kugou`, `qishui`, `apple_music`, `spotify`, `musixmatch` | Fallback order for `auto` |
| `translation_language` | `zh-Hans` | Language requested from sources that translate |
| `lyrics_offset_ms` | `0` | Positive shifts the highlighted line earlier |
| `poll_interval_ms` | `500` | MPRIS poll interval |
| `player_allowlist` / `player_blocklist` | empty | Restrict which MPRIS players are tracked |
| `lyrics_directory` | empty | Directory for the `.lrc` and `.txt` files; empty writes none and keeps the lyrics in memory |
| `music_only` | on | Treat a track with no artist tag as a video: no lyrics searched or written |
| `splayer_api_url`, `qishui_api_url`, `qishui_token`, `custom_url`, `custom_json_field`, `spotify_sp_dc`, `spotify_access_token`, `apple_developer_token`, `apple_user_token`, `apple_storefront`, `musixmatch_token` | — | Per-source credentials and endpoints |

Per-widget settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| `show_lyrics` | on | Show the current lyric line instead of the track text |
| `album_art_only` | off | Art only, no text |
| `hide_album_art` | off | Text only, no art or glyph |
| `hide_artist` | off | Drop the artist from the text |
| `artist_first` | off | `artist - title` instead of `title - artist` |
| `min_length` | `64` | Minimum widget width in logical pixels |
| `max_length` | `176` | Maximum width; the text is trimmed to fit |
| `art_size` | `16` | Album art box in logical pixels |
| `title_scroll` | `none` | `none`, `always` or `on_hover` marquee for text wider than the label |
| `show_progress` | off | Progress fill behind the text row |
| `hide_when_no_media` | off | Hide the item while no player is present |
| `hide_when_idle` | off | Hide the item while a player is paused |

`album_art_only`, `hide_album_art`, `hide_artist`, `artist_first`, `min_length`, `max_length`,
`title_scroll` and `show_progress` are hidden in the settings UI while `album_art_only` is on.

A bar entry renders a declarative tree, which the host measures and lays out. The progress fill is the
shell's `ui.progress` control, the one the built-in `media` widget uses: a full pill of the capsule's
box whose rounded ends are revealed through a clip, so a small progress shows the capsule's round cap
with a straight cut instead of a narrow oval. It is laid out ahead of the content and pulled back under
it by a negative gap, since a plugin tree has no z-order. The row's negative padding comes from
`capsule_padding`, the row's height from the capsule cross size (`thickness` × `capsule_thickness`), and
the fill's radius from `capsule_radius` — the value the capsule itself is drawn with, so reshaping the
capsules reshapes the fill with them. `capsule_padding` and `capsule_radius` are looked up on this widget
first and on the bar second, which is the order the shell resolves them in, so a radius set for the
widget alone works. All of them are read from the effective configuration; a capsule that leaves
`capsule_radius` out gets the automatic pill radius the shell gives its own capsules, and a bar that
cannot be read at all falls back to the compile-time defaults `6` and `0.76`.

## Lyrics on disk

`lyrics_directory` starts empty, and with it empty nothing is written: the service keeps the lyrics in
memory and publishes them as state, which is all the bar and the panel need. With a directory set, the
fork writes what the bar is already showing:

- `<artist> - <title>.lrc` — `[mm:ss.xx]` timestamps, each translation and romanization repeated under
  its original line at the same timestamp.
- `<artist> - <title>.txt` — the same lines with every timestamp removed, the form ncmpcpp's lyrics
  screen wants.

The base name is `<artist> - <title>` sanitised for ncmpcpp (`/`, `\` and control characters become
`_`, whitespace collapses, 150-character / 200-byte cap), so a lyric file matches a library file with
the same stem. Point ncmpcpp's `lyrics_directory` at `lyrics_directory`, or set
`store_lyrics_in_song_dir = yes`.

`music_only` separates songs from everything else by the artist tag: a track with a non-empty
`artist` is a song, one without is a film or web video. A video gets no lyrics searched and none
written, and the bar shows its title where a song shows its lyric line. Turn the setting off to
treat every track as a song.

## Lyrics model

Every source is normalized to lines with independent original, translation, romanization and
character-timing fields:

```json
{
  "time": 1200,
  "duration": 1800,
  "text": "Original lyric",
  "translation": "Translated lyric",
  "romanization": "romanized lyric",
  "chars": [1200, 1500, 1800]
}
```

## Sources

`auto` tries the IDs listed in `lyrics_sources` from top to bottom:

- `lrclib`: public LRCLIB search with automatic synchronized-result ranking and manual selection.
- `netease`: public NetEase search, synchronized lyrics, translations and romanization when returned.
- `splayer`: SPlayer's complete current lyric data, including line and word timing, translations,
  romanization, background lines and duet markers. SPlayer must be running; the default API URL is
  `http://127.0.0.1:25884`. Changing this URL sends current track metadata to the configured service.
- `qqmusic`: public QQ Music search and lyric endpoint.
- `kugou`: public Kugou search and lyric download endpoint.
- `qishui`: user-configured HTTP endpoint supporting `{title}`, `{artist}` and `{album}` placeholders.
- `apple_music`: Apple Music catalog and lyrics request with manually supplied tokens.
- `spotify`: Spotify search and color-lyrics request with a manually supplied access token or `sp_dc`.
- `musixmatch`: Musixmatch subtitle request with a manually supplied usertoken.
- `mpris`: embedded `xesam:asText` lyrics from the selected player.
- `custom`: a generic HTTP endpoint.
- `external`: lyrics pushed through Noctalia IPC.

Source APIs change or reject requests by region or account; a failure in automatic mode moves to the
next source. Album artwork uses MPRIS first, then the matched lyric source. LRCLIB, Qishui and
Musixmatch matches fall back to the public iTunes Search API. Cached covers keep their detected image
format, and the oldest files are removed once the cache holds 80 covers.

## Credential warning

Noctalia exposes the source credentials as ordinary string settings, not secret fields, so Spotify,
Apple Music, Musixmatch and Qishui credentials sit in plaintext in Noctalia's settings. The plugin
never reads browser cookies, never logs a credential value, and deletes its temporary credential
request file as soon as the source adapter reads it; the request directory is mode `0700` before any
credential-bearing file is written.

## Local development

Add the parent directory of this checkout as a local Noctalia source and enable the plugin:

```sh
noctalia msg plugins source add media-lyrics-dev path /path/to/noctalia-media-lyrics/plugin
noctalia msg plugins enable noxke/media-lyrics
noctalia msg config-reload
```

Or copy it into Noctalia's plugin directory and lint it in one step:

```sh
tools/install-plugin.sh install     # from the repository root
```

Verification, from this directory:

```sh
python3 -W error::ResourceWarning -m unittest test_lyric_sources.py test_lyrics_writer.py
noctalia plugins lint .
```

There is no language server for `.luau`; check syntax by expanding `+=` and loading the file, as in
[`../../docs/engineering-notes.md`](../../docs/engineering-notes.md) §9.

## External protocol

Address the singleton service with:

```sh
noctalia msg plugin noxke/media-lyrics:service all <event> '<payload>'
```

Supported events: `push-lrc` (synchronized or plain LRC text), `push-json` (JSON with `lines` or
`lyrics`), `push-state` (also updates track, position, playing and cover) and `clear`.

MPRIS track duration and playback position are microseconds; lyric line, duration and character
timestamps are milliseconds.
