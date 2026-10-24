# Changelog

## Unreleased — published as its own repository

- The plugin id is `noxke/media-lyrics`, matching its new home. A copy installed under the old id
  keeps that id until it is reinstalled.
- `LICENSE` carries both copyright lines: `h465855hgg` for upstream 1.5.5 and `noxke` for this fork.

## 2.7.0 — songs by artist, and one bar source

- A track is a song when its `artist` tag is non-empty, and a film or web video when it is not. The
  earlier test (title, duration between 30 s and 30 min, and a player URL naming no video service) is
  gone: it misread long tracks and needed a list of video hosts that could never be complete. Local
  files and MPD publish an artist, a browser on a video page does not.
- The setting is renamed `lyrics_music_only` → **`music_only`** and its scope widened from the file
  writer to the whole lyric feature. With it on, a video gets no lyric search, no lyric file and no
  lyric line; the bar shows its title, as a song without lyrics does. The old key is not read.
- The bar follows one player at a time by three rules in order: a playing player beats a paused one, a
  song beats a video, and a dedicated player beats a browser. A paused song therefore yields to a
  playing video, while MPD keeps the bar when a browser reports a song of its own.
- The panel's lyric page names a video instead of reporting that no lyrics were found.

## 2.6.1 — the fill follows the widget's own capsule keys

- `capsule_radius` and `capsule_padding` are read from this widget's settings first and from the bar's
  second, the order the shell resolves the capsule in, so a radius set for the widget alone — the knob
  the settings window offers — reaches the fill.
- Those keys are re-read with the plugin settings each second, so a change in the settings window lands
  without a reload.

## 2.6.0 — the fill's radius follows the bar's

- The progress fill is drawn with the bar's own `capsule_radius`, the value the shell gives the capsule
  around the widget, so a bar whose capsules the user reshapes keeps the fill inside them. A bar that
  leaves the key out gets the automatic pill radius the shell gives its own capsules.
- The bar's `capsule_padding` is read under that key (the read used the C++ field's name and never
  matched), and a bar's settings are read as one table, which keeps the optional keys out of the shell's
  missing-path log.

## 2.5.0 — a narrower item, and lyric files on request

- The default width is four fifths of what it was: `min_length` 80 → 64 and `max_length` 220 → 176
  logical pixels. Long titles and lyric lines are trimmed sooner.
- `lyrics_directory` starts empty. With no directory set the service writes no `.lrc` or `.txt` file
  and never runs the writer script: the lyrics it fetches stay in its memory and in the state it
  publishes, which is all the bar and the panel read. Set a directory to get the files back.

## 2.4.4 — the fill takes the capsule's box

- The shell draws the capsule at the bar's own cross size, `round(thickness × capsule_thickness)`,
  independent of the widget's box, and leaves `widget_capsule_padding` between the widget and the
  capsule. Both are now read from the bar's effective config through `noctalia.getSetting`
  (`bar.order[0]` names the bar; `bar.<name>.thickness`, `bar.<name>.capsule_thickness`,
  `bar.<name>.widget_capsule_padding`). The widget's row takes that cross size, so the fill's pill and
  the capsule's share one radius instead of the fill curving a little more tightly and crossing it; the
  horizontal inset is no longer a mirrored constant. On the user's bar (`thickness` 34,
  `capsule_thickness` 0.65) the capsule is 22 logical pixels.
- A config whose keys do not read falls back to the shell's compile-time defaults (`0.76` ratio,
  `6` padding) and to the content-sized box.

## 2.4.3 — the fill is the shell's progress control

- The progress fill is a `ui.progress` node the size of the capsule's box, the same control the built-in
  `media` widget uses. The control draws a full pill and reveals it through a clip, so a small progress
  shows the capsule's round cap with a straight cut instead of a standing oval a few pixels wide.
