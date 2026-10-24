--!nonstrict
-- Media panel: now playing (art, title, artist, album), transport controls, progress and
-- a scrollable lyric list held on the line being sung, plus the lyric-source picker when
-- the service found several candidates.

local playback = require("./progress.luau")

local candidateState = noctalia.state.get("lyrics_candidate_state") or {}
local track = noctalia.state.get("track")
local lyrics = noctalia.state.get("lyrics")
local isMusic = noctalia.state.get("is_music") ~= false
local cover = noctalia.state.get("cover")
local playing = noctalia.state.get("playing") == true
local playerInstance = tostring(noctalia.state.get("player_instance") or "")
local sourceUsed = tostring(noctalia.state.get("lyrics_source_used") or "")
local lyricsFile = tostring(noctalia.state.get("lyrics_file") or "")
local requestCounter = 0
local dirty = true
local open = false
local scrollKey = 0
local lastSecond = -1

local SOURCE_NAMES = {
  lrclib = "LRCLIB", netease = "NetEase", splayer = "SPlayer", qqmusic = "QQ Music", kugou = "Kugou",
  qishui = "Qishui", apple_music = "Apple Music", spotify = "Spotify",
  musixmatch = "Musixmatch", mpris = "MPRIS", custom = "Custom", cache = "Cache",
}

-- The lyric list holds the whole song, so every line that has been sung can be scrolled back to.
-- The view follows the song through revealKey: an empty node half a viewport minus half a row away
-- from the sung row is revealed, and the host scrolls the smallest distance that brings that node
-- whole into view, which leaves the sung row in the middle. A node revealed from below is aligned
-- with the viewport's bottom and one revealed from above with its top, so it takes the side the
-- sung row is being approached from. It rides inside another lyric row, past that row's line,
-- where the row's own height keeps it out of the layout. The song's first and last lines rest
-- against the ends of the list, where the offset clamps (scroll_view.cpp:164,564), and so do its
-- last LYRIC_ROWS_AFTER lines, which are revealed as rows rather than through that node.
local LYRIC_ROW_HEIGHT = 34
local LYRIC_ROWS_AFTER = 5
-- Two seconds at the two position ticks the service publishes per second.
local LYRIC_IDLE_TICKS = 4

local idleTicks = 0
local scrolledAway = false
local hoveredIndex = nil
local viewportHeight = 0
local contentRows = 0
local scrollOffset = 0
local revealKey = "reveal-1"
local revealRev = 1
local revealing = false
local revealTargetOffset = nil
-- The string the last render handed to the host. A render while the reader is elsewhere
-- resubmits that same string: the host reads a string it has not applied as a request to scroll,
-- and the node that string names is therefore kept in the tree as well, because a key whose node
-- is missing is forgotten and its return would read as a new request.
local revealedTarget = nil
local lastLyricIndex = 0
local render
local refresh
-- Where the seek bar's pointer last put the position, while it is being dragged. It is the
-- value the bar's labels show until the drag ends and the player has been moved.
local seekPreviewUs = nil
local seekToUs
-- The whole second the last render handed the slider. A report that repeats it is that same
-- value coming back through onChange, not the pointer.
local renderedSeekMs = -1

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function trackKey(value)
  if type(value) ~= "table" then return "" end
  local durationSeconds = math.floor((tonumber(value.duration) or 0) / 1000000)
  return (value.playerInstance or "") .. "|" .. (value.trackId or "") .. "|"
    .. (value.title or "") .. "|" .. (value.artist or "") .. "|" .. (value.album or "")
    .. "|" .. tostring(durationSeconds)
end

local function stateForTrack()
  if type(candidateState) ~= "table" or candidateState.track_key ~= trackKey(track) then return {} end
  return candidateState
end

local function durationLabel(value)
  local seconds = math.max(0, math.floor(tonumber(value) or 0))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function timeLabel(microseconds)
  return durationLabel((tonumber(microseconds) or 0) / 1000000)
end

local function basename(path)
  return (tostring(path or ""):match("([^/]+)$")) or ""
end

