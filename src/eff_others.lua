-- Discworld Magic — other-player EFF state tracking.
--
-- Mirrors the self-side flow in eff.lua, keyed by player name. Each
-- detected wire transition emits a unified shield.up / shield.down
-- event with `subject = <PlayerName>` so consumers (discworld-grouping,
-- audio plugins, etc.) can track group-mates' floaters without
-- re-parsing.
--
-- State (module-local; one row per observed player):
--   eff_others[player] = { item = "<item>" }
--
-- Triggers ported from Quow's *_ON*_EFF set. The " * X is floating
-- around (him|her|it):" status-report variant is deferred because it
-- carries no player name on the line itself — protection_report.lua
-- handles attribution via the surrounding "Arcane protection for X:-"
-- block header.
--
-- Events emitted on every transition:
--   net.mallard.discworld.shield.up   { subject = "<PlayerName>", type = "eff", item = "<floater>" }
--   net.mallard.discworld.shield.down { subject = "<PlayerName>", type = "eff", silent = false }

local eff_others = {}

local function set_other_eff(player, item)
  if type(player) ~= "string" or player == "" then return end
  if type(item)   ~= "string" or item   == "" then return end
  eff_others[player] = { item = item }
  events.emit("net.mallard.discworld.shield.up", {
    subject = player,
    type    = "eff",
    item    = item,
  })
end

local function break_other_eff(player)
  if type(player) ~= "string" or player == "" then return end
  eff_others[player] = nil
  events.emit("net.mallard.discworld.shield.down", {
    subject = player,
    type    = "eff",
    silent  = false,
  })
end

-- `X begins to float around Y.` Captures: [1] = item, [2] = player.
-- The leading "(?:The )?" matches the optional article for unnamed items
-- ("The shield begins to float around Brodfist.") without consuming the
-- name on a named-item line ("Steelwing begins to float around Brodfist.").
mud.trigger([[^(?:The )?(.+) begins to float around ([A-Z][a-zA-Z'-]+(?: [A-Z][a-zA-Z'-]+){0,3})\.$]],
  function(m) set_other_eff(m[2], m[1]) end)

-- `In blocking the attack X floating around Y is knocked out of orbit.`
mud.trigger([[^In blocking the attack (.+) floating around ([A-Z][a-zA-Z'-]+(?: [A-Z][a-zA-Z'-]+){0,3}) is knocked out of orbit\.$]],
  function(m) break_other_eff(m[2]) end)

-- `X floating around Y breaks!`
mud.trigger([[^(.+) floating around ([A-Z][a-zA-Z'-]+(?: [A-Z][a-zA-Z'-]+){0,3}) breaks!$]],
  function(m) break_other_eff(m[2]) end)
