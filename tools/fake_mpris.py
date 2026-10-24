#!/usr/bin/env python3
"""Publish a fake MPRIS player so the plugin's live path can be exercised.

Run with a JSON object: {"title": ..., "artist": ..., "album": ...,
"duration_ms": ..., "status": "Playing"} or plain argv: title artist album ms.
"""

import json
import sys

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

ROOT_IFACE = "org.mpris.MediaPlayer2"
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
BUS_NAME = "org.mpris.MediaPlayer2.faketest"
TRACK_PATH = "/org/mpris/MediaPlayer2/faketest/track/1"


def read_track() -> dict:
    if len(sys.argv) > 1 and sys.argv[1].startswith("{"):
        return json.loads(sys.argv[1])
    return {
        "title": sys.argv[1] if len(sys.argv) > 1 else "Unknown",
        "artist": sys.argv[2] if len(sys.argv) > 2 else "",
        "album": sys.argv[3] if len(sys.argv) > 3 else "",
        "duration_ms": int(sys.argv[4]) if len(sys.argv) > 4 else 0,
        "status": sys.argv[5] if len(sys.argv) > 5 else "Playing",
    }


TRACK = read_track()


def v_str(value):
    return dbus.String(str(value), variant_level=1)


def v_int(value):
    return dbus.Int64(int(value), variant_level=1)


def v_bool(value):
    return dbus.Boolean(bool(value), variant_level=1)


def v_double(value):
    return dbus.Double(float(value), variant_level=1)


def v_array(values):
    return dbus.Array([dbus.String(str(x)) for x in values], signature="s", variant_level=1)


def v_dict(mapping):
    return dbus.Dictionary(mapping, signature="sv", variant_level=1)


def metadata() -> dict:
    return v_dict({
        "mpris:trackid": dbus.ObjectPath(TRACK_PATH, variant_level=1),
        "mpris:length": v_int(int(TRACK.get("duration_ms", 0)) * 1000),
        "xesam:title": v_str(TRACK.get("title", "")),
        "xesam:artist": v_array([TRACK.get("artist", "")]),
        "xesam:album": v_str(TRACK.get("album", "")),
        "xesam:url": v_str("https://music.163.com/st/webplayer"),
    })


ROOT_PROPS = v_dict({
    "CanQuit": v_bool(False),
    "CanRaise": v_bool(False),
    "HasTrackList": v_bool(False),
    "Identity": v_str("Fake MPRIS Test"),
    "DesktopEntry": v_str("faketest"),
    "SupportedUriSchemes": v_array([]),
    "SupportedMimeTypes": v_array([]),
})

PLAYER_PROPS = v_dict({
    "PlaybackStatus": v_str(TRACK.get("status", "Playing")),
    "LoopStatus": v_str("None"),
    "Rate": v_double(1.0),
    "Shuffle": v_bool(False),
    "Metadata": metadata(),
    "Volume": v_double(0.0),
    "Position": v_int(0),
    "MinimumRate": v_double(1.0),
    "MaximumRate": v_double(1.0),
    "CanGoNext": v_bool(False),
    "CanGoPrevious": v_bool(False),
    "CanPlay": v_bool(True),
    "CanPause": v_bool(True),
    "CanSeek": v_bool(False),
    "CanControl": v_bool(True),
})


class FakePlayer(dbus.service.Object):
    def __init__(self, bus):
        super().__init__(bus, "/org/mpris/MediaPlayer2")

    @dbus.service.method(PROPS_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, prop):
        return self._props(interface)[prop]

    @dbus.service.method(PROPS_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return self._props(interface)

    @dbus.service.method(PROPS_IFACE, in_signature="ssv")
    def Set(self, interface, prop, value):
        raise dbus.exceptions.DBusException("Read-only property")

    @dbus.service.signal(PROPS_IFACE, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    @dbus.service.method(ROOT_IFACE)
    def Raise(self):
        pass

    @dbus.service.method(ROOT_IFACE)
    def Quit(self):
        pass

    @dbus.service.method(PLAYER_IFACE)
    def Next(self):
        pass

    @dbus.service.method(PLAYER_IFACE)
    def Previous(self):
        pass

    @dbus.service.method(PLAYER_IFACE)
    def Pause(self):
        pass

    @dbus.service.method(PLAYER_IFACE)
    def PlayPause(self):
        pass

    @dbus.service.method(PLAYER_IFACE)
    def Stop(self):
        pass

    @dbus.service.method(PLAYER_IFACE)
    def Play(self):
        pass

    @dbus.service.method(PLAYER_IFACE, in_signature="x")
    def Seek(self, offset):
        pass

    @dbus.service.method(PLAYER_IFACE, in_signature="ox", out_signature="")
    def SetPosition(self, track_id, position):
        pass

    @dbus.service.method(PLAYER_IFACE, in_signature="s", out_signature="a{sv}")
    def OpenUri(self, uri):
        return {}

    def _props(self, interface):
        if interface == ROOT_IFACE:
            return ROOT_PROPS
        if interface == PLAYER_IFACE:
            return PLAYER_PROPS
        raise dbus.exceptions.DBusException(f"Unknown interface {interface}")


def main() -> None:
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    # Keep a reference: a collected BusName releases the name immediately.
    name = dbus.service.BusName(BUS_NAME, bus)
    player = FakePlayer(bus)
    print(f"{BUS_NAME} publishing {TRACK}", flush=True)
    GLib.MainLoop().run()
    _ = (name, player)


if __name__ == "__main__":
    main()
