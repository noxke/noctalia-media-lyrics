# Engineering notes — the problems that cost time

The fork's design and usage are in [`plugin/media-lyrics/README.md`](../plugin/media-lyrics/README.md)
and [`FORK.md`](../plugin/media-lyrics/FORK.md), its version history in
[`CHANGELOG.md`](../plugin/media-lyrics/CHANGELOG.md). The toolchain — the Lua syntax check, the lint,
the plugin lifecycle, the project's conventions — is in §9 below.

What follows is the other half of the record: each problem that took real work, the cause as the
evidence identified it, and the change that closed it — so the next person neither re-derives it nor
undoes it by accident. References to `src/…` and `docs/…` are Noctalia's own files, read from a
checkout of <https://github.com/noctalia-dev/noctalia> at commit `45084cf`
(`docs/user/plugins/development/` holds the plugin API documentation).

## 1. The lyric list follows the sung line, with no blank row anywhere

**Symptom.** Centring the sung line needs something that pushes it to the middle. The first attempt
put a spacer row between lyrics — `ui.box({ height = viewportHeight / 2 - LYRIC_ROW_HEIGHT / 2,
opacity = 0 })` — which showed as a blank row the moment the list moved. The requirement that
replaced it: no blank filler at all, in manual and automatic scrolling alike.

**Cause.** Two independent facts.

- A reveal cannot centre anything. `revealKey` "scrolls the descendant with that `key` into view by
  the smallest distance that shows it whole, and leaves the offset alone when it is already fully
  visible" (`docs/user/plugins/development/declarative-ui.mdx:173-178`), and the arithmetic behind it
  (`src/ui/scroll_into_view.cpp:28-42`) has exactly three outcomes: the target's top, its bottom minus
  the viewport height, or no move at all. A node that *is* the lyric row can therefore only come to
  rest at a viewport edge.
- `opacity = 0` hides colour, not layout. The spacer still occupied `LYRIC_ROW_HEIGHT` of the flow,
  and that is the blank row.

**Fix.** A second node — the centring node — whose own height stays out of the layout: every lyric row
is a fixed-height column (`ui.column({ height = LYRIC_ROW_HEIGHT })`,
`plugin/media-lyrics/panel.luau:427-432`) holding the text row and, in the one row `anchorRow`,
`ui.box({ key = revealKey, height = anchorHeight, opacity = 0 })` (`:424-426`). The box overflows the
row, so it costs no layout height, draws nothing, and a reveal still finds it.
`centringAnchor()` (`:300-308`) chooses `anchorRow` and `anchorHeight` such that the host's
bottom-alignment leaves the sung row's slot centre on `viewportHeight / 2 - LYRIC_ROW_HEIGHT / 2` —
the viewport's middle, given that a slot's own centre sits half a row below the offset the reveal
produces. Before the viewport has been measured the fallback is `LYRIC_ROW_HEIGHT * 2`, and the
above-case distance uses `math.floor` so rounding can only leave the row high, never low (user rule,
centring or slightly high is acceptable, slightly low is not).

**Evidence.** The plugin's own `onScroll(offset, maxOffset)` callback reports 33 rows and
`maxOffset = 871`, i.e. `viewportHeight = 251`, and the reveal offsets for a run of lines landed
exactly on the arithmetic's predictions. A throwaway probe plugin (`.scratch/scroll-lab`, removed in
the cleanup) established the property the trick depends on: a fixed-height column does *not* grow when
a taller child sits in it — its `maxOffset` stayed at 1591 while the child's height went 0 → 408 px.
The same probe showed that a reveal does call `onScroll`, while a programmatic `scrollToBottomRev`
jump does not.

## 2. One wheel notch at the song's first line was pulled straight back

**Symptom.** While the sung line sits on the first row, scrolling the wheel down
"scrolls a little and is immediately pulled back", which reads as a stutter in a scroll that is
otherwise smooth.

