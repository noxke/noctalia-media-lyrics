# MediaLyrics for Noctalia

A media widget for the [Noctalia](https://github.com/noctalia-dev/noctalia) bar that replaces the
track title with the lyric line being sung, adds a scrollable lyrics panel, and writes every track's
lyrics to disk for MPD clients such as ncmpcpp.

It follows Noctalia's built-in `media` item — album art, one text line, an inline progress bar, the
same hide rules and gestures — so it takes that item's place rather than sitting beside it. The only
change is the text: while a song plays, the line you hear replaces `artist - title`.

It works with any player on the session bus, not one service: the NetEase web player, Spotify, a
local MPD, a video in Firefox. Playback state comes from MPRIS; lyrics come from nine public sources.

> **Upstream:** this is a fork of [`h465855hgg/lyrics`](https://github.com/h465855hgg/lyrics) 1.5.5
> (MIT). See [FORK.md](plugin/media-lyrics/FORK.md) for the file-by-file differences and
> [CHANGELOG.md](plugin/media-lyrics/CHANGELOG.md) for the versions.

## What it looks like

| Where | What it shows |
| --- | --- |
| Bar widget | Album art, the current lyric line (or `artist - title` between lines), a progress fill behind the text |
| Panel | Album art, title, transport controls, a draggable seek bar, the full synced lyrics, and the lyric-source picker |
| On disk | `<lyrics dir>/<artist> - <title>.lrc` and `.txt`, read by MPD clients without talking to the plugin |

## Requirements

- Noctalia 5.2.x or newer (`plugin_api` 22 — the first level whose entry scripts can require a
  shared module)
- `playerctl`
- `python3`

On Arch:

```sh
sudo pacman -S --needed playerctl python3
```

## Install

The plugin lives in [`plugin/media-lyrics/`](plugin/media-lyrics). Noctalia scans
`$XDG_DATA_HOME/noctalia/plugins` for local plugins, so the source is copied there:

```sh
tools/install-plugin.sh install     # copy, lint, enable
tools/install-plugin.sh status      # what is installed
tools/install-plugin.sh uninstall   # remove
```

Then, in Noctalia:

1. **Add the widget** — Settings → Bar → Add widget → **MediaLyrics**. Placement has no CLI; the
   Settings UI writes it.
2. **Configure it** — `noctalia msg settings-open-plugin noxke/media-lyrics`, or Settings → Plugins →
   MediaLyrics. See [plugin/media-lyrics/README.md](plugin/media-lyrics/README.md) for every setting.
3. **Disable any other lyrics plugin** so only one service polls MPRIS.

## Capsule geometry

The bar draws a capsule around every widget and owns its cross size and radius. The widget reads
those values back out of the effective bar configuration, so the progress fill follows the capsule
automatically — including a per-widget `[widget.<instance>]` override, which the shell resolves
before the bar's own value.

Two settings exist for the cases the automatic read cannot cover, where the capsule's geometry comes
from something other than a `capsule_radius` / `capsule_padding` key:

| Setting | Meaning |
| --- | --- |
| `capsule_radius` | the capsule's corner radius in logical pixels; leave unset to use the shell's pill radius |
| `capsule_padding` | the inset between the widget's box and its capsule; defaults to the shell's `6` |

## Verifying the pipeline

```sh
./setup.sh status      # dependencies, plugin state, MPRIS players on the bus
./setup.sh doctor      # read the playing track off MPRIS and query the lyric APIs directly
```

`doctor` is the honest end-to-end check: it reads the playing track straight from MPRIS, with no
plugin involved, then queries LRCLIB and the source's search endpoint with that title, artist and
duration. If `doctor` cannot find lyrics for a track, the plugin will not find them either.

## Lyric sources

`auto` tries them in order; any one can be forced in the settings.

| Source | Auth |
| --- | --- |
| LRCLIB | none |
| NetEase | none (public search) |
| SPlayer, QQ Music, Kugou, Qishui | none |
| Apple Music | token |
| Spotify | client credentials |
| Musixmatch | API key |

Sources that need credentials stay off until one is supplied; `auto` skips them.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No player in `./setup.sh status` | Is the page actually playing? Firefox only registers a player while media is loaded |
| Widget installed but the bar is empty | The widget is not added (Settings → Bar), or the plugin is disabled (`noctalia msg plugins list \| grep media-lyrics`) |
| Progress fill is a standing oval | The bar's capsule must come from `capsule_radius`; set the widget's `capsule_radius` to match it |
| Wrong or missing lyrics | Run `./setup.sh doctor`; if the lookup is wrong, change `lyrics_source` |
| Lyrics lag the audio | Adjust `lyrics_offset_ms` (positive = earlier) |
| The wrong player wins | Set `player_allowlist` to the player name from `./setup.sh status` |
| A video's title fills the bar | Leave `music_only` on — it requires a non-empty `xesam:artist`, which a music service sets and a video page does not |

## Layout

```
plugin/media-lyrics/         the plugin: widget, panel, service, shortcut
docs/research.md             the protocol survey behind the design
docs/engineering-notes.md    the problems that cost time, their causes and their fixes
setup.sh                     status / doctor / uninstall
lib/doctor.py                MPRIS + lyric-API probe used by `doctor`
tools/install-plugin.sh      copy the plugin into Noctalia's plugin directory, lint, enable
tools/fake_mpris.py          a fake MPRIS player for exercising the live path without a browser
tools/realip.sh              resolve a hostname over DNS-over-HTTPS when the local resolver lies
```

## License

MIT. `plugin/media-lyrics/LICENSE` carries both copyright lines: the upstream plugin's and this
fork's.