- The fill's radius is half the capsule's height and its track is transparent (`#00000000`).
- `PROGRESS_RADIUS` and the extra `media-progress-slot` row are gone; the fill is pulled under the
  content by a negative gap of the whole capsule width.

## 2.4.2 — the fill keeps the capsule's shape

- The bar's capsule is a pill around the widget's box plus its own padding, so the fill takes the same
  box: the outer row adds `paddingV = -CAPSULE_PADDING` next to the horizontal inset it already had.
  The fill's pill radius now equals the capsule's instead of being a smaller one of its own.
- The fill's height stays at or below its width. A rounded box narrower than it is tall draws as a
  standing oval — a few pixels wide and as tall as the capsule at the start of a song — so the fill
  now begins as the capsule's round cap and widens into the full-height pill.

## 2.4.1 — a repaint leaves the reader's place

- While the reader is elsewhere in the song the lyric list hands the host the reveal key it already
  holds, so the repaint that advances the seek bar cannot scroll the view back to the sung row.
- The centring node is rebuilt in the sung row for those renders: the host forgets a key whose node
  is absent, and its return would then read as a new request to scroll.
- The ends of the list are where the target changed on a plain repaint before, because the centring
  node has no row of its own there.

## 2.4.0 — the panel's seek bar

- The panel's progress bar is a slider. Dragging it moves the player when it is released; the arrow
  keys move it one second at a time, Page Up / Page Down ten, while it has focus.
- The bar always renders the shared clock. A value the tree took from the slider's own report comes
  back through `onChange` as that same value, and a bar rendering it would stop where it was.
