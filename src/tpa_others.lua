-- Discworld Magic — other-player TPA state tracking.
--
-- Mirrors the self-side ladder math in tpa.lua, keyed by player name.
-- Each detected wire transition emits a unified shield.up / shield.down
-- event with `subject = <PlayerName>` so consumers (discworld-grouping,
-- audio plugins, etc.) can track group-mates' shields without
-- re-parsing.
--
-- State (module-local; one row per observed player):
--   tpa_others[player] = {
--     glow        = "<glow>",
--     percent     = 0..100|nil,
--     hits        = int,
--     started_at  = epoch seconds,
--   }
--
-- Events emitted on every transition:
--   net.mallard.discworld.shield.up {
--       subject          = "<PlayerName>",
--       type             = "tpa",
--       glow             = "<current colour>",
--       percent          = 0..100,
--       previous_glow    = "<previous colour>" or "" if first transition,
--       previous_percent = 0..100 or nil,
--       hits             = absorbed-hits counter,
--   }
--   net.mallard.discworld.shield.down {
--       subject          = "<PlayerName>",
--       type             = "tpa",
--       silent           = false,
--       hits             = int,
--       duration_seconds = int or nil,
--       previous_glow    = "<glow>",
--       previous_percent = 0..100 or nil,
--   }

local TPA_PERCENT = {
  ["invisible"]         = 100,
  ["dull red"]          = 80,
  ["bright red"]        = 60,
  ["wobbling orange"]   = 40,
  ["flickering yellow"] = 20,
  ["broken"]            = 0,
}

local tpa_others = {}   -- player → state row

local function set_other_tpa(player, glow)
  if type(player) ~= "string" or player == "" then return end
  local row = tpa_others[player]
  local new_glow    = glow or ""
  local new_percent = TPA_PERCENT[new_glow]
  local prev_glow   = (row and row.glow)    or ""
  local prev_pct    = (row and row.percent) or nil

  if not row then
    row = { glow = new_glow, percent = new_percent, hits = 0, started_at = os.time() }
    tpa_others[player] = row
  else
    -- Shield weakened a rung — count one more absorbed hit.
    if new_percent and prev_pct and new_percent < prev_pct then
      row.hits = row.hits + 1
    end
    row.glow    = new_glow
    row.percent = new_percent
  end

  events.emit("net.mallard.discworld.shield.up", {
    subject          = player,
    type             = "tpa",
    glow             = new_glow,
    percent          = new_percent,
    previous_glow    = prev_glow,
    previous_percent = prev_pct,
    hits             = row.hits,
  })
end

local function break_other_tpa(player)
  if type(player) ~= "string" or player == "" then return end
  local row       = tpa_others[player]
  local prev_glow = (row and row.glow)    or ""
  local prev_pct  = (row and row.percent) or nil
  local hits      = (row and row.hits)    or 0
  local duration  = row and row.started_at and (os.time() - row.started_at) or nil

  tpa_others[player] = nil

  events.emit("net.mallard.discworld.shield.down", {
    subject          = player,
    type             = "tpa",
    silent           = false,
    hits             = hits,
    duration_seconds = duration,
    previous_glow    = prev_glow,
    previous_percent = prev_pct,
  })
end

-- Plink — fresh shield, 100%. Capture: [1] = player.
mud.trigger([[^With a noise that sounds like "Plink!", the air around (.+) flashes (?:yellow|red) for a moment\.$]],
  function(m) set_other_tpa(m[1], "invisible") end)

-- New visible glow appears around X. Captures: [1] = glow, [2] = player.
mud.trigger([[^A (dull red|bright red|wobbling orange|flickering yellow) glow appears around (.+)\.$]],
  function(m) set_other_tpa(m[2], m[1]) end)

-- Glow weakens (or shifts). Captures: [1] = old glow, [2] = player, [3] = new glow.
mud.trigger([[^The (dull red|bright red|wobbling orange|flickering yellow) glow around (.+) becomes (dull red|bright red|wobbling orange|flickering yellow)\.$]],
  function(m) set_other_tpa(m[2], m[3]) end)

-- Glow disappears — shield recovered to invisible/100%. Captures: [1] = player.
mud.trigger([[^The (?:dull red|bright red|wobbling orange|flickering yellow) glow around (.+) disappears\.$]],
  function(m) set_other_tpa(m[1], "invisible") end)

-- White flash → shield broke. Captures: [1] = player.
mud.trigger([[^There is a sudden white flash around (.+)\.$]],
  function(m) break_other_tpa(m[1]) end)

-- Look-at status report: " * He/She/It is surrounded by a magical impact shield."
mud.trigger([[^ \* (?:He|She|It) is surrounded by a magical impact shield\.$]],
  function(_m)
    -- We don't have the player name on this line — Quow correlates it
    -- with the preceding `look X` target. We accept the limitation
    -- (documented in §5.3 of the design): no emit from this line.
  end)

-- Look-at status report with a visible glow.
-- Captures: [1] = glow.
mud.trigger([[^ \* (?:He|She|It) is surrounded by a (dull red|bright red|wobbling orange|flickering yellow) magical impact shield\.$]],
  function(_m) end)
