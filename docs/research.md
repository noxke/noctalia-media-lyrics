# Protocol survey: what can be reused for lyrics on Linux

Question: is there a general lyrics protocol on Linux that removes the need for
a custom capture script, bridge and renderer? Measurements below were taken on
this machine (Arch, Noctalia 5.2.0, Firefox playing music.163.com).

## 1. Playback state: MPRIS is the standard, and the browser already speaks it

`org.mpris.MediaPlayer2.Player` over the session bus carries everything the
state half of a sync tool needs, and Chromium/Firefox publish it themselves for
whatever the page is playing:

```
$ busctl --user list | grep -i mpris
dev.noctalia.Mpris
org.mpris.MediaPlayer2.firefox.instance_<pid>

$ gdbus call --session --dest org.mpris.MediaPlayer2.firefox.instance_<pid> \
    --object-path /org/mpris/MediaPlayer2 \
    --method org.freedesktop.DBus.Properties.GetAll org.mpris.MediaPlayer2.Player
({'PlaybackStatus': <'Playing'>, 'Rate': <1.0>,
  'Metadata': <{'mpris:trackid': <objectpath '/org/mpris/MediaPlayer2/firefox'>,
                'xesam:title': <'<title>'>,
                'xesam:album': <'<album>'>,
                'xesam:artist': <['<artist>/<artist>']>,
                'mpris:artUrl': <'file:///home/<user>/.mozilla/firefox/firefox-mpris/<pid>_<n>.png'>,
                'xesam:url': <'https://music.163.com/st/webplayer'>,
                'mpris:length': <int64 226000000>}>,
  'Position': <int64 114000000>, 'CanSeek': <true>, ...},)
```

Noctalia adds its own aggregator on top: `dev.noctalia.Mpris` exposes
`GetActivePlayer`, `GetPlayers`, `GetPositionActive`, `SetPositionActive`,
`GetVolumeActive` and the signals `ActivePlayerChanged`, `PlayersChanged`,
`TrackChanged`. Its own media widget consumes it.

Consequence: track identity, duration, play/pause, rate and position are free.
A custom state machine plus position interpolation duplicates this.

## 2. Lyrics: no protocol, only de facto pieces

- **MPRIS has no lyrics property.** The only informal carrier is the Xesam
  metadata key `xesam:asText`, which lyric-capable players embed; Firefox leaves
  it empty (see the dump above). The community plugin below reads it as its
  `mpris` lyric source.
- **LRCLIB** (`https://lrclib.net/api/get`) is the de facto public lyric API: no
  key, plain + synced lyrics, and a word-sync flag. Measured response keys:
  `plainLyrics`, `syncedLyrics`, `hasWordSync`, `instrumental`, `duration`.
- **Text formats**: LRC (with enhanced and proprietary word-timed variants such
  as NetEase `YRC`/Kugou `KRC`) is what music players actually use. W3C TTML2 is
  the only formal timed-text standard with karaoke support, but it is a
  video/subtitle format and is not what desktop lyric tools consume.

## 3. Existing implementations in the Noctalia community source

`noctalia msg plugins list` (all disabled by default):

| Plugin | plugin_api | Deps | Lyric sources |
|---|---|---|---|
| `h465855hgg/lyrics` 1.5.5 | 3 | `playerctl`, `python3`, `cp`, `chmod`, `timeout` | `lrclib`, `netease`, `splayer`, `qqmusic`, `kugou`, `qishui`, `apple_music`, `spotify`, `musixmatch`, `mpris` (`xesam:asText`), `custom`, `external` |
| `tranzem/media-lyrics` 0.9.7 | 30 | `busctl`, `curl` | LRCLIB only (`/api/get`, then `/api/search`) |
| `goatnath/spotify-lyrics` 1.2.1 | 3 | `playerctl`, `python3`, `syncedlyrics` | the `syncedlyrics` CLI |

`h465855hgg/lyrics` normalizes every source to lines with independent original,
translation, romanization and character-timing fields

```json
{"time": 1200, "duration": 1800, "text": "…", "translation": "…", "romanization": "…", "chars": [1200, 1500, 1800]}
```

and documents an inbound path for captured lyrics:

```sh
noctalia msg plugin h465855hgg/lyrics:service all <event> '<payload>'
# events: push-lrc | push-json | push-state | clear
# payload keys: track, lines, lyrics, position (ms), playing, cover
```

## 4. What cannot be reused: page-session lyrics

Browser MPRIS publishes title/artist/album/duration only — no song id, no lyric
text. Any title-based lookup is therefore a guess, and the public NetEase search
is a demonstrably imperfect one:

```
search "依赖症 阿良良木健"  ->  top hit id 2020087990 (无理无智), not the requested song
```

Word-level NetEase `YRC` timing, the page's translation/romanization layers, and
the exact playing song id live only inside the page. Also measured earlier: some
tracks answer `uncollected`/`nolyric` on both the anonymous API and the page.

### Measured case study of the title-based route

`lib/doctor.py` run while Firefox played a Chinese release (253 s):

```
LRCLIB exact match:
  not found (HTTP 404)
NetEase public search:
  id=<id> '<title>' - <artist> / <artist> (<duration>s)     <- correct
  id=<id> '<title>' - <artist> / <artist> (<duration>s)
  id=<id> '<title>' - <artist> / <artist> (<duration>s)
```

Two lessons: LRCLIB does not cover every Chinese release, so
`lyrics_source=netease` (or `auto` with `netease` first) is the right default for
this workflow; and the public search does return the correct recording when
title, artist and duration line up — the near misses above are a risk, not the
norm.

## 5. Conclusion

- State half: fully replaceable by MPRIS — no custom code.
- Lyrics half: reusable via `h465855hgg/lyrics` (or `media-lyrics`), at the cost
  of title-based lookups and no page-exact word timing.
- Page-exact fidelity (song id, YRC karaoke, page translations) still requires
  capturing inside the page. A capture tool can feed this plugin through the
  `external` protocol instead of shipping its own renderer.

## 6. Environment facts

- `~/.config/noctalia/config.toml` is the hand-written base layer;
  `~/.local/state/noctalia/settings.toml` holds GUI-managed overrides and wins
  over it (documented in Noctalia's configuration docs). `plugins enable`
  writes the `[plugins] enabled` list there.
- Bar widget placement has no CLI (`noctalia msg bar-*` only hides/shows
  bars); it is edited in Settings → Bar.
- On this machine `playerctl` was not installed; `python3`, `busctl` and `curl`
  were.