local function candidateLabel(candidate)
  local parts = {}
  local title = tostring(candidate.track_name or "")
  local artist = tostring(candidate.artist_name or "")
  if title ~= "" then parts[#parts + 1] = title end
  if artist ~= "" then parts[#parts + 1] = artist end
  if tonumber(candidate.duration) and tonumber(candidate.duration) > 0 then
    parts[#parts + 1] = durationLabel(candidate.duration)
  end
  parts[#parts + 1] = noctalia.tr(candidate.synced == true and "panel.synced" or "panel.unsynced")
  return table.concat(parts, "  ·  ")
end

local function selectedIndex()
  local state = stateForTrack()
  local candidates = type(state.candidates) == "table" and state.candidates or {}
  local selectedCandidateId = tostring(state.selected_id or "")
  for index, candidate in ipairs(candidates) do
    if tostring(candidate.id or "") == selectedCandidateId then return index - 1 end
  end
  return 0
end

-- Index of the lyric line that should be highlighted (1-based, 0 when there is none).
local function currentLyricIndex()
  if type(lyrics) ~= "table" or #lyrics == 0 then return 0 end
  if not (tonumber(lyrics[1].time) and tonumber(lyrics[1].time) >= 0) then return 1 end
  local positionMs = playback.getUs() / 1000
  local index = 1
  for i = #lyrics, 1, -1 do
    if (tonumber(lyrics[i].time) or 0) <= positionMs then
      index = i
      break
    end
  end
  return index
end

local function secondaryText(line)
  if type(line) ~= "table" then return "" end
  local translation = tostring(line.translation or "")
  local romanization = tostring(line.romanization or "")
  if translation ~= "" then return translation end
  return romanization
end

local function header()
  local art = nil
  if cover and cover ~= "" and noctalia.fileExists(cover) then
    art = ui.image({ path = cover, width = 56, height = 56, radius = 8, fit = "cover" })
  else
    art = ui.glyph({ name = "music", size = 30, color = "on_surface_variant" })
  end

  local meta = {}
  if track then
    if track.artist and track.artist ~= "" then meta[#meta + 1] = track.artist end
    if track.album and track.album ~= "" then meta[#meta + 1] = track.album end
  end

  local details = {}
  details[#details + 1] = ui.label({
    text = track and tostring(track.title or "") or "",
    fontSize = 16,
    fontWeight = "bold",
    maxLines = 1,
  })
  if #meta > 0 then
    details[#details + 1] = ui.label({
      text = table.concat(meta, "  ·  "),
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
    })
  end
  if sourceUsed ~= "" then
    details[#details + 1] = ui.label({
      text = noctalia.tr("source_label") .. ": " .. (SOURCE_NAMES[sourceUsed] or sourceUsed),
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
    })
  end
  if lyricsFile ~= "" then
    details[#details + 1] = ui.label({
      text = noctalia.tr("panel.saved") .. ": " .. basename(lyricsFile),
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
    })
  end

  return ui.row({ align = "center", gap = 12 }, {
    art,
    ui.column({ flexGrow = 1, gap = 2 }, details),
    ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onCloseClicked" }),
  })
end

local function transport()
  local durationUs = playback.getDurationUs()
  local positionUs = playback.getUs()
  -- The bar always renders the clock: a value the tree took from the slider's own report
  -- would come back as that same value on the next render and the bar would stop there.
  -- While the pointer is down the host holds the value it was given, so the only thing the
  -- drag needs from here is the label.
  local labelUs = seekPreviewUs or positionUs
  local maxMs = math.max(1, math.floor(durationUs / 1000))
  renderedSeekMs = math.min(maxMs, math.max(0, math.floor(positionUs / 1000)))
  return ui.column({ gap = 6, align = "stretch" }, {
    ui.slider({
      key = "panel-seek",
      min = 0,
      max = maxMs,
      step = 1000,
      value = renderedSeekMs,
      enabled = durationUs > 0,
      controlSize = "sm",
      onChange = "onSeekChanged",
      onDragEnd = "onSeekCommitted",
    }),
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = timeLabel(labelUs), color = "on_surface_variant", fontSize = 11 }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        glyph = "player-skip-back",
        variant = "ghost",
        tooltip = noctalia.tr("panel.previous"),
        enabled = track ~= nil,
        onClick = "onPreviousClicked",
      }),
      ui.button({
        glyph = playing and "player-pause" or "player-play",
        variant = "secondary",
        tooltip = noctalia.tr(playing and "panel.pause" or "panel.play"),
        enabled = track ~= nil,
        onClick = "onPlayPauseClicked",
      }),
      ui.button({
        glyph = "player-skip-forward",
        variant = "ghost",
        tooltip = noctalia.tr("panel.next"),
        enabled = track ~= nil,
        onClick = "onNextClicked",
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = timeLabel(durationUs), color = "on_surface_variant", fontSize = 11 }),
    }),
  })
