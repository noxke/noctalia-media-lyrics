-- The plugin's playback clock. Every entry reads the position from here instead of
-- interpolating the service's `position` state on its own, so the bar widget, the panel
-- and anything added later move together and cannot drift apart.
--
-- MPRIS reports arrive on metadata, playback and seek events, with a slow
-- reconciliation snapshot. Between reports the display advances at real time.
-- A slightly stale report may pull the display forward. A seek, a pause, or a
-- large drift in either direction is authoritative and resynchronizes it.

local M = {}

-- A report this far below the previous one, or this far above the display, is the player
-- at another point of the track rather than the clock it is on.
local SEEK_BACK_US = 1500000
local SEEK_FORWARD_US = 2000000
-- A report is the floor of the player's position, so its middle is the best estimate of
-- where the player actually is.
local MID_SECOND_US = 500000

local attached = false
local onChange = nil
local playing = false
local displayUs = 0
local anchorMs = 0
local lastReportedUs = 0
local durationUs = 0

-- The wall clock, not os.clock(): in this host os.clock() counts CPU time and runs faster
-- than the clock the player keeps.
local function wallMs()
  if noctalia.nowMs ~= nil then
    return noctalia.nowMs()
  end
  return os.clock() * 1000
end

-- Fold elapsed wall time into the display before adopting another report.
local function materialize()
  local now = wallMs()
  if anchorMs == 0 then
    anchorMs = now
    return
  end
  if playing and now > anchorMs then
    displayUs = displayUs + (now - anchorMs) * 1000
  end
  anchorMs = now
end

local function changed()
  if onChange ~= nil then
    onChange()
  end
end

-- Take the reported position as the display, which is what a seek and a pause are.
local function adopt(reported)
  displayUs = reported
  lastReportedUs = reported
  anchorMs = wallMs()
end

function M.getUs()
  if not playing or anchorMs == 0 then
    return math.floor(displayUs)
  end
  local elapsed = wallMs() - anchorMs
  if elapsed <= 0 then
    return math.floor(displayUs)
  end
  return math.floor(displayUs + elapsed * 1000)
end

function M.getDurationUs()
  return durationUs
end

function M.isPlaying()
  return playing
end

-- The player has been asked to move to this position; the report that confirms it arrives
-- with the next MPRIS update. Adopting it now keeps the display on the new position instead of
-- falling back to the old one until that report lands.
function M.noteSeek(us)
  adopt(tonumber(us) or 0)
  changed()
end

local function onPosition(value)
  local reported = tonumber(value) or 0
  materialize()
  local notify = false
  if not playing then
    notify = reported ~= lastReportedUs
    adopt(reported)
  else
    local estimate = reported + MID_SECOND_US
    if reported < lastReportedUs - SEEK_BACK_US
      or reported - displayUs > SEEK_FORWARD_US
      or displayUs - estimate > SEEK_BACK_US then
      adopt(estimate)
      notify = true
    else
      if estimate > displayUs then
        displayUs = estimate
        notify = true
      end
      anchorMs = wallMs()
      if reported > lastReportedUs then
        lastReportedUs = reported
      end
    end
  end
  if notify then changed() end
end

local function onPlaying(value)
  local nextPlaying = value == true
  materialize()
  if nextPlaying ~= playing then
    playing = nextPlaying
    changed()
  end
end

local function onTrack(value)
  local nextDuration = tonumber(value and value.duration) or 0
  if nextDuration ~= durationUs then
    durationUs = nextDuration
    changed()
  end
end

-- Installs the state watches; every entry calls this once at load. A later call only
-- replaces the change handler. The position of a new track needs no special case: it is
-- far below the last reported one, which the position watch already reads as a seek.
function M.attach(handler)
  onChange = handler
  if attached then
    return
  end
  attached = true
  playing = noctalia.state.get("playing") == true
  local track = noctalia.state.get("track")
  durationUs = tonumber(track and track.duration) or 0
  adopt(tonumber(noctalia.state.get("position")) or 0)
  noctalia.state.watch("position", onPosition)
  noctalia.state.watch("playing", onPlaying)
  noctalia.state.watch("track", onTrack)
end

return M
