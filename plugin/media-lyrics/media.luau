-- MediaLyrics bar widget.
--
-- Noctalia's media player is a built-in C++ bar widget, not a plugin
-- (src/shell/bar/widgets/media_widget.cpp upstream), so this entry reproduces
-- that widget's behaviour and adds the lyric line on top:
--
--   * circular artwork (radius = art_size / 2, cover fit)
--   * "Title - Artist" / "Artist - Title" / title-only text, with the same
--     identity fallbacks when the metadata is incomplete
--   * a "disc" glyph when a player exists but has no artwork, "music-off" when
--     nothing is playing, and no glyph at all while artwork is shown
--   * vertical bars (and album_art_only) show artwork only
--   * hide_when_no_media / hide_when_idle hide the widget instead of the row
--   * label colour: on_surface while playing, on_surface_variant otherwise
--   * a min_length / max_length width budget, sized from the widest lyric of the
--     track so the widget keeps its width while the song plays
--   * show_progress paints the playback position as a fill behind the row
--
-- Lyric extension: while the track has lyrics and show_lyrics is on, the lyric
-- line for the current position replaces the media text (the tooltip still names
-- the track and the source). The line is drawn one label per character, so the
-- part of it the song has passed carries the active colour and the rest the
-- inactive one, and the line scrolls when it does not fit the budget. Lyrics come
-- from the service entry, which publishes them as shared state; this entry only
-- renders.
--
-- Gestures are configuration: the manifest binds left to the media panel, right
-- to play/pause and the thumb buttons to previous/next.

local playback = require("./progress.luau")

-- Style::spaceXs upstream: the gap between the artwork and the text.
local SPACE_XS = 4
-- Fallback glyph size; the bar thickness clamps it.
local GLYPH_SIZE = 16
-- The plugin API exposes no text metrics, so label widths are estimated from one
-- glyph at the shell's default bar font: a full-width glyph takes an em, the rest
-- an average Latin advance of 0.53 em.
local FONT_PX = 14
local WIDE_PX = FONT_PX
local NARROW_PX = FONT_PX * 0.53
-- Marquee pacing, in pixels per second through the travel and the pause at each
-- end of it.
local MARQUEE_PX_PER_SECOND = 30
local MARQUEE_HOLD_SECONDS = 1.1
-- Fraction of a character the karaoke sweep blends across.
local KARAOKE_BLEND = 0.16
-- The shell insets a widget's capsule from its root box by
-- `bar.<name>.capsule_padding`, which falls back to Style::barCapsulePadding. The
-- fill and the content straddle that inset so the progress reaches the capsule's ends.
local DEFAULT_CAPSULE_PADDING = 6
-- A capsule's cross size is the bar's visual height times `bar.capsule_thickness`,
-- the same for every capsule in the bar (bar.cpp:969-973, `capsuleCross`), and the
-- compile-time default of that ratio is 0.76 (config_types.h:168).
local DEFAULT_CAPSULE_THICKNESS = 0.76

local settings = {}

-- Bar settings are read through `noctalia.getSetting` (runtime-api.mdx:22-31): the
-- shell keys its bars by name and lists them in `bar.order`, so the path to a bar's
-- own keys is `bar.<name>.<key>`.
local barName = nil
local function settingValue(path)
  if type(noctalia.getSetting) ~= "function" then
    return nil
  end
  local ok, value = pcall(noctalia.getSetting, path)
  return ok and value or nil
end

local function thisBarName()
  if barName == nil then
    local name = settingValue("bar.order[0]")
    barName = type(name) == "string" and name or "main"
  end
  return barName
end

-- One bar key, from the bar's effective settings. The whole table is read once: an
-- optional key a bar leaves out would otherwise log a missing-path warning per read.
local barTable = nil
local barTableRead = false
local function ensureBarTable()
  if not barTableRead then
    barTableRead = true
    local table = settingValue("bar." .. thisBarName())
    barTable = type(table) == "table" and table or false
  end
end

local function barValue(key)
  ensureBarTable()
  if barTable ~= false then
    return tonumber(barTable[key])
  end
  return tonumber(settingValue("bar." .. thisBarName() .. "." .. key))
end

