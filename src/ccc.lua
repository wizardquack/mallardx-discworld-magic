-- Discworld Magic — Chrenedict's Corporeal Covering (CCC / skin shield).
--
-- Mirrors `tpa.lua` in structure: state, transition functions, banner +
-- OS notification on dispel, unified shield.up / shield.down events,
-- and an `Arcane protection status:` reset hook.
--
-- Sections in this file:
--   1. Substance/strength model + module-local state.
--   2. set_ccc / drop_ccc — state transition + cross-plugin events.
--   3. State-tracking triggers (self).
--   4. Arcane-protection-status reset trigger.
--   5. !ccc debug alias.

-- ---------------------------------------------------------------------
-- 1. Substance/strength model + module-local state.
-- ---------------------------------------------------------------------
-- CCC paints the skin in one of three substances with a 1..5 strength
-- ladder. Unlike TPA, the wire doesn't expose a per-hit absorption
-- ladder — strength changes only when the player re-casts (refreshing
-- the covering) or inspects via `protections` / `look at self`. The
-- covering ends abruptly on dispel; there's no "weakening" intermediate
-- state visible to triggers.
--
-- Substance values: "chalk" | "latex" | "metal" | "" (unknown).
-- Strength values:  1..5 or nil (unknown — e.g. immediately after a
--                   fresh cast, before strength has been observed).
--
-- The 15 status-report phrases (5 strength rungs × 3 substances) come
-- from `protections`. The cast-message phrases give us the substance
-- but not the strength; that arrives later via `protections`.
--
-- Cross-plugin events emitted on every transition:
--   net.mallard.discworld.shield.up {
--       subject             = "self",
--       type                = "ccc",
--       substance           = "chalk" | "latex" | "metal" | "",
--       strength            = 1..5 | nil,
--       previous_substance  = previous substance or "",
--       previous_strength   = previous strength or nil,
--   }
--   net.mallard.discworld.shield.down {
--       subject             = "self",
--       type                = "ccc",
--       silent              = false,                 -- CCC has no silent-drop path
--       duration_seconds    = lifetime in seconds (nil if untracked),
--       previous_substance  = last substance before dispel,
--       previous_strength   = last known strength (nil if it was never observed),
--   }
-- This plugin owns the CCC concept end-to-end: it detects state from the
-- wire, fires the *** CCC gone! *** banner + OS notification, and emits
-- the events for downstream consumers (discworld-grouping's chip grid,
-- future audio plugins). Repeat detections of the same state re-fire
-- the event — consumers dedupe if they care about transitions vs.
-- confirmations.

local ccc_substance  = ""
local ccc_strength   = nil
local ccc_state      = ""
local ccc_started_at = nil

-- ---------------------------------------------------------------------
-- 2. State transitions.
-- ---------------------------------------------------------------------

local function set_ccc(substance, strength)
  local new_substance = substance or ""
  local new_strength  = strength            -- nil = unknown
  local prev_sub      = ccc_substance
  local prev_str      = ccc_strength

  if ccc_state ~= "up" then
    ccc_started_at = os.time()
  end
  ccc_substance = new_substance
  ccc_strength  = new_strength
  ccc_state     = "up"

  events.emit("net.mallard.discworld.shield.up", {
    subject            = "self",
    type               = "ccc",
    substance          = new_substance,
    strength           = new_strength,
    previous_substance = prev_sub,
    previous_strength  = prev_str,
  })
end

local function drop_ccc(hint_substance)
  local prev_sub = (hint_substance ~= "" and hint_substance) or ccc_substance
  local prev_str = ccc_strength
  local duration = ccc_started_at and (os.time() - ccc_started_at) or nil

  ccc_substance = ""
  ccc_strength  = nil
  ccc_state     = "down"

  -- Banner shape mirrors `*** TPA broken! ***` and `*** Floater down! ***`.
  mud.note("***",                { fg = "magenta", bold = true })
  mud.note("*** CCC gone! ***",  { fg = "magenta", bold = true })
  if duration then
    mud.note(string.format("*** Lasted %ds ***", duration),
      { fg = "magenta", bold = true })
  end
  mud.note("***",                { fg = "magenta", bold = true })

  ui.notify("CCC gone!",
    (prev_sub ~= "") and ("Your " .. prev_sub .. " covering has dispelled.")
                     or  "Your skin covering has dispelled.",
    { icon = "warning" })

  events.emit("net.mallard.discworld.shield.down", {
    subject            = "self",
    type               = "ccc",
    silent             = false,
    duration_seconds   = duration,
    previous_substance = prev_sub,
    previous_strength  = prev_str,
  })

  ccc_started_at = nil
end

-- ---------------------------------------------------------------------
-- 3. State-tracking triggers (self).
-- ---------------------------------------------------------------------

-- Initial cast / refresh — substance known, strength unknown.
mud.trigger([[^You feel your skin become rock hard\.$]],
  function() set_ccc("chalk", nil) end)
mud.trigger([[^You feel your skin become elastic as rubber\.$]],
  function() set_ccc("latex", nil) end)
mud.trigger([[^You feel your skin tingle as the metal powder fuses together into thin metal bands, forming a net-like shape\.$]],
  function() set_ccc("metal", nil) end)

