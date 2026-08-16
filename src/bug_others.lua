-- Discworld Magic — other-player Bugshield state tracking.
--
-- Mirrors the self-side flow in bug.lua, keyed by player name. Cast,
-- scatter, and crash lines all carry the player name explicitly; the
-- `protections` / `look <player>` active-status report does not (same
-- v1 limitation already documented for TPA/CCC/EFF look-at lines), so
-- it's omitted.
--
-- State (module-local; one row per observed player):
--   bug_others[player] = {
--     size       = "<cloud size>",
--     bugs       = "<species>",
--     started_at = epoch seconds,
--   }

-- Wire vocabulary + pattern shapes shared with bug.lua; see
-- src/bug_patterns.lua for why each part is bounded the way it is.
local P = require("bug_patterns")

-- The other-player target: a captured name rather than the literal
-- `you`. The up-line pattern attaches the target in two alternative
-- branches, so the name lands in whichever of the two groups fired.
local TARGET = "(" .. P.NAME .. ")"
local function named(m, a, b)
  local v = m[a]
  if v == nil or v == "" then v = m[b] end
  return v
end

local bug_others = {}   -- player → state row

local function set_other_bug(player, size, bugs)
  if type(player) ~= "string" or player == "" then return end
  local row = bug_others[player]
  local prev_size = (row and row.size) or ""
  local prev_bugs = (row and row.bugs) or ""
  -- Carry forward whichever attribute this line didn't mention — same
  -- reasoning as bug.lua's set_bug.
  local new_size = (size ~= nil and size ~= "") and size or prev_size
  local new_bugs = (bugs ~= nil and bugs ~= "") and bugs or prev_bugs

  if not row then
    row = { size = new_size, bugs = new_bugs, started_at = os.time() }
    bug_others[player] = row
  else
    row.size = new_size
    row.bugs = new_bugs
  end

  events.emit("net.mallard.discworld.shield.up", {
    subject       = player,
    type          = "bug",
    size          = new_size,
    bugs          = new_bugs,
    previous_size = prev_size,
    previous_bugs = prev_bugs,
  })
end

local function break_other_bug(player, cause)
  if type(player) ~= "string" or player == "" then return end
  local row       = bug_others[player]
  local prev_size = (row and row.size) or ""
  local prev_bugs = (row and row.bugs) or ""
  local duration  = row and row.started_at and (os.time() - row.started_at) or nil

  bug_others[player] = nil

  events.emit("net.mallard.discworld.shield.down", {
    subject          = player,
    type             = "bug",
    silent           = false,
    cause            = cause or "scatter",
    duration_seconds = duration,
    previous_size    = prev_size,
    previous_bugs    = prev_bugs,
  })
end

-- ---------------------------------------------------------------------
-- Cast line — same shape as self, with the player name captured in
-- place of `you`. Captures: [1] = size, [2] = bugs, [3]/[4] = player.
-- ---------------------------------------------------------------------
mud.trigger(P.up(TARGET),
  function(m) set_other_bug(named(m, 3, 4), m[1], m[2]) end)

-- Upgrade — a better species takes over. Captures the INCOMING species;
-- see bug.lua for why this can't fold into the pattern above.
mud.trigger(P.retreat(TARGET),
  function(m) set_other_bug(m[3], m[1], m[2]) end)

-- ---------------------------------------------------------------------
-- Drop lines — captures: [1] = bugs, [2] = player.
-- ---------------------------------------------------------------------

-- Wore off.
mud.trigger(P.scatter(TARGET),
  function(m) break_other_bug(m[2], "scatter") end)

-- Destroyed.
mud.trigger(P.crash(TARGET),
  function(m) break_other_bug(m[2], "destroyed") end)