-- The shell resolves a widget's capsule from the bar's keys first and then from this
-- widget's own `[widget.<instance>]` overrides (resolveWidgetBarCapsuleSpec,
-- config_types.cpp:333-361). A plugin is told neither its instance name nor its plugin
-- id, so the widget table is scanned for the entry declared with this entry's type,
-- preferring the instance the bar actually places.
local widgetEntry = nil
local widgetEntryRead = false
local function placedWidgetNames()
  local names = {}
  local function collect(list)
    if type(list) == "table" then
      for _, name in ipairs(list) do
        if type(name) == "string" then
          names[name] = true
        end
      end
    end
  end
  ensureBarTable()
  if barTable ~= false then
    collect(barTable.start)
    collect(barTable.center)
    collect(barTable["end"])
    if type(barTable.monitors) == "table" then
      for _, monitor in pairs(barTable.monitors) do
        if type(monitor) == "table" then
          collect(monitor.start)
          collect(monitor.center)
          collect(monitor["end"])
        end
      end
    end
  end
  return names
end

local function thisWidgetEntry()
  if not widgetEntryRead then
    widgetEntryRead = true
    local all = settingValue("widget")
    if type(all) == "table" then
      local placed = nil
      local fallback = nil
      local names = placedWidgetNames()
      for name, entry in pairs(all) do
        local kind = type(entry) == "table" and entry.type or nil
        if type(kind) == "string" and kind:match(":media$") ~= nil then
          if names[name] then
            placed = entry
            break
          end
          if fallback == nil then
            fallback = entry
          end
        end
      end
      widgetEntry = placed or fallback
    end
  end
  return widgetEntry
end

-- One capsule key, with the widget's own override ahead of the bar's value.
local function capsuleValue(key)
  local entry = thisWidgetEntry()
  if type(entry) == "table" then
    local value = tonumber(entry[key])
    if value ~= nil then
      return value
    end
  end
  return barValue(key)
end

local capsulePadding = nil
-- The inset between this widget's box and its capsule, in logical pixels.
local function capsuleInset()
  if capsulePadding == nil then
    capsulePadding = capsuleValue("capsule_padding") or DEFAULT_CAPSULE_PADDING
  end
  return capsulePadding
end

local capsuleCrossPx = nil
local capsuleCrossRead = false
-- The height of the capsule the shell draws around this widget, in logical pixels
-- (bar.cpp:1294 takes the cross size of a horizontal bar from `capsuleCross`). The
-- row takes that height so the fill's pill and the capsule's have one radius.
local function capsuleCrossHeight()
  if not capsuleCrossRead then
    capsuleCrossRead = true
    local thickness = barValue("thickness")
    if thickness ~= nil and thickness > 0 then
      local ratio = barValue("capsule_thickness") or DEFAULT_CAPSULE_THICKNESS
      capsuleCrossPx = math.max(FONT_PX, math.floor(thickness * ratio + 0.5))
    end
  end
  return capsuleCrossPx
end

-- The capsule's corner radius in logical pixels: this widget's `capsule_radius`, the
-- bar's, or the automatic pill radius of the capsule's box when neither is set
-- (Widget::resolvedBarCapsuleRadius, widget.cpp:70-76). The shell scales a bar radius
-- into the render target itself (ui_tree_reconciler.cpp:1428-1429).
local function capsuleRadius(fillWidth, fillHeight)
  local maxRadius = math.max(0, math.min(fillWidth, fillHeight) * 0.5)
  local pinned = capsuleValue("capsule_radius")
  if pinned == nil then
    return maxRadius
  end
  return math.min(math.max(pinned, 0), maxRadius)
end

-- The capsule keys live in the shell's settings, so the caches above are dropped
-- alongside the plugin settings each second and a change lands without a reload.
local function resetCapsuleCache()
  barTable = nil
  barTableRead = false
  widgetEntry = nil
  widgetEntryRead = false
  capsulePadding = nil
  capsuleCrossPx = nil
  capsuleCrossRead = false
end

local function readSettings()
  local function bool(key, fallback)
    local value = noctalia.getConfig(key)
    if value == nil then
      return fallback
    end
    return value == true
  end
  local function number(key, fallback)
    local value = tonumber(noctalia.getConfig(key))
    if value == nil then
      return fallback
    end
    return value
  end

  settings = {
    albumArtOnly = bool("album_art_only", false),
    hideAlbumArt = bool("hide_album_art", false),
    hideArtist = bool("hide_artist", false),
    artistFirst = bool("artist_first", false),
    minLength = number("min_length", 64),
    maxLength = number("max_length", 176),
    artSize = number("art_size", 16),
    titleScroll = noctalia.getConfig("title_scroll") or "always",
    showProgress = bool("show_progress", true),
    hideWhenNoMedia = bool("hide_when_no_media", false),
    hideWhenIdle = bool("hide_when_idle", false),
    showLyrics = bool("show_lyrics", true),
  }

  if settings.minLength < 0 then
    settings.minLength = 0
  end
  if settings.maxLength < settings.minLength then
    settings.maxLength = settings.minLength
  end
  if settings.artSize < 1 then
    settings.artSize = 1
  end
  if settings.artSize > 96 then
    settings.artSize = 96
  end