**Cause.** Read out of the code, in three links. The panel repaints every 200 ms while it is open and
the song is playing (`plugin/media-lyrics/panel.luau:642-648`, `PAINT_STEP_US = 200000`). Every
repaint recomputes both the centring row and the string it hands to `revealKey` (`:326-339`), and for
a song's first rows `centringAnchor()`'s above case returns a row below `1`, which `:337` turns into
`0` — so the target alternates between the centring node (`revealKey`) and the sung row
(`"lyric-" .. current`). The host re-applies a reveal whenever the string differs from the one it last
applied (`src/ui/ui_tree_reconciler.cpp:881-898`; equal strings return early at `:894`) and
`ScrollView::requestScrollIntoView` (`src/ui/controls/scroll_view.cpp:347-348`) applies it on the next
layout pass (`:534`). A repaint — not the wheel — therefore moved the view, and the reader's own
scroll was undone as soon as the string flipped back.

**Fix.** While the reader has scrolled away (`scrolledAway`), the render resubmits the exact string the
host already holds (module state `revealedTarget`, `panel.luau:56`), rebuilding the centring node in
the sung row when that string is `revealKey` and no row owns it (`:340-348`), and records
`revealTargetOffset = scrollOffset` so the panel does not mistake the host's own move for the
reader's. The freeze is released wherever following resumes — the idle return, the panel opening and
a track change (`:531`, `:551`, `:625`).

**Evidence.** With `scrolledAway` forced true, a temporary probe logged 71 renders over 9 s: `current`
advanced 42 → 45 and `anchorRow` 44 → 47 while the target string stayed `reveal-1` in every one of
them. The scroll test closes the report.

## 3. The progress fill and the capsule's lyric sweep jittered

**Symptom.** The widget's progress fill shortened by a few pixels and grew
again, and the lyric text inside the capsule did the same.

