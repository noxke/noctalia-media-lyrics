#!/usr/bin/env python3
"""Read the playing track from MPRIS and try the lyric APIs directly.

No plugin is involved: this exercises the pipeline the plugin uses, so a track
that fails here fails in the bar as well.
"""

import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

UA = "noctalia-media-lyrics doctor"


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""


def mpris_players():
    out = run(["busctl", "--user", "list"])
    names = []
    for line in out.splitlines():
        m = re.match(r"(org\.mpris\.MediaPlayer2\.\S+)", line.strip())
        # playerctld forwards whichever player is active; it is not a player itself.
        if m and m.group(1) not in names and not m.group(1).endswith(".playerctld"):
            names.append(m.group(1))
    return names


def player_props(dest):
    out = run([
        "gdbus", "call", "--session", "--dest", dest,
        "--object-path", "/org/mpris/MediaPlayer2",
        "--method", "org.freedesktop.DBus.Properties.GetAll",
        "org.mpris.MediaPlayer2.Player",
    ])

    def grab(pattern):
        m = re.search(pattern, out, re.S)
        return m.group(1) if m else None

    artists_raw = grab(r"'xesam:artist':\s*<\[(.*?)\]>")
    artists = [a.strip().strip("'") for a in artists_raw.split(",")] if artists_raw else []
    # A browser reports [""] for a video page; an empty name carries no artist.
    artists = [a for a in artists if a]
    length = grab(r"'mpris:length':\s*<int64 (\d+)>")
    position = grab(r"'Position':\s*<int64 (\d+)>")
    return {
        "status": grab(r"'PlaybackStatus':\s*<'([^']*)'>"),
        "title": grab(r"'xesam:title':\s*<'((?:[^'\\]|\\.)*)'>"),
        "artists": artists,
        "album": grab(r"'xesam:album':\s*<'((?:[^'\\]|\\.)*)'>"),
        "length_us": int(length) if length else None,
        "position_us": int(position) if position else None,
        "url": grab(r"'xesam:url':\s*<'([^']*)'>"),
        "as_text": grab(r"'xesam:asText':\s*<'((?:[^'\\]|\\.)*)'>"),
    }


def fetch_json(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def lrclib(title, artists, album, duration_s):
    params = {"track_name": title, "artist_name": " ".join(artists)}
    if album:
        params["album_name"] = album
    if duration_s:
        params["duration"] = str(int(round(duration_s)))
    url = "https://lrclib.net/api/get?" + urllib.parse.urlencode(params)
    try:
        data = fetch_json(url)
    except urllib.error.HTTPError as exc:
        return None, f"HTTP {exc.code}"
    except Exception as exc:
        return None, type(exc).__name__
    synced = data.get("syncedLyrics") or ""
    return data, (f"{len(synced.splitlines())} synced lines" if synced else "plain lyrics only")


def netease_search(title, artists):
    params = urllib.parse.urlencode({
        "s": (title + " " + " ".join(artists)).strip(),
        "type": 1,
        "limit": 3,
        "offset": 0,
    })
    url = "https://music.163.com/api/search/get/web?" + params
    headers = {"User-Agent": "Mozilla/5.0", "Referer": "https://music.163.com/"}
    try:
        data = fetch_json(url, headers)
    except Exception as exc:
        return None, type(exc).__name__
    return (data.get("result") or {}).get("songs") or [], None


def pick_player(players):
    """The player the plugin would show: one that is playing, else one with a
    title and an artist, else whatever reports a title."""
    playing_song = playing_any = song = any_title = None
    for dest in players:
        props = player_props(dest)
        if not props["title"]:
            continue
        is_song = bool(props["artists"])
        any_title = any_title or (dest, props)
        if is_song:
            song = song or (dest, props)
        if props["status"] == "Playing":
            playing_any = playing_any or (dest, props)
            if is_song:
                playing_song = playing_song or (dest, props)
    return playing_song or playing_any or song or any_title


def main():
    players = mpris_players()
    if not players:
        print("no MPRIS player on the session bus: start playback first")
        return 1

    print(f"MPRIS players: {len(players)}")
    for dest in players:
        props = player_props(dest)
        kind = "song" if props["artists"] else "video/other"
        print(f"  {dest}")
        print(f"    status={props['status']} kind={kind} title={props['title']!r} artists={props['artists']}")
        print(f"    url={props['url'] or '(none)'}")
        if props["as_text"]:
            print("    embedded xesam:asText lyrics: yes")

    chosen = pick_player(players)
    print()
    if chosen is None:
        print("no player reports a title; nothing to look up")
        return 1
    dest, target = chosen
    print(f"the plugin would show: {dest}")

    title = target["title"] or ""
    artists = target["artists"]
    duration_s = (target["length_us"] / 1_000_000) if target["length_us"] else None
    who = " / ".join(artists) if artists else "(no artist)"
    when = f" ({duration_s:.0f}s)" if duration_s else ""
    print(f"current track: {title} - {who}{when}")

    if not artists:
        print()
        print("no xesam:artist, so music_only treats this as a video: no lyrics are looked up")
        return 0

    print()
    print("LRCLIB exact match:")
    data, note = lrclib(title, artists, target["album"], duration_s)
    if data:
        print(f"  found: {data.get('trackName')} - {data.get('artistName')} [{note}]")
        print(f"  word sync available: {bool(data.get('hasWordSync'))}, instrumental: {bool(data.get('instrumental'))}")
    else:
        print(f"  not found ({note})")

    print()
    print("NetEase public search (what the plugin's netease source sees):")
    songs, err = netease_search(title, artists)
    if err:
        print(f"  search failed ({err})")
    elif not songs:
        print("  no results")
    else:
        for song in songs:
            names = " / ".join(a.get("name", "") for a in song.get("artists", []))
            secs = (song.get("duration") or 0) / 1000
            print(f"  id={song.get('id')} {song.get('name')!r} - {names} ({secs:.0f}s)")
        if duration_s and songs[0].get("duration"):
            delta = abs(songs[0]["duration"] / 1000 - duration_s)
            print(f"  top hit differs from the playing track by {delta:.0f}s in duration")
    return 0


if __name__ == "__main__":
    sys.exit(main())