end

readSettings()

-- Shared state published by the service entry.
local track = nil
local lyrics = nil
local musicOnly = nil
local cover = ""
local playing = false
local playerInstance = ""
local playerName = ""
local durationUs = 0

local lastClock = 0

local hovering = false
local marqueeSeconds = 0
local settingsClock = os.clock()
local lastSignature = ""
local lastLineKey = nil

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function trackArtists()
  if track == nil then
    return ""
  end
  return track.artist or ""
end

local function trackTitle()
  if track == nil then
    return ""
  end
  return track.title or ""
end

-- buildDisplayText() from the built-in widget, with our own track table.
local function buildDisplayText()
  local artists = settings.hideArtist and "" or trackArtists()
  local title = trackTitle()
  if title ~= "" and artists ~= "" then
    if settings.artistFirst then
      return artists .. " - " .. title
    end
    return title .. " - " .. artists
  end
  if title ~= "" then
    return title
  end
  if artists ~= "" then
    return artists
  end
  if playerName ~= "" then
    return playerName
  end
  if playerInstance ~= "" then
    return playerInstance
  end
  if playing then
    return noctalia.tr("playing")
  end
  return noctalia.tr("nothing_playing")
end

-- Fraction of the line the song has passed. The service publishes line timing
-- only, so the sweep interpolates towards the next timed line and holds on the
-- last one.
local function lineProgress(index, line)
  local startMs = tonumber(line.time)
  if startMs == nil or startMs < 0 then
    return 1
  end
  local endMs = nil
  for nextIndex = index + 1, #lyrics do
    local time = tonumber(lyrics[nextIndex].time)
    if time ~= nil and time > startMs then
      endMs = time
      break
    end
  end
  if endMs == nil and durationUs > 0 then
    endMs = durationUs / 1000
  end
  if endMs == nil or endMs <= startMs then
    return 1
  end
  return clamp((playback.getUs() / 1000 - startMs) / (endMs - startMs), 0, 1)
end

-- The current lyric line for the playing position, with its index and the part
-- of it already sung. Lines carry article time in milliseconds; a line without a
-- time is only used when nothing is timed.
local function currentLyric()
  if lyrics == nil or #lyrics == 0 then
    return nil
  end
  local positionMs = math.floor(playback.getUs() / 1000)
  local chosenIndex = nil
  local timed = false
  for index, line in ipairs(lyrics) do
    local time = tonumber(line.time)
    if time ~= nil and time >= 0 then
      timed = true
      if time <= positionMs then
        chosenIndex = index
      else
        break
      end
    end
  end
  if chosenIndex == nil then
    if timed then
      return nil
    end
    chosenIndex = 1
  end
  local line = lyrics[chosenIndex]
  local text = tostring(line.text or "")
  if text == "" then
    return nil
  end
  return { index = chosenIndex, text = text, progress = lineProgress(chosenIndex, line) }
end

-- Full-width glyphs (CJK, kana, hangul, full-width punctuation) take an em; the
-- rest is approximated by one Latin advance.
local function glyphWidth(code)
  if code >= 0x1100 and (code <= 0x115F or code == 0x2329 or code == 0x232A
      or (code >= 0x2E80 and code <= 0xA4CF)
      or (code >= 0xAC00 and code <= 0xD7A3)
      or (code >= 0xF900 and code <= 0xFAFF)
      or (code >= 0xFE30 and code <= 0xFE6F)
      or (code >= 0xFF00 and code <= 0xFF60)
      or (code >= 0xFFE0 and code <= 0xFFE6)
      or (code >= 0x20000 and code <= 0x3FFFD)) then
    return WIDE_PX
  end
  return NARROW_PX
end

local function textWidth(text)
  local width = 0
  for _, code in utf8.codes(text) do
    width = width + glyphWidth(code)
  end
  return width
end

