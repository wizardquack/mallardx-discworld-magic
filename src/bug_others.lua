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

local SIZES   = [[handful|cloud|small swarm|large swarm|vast swarm|plague]]
local SPECIES = [[lacewings|stick insects|mayflies|praying mantids|butterflies|ladybirds|dragonflies|damselflies|moths|grasshoppers|winged termites|termites|sandflies|mosquitoes|gnats|crickets|flying ants|ants|locusts|horseflies|cicadas|bees|wasps|hornets|elephant beetles|assassin bugs]]
local NAME    = [[[A-Z][a-zA-Z'-]+(?: [A-Z][a-zA-Z'-]+){0,3}]]

local bug_others = {}   -- player → state row

local function set_other_bug(player, size, bugs)
  if type(player) ~= "string" or player == "" then return end
  local row = bug_others[player]
  local new_size = size or ""
  local new_bugs = bugs or ""
  local prev_size = (row and row.size) or ""
  local prev_bugs = (row and row.bugs) or ""

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
-- Cast line — same shape as self, with the player name captured at
-- the end. Captures: [1] = size, [2] = bugs, [3] = player.
-- ---------------------------------------------------------------------
mud.trigger(string.format(
  [[^(?:[^,]+, )?[Tt]he (%s) of (%s) (?:flutters into a loosely-formed orbit around |forms a chaotic web of small white bodies around |starts to hover near |begins to circle |begins to circle around |begins to orbit |clusters haphazardly |begins to cluster around |begins to buzz erratically around |begins to buzz around |flutters into a chaotic formation around )(%s)(?:| happily| slowly|, chirping gently|, buzzing hungrily)\.$]],
  SIZES, SPECIES, NAME),
  function(m) set_other_bug(m[3], m[1], m[2]) end)

-- ---------------------------------------------------------------------
-- Drop lines — captures: [1] = bugs, [2] = player.
-- ---------------------------------------------------------------------

-- Wore off.
mud.trigger(string.format(
  [[^The (%s) surrounding (%s) scatter in different directions and fly off\.$]],
  SPECIES, NAME),
  function(m) break_other_bug(m[2], "scatter") end)

-- Destroyed.
mud.trigger(string.format(
  [[^The last of the injured (%s) surrounding (%s) crash to the ground\.$]],
  SPECIES, NAME),
  function(m) break_other_bug(m[2], "destroyed") end)