end

-- Clicking a line plays the song from that line's timestamp.
local function seekToLine(line)
  local ms = tonumber(line and line.time)
  if not ms or ms < 0 then return end
  seekToUs(ms * 1000)
end

-- The reveal the host performs for us lands the view exactly where the follow wants it. That one
-- move is not the reader's, so it is recognised by where the render predicted it would land; before
-- the first measurement the reveal is the only thing that can have asked for a move.
function onLyricsScroll(offset, maxOffset)
  local moved = tonumber(offset) or 0
  local endOffset = tonumber(maxOffset) or 0
  scrollOffset = moved
  idleTicks = 0
  local expected = revealTargetOffset
  local ours = false
  if expected then
    ours = math.abs(moved - math.max(0, math.min(expected, endOffset))) <= 2
  elseif revealing then
    ours = true
    revealing = false
  end
  if not ours then scrolledAway = true end

  -- This callback is the one place the shell states how tall the viewport is: with the content
  -- height known, the offset it clamped to gives the viewport.
  local measured = contentRows * LYRIC_ROW_HEIGHT - endOffset
  if measured >= LYRIC_ROW_HEIGHT * 3 and measured <= LYRIC_ROW_HEIGHT * 30 then
    viewportHeight = measured
  end
end

-- Hovering a row reveals its play button; the button keeps the row hovered while the
-- pointer is on it. Only a change of the hovered row re-renders, because the shell
-- re-fires hover for every node of a rebuilt tree.
local function setHover(index, entering)
  local next = entering and index or (hoveredIndex == index and nil or hoveredIndex)
  if next == hoveredIndex then return end
  hoveredIndex = next
  refresh()
end

-- Where the centring node sits and how tall it is. That node is aligned with an edge of the
-- viewport, so the sung row lands half a viewport away from that edge: whole rows cover the bulk of
-- that distance and the node's own height covers the remainder, which is what lets the row's
-- middle, rather than its edge, reach the middle of the display. A node above the sung row is used
-- when the view has already passed it, because a reveal from that side aligns the node's top and
-- whole rows are the only distances available there; that distance rounds down so the sung row
-- stays at or above the middle. Until the first scroll callback states the viewport, two rows stand
-- in for it, which keeps the sung row high rather than low.
local function centringAnchor(current, above)
  local middle = viewportHeight > 0 and (viewportHeight / 2 - LYRIC_ROW_HEIGHT / 2)
    or LYRIC_ROW_HEIGHT * 2
  if above then
    return current - 1 - math.floor(middle / LYRIC_ROW_HEIGHT), 1
  end
  local rowsBelow = math.max(0, math.floor(middle / LYRIC_ROW_HEIGHT))
  return current + rowsBelow, math.max(1, middle - rowsBelow * LYRIC_ROW_HEIGHT)
end

-- The host applies a reveal only when its string differs from the last one, so a fresh key is
-- what asks it to bring the view back to the sung row.
local function settleReveal()
  revealRev = revealRev + 1
  revealKey = "reveal-" .. tostring(revealRev)
  revealing = true
end

