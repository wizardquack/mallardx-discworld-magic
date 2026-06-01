-- Discworld Magic — Major Shield (divine protection).
--
-- Self only. Discworld priests cast Major Shield in the name of one of
-- ten gods; the protection expires after a timed duration. Unlike TPA /
-- EFF / CCC / Bugshield, there's no "broken in combat" path — divine
-- protection only ends when its timer runs out.
--
-- Sections in this file:
--   1. Vocabulary + module-local state.
--   2. set_ms / drop_ms — state transition + banner.
--   3. State-tracking triggers (self).
--   4. Arcane-protection-status reset trigger.
--   5. !ms debug alias.
--
-- tt_dw has no ms.tin equivalent; the patterns here come from Quow's
-- ArcaneShield*_Y*__MS triggers. Other-player MS is omitted: Quow's
-- only ONA line is the look-at status report, which doesn't carry a
-- player name on the line itself — same v1 limitation already
-- documented for TPA / CCC / EFF / BUG look-at lines.

-- ---------------------------------------------------------------------
-- 1. Vocabulary + module-local state.
-- ---------------------------------------------------------------------
-- The cast / status lines split into three captured parts:
--   strength: ""|"barely"|"really"|"perfectly"  (qualifies "protected"
--              — absent on the "shielded" form and on the unqualified
--              "protected" form)
--   form:     "protected" | "shielded"          (which priest verb the
--              wire uses for this deity)
--   via:      "power" | "protective armour" | "grace"
--              (the conduit phrase; deity-dependent)
--   deity:    Pishe | Gufnork | Gapp | Sandelfon | Fish | Hat | Sek |
--              Aegadon | Cubal | Reebox
--
-- Cross-plugin events emitted on every transition:
--   net.mallard.discworld.shield.up {
--       subject           = "self",
--       type              = "ms",
--       deity             = "<deity>",
--       form              = "protected" | "shielded",
--       via               = "power" | "protective armour" | "grace",
--       strength          = "" | "barely" | "really" | "perfectly",
--       previous_deity    = previous deity or "",
--       previous_strength = previous strength or "",
--   }
--   net.mallard.discworld.shield.down {
--       subject           = "self",
--       type              = "ms",
--       silent            = false,
--       duration_seconds  = lifetime in seconds (nil if untracked),
--       previous_deity    = last deity before expiry,
--       previous_strength = last strength before expiry,
--   }

local DEITIES = [[Pishe|Gufnork|Gapp|Sandelfon|Fish|Hat|Sek|Aegadon|Cubal|Reebox]]
local VIA     = [[power|protective armour|grace]]

local ms_deity      = ""
local ms_form       = ""
local ms_via        = ""
local ms_strength   = ""
local ms_state      = ""
local ms_started_at = nil

-- ---------------------------------------------------------------------
-- 2. Transitions.
-- ---------------------------------------------------------------------

local function set_ms(strength, form, via, deity)
  local new_strength = strength or ""
  local new_form     = form or ""
  local new_via      = via or ""
  local new_deity    = deity or ""
  local prev_deity   = ms_deity
  local prev_str     = ms_strength

  if ms_state ~= "up" then
    ms_started_at = os.time()
  end
  ms_strength = new_strength
  ms_form     = new_form
  ms_via      = new_via
  ms_deity    = new_deity
  ms_state    = "up"

  events.emit("net.mallard.discworld.shield.up", {
    subject           = "self",
    type              = "ms",
    deity             = new_deity,
    form              = new_form,
    via               = new_via,
    strength          = new_strength,
    previous_deity    = prev_deity,
    previous_strength = prev_str,
  })
end

local function drop_ms()
  local prev_deity = ms_deity
  local prev_str   = ms_strength
  local duration   = ms_started_at and (os.time() - ms_started_at) or nil

  ms_deity    = ""
  ms_form     = ""
  ms_via      = ""
  ms_strength = ""
  ms_state    = "down"

  -- Banner shape mirrors the rest of the shield family. Cyan rather
  -- than red/magenta since divine timeout isn't an emergency.
  mud.note("***",                              { fg = "cyan", bold = true })
  mud.note("*** Divine protection expired! ***", { fg = "cyan", bold = true })
  if duration then
    mud.note(string.format("*** Lasted %ds ***", duration), { fg = "cyan", bold = true })
  end
  mud.note("***",                              { fg = "cyan", bold = true })

  ui.notify("Divine protection expired",
    (prev_deity ~= "") and ("Your protection from " .. prev_deity .. " has worn off.")
                       or  "Your divine protection has worn off.",
    { icon = "info" })

  events.emit("net.mallard.discworld.shield.down", {
    subject           = "self",
    type              = "ms",
    silent            = false,
    duration_seconds  = duration,
    previous_deity    = prev_deity,
    previous_strength = prev_str,
  })

  ms_started_at = nil
end

-- ---------------------------------------------------------------------
-- 3. State-tracking triggers (self).
-- ---------------------------------------------------------------------

-- Cast confirmation (no trailing "You will be protected for ..." suffix).
-- "shielded" form has no strength qualifier; "protected" optionally does.
-- Captures (4): strength ("" if absent), form, via, deity.
mud.trigger(string.format(
  [[^You are (?:(barely|really|perfectly) )?(protected|shielded) by the (%s) of (%s)\.$]],
  VIA, DEITIES),
  function(m)
    set_ms(m[1] or "", m[2], m[3], m[4])
  end)

-- Active status from `protections` / `look at self` — same shape with a
-- trailing "  You will be protected for <duration>." suffix; we anchor
-- the prefix and let the timing text fall on the floor (Quow does the
-- same).
mud.trigger(string.format(
  [[^ \* You are (?:(barely|really|perfectly) )?(protected|shielded) by the (%s) of (%s)\.  You will be protected for ]],
  VIA, DEITIES),
  function(m)
    set_ms(m[1] or "", m[2], m[3], m[4])
  end)

-- Expiry.
mud.trigger([[^Your divine protection expires\.$]], drop_ms)

-- ---------------------------------------------------------------------
-- 4. Arcane-protection-status reset.
-- ---------------------------------------------------------------------
-- Same shared hook as the other shield modules.

mud.trigger([[^Arcane protection status:$]], function()
  ms_deity      = ""
  ms_form       = ""
  ms_via        = ""
  ms_strength   = ""
  ms_state      = ""
  ms_started_at = nil
end)

-- ---------------------------------------------------------------------
-- 5. Debug alias.
-- ---------------------------------------------------------------------

mud.alias([[^!ms$]], function()
  if ms_deity == "" and ms_state == "" then
    mud.note("[ms] no divine protection tracked")
    return
  end
  local age = ms_started_at and (os.time() - ms_started_at) or nil
  mud.note(string.format(
    "[ms] deity=%s form=%s via=%s strength=%s state=%s%s",
    (ms_deity    ~= "") and ms_deity    or "?",
    (ms_form     ~= "") and ms_form     or "?",
    (ms_via      ~= "") and ms_via      or "?",
    (ms_strength ~= "") and ms_strength or "-",
    ms_state,
    age and (" age=" .. age .. "s") or ""))
end)