**Cause**, three compounding ones. The player's position arrives as a whole second — `playerctl
--all-players metadata` (`plugin/media-lyrics/service.luau:942`) is parsed with
`tonumber(parts[7])` (`:972`) — and the service republishes it on every poll, twice a second
(`:1025`), so one second is reported twice. Each entry re-anchored its own interpolation on every
event, including a `track` watcher that reset the baseline unconditionally. And the clock was
`os.clock()`, which on this host counts **CPU** time rather than wall time: 26.63 s against the
player's 26.00 s over one probe window.

**Fix.** One shared clock, `plugin/media-lyrics/progress.luau`, required by both entries
(`media.luau:30`, `panel.luau`). It never assigns a report to the display: the display is carried by a
rate inside 0.75 … 1.25 (`progress.luau:20-21`) and a report only steers that rate, using the report's
middle as the best estimate of where the player really is (`MID_SECOND_US = 500000`, `:22-24`). A
report is adopted outright only while paused or when it is a seek, i.e. more than 1.5 s behind or 2 s
ahead of the display (`:15-16`, `:109-124`). Wall time comes from `noctalia.nowMs()` — "wall-clock
milliseconds since the Unix epoch … the only way to see sub-second time"
(`docs/user/plugins/development/runtime-api.mdx:106,114`) — with an `os.clock()` fallback. Because the
module needs `require`, `plugin.toml` declares `plugin_api = 22`, the level that introduced
`module-require` (`src/scripting/plugin_api.h:24`). The panel drives its own repaint at 200 ms
(`panel.luau:642-648`, `:671`).

**Why it cannot step back.** Every assignment that is not a pause or a seek is a forward move
(`rate >= 0.75 > 0`), so the fill width, the karaoke sweep and the time labels are monotone. The price
is a bounded error around the whole-second source.

**Evidence.** 322 render samples over ~85 s: displayed position, fill width and sweep fraction had
zero decreases; the display stayed within −783 … +1204 ms of the report; the raw report changed only
in 1000 ms steps. On the panel, three captures 1 s apart put the bar's fill edge at 1189 → 1193 → 1195
device px.

## 4. The widget's progress fill and the capsule

**Symptom.** The fill began a few pixels inside the capsule on the left, and
did not reach the far end when the song finished.

**Cause.** The capsule the user sees is drawn by the shell around the widget, not by the widget:
`root->width() + 2.0F * pad` starting at `rootX - pad`, with
`pad = widget->barCapsuleSpec().padding * widget->contentScale()`
(`src/shell/bar/bar.cpp:1294-1299`). That padding defaults to `Style::barCapsulePadding = 6.0F`
(`src/ui/style.h:32`) and is configurable per bar within 0 … 48
(`src/config/config_overrides.cpp:289-290`). The plugin's row therefore starts that inset inside the
background it is painted on, and it is the widget that has to allow for it.

**The capsule's cross size.** A horizontal bar draws the capsule at
`capsuleCross = max(1, round(slotCross * bar.capsule_thickness))`, a size the bar owns and the widget's
own box does not affect (`src/shell/bar/bar.cpp:969-973`), with `0.76` as the compile-time default of
the ratio (`src/config/config_types.h:168`). A fill sized from the content alone curves a little more
tightly than the capsule and crosses it.

**Reading them.** `barValue()` (`media.luau:91-96`) reads the bar's effective settings as one table,
named by `bar.order[0]`, and `capsuleInset()` (`media.luau:175-185`) and `capsuleCrossHeight()`
(`media.luau:187-201`) take the padding and the cross size from it; both fall back to the two defaults
above when a key does not read. Reading the table once keeps an optional key a bar leaves out — such as
`capsule_radius` — out of the shell's missing-path warning
(`runtime-api.mdx:22-31`; `noctalia.getSetting("bar.main")` returns the effective table, verified with a
temporary log probe).

**The widget's own keys.** The shell resolves a capsule from the bar's keys and then from
the instance's `[widget.<name>]` overrides (`src/config/config_types.cpp:346-361`), so a radius the
settings window writes belongs to the widget and the bar's value alone misses it. A plugin is told
neither its instance name nor its plugin id, so `thisWidgetEntry()` (`media.luau:135-160`) scans
`noctalia.getSetting("widget")` for the entry whose `type` ends in this entry's id — preferring the
instance the bar's own widget lists name — and `capsuleValue()` (`media.luau:162-173`) reads that entry
before the bar. `resetCapsuleCache()` (`media.luau:214-223`) drops both tables together with the plugin
settings each second, so a change in the settings window reaches the fill without a reload.

**Why a new declared default needs a restart.** A widget's settings map is seeded from the manifest the
shell parsed when the plugin was first loaded. Replacing `plugin.toml` on disk and re-enabling the plugin
refreshes the files but not that parse, so a changed `default` stays ignored until the shell restarts. A
value in `[widget.<name>]`, or one the settings window writes, is applied at once, because the settings
store re-seeds the widget on every change.

**The fill's box.** The outer row carries `paddingH = -inset` and `height = capsuleCross`
(`media.luau:741-748`), the content row the compensating `paddingH = inset` (`:737`), and the fill is
sized from `trackWidth = (rowWidth or maxLength) + 2 * inset` (`:657`). One box then serves the row, the
capsule and the fill: the progress reaches the capsule's far end at 100 % and its pill and the
capsule's share one radius.

**Evidence.** A pixel probe of the fill colour `#40546c` (primary at 0.25 over the capsule `#252c3a`)
found it flush with the capsule's inner edge on both sides, leaving only the 1–2 px anti-aliased
corner. On this bar — the effective `thickness` 28 with `capsule_thickness` 0.8 — the capsule is 22
logical pixels, against the 21.8 the content alone gives.