local function lyricsSection()
  if type(lyrics) ~= "table" or #lyrics == 0 then
    -- A video is not a song: it has no lyrics to wait for, so the page says so
    -- rather than claiming none were found.
    local glyph = isMusic and "music-off" or "video"
    local text = isMusic and noctalia.tr("no_lyrics") or noctalia.tr("not_a_song")
    return ui.column({ align = "center", justify = "center", gap = 8, flexGrow = 1 }, {
      ui.glyph({ name = glyph, size = 26, color = "on_surface_variant" }),
      ui.label({ text = text, color = "on_surface_variant" }),
    })
  end

  local current = currentLyricIndex()
  local count = #lyrics
  -- The song's closing lines rest at the end of the list instead of following the sung row, so
  -- they are revealed as rows and no centring node is used.
  local closing = current > count - LYRIC_ROWS_AFTER
  -- A node revealed from below is aligned with the viewport's bottom, one revealed from above
  -- with the viewport's top, so it takes the side the sung row is approached from.
  local anchorRow, anchorHeight = 0, 0
  if not closing then
    anchorRow, anchorHeight = centringAnchor(
      current, scrollOffset > (current - 1) * LYRIC_ROW_HEIGHT)
    if anchorRow < 1 or anchorRow > count then anchorRow = 0 end
  end
  local target = anchorRow > 0 and revealKey or ("lyric-" .. tostring(current))
  if scrolledAway and revealedTarget ~= nil then
    -- A repaint must not move the view: the key the host holds is resubmitted, and the node it
    -- names is rebuilt in the sung row when the centring node has no row of its own there.
    target = revealedTarget
    if target == revealKey and anchorRow == 0 then
      anchorRow = math.max(1, math.min(count, current))
      anchorHeight = 1
    end
    revealTargetOffset = scrollOffset
  else
    -- Where the host will leave the view when it applies that reveal: it aligns the node with the
    -- edge it is nearer, so the offset follows from the geometry of the node and the last offset it
    -- reported (scroll_view.cpp:236-266). onLyricsScroll uses this to tell our own move apart from
    -- the reader's.
    local targetTop = (current - 1) * LYRIC_ROW_HEIGHT
    local targetHeight = LYRIC_ROW_HEIGHT
    if anchorRow > 0 then
      targetTop = anchorRow * LYRIC_ROW_HEIGHT
      targetHeight = anchorHeight
    end
    if viewportHeight > 0 then
      if targetTop < scrollOffset then
        revealTargetOffset = targetTop
      elseif targetTop + targetHeight > scrollOffset + viewportHeight then
        revealTargetOffset = targetTop + targetHeight - viewportHeight
      else
        revealTargetOffset = scrollOffset
      end
    else
      revealTargetOffset = nil
    end
  end
  revealedTarget = target

  local rows = {}
  for index = 1, count do
    local line = lyrics[index]
    local isCurrent = index == current
    local cells = {
      ui.label({
        text = tostring(line.text or ""),
        fontSize = isCurrent and 15 or 14,
        fontWeight = isCurrent and "bold" or "normal",
        color = isCurrent and "primary" or "on_surface_variant",
        maxLines = 1,
      }),
    }
    local secondary = secondaryText(line)
    if secondary ~= "" then
      cells[#cells + 1] = ui.label({
        text = secondary,
        fontSize = isCurrent and 12 or 11,
        color = isCurrent and "secondary" or "on_surface_variant",
        maxLines = 1,
      })
    end
    local children = {
      ui.row({
        height = LYRIC_ROW_HEIGHT,
        gap = 8,
        align = "center",
        onHover = function(state, _key)
          setHover(index, tostring(state) == "true")
        end,
      }, {
        ui.column({ flexGrow = 1, gap = 0, align = "start" }, cells),
        ui.button({
          glyph = "player-play",
          variant = "primary",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.play_from_here"),
          visible = hoveredIndex == index,
          onHover = function(state, _key)
            setHover(index, tostring(state) == "true")
          end,
          onClick = function()
            seekToLine(line)
          end,
        }),
      }),
    }
    -- The centring node rides in the row it is measured against, past that row's line. The
    -- enclosing height is what that row occupies, so the node overflows it and adds no height of
    -- its own; nothing is drawn where it sits, and a reveal still finds it.
    if index == anchorRow then
      children[#children + 1] = ui.box({ key = revealKey, height = anchorHeight, opacity = 0 })
    end
    rows[#rows + 1] = ui.column({
      key = "lyric-" .. tostring(index),
      height = LYRIC_ROW_HEIGHT,
      gap = 0,
      align = "stretch",
    }, children)
  end

  contentRows = count

  return ui.column({ flexGrow = 1, gap = 6, align = "stretch" }, {
    ui.label({ text = noctalia.tr("panel.lyrics"), color = "on_surface_variant", fontSize = 11 }),
    -- The viewport is smaller than the content only while the section that holds the scroll
    -- fills a bounded height, so the section grows and the scroll grows with it; a viewport
    -- as tall as its content leaves the wheel nothing to move (scroll_view.cpp:466,493 and
    -- scrollable() in scroll_view.h:66).
    ui.scroll({
      key = "lyrics-scroll-" .. tostring(scrollKey),
      flexGrow = 1,
      gap = 0,
      paddingV = 0,
      align = "stretch",
      onScroll = "onLyricsScroll",
      -- The host scrolls the keyed node into view when this string changes, and leaves the view
      -- alone when that node is already whole inside it (scroll_view.cpp:236-266).
      revealKey = target,
    }, rows),
  })