- The player is moved with `playerctl position`, and the clock adopts the target at once
  (`progress.luau`'s `noteSeek`), so the bar and the labels do not fall back to the old position
  while the confirmation is in flight. Clicking a lyric line takes the same path.

## 2.3.0 — one playback clock

- The bar widget and the panel read the playback position from `progress.luau` instead of interpolating
  the service's whole-second `position` state on their own, so both move together and cannot drift.
- The shared clock carries the position on a rate that each report steers towards the player, so the
  fill, the karaoke sweep and the panel's bar only move forward while the song plays. A report more
  than 1.5 s below the last one, or more than 2 s above the display, is a seek and is followed at once.
- The panel repaints every 200 ms while the song plays: its progress bar travels instead of stepping
  once a second.
- The interpolation is timed with `noctalia.nowMs()`. `os.clock()`, which the widget used before,
  counts CPU time in this host and runs faster than the wall clock.
- `plugin_api` 14 → 22, the level at which an entry can require a shared module.

## 2.2.0 — the media widget's own contract

- The bar widget now carries the built-in `media` widget's contract instead of an invented one: the
  same setting names, defaults and interactions (`album_art_only`, `hide_album_art`, `hide_artist`,
  `artist_first`, `min_length` 80, `max_length` 220, `art_size` 16, `title_scroll`
  `none`/`always`/`on_hover`, `show_progress`, `hide_when_no_media`, `hide_when_idle`), the same text
  fallback order and the same hide rules. `show_lyrics` (default on) is the fork's addition.
- `rotate_album_art` has no counterpart: Noctalia's plugin API exposes no rotation transform.
- Gestures moved into the manifest as `[widget.actions]` defaults — left opens the panel, right
  toggles playback, the mouse thumb buttons skip — which raises `plugin_api` to 14 and lets each bar
  item rebind them under `[widget.<instance>.actions]`.
- Presentation settings of 2.1.0 are gone: display mode, panel-on-hover, progress height/width,
  colours, typography, spacing, cover shape, transitions and animation controls. `translations/`
  carries the new surface (98 keys, `en` + `zh-Hans`).
- A bar entry renders a measured tree, so the inline progress bar follows the text; the built-in
  widget paints its own behind the row.

## 2.1.0 — the media widget, with lyrics

- Rebuilt the presentation around the media widget instead of the lyrics plugin: entries are now
  `media.luau` (bar widget), `panel.luau` (panel), `service.luau` (service) and `shortcut.luau`, with
  ids `media`, `panel`, `service` and `open_panel`.
- The bar widget is an album art + track text item with a thin progress bar
  (`show_progress`, `progress_height`, `progress_width`), hides itself while no track plays, and
  falls back to `artist - title` instead of a "no lyrics" notice.
- Gestures follow media-widget conventions: left click plays/pauses, the wheel skips tracks, right
  click opens the panel and middle click toggles lyric/track text in `display_mode = "toggle"`.
- The panel is now a now-playing panel: cover, title/artist/album, lyric source and saved file,
  progress with position/duration, previous/play-pause/next buttons and the full lyrics with the
  current line highlighted and pinned; the lyric-source picker stays below.
- `display_mode` now defaults to `lyrics`; the hover-to-open behaviour is off by default and opt-in
  through `panel_on_hover`.
- `lyrics.luau:643`/`lyrics_shortcut.luau`'s panel reference and the panel state key moved with the
  rename (`media_panel_open`, panel id `local/media-lyrics:panel`).

## 2.0.0 — local fork of 1.5.5

- Renamed to **MediaLyrics**, because this plugin is meant to become the media widget with lyrics;
  the fork notes are in [FORK.md](FORK.md). (Earlier revisions were called `local/lyrics-cached`, then
  `local/lyrics-saved`.)
- Added the **Lyrics directory** setting: every track's lyrics are written to disk as
  `<artist> - <title>.lrc` (timed, translation and romanization interleaved under each line) and
  `<artist> - <title>.txt` (timestamp-free, for ncmpcpp's lyrics screen). Default `~/Musics/Lyrics`.
- Added the **Lyrics for songs only** setting (`music_only` as of 2.7.0, on by default): a track with
  no artist tag is a film or web video, and no lyrics are searched or written for it.
- Removed the audio cache that an earlier revision of this fork carried: its settings,
  `song_cache.py`, `test_song_cache.py` and the `ffmpeg`/`ffprobe` dependencies.
- Everything else is unchanged from upstream 1.5.5.

## 1.5.5

- Retry MPRIS discovery after a short startup failure instead of leaving the
  service stuck while `playerctl` waits for the session bus.
- Add a timeout to each `playerctl` poll so the service remains recoverable
  when a player is unavailable during login.
- Use the translated no-lyrics message when the widget is visible without
  lyrics; the existing hide-when-no-lyrics option still hides it completely.

## 1.5.4

- Bound MPRIS metadata output and field processing so unusually large song
  metadata is discarded instead of exhausting the async callback CPU budget.

## 1.5.3

- Replace pattern-based MPRIS metadata parsing with a linear separator scan so
  unusually large or malformed player metadata cannot exhaust the async
  callback CPU budget.

## 1.5.2

- Filter duplicate Musixmatch subtitle entries at the same timestamp so
  repeated API entries do not flash several unrelated lyric lines during
  playback.

## 1.5.1

- Fix the service exceeding Noctalia's async callback CPU budget when playback
  starts by skipping the potentially very large MPRIS `xesam:asText` field
  unless MPRIS lyrics are enabled as a source.

## 1.5.0

- Move display mode, lyric layers, karaoke, animation, scrolling, sizing,
  typography, spacing, cue text, and alignment into per-widget settings.
- Keep lyric sources, player selection, timing, polling, and credentials shared
  by the singleton background service.
- Continue fetching lyrics when one widget uses track-only mode so other widget
  instances can display synchronized lyrics.
- Existing 1.4 display settings must be reapplied for each lyrics widget after
  upgrading; source and service settings are unchanged.

## 1.4.6

- Fix MPRIS player detection on systems where `/bin/sh` is `dash` rather than
  Bash, contributed by @Dioxane123 in [#404](https://github.com/noctalia-dev/community-plugins/pull/404).

## 1.4.5

- Add a per-widget option to hide the lyrics widget when no lyrics are
  available, contributed by @NullSeile in [#216](https://github.com/noctalia-dev/community-plugins/pull/216).
- Keep the widget visible in track-only mode when that option is enabled.

## 1.4.4

- Add ranked, selectable LRCLIB results through an attached selector panel and
  `open_selector` shortcut.
- Bind candidate requests and selected results to the current track so stale
  responses cannot replace current lyrics.

## 1.4.3

- Add controls to hide the fallback glyph and its picker when it is disabled.
- Add mouse-wheel previous/next track controls.
- Use Noctalia's host scroll handling for the widget.

## 1.4.2

- Add Simplified Chinese translations.
- Restore `splayer` in the automatic-source settings help text.
- Add matched-provider and iTunes Search artwork fallbacks when MPRIS artwork is
  unavailable, with content-type detection, bounded cache cleanup, and stale
  request protection.

## 1.4.1

- Add an SPlayer preset that consumes SPlayer's complete current lyric data,
  including line and word timing, translations, romanization, background lines,
  and duet markers.
- Preserve SPlayer word boundaries and expose character timing for karaoke
  highlighting without tying the preset to a specific upstream music service.
- Pass MPRIS track IDs and media URLs through the service for stable track
  identity.
- Detect pseudo word-timed lines whose inferred end time is stretched to the
  next LRC timestamp, restoring instrumental-break cues without changing real
  multi-word timing.

## 1.4.0

- Add English and Simplified Chinese localization following Noctalia's global
  language, without exposing unsupported per-plugin language overrides.
- Add translation and romanization lyric layers with double-line display,
  independent visibility controls, and secondary-line priorities.
- Add unified LRCLIB, NetEase, QQ Music, Kugou, Qishui, Apple Music, Spotify,
  Musixmatch, MPRIS, custom HTTP, and external IPC source handling.
- Add manually supplied Spotify, Apple Music, Musixmatch, and Qishui credentials
  without automatic browser-cookie discovery or credential logging.
- Add lyrics timing offset and configurable MPRIS polling interval.
- Add cover shape, custom radius, and cover size controls.
- Add track-only mode, per-character karaoke toggle, font family/size/weight,
  secondary font size, supported baseline styles, line spacing, and side padding.
- Add typewriter, pulse, and blink transitions alongside existing animations.
- Cancel stale source callbacks when changing sources on the same track, and
  show credential settings only for their selected source.
- Add independent primary/secondary lyric font sizes and inter-line spacing.
- Reorganize settings into a focused common view and a collapsed advanced view
  for credentials, source ordering, polling, marquee metrics, and fine layout.

## 1.3.0

- Add an option for intro/interlude characters to follow the interface font or
  use a custom installed font family.
- Change the default active lyric color to `on_surface`.
- Change the default maximum visible character count to 15.

## 1.2.0

- Select the active MPRIS player across all available `playerctl` players.
- Add optional player allowlist and blocklist settings with wildcard matching.
- Send play/pause commands to the selected player instead of the global default.
- Prevent stale lyric and artwork requests from replacing the current track.

## 1.1.0

- Add per-widget active and inactive lyric color controls.
- Keep theme-aware semantic colors as defaults while allowing custom colors.

## 1.0.0

- Initial public release.
- Synchronized status-bar lyric widget with karaoke highlighting and animated
  line transitions (karaoke, cascade, wave, fade, none).
- Long-line smooth marquee scrolling with end pauses.
- Intro/instrumental cue text with configurable characters.
- Lyric sources: auto, LRCLIB, public NetEase, MPRIS text, custom HTTP, and
  external IPC push.
- Album artwork display with circular crop and runtime cache.
- Track-information fallback (`title + artist`) when no lyrics are available.
- Right-click pause/resume via `playerctl` with dimmed paused state.
- KRC dynamic-lyric parsing (plain, prefixed, and three-argument formats).