-- The characters of a label, each with the width it is estimated to take.
local function splitGlyphs(text)
  local glyphs = {}
  for _, code in utf8.codes(text) do
    glyphs[#glyphs + 1] = { char = utf8.char(code), width = glyphWidth(code) }
  end
  return glyphs
end

-- The part of `text` inside the budget-wide window that starts `offsetPx` in.
local function windowText(text, offsetPx, budgetPx)
  local glyphs = splitGlyphs(text)
  local first, last = nil, nil
  local consumed = 0
  for index, glyph in ipairs(glyphs) do
    if consumed + glyph.width > offsetPx then
      if first == nil then
        first = index
      end
      if consumed + glyph.width - offsetPx > budgetPx then
        break
      end
      last = index
    end
    consumed = consumed + glyph.width
  end
  if first == nil then
    return ""
  end
  local parts = {}
  for index = first, last or first do
    parts[#parts + 1] = glyphs[index].char
  end
  return table.concat(parts)
end

local function marqueeActive()
  if settings.titleScroll == "always" then
    return true
  end
  return settings.titleScroll == "on_hover" and hovering
end

-- Marquee viewport offset in pixels, cycling hold - travel - hold - return.
local function marqueeOffset(travelPx)
  if travelPx <= 0 then
    return 0
  end
  local travel = travelPx / MARQUEE_PX_PER_SECOND
  local cycle = MARQUEE_HOLD_SECONDS * 2 + travel * 2
  local phase = marqueeSeconds % cycle
  if phase < MARQUEE_HOLD_SECONDS then
    return 0
  end
  phase = phase - MARQUEE_HOLD_SECONDS
  if phase < travel then
    return travelPx * (phase / travel)
  end
  phase = phase - travel
  if phase < MARQUEE_HOLD_SECONDS then
    return travelPx
  end
  phase = phase - MARQUEE_HOLD_SECONDS
  return travelPx * (1 - phase / travel)
end

-- Characters the song has passed carry the active colour, the ones it has not
-- reached the inactive one, and the character the sweep crosses blends towards
-- the active colour.
local function karaokeColor(charProgress, progress)
  if not playing then
    return "on_surface_variant"
  end
  if progress >= charProgress then
    return "on_surface"
  end
  local distance = charProgress - progress
  if distance >= KARAOKE_BLEND then
    return "on_surface_variant"
  end
  local alpha = 1 - distance / KARAOKE_BLEND
  if alpha <= 0.5 then
    return "on_surface_variant"
  end
  return string.format("on_surface/%.2f", math.max(0.72, alpha))
end

-- The lyric line as one label per character, so each one can carry its own
-- colour. The window holds the characters inside the budget; the two it cuts in
-- half fade out.
local function glyphRow(key, text, offsetPx, budgetPx, progress)
  local glyphs = splitGlyphs(text)
  local first, last = nil, nil
  local consumed = 0
  for index, glyph in ipairs(glyphs) do
    if consumed + glyph.width > offsetPx and consumed - offsetPx < budgetPx then
      if first == nil then
        first = index
      end
      last = index
    end
    consumed = consumed + glyph.width
  end
  local labels = {}
  if first == nil then
    return ui.row({ key = key, gap = 0, align = "center", justify = "start" }, labels)
  end
  local start = 0
  for index = 1, first - 1 do
    start = start + glyphs[index].width
  end
  for index = first, last do
    local glyph = glyphs[index]
    local left = start - offsetPx
    local opacity = 1
    if left < 0 then
      opacity = 1 + left / glyph.width
    end
    if left + glyph.width > budgetPx then
      opacity = math.min(opacity, (budgetPx - left) / glyph.width)
    end
    local charProgress = #glyphs > 1 and (index - 1) / (#glyphs - 1) or 0
    -- The window cuts this glyph: giving its box only the visible part shifts every
    -- following glyph by the sub-glyph remainder, so the line slides instead of
    -- jumping from one glyph boundary to the next.
    local width = nil
    if left < 0 then
      width = glyph.width + left
      if width < 1 then
        width = nil
      end
    end
    labels[#labels + 1] = ui.label({
      key = key .. "-" .. tostring(index),
      text = glyph.char,
      width = width,
      color = karaokeColor(charProgress, progress),
      opacity = clamp(opacity, 0.05, 1),
      maxLines = 1,
    })
    start = start + glyph.width
  end
  return ui.row({ key = key, gap = 0, align = "center", justify = "start" }, labels)
end

local sourceNames = {
  lrclib = "LRCLIB", netease = "NetEase", splayer = "SPlayer", qqmusic = "QQ Music", kugou = "Kugou",
  qishui = "Qishui", apple_music = "Apple Music", spotify = "Spotify", musixmatch = "Musixmatch",
  mpris = "MPRIS", custom = "Custom",
}

local function tooltipText()
  local lines = {}
  local label = buildDisplayText()
  if label ~= "" then
    lines[#lines + 1] = label
  end
  local source = noctalia.state.get("lyrics_source_used")
  if source ~= nil and source ~= "" then
    lines[#lines + 1] = noctalia.tr("source_label") .. ": " .. (sourceNames[source] or source)
  end
  local file = noctalia.state.get("lyrics_file")
  if file ~= nil and file ~= "" then
    lines[#lines + 1] = noctalia.tr("panel.saved") .. ": " .. file:match("([^/]+)$")
  end
  return table.concat(lines, "\n")
end

-- The widest string the widget can show for this track: every lyric line and the
-- media text. The row is sized from it so the widget keeps one width while the
-- song plays, where the built-in follows the label it happens to show.
local function trackTextWidth(hasLyrics)
  local widest = textWidth(buildDisplayText())
  if hasLyrics and type(lyrics) == "table" then
    for _, entry in ipairs(lyrics) do
      local width = textWidth(tostring(entry.text or ""))
      if width > widest then
        widest = width
      end
    end
  end
  return widest
end

local function render()
  local vertical = barWidget.isVertical() == true
  local hasPlayer = track ~= nil
  local showWidget = true
  if hasPlayer then
    showWidget = not settings.hideWhenIdle or playing
  else
    showWidget = not settings.hideWhenNoMedia
  end
  barWidget.setVisible(showWidget)
  if not showWidget then
    lastSignature = ""
    lastLineKey = nil
    return
  end

  local artOnly = vertical or settings.albumArtOnly
  local maxLength = settings.maxLength
  local minLength = clamp(settings.minLength, 0, maxLength)
  local hideArt = settings.hideAlbumArt and not vertical
  local showArtSlot = not hideArt and cover ~= ""
  local artSize = settings.artSize
  -- A video has no lyrics to search for, so its line is the title: the same
  -- marquee a song without lyrics gets.
  local isMusic = musicOnly ~= false
  local line = settings.showLyrics and isMusic and currentLyric() or nil
  local text = line and line.text or buildDisplayText()
  local showLabel = not artOnly and text ~= ""
  local showEmptyGlyph = not showArtSlot and not hideArt
  local leading = showArtSlot and artSize or (showEmptyGlyph and GLYPH_SIZE or 0)
  local spacing = (showLabel and leading > 0) and SPACE_XS or 0
  local showProgress = settings.showProgress and not artOnly and hasPlayer and durationUs > 0
  local progressValue = showProgress and clamp(playback.getUs() / durationUs, 0, 1) or 0

  local rowWidth = nil
  if not artOnly then
    local budget = math.max(0, maxLength - leading - spacing)
    local contentWidth = leading + spacing + math.min(trackTextWidth(line ~= nil), budget)
    rowWidth = clamp(contentWidth, minLength, maxLength)
  end
  local labelBudget = math.max(NARROW_PX, (rowWidth or maxLength) - leading - spacing)

  -- A new line starts the sweep and the marquee from the line's own beginning.
  local lineKey = line and (tostring(line.index) .. "|" .. line.text) or ""
  if lineKey ~= lastLineKey then
    lastLineKey = lineKey
    marqueeSeconds = 0
  end
  local travel = showLabel and math.max(0, textWidth(text) - labelBudget) or 0
  local offsetPx = (showLabel and marqueeActive()) and marqueeOffset(travel) or 0
  local progress = line and line.progress or 0
  local inset = capsuleInset()
  local trackWidth = (rowWidth or maxLength) + 2 * inset

  -- The fill is the shell's own progress control, the one the built-in media
  -- widget uses: a full pill of the capsule's box whose rounded ends are revealed
  -- through a clip, so a small progress shows the capsule's cap rather than a
  -- narrow oval. The row takes the capsule's own cross size so the fill's pill and
  -- the capsule's coincide; without it the fill is a pill of the row's height and
  -- curves too tightly. The radius is the bar's own `capsule_radius`, so a capsule
  -- the user reshapes takes the fill with it.
  local contentHeight = math.max(artSize, showEmptyGlyph and GLYPH_SIZE or 0, FONT_PX * 1.5)
  local capsuleCross = capsuleCrossHeight()
  local fillHeight = capsuleCross or (contentHeight + 2 * inset)

  local signature = table.concat({
    tostring(vertical), tostring(artOnly), tostring(showArtSlot), tostring(showLabel),
    tostring(showEmptyGlyph), tostring(showProgress), tostring(playing),
    cover, text, tostring(maxLength), tostring(minLength), tostring(math.floor(labelBudget)),
    tostring(rowWidth), tostring(math.floor(offsetPx)), string.format("%.2f", progress),
    string.format("%.4f", progressValue), tostring(capsuleCross), tostring(isMusic),
  }, "|")
  if signature == lastSignature then
    return
  end
  lastSignature = signature
  local content = {}
  if showArtSlot then
    content[#content + 1] = ui.image({
      key = "media-art",
      path = cover,
      width = artSize,
      height = artSize,
      radius = artSize / 2,
      fit = "cover",
    })
  elseif showEmptyGlyph then
    content[#content + 1] = ui.glyph({
      key = "media-glyph",
      name = hasPlayer and "disc" or "music-off",
      size = GLYPH_SIZE,
      color = "on_surface_variant",
    })
  end

  if showLabel then
    if line then
      content[#content + 1] = glyphRow("media-text", text, offsetPx, labelBudget, progress)
    else
      content[#content + 1] = ui.label({
        key = "media-text",
        text = marqueeActive() and windowText(text, offsetPx, labelBudget) or text,
        maxWidth = labelBudget,
        maxLines = 1,
        color = playing and "on_surface" or "on_surface_variant",
      })
    end
  end

  if #content == 0 then
    content[#content + 1] = ui.glyph({ key = "media-glyph", name = "music-off", size = GLYPH_SIZE, color = "on_surface_variant" })
  end

  local children = {}
  if showProgress then
    -- The fill is laid out ahead of the content and pulled back under it by a
    -- negative gap: a plugin tree has no z-order, so this is how the built-in's
    -- behind-the-row progress bar is reproduced.
    children[#children + 1] = ui.progress({
      key = "media-progress",
      width = trackWidth,
      height = fillHeight,
      progress = progressValue,
      fill = "primary/0.25",
      track = "#00000000",
      radius = capsuleRadius(trackWidth, fillHeight),
    })
  end
  children[#children + 1] = ui.row({
    key = "media-content",
    gap = spacing > 0 and spacing or SPACE_XS,
    align = "center",
    paddingH = inset,
  }, content)

  barWidget.render(ui.row({
    key = "media-row",
    width = rowWidth,
    height = capsuleCross,
    gap = showProgress and -trackWidth or SPACE_XS,
    align = "stretch",
    paddingH = -inset,
    paddingV = capsuleCross and 0 or -inset,
  }, children))
  barWidget.setTooltip(tooltipText())
end

function onHover(entered)
  hovering = entered == true
  if not hovering then
    marqueeSeconds = 0
  end
end

function update()
  local now = os.clock()
  local delta = lastClock > 0 and (now - lastClock) or 0
  lastClock = now

  -- Bar entries get no config-changed callback, so re-read the settings twice a
  -- second and re-render when one of them moved.
  if now - settingsClock >= 1 then
    settingsClock = now
    resetCapsuleCache()
    readSettings()
    lastSignature = ""
  end

  track = noctalia.state.get("track")
  lyrics = noctalia.state.get("lyrics")
  musicOnly = noctalia.state.get("is_music")
  cover = noctalia.state.get("cover") or ""
  playing = playback.isPlaying()
  durationUs = playback.getDurationUs()
  playerInstance = noctalia.state.get("player_instance") or ""
  playerName = noctalia.state.get("player_name") or ""

  if marqueeActive() then
    marqueeSeconds = marqueeSeconds + delta
  end

  render()
end

-- The playback clock owns the position, the duration and the playing flag, and this
-- entry re-renders when one of them moves.
playback.attach(function()
  lastSignature = ""
end)

noctalia.state.watch("lyrics", function()
  lastSignature = ""
end)

noctalia.state.watch("cover", function()
  lastSignature = ""
end)

-- One update per frame at 20 Hz: the karaoke sweep and the marquee move smoothly
-- at this rate, and a label tree that has not changed is skipped by the signature.
noctalia.setUpdateInterval(33)