end

-- The lyric-source picker: every candidate the service found for the track, the one in
-- use preselected. One candidate leaves nothing to choose, so the section stays out.
local function sourceSection()
  local state = stateForTrack()
  local candidates = type(state.candidates) == "table" and state.candidates or {}
  if #candidates < 2 then return nil end

  local options = {}
  for _, candidate in ipairs(candidates) do
    options[#options + 1] = candidateLabel(candidate)
  end

  local rows = {
    ui.label({ text = noctalia.tr("panel.result"), color = "on_surface_variant", fontSize = 11 }),
    ui.select({
      key = "lyric-source",
      options = options,
      selectedIndex = selectedIndex(),
      controlSize = "sm",
      enabled = state.loading ~= true,
      onChange = "onCandidateChange",
    }),
  }
  if state.loading == true then
    rows[#rows + 1] = ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant", fontSize = 11, maxLines = 1 })
  elseif type(state.error) == "string" and state.error ~= "" then
    rows[#rows + 1] = ui.label({ text = noctalia.tr("panel.selection_failed"), color = "error", fontSize = 11, maxLines = 1 })
  end
  return ui.column({ gap = 4, align = "stretch" }, rows)
end

render = function()
  dirty = false

  if not track then
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
      ui.column({ align = "center", justify = "center", gap = 8, flexGrow = 1 }, {
        ui.glyph({ name = "music-off", size = 28, color = "on_surface_variant" }),
        ui.label({ text = noctalia.tr("panel.no_track"), color = "on_surface_variant" }),
      }),
    }))
    return
  end

  local sections = {
    header(),
    transport(),
    lyricsSection(),
  }
  local sources = sourceSection()
  if sources then sections[#sections + 1] = sources end
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, sections))
end

-- A plugin panel receives no periodic update() tick, so the tree is rebuilt from
-- the watchers themselves while the panel is open.
refresh = function()
  dirty = true
  if open then render() end
end

local function watch(key, transform)
  noctalia.state.watch(key, function(value)
    transform(value)
    refresh()
  end)
end

watch("lyrics_candidate_state", function(value) candidateState = type(value) == "table" and value or {} end)
watch("track", function(value) track = value end)
watch("lyrics", function(value)
  lyrics = value
  -- A new song starts at its first line, whatever the closing lines left the view on.
  scrollKey = scrollKey + 1
  scrolledAway = false
  idleTicks = 0
  lastLyricIndex = currentLyricIndex()
  settleReveal()
end)
watch("cover", function(value) cover = value end)
watch("playing", function(value) playing = value == true end)
watch("player_instance", function(value) playerInstance = tostring(value or "") end)
watch("lyrics_source_used", function(value) sourceUsed = tostring(value or "") end)
watch("lyrics_file", function(value) lyricsFile = tostring(value or "") end)