-- Refresh while already covered — substance known, strength still unknown.
mud.trigger([[^Your skin feels even harder now\.$]],
  function() set_ccc("chalk", nil) end)
mud.trigger([[^Your skin feels much more elastic now\.$]],
  function() set_ccc("latex", nil) end)
mud.trigger([[^The metallic network on your skin feels (?:.+) stronger now\.$]],
  function() set_ccc("metal", nil) end)

-- Max-strength refresh — strength=5.
mud.trigger([[^Your skin is now as hard as it can get\.$]],
  function() set_ccc("chalk", 5) end)
mud.trigger([[^Your skin is now as elastic as it can get\.$]],
  function() set_ccc("latex", 5) end)
mud.trigger([[^Your skin is now as thickly covered as it can get\.$]],
  function() set_ccc("metal", 5) end)

-- Status-report lines from `protections` / `look at self`. Each phrase
-- pins both substance and exact strength. The `(?:has been|has|is)`
-- alternation covers Quow's three observed wire variants.

-- Chalk ladder (5..1)
mud.trigger([[^ \* Your skin (?:has been|has|is) hardened to a rock-like form,]],
  function() set_ccc("chalk", 5) end)
mud.trigger([[^ \* Your skin (?:has been|has|is) hardened with numerous layers of a mineral-like substance,]],
  function() set_ccc("chalk", 4) end)
mud.trigger([[^ \* Your skin (?:has been|has|is) hardened with a chalk-like substance,]],
  function() set_ccc("chalk", 3) end)
mud.trigger([[^ \* Your skin (?:has been|has|is) covered with several layers of a chalk-like substance,]],
  function() set_ccc("chalk", 2) end)
mud.trigger([[^ \* Your skin (?:has been|has|is) covered with a thin layer of chalk,]],
  function() set_ccc("chalk", 1) end)

-- Latex ladder (5..1)
mud.trigger([[^ \* Your skin has solidified into a rubberous form,]],
  function() set_ccc("latex", 5) end)
mud.trigger([[^ \* Your skin (?:has been|has|is) made elastic with numerous layers of a rubber-like substance,]],
  function() set_ccc("latex", 4) end)
mud.trigger([[^ \* Your skin (?:has been|has|is) treated with a latex-like substance,]],
  function() set_ccc("latex", 3) end)
mud.trigger([[^ \* Your skin (?:has been|has|is) covered with several layers of a latex-like substance,]],
  function() set_ccc("latex", 2) end)
mud.trigger([[^ \* Your skin (?:has been|has|is) covered with a thin layer of latex,]],
  function() set_ccc("latex", 1) end)

-- Metal ladder (5..1) — note rung 4 ("metal bands ... forming a kind of
-- net") uses "has" not "(has been|has|is)", and rung 1 ("Tiny threads")
-- has its own line shape with no "skin" prefix.
mud.trigger([[^ \* Your skin (?:has been|has|is) covered with a thick metal net,]],
  function() set_ccc("metal", 5) end)
mud.trigger([[^ \* Your skin has metal bands running all over it, forming a kind of net,]],
  function() set_ccc("metal", 4) end)
mud.trigger([[^ \* Your skin (?:has been|has|is) covered with a thin metal net,]],
  function() set_ccc("metal", 3) end)
mud.trigger([[^ \* Your skin (?:has been|has|is) covered with a thin, net-like metal coating,]],
  function() set_ccc("metal", 2) end)
mud.trigger([[^ \* Tiny threads of metal run criss-cross all over your skin,]],
  function() set_ccc("metal", 1) end)

-- Dispel — covering wears off naturally (gradual flake-off).
mud.trigger([[^Your skin feels itchy; large pieces flake off as you scratch it\.$]],
  function() drop_ccc("") end)

-- Dispel — magic-flash variant carries a substance hint via the
-- {metallic|stony|elastic} adjective.
mud.trigger([[^With a brief flash of magic, your (metallic|stony|elastic) skin falls away\.$]],
  function(m)
    local adj = m[1] or ""
    local substance = ({ metallic = "metal", stony = "chalk", elastic = "latex" })[adj] or ""
    drop_ccc(substance)
  end)

-- ---------------------------------------------------------------------
-- 4. Arcane-protection-status reset.
-- ---------------------------------------------------------------------
-- Same hook as tpa.lua / main.lua's EFF reset. The " * ..." lines that
-- follow repopulate CCC state via the per-rung triggers above; if no CCC
-- line follows, state stays cleared (no covering active).

mud.trigger([[^Arcane protection status:$]], function()
  ccc_substance  = ""
  ccc_strength   = nil
  ccc_state      = ""
  ccc_started_at = nil
end)

-- ---------------------------------------------------------------------
-- 5. Debug alias.
-- ---------------------------------------------------------------------

mud.alias([[^!ccc$]], function()
  if ccc_substance == "" and ccc_state == "" then
    mud.note("[ccc] no covering tracked")
    return
  end
  local age = ccc_started_at and (os.time() - ccc_started_at) or nil
  mud.note(string.format(
    "[ccc] substance=%s strength=%s state=%s%s",
    (ccc_substance ~= "") and ccc_substance or "?",
    (ccc_strength  ~= nil) and tostring(ccc_strength) or "?",
    ccc_state,
    age and (" age=" .. age .. "s") or ""))
end)