**The fill's shape.** A rounded box draws as a pill whose radius is
`min(width, height) / 2`, which is why the fill is given the capsule's box rather than one of its own.
The shell's answer is in the built-in `media` widget
(`src/shell/bar/widgets/media_widget.cpp:49-58`, `:195-202`) and in the control it uses
(`src/ui/controls/progress_bar.cpp:15-25`, `:100-131`): the fill is a full-size copy of the track,
given the capsule's own radius through `resolvedBarCapsuleRadius`
(`src/shell/bar/widget.cpp:70-76`), and revealed through a clip node whose width is `width * progress`
— so a small progress is the capsule's round cap with a straight cut. The declarative tree has no clip
prop (`ui_tree_reconciler.cpp`'s known-prop sets carry none), but `ui.progress` maps to that same
`ProgressBar` (`:1417-1433`), so `media.luau:723-731` hands it the capsule's box, `progress`, the fill
colour, a transparent track (`#00000000` — `parseColor` takes a role with an alpha suffix or
`#rrggbb[aa]`, `:155-190`) and the bar's own radius.

**The fill's radius.** `capsuleRadius()` (`media.luau:203-212`) reproduces
`resolvedBarCapsuleRadius`: the automatic pill radius `min(width, height) / 2` for a capsule that leaves
`capsule_radius` out, otherwise `capsule_radius` clamped to that same maximum. The key is the bar's own
(`src/config/schema/config_schema.cpp:2320-2321`; `capsule_padding` 0–48 defaulting to 6,
`capsule_radius` 0–80 and optional, and a per-monitor override of the bar may carry either,
`:2390-2391`), and it is in logical pixels: the shell multiplies it by the content scale when it hands it
to the control (`ui_tree_reconciler.cpp:1428-1429`), so the plugin passes it unscaled. The widget's own
override of the same key is read first — see "The widget's own keys" above.

## 5. The panel's progress bar could not be dragged

**Cause.** `ui.progress` has no interaction at all — `progress`, `fill`, `track`, `radius`, `width`,
`height` (`docs/user/plugins/development/declarative-ui.mdx:63`). `ui.slider` is the API's only
drag-capable control (`:67`), and the panel drag-and-drop API (`ui.dragSource` / `ui.dropZone`,
`:485-548`) exists for reorderable lists and cross-container moves, not for a seek bar.

**Fix.** The transport row uses `ui.slider` (`panel.luau:208-218`: `min` 0, `max` the duration in ms,
`step` 1000, `controlSize = "sm"`, `onChange`, `onDragEnd`). The shell's slider jumps to wherever the
press landed, follows the motion while the button is down, and calls `onDragEnd` on release; the arrow
keys move one `step`, Page Up/Down ten, Home/End go to the ends (`src/ui/controls/slider.cpp`). The
reconciler refuses to overwrite the value of a slider that is being dragged
(`src/ui/ui_tree_reconciler.cpp:1644-1690`), so a repaint cannot interrupt a drag.

**The latch this introduced.** Rendering the drag preview back into the tree made the host re-report
that value through `onChange`, which the tree rendered again — the bar froze at the last applied
second and stopped following the music. The transport row now always renders the clock
and accepts a report only when it differs from the value it last rendered (`panel.luau:197-206`,
`:587-603`); `onDragEnd` seeks, and `progress.noteSeek()` adopts the target immediately so the bar does
not spring back (`progress.luau:104-107`).

**Evidence.** Three captures 1 s apart after the fix: the fill's right edge 434 → 438 → 445 device px
with the left edge fixed, i.e. the bar tracks the music again.

## 6. Verifying a widget without a mouse, and a panel that cannot be photographed

- **No input injection.** `ydotool`, `wtype`, `dotool` and `wlrctl` are all absent, so a drag or a
  wheel notch cannot be synthesized. Verification is a `grim` capture plus a temporary probe inside
  the plugin: a ring buffer of `os.clock()`-stamped lines flushed every 3 s through
  `noctalia.writeFile`, and removed again before the final install.
- **`grim`.** `-o` and `-g` are mutually exclusive, and `-g` takes logical coordinates at the
  output's scale. The widget fill's edge is read by scanning one row of the capture for the fill
  colour.
- **A rotated output writes a transposed capture.** `grim -o` writes the image in the output's own
  pixel size and orientation, while a crop takes coordinates in that image, not in logical layout
  coordinates. Read the scale from the output's mode before converting between the two.
- **A panel is not photographable while a fullscreen window is up.** `niri msg --json layers` lists
  layers flat (namespace, output, layer, keyboard_interactivity) and carries no geometry, so the panel
  cannot be located through it; a fullscreen window also covers Top layers, so the panel is simply not
  in the capture. A probe log from inside the plugin answers the same question without pixels.
- **No `numpy`.** Measurement scripts are PIL-only: grayscale, subtract `ImageFilter.GaussianBlur`,
  threshold at mean + 0.5 · sd, keep runs longer than 8 px, and average with
  `Image.resize((1, h), Image.BOX)` for an ink profile.

## 7. Telling a song from a video, and choosing which player the bar follows

MPRIS describes a film, a web video and a song with the same fields, so the plugin has to decide which
of the three it was handed. The first attempt tested the title, a duration window of 30 s–30 min, and a
list of video hosts in `xesam:url`. All three were wrong. The duration window rejected long songs and
accepted short clips; the host list could never be complete; and the URL turns out to be the weakest
signal of all, because a browser publishes whatever URL its media tab happens to show. The field that
does separate them is `xesam:artist`: NetEase on a song page publishes one, `mpd-mpris` publishes the
tag from the file, and a browser on a video page publishes an empty array — `xesam:artist = ['']`,
which `parts[5] or ""` reads as an empty string. So `looksLikeMusic(track)` is a title, a non-empty
`artist` after trimming, and nothing else.

The setting that carries the decision is `music_only`, renamed from `lyrics_music_only` when its scope
widened from the file writer alone to the whole lyric feature. The rename is a clean break: the old key
is not read. That was deliberate — the setting had only ever been documented as affecting the writer,
so a stale `true` under the old name means what the new default already means.

Which player the bar follows is a separate question, and the first scoring attempt got it wrong twice. The
first version gave a song +2 and a playing player +1, which let a paused song hold the bar against a
playing video — the bar is a now-playing readout, and a paused player is not playing. The second version
reversed the fault in the other direction by keeping "songs beat videos" as the top rule. The order that
holds is *playing first*: +8 playing, +4 song, +1 dedicated player, spaced so that no combination of the
lower rules can overturn a higher one. A paused song therefore yields to a playing video, while MPD still
wins over a browser that reports a song of its own.

One limit is worth recording, because it cannot be fixed from the plugin side. Firefox publishes a
single MPRIS instance for the whole browser, naming only the media tab that is currently active.
Open NetEase and a video in two tabs and the plugin sees one of them, whichever Firefox chose; there is
no way to ask for the other. "Show the song when the browser plays both" therefore reduces to "show the
song when the browser reports one", which is exactly what the artist test already does.

## 8. What the cleanup removed

`.scratch/` held 493 MB: 309 captures, the Noctalia checkout and two package archives used to read the
shell's own behaviour, probe logs, lint copies of the plugin and backups of the shell's settings. It is
gone, as is `plugin/media-lyrics/__pycache__/`. The one piece worth keeping moved to
[`tools/fake_mpris.py`](../tools/fake_mpris.py): a fake MPRIS player (`dbus` + `gi`, no arguments
needed) that exercises the live lyrics path without a browser. Every fact taken from the deleted
checkout is cited above by file and line; the checkout itself is one `git clone` away.

## 9. Toolchain notes

- No language server handles `.luau`. Check syntax by expanding the single `+=` and loading the file
  with a stock Lua:

  ```bash
  sed -E 's/^([[:space:]]*)([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]*\+=[[:space:]]*(.*)$/\1\2 = \2 + \3/' \
    file.luau > /tmp/check.luau && lua -e 'assert(loadfile("/tmp/check.luau"))'
  ```

- Lint a plugin with `noctalia plugins lint <plugin-dir>`. It reports the manifest and the entry
  scripts; it does not load modules an entry reaches through `require`, so a syntax pass above a clean
  lint is still worth running.
- Plugin lifecycle: `noctalia msg plugins list`, `… enable <id>`, `… disable <id>`,
  `… update community`, `noctalia msg settings-open-plugin <id>`; bar placement is Settings → Bar → Add
  widget, with no CLI. `settings.toml` belongs to the settings GUI — `[plugins] enabled` is not
  hand-edited, while a `[widget.<name>]` value typed by hand applies at once.
- Conventions: code, comments and docs in English; the plugin UI ships `en` and `zh-Hans` and Noctalia
  picks by locale. Chinese is the real shape of lyric fixtures. Credentials are never read or printed.