-- The playback clock republishes the position about twice a second; the idle count below
-- is expressed in those ticks rather than in seconds.
playback.attach(function()
  if scrolledAway then
    -- While the reader is elsewhere in the song the tree is left alone, because a rebuild
    -- would move the view back to the sung row and lose their place. Only the idle
    -- count brings it back to the sung line.
    idleTicks = idleTicks + 1
    if idleTicks >= LYRIC_IDLE_TICKS then
      scrolledAway = false
      hoveredIndex = nil
      settleReveal()
      refresh()
    end
    return
  end
  local second = math.floor(playback.getUs() / 1000000)
  if second ~= lastSecond then
    lastSecond = second
    local index = currentLyricIndex()
    if index ~= lastLyricIndex then
      lastLyricIndex = index
      settleReveal()
    end
    refresh()
  end
end)

local function playerctl(action)
  if playerInstance == "" then return end
  noctalia.runAsync("playerctl --player " .. shellQuote(playerInstance) .. " " .. action, function() end)
end

-- Moves the player and the clock together, so the bar and the labels are on the new position
-- before the poll that confirms the seek arrives.
function seekToUs(us)
  if playerInstance == "" then return end
  playback.noteSeek(us)
  noctalia.runAsync(
    "playerctl --player " .. shellQuote(playerInstance) .. " position " .. string.format("%.3f", us / 1000000),
    function() end
  )
  refresh()
end

-- The slider reports the value it holds, and the clock's own value arrives here the same way
-- on the render that applies it; that repeat is the tree talking to itself. Anything else is
-- the pointer, which is where the drag is, until the release moves the player there. The host
-- keeps its value for as long as the pointer is down, so a render cannot interrupt a drag.
function onSeekChanged(value)
  local ms = tonumber(value)
  if not ms or ms == renderedSeekMs then return end
  seekPreviewUs = ms * 1000
  render()
end

function onSeekCommitted()
  local target = seekPreviewUs
  seekPreviewUs = nil
  if not target then return end
  seekToUs(target)
end

function onPreviousClicked()
  playerctl("previous")
end

function onNextClicked()
  playerctl("next")
end

function onPlayPauseClicked()
  if playerInstance == "" then return end
  playerctl("play-pause")
  -- Optimistic flip so the button responds before the next service poll.
  playing = not playing
  refresh()
end

function onOpen(_context)
  noctalia.state.set("media_panel_open", true)
  open = true
  scrollKey = scrollKey + 1
  scrolledAway = false
  hoveredIndex = nil
  idleTicks = 0
  lastLyricIndex = currentLyricIndex()
  settleReveal()
  dirty = true
  render()
end

function onClose()
  noctalia.state.set("media_panel_open", false)
  open = false
end

-- A track of a few minutes put on a bar a few hundred pixels wide moves about a pixel
-- every 200 ms, so repainting at that rate carries the bar instead of stepping it.
local lastPaintUs = -1
local PAINT_STEP_US = 200000

function update()
  local us = playback.getUs()
  if open and playback.isPlaying() and math.abs(us - lastPaintUs) >= PAINT_STEP_US then
    lastPaintUs = us
    dirty = true
  end
  if dirty then render() end
end

function onCloseClicked()
  panel.close()
end

function onCandidateChange(index, _label)
  local state = stateForTrack()
  local candidates = type(state.candidates) == "table" and state.candidates or {}
  local selectedCandidateId = tostring(state.selected_id or "")
  local candidate = candidates[(math.floor(tonumber(index) or 0)) + 1]
  if not candidate or tostring(candidate.id or "") == selectedCandidateId or not track then return end
  requestCounter = requestCounter + 1
  noctalia.state.set("lyrics_candidate_request", {
    request_id = tostring(os.clock()) .. "-" .. tostring(requestCounter),
    candidate_id = tostring(candidate.id or ""),
    track_key = trackKey(track),
  })
end

noctalia.setUpdateInterval(200)

render()
