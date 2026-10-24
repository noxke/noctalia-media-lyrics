-- The plugin's playback clock. Every entry reads the position from here instead of
-- interpolating the service's `position` state on its own, so the bar widget, the panel
-- and anything added later move together and cannot drift apart.
--
-- The service publishes the whole second the player is in, twice a second. Advancing a
-- display straight from that value makes it step backwards whenever a report lands behind
-- the interpolation, so the position is carried by a rate instead: a report steers a rate
-- that stays near 1, and the only assignments that are not forward moves are the seeks and
-- the pauses.

local M = {}

-- A report this far below the previous one, or this far above the display, is the player
-- at another point of the track rather than the clock it is on.
local SEEK_BACK_US = 1500000
local SEEK_FORWARD_US = 2000000
-- The error is erased over about this long while the rate stays inside these limits, so
-- the display cannot stall and cannot visibly change speed while it catches up.
local CATCHUP_US = 1500000
local RATE_MIN = 0.75
local RATE_MAX = 1.25
-- A report is the floor of the player's position, so its middle is the best estimate of
-- where the player actually is.
local MID_SECOND_US = 500000

local attached = false
local onChange = nil
local playing = false
local displayUs = 0
local anchorMs = 0
local rate = 1
local lastReportedUs = 0
local durationUs = 0

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

-- The wall clock, not os.clock(): in this host os.clock() counts CPU time and runs faster
-- than the clock the player keeps.
local function wallMs()
  if noctalia.nowMs ~= nil then
    return noctalia.nowMs()
  end
  return os.clock() * 1000
end

-- Fold the time that has passed at the current rate into the display, so the rate can be
-- changed without moving the position itself.
local function materialize()
  local now = wallMs()
  if anchorMs == 0 then
    anchorMs = now
    return
  end
  if playing and now > anchorMs then
    displayUs = displayUs + (now - anchorMs) * 1000 * rate
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
  rate = 1
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
  return math.floor(displayUs + elapsed * 1000 * rate)
end

function M.getDurationUs()
  return durationUs
end

function M.isPlaying()
  return playing
end

-- The player has been asked to move to this position; the report that confirms it arrives
-- with the next poll. Adopting it now keeps the display on the new position instead of
-- falling back to the old one until that report lands.
function M.noteSeek(us)
  adopt(tonumber(us) or 0)
  changed()
end

local function onPosition(value)
  local reported = tonumber(value) or 0
  materialize()
  if not playing then
    adopt(reported)
  elseif reported < lastReportedUs - SEEK_BACK_US or reported - displayUs > SEEK_FORWARD_US then
    adopt(reported)
  else
    rate = clamp(1 + (reported + MID_SECOND_US - displayUs) / CATCHUP_US, RATE_MIN, RATE_MAX)
    if reported > lastReportedUs then
      lastReportedUs = reported
    end
  end
  changed()
end

local function onPlaying(value)
  local nextPlaying = value == true
  materialize()
  if nextPlaying ~= playing then
    playing = nextPlaying
    rate = 1
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
