# Contributing

## What runs on a change

```sh
# 1. Luau syntax: no Luau compiler is assumed present, so transpose the one
#    compound operator Luau adds over Lua and parse the result with a stock Lua.
for f in plugin/media-lyrics/*.luau; do
  sed -E 's/(\w+) \+=/\1 = \1 +/g' "$f" > "/tmp/$(basename "$f")"
  luac -p "/tmp/$(basename "$f")" || exit 1
done

# 2. The plugin manifest and the entry scripts, checked by Noctalia itself.
noctalia plugins lint plugin/media-lyrics      # expect: 0 errors, 0 warnings

# 3. The Python lyric pipeline.
python3 -m unittest discover -s plugin/media-lyrics -p "test_*.py"
```

A change to the widget or the panel needs a live check too — the shell renders them, so nothing
above proves they look right:

```sh
tools/install-plugin.sh install
tools/install-plugin.sh status
```

## Style

- Luau, English identifiers and comments; user-facing strings in both `en` and `zh-Hans`.
- A comment states an external cause the code cannot show — a shell constant read from the Noctalia
  source, a protocol quirk, an ordering constraint. It does not narrate the block below it.
- `plugin_api = 22` is the floor: entry scripts `require` a shared module (`progress.luau`), which
  level 22 is the first to allow. Lowering it breaks the load.

## Scope

The widget mirrors Noctalia's built-in `media` item. When the shell gains a setting, mirror it as a
plugin setting rather than reading the shell's state directly, and record the shell constant it
mirrors in [engineering-notes.md](docs/engineering-notes.md) so the next change does not re-derive it.

## Credentials

Never commit an API token. `spotify`, `apple_music` and `musixmatch` take credentials at runtime
through the plugin settings; the repository holds none, and `tools/doctor.py` calls only endpoints
that need no authentication.
