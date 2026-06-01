-- Discworld Magic — other-player CCC state tracking.
--
-- Mirrors the self-side flow in ccc.lua, keyed by player name. Each
-- detected wire transition emits a unified shield.up / shield.down event
-- with `subject = <PlayerName>` so consumers (discworld-grouping,
-- audio plugins, etc.) can track group-mates' coverings without
-- re-parsing.
--
-- State (module-local; one row per observed player):
--   ccc_others[player] = {
--     substance   = "chalk" | "latex" | "metal",
--     strength    = 1..5 | nil,
--     started_at  = epoch seconds,
--   }
--
-- v1 limitation — the `protections` / status-report variants for other
-- players (` * His skin (has been|has|is) hardened ..., although `,
-- ` * Tiny threads of metal run criss-cross all over his skin, although `)
-- don't carry the player name on the line itself. Quow correlates them
-- against the preceding `look <target>` line via plugin-wide state; for
-- v1 we accept the same limitation already documented for EFF and TPA
-- look-at variants (see design doc §5.3 + tpa_others.lua section 6).
-- The cast / max / dispel triggers below all carry the player name
-- explicitly.

local ccc_others = {}   -- player → state row

local function set_other_ccc(player, substance, strength)
  if type(player) ~= "string" or player == "" then return end
  local row = ccc_others[player]
  local new_substance = substance or ""
  local new_strength  = strength
  local prev_sub      = (row and row.substance) or ""
  local prev_str      = (row and row.strength)  or nil

  if not row then
    row = { substance = new_substance, strength = new_strength, started_at = os.time() }
    ccc_others[player] = row
  else
    row.substance = new_substance
    row.strength  = new_strength
  end

  events.emit("net.mallard.discworld.shield.up", {
    subject            = player,
    type               = "ccc",
    substance          = new_substance,
    strength           = new_strength,
    previous_substance = prev_sub,
    previous_strength  = prev_str,
  })
end

local function break_other_ccc(player)
  if type(player) ~= "string" or player == "" then return end
  local row       = ccc_others[player]
  local prev_sub  = (row and row.substance) or ""
  local prev_str  = (row and row.strength)  or nil
  local duration  = row and row.started_at and (os.time() - row.started_at) or nil

  ccc_others[player] = nil

  events.emit("net.mallard.discworld.shield.down", {
    subject            = player,
    type               = "ccc",
    silent             = false,
    duration_seconds   = duration,
    previous_substance = prev_sub,
    previous_strength  = prev_str,
  })
end

-- ---------------------------------------------------------------------
-- Initial-cast triggers — substance known, strength unknown.
-- ---------------------------------------------------------------------

-- Chalk / latex via the "<player>'s skin becomes ..." shape.
-- Capture: [1] = player, [2] = "elastic as rubber" | "rock hard".
mud.trigger([[^([A-Z][a-zA-Z'-]+(?: [A-Z][a-zA-Z'-]+){0,3})'s skin becomes (elastic as rubber|rock hard)\.$]],
  function(m)
    local substance = (m[2] == "rock hard") and "chalk" or "latex"
    set_other_ccc(m[1], substance, nil)
  end)

-- Metal cast: "The metal powder fuses together into metal bands on X's skin."
mud.trigger([[^The metal powder fuses together into metal bands on ([A-Z][a-zA-Z'-]+(?: [A-Z][a-zA-Z'-]+){0,3})'s skin\.$]],
  function(m) set_other_ccc(m[1], "metal", nil) end)

-- ---------------------------------------------------------------------
-- Max-strength refresh — strength=5; substance from the descriptor word.
-- ---------------------------------------------------------------------
-- "X's skin is now as {elastic|thickly covered|hard} as it can get."
mud.trigger([[^([A-Z][a-zA-Z'-]+(?: [A-Z][a-zA-Z'-]+){0,3})'s skin is now as (elastic|thickly covered|hard) as it can get\.$]],
  function(m)
    local kind = m[2]
    local substance = (kind == "hard")           and "chalk"
                   or (kind == "elastic")        and "latex"
                   or (kind == "thickly covered") and "metal"
                   or ""
    set_other_ccc(m[1], substance, 5)
  end)

-- ---------------------------------------------------------------------
-- Dispel triggers — covering ends.
-- ---------------------------------------------------------------------

-- Gradual: "X scratches {himself|herself|itself}, and large pieces of skin flake off."
mud.trigger([[^([A-Z][a-zA-Z'-]+(?: [A-Z][a-zA-Z'-]+){0,3}) scratches (?:himself|herself|itself), and large pieces of skin flake off\.$]],
  function(m) break_other_ccc(m[1]) end)

-- Magic-flash: "There is a brief flash of magic, and something falls away from X's skin."
mud.trigger([[^There is a brief flash of magic, and something falls away from ([A-Z][a-zA-Z'-]+(?: [A-Z][a-zA-Z'-]+){0,3})'s skin\.$]],
  function(m) break_other_ccc(m[1]) end)
