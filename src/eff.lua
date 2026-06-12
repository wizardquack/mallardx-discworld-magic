-- Discworld Magic — Endorphin's Floating Friend (EFF / floater shield).
--
-- Split out of main.lua so EFF owns its concept end-to-end in one file:
-- module-local state, transition callbacks, the *** Floater down! ***
-- banner + (gated) OS notification + sound, cross-plugin events, and
-- the visual cue when the floater intercepts an attack.
--
-- Tracks the currently-orbiting floater item so we can call out attack
-- blocks visually and announce a clear banner the moment the floater
-- drops. The combat counter that the original `function {eff}` consumed
-- (`combat[def][floater]` / `floater_swoop`) lives in tt_dw's
-- `misc/combat.tin` framework and is intentionally out of scope here.
--
-- Sections in this file:
--   1. Module-local state.
--   2. set_eff / drop_eff — state transition + cross-plugin events.
--   3. State-tracking triggers (self) + combat-block highlight.
--   4. Chain counterwise-orbit silent path.
--   5. Arcane-protection-status reset trigger.
--   6. !eff debug alias.
--
-- Cross-plugin events emitted on every state transition:
--   net.mallard.discworld.shield.up   { subject = "self", type = "eff", item = "<floater>" }
--   net.mallard.discworld.shield.down { subject = "self", type = "eff", silent = bool }
-- This plugin owns the floater concept end-to-end: it detects the state from
-- the wire, fires the *** Floater down! *** banner, AND emits the event for
-- downstream consumers (discworld-vitals' panel cell, discworld-grouping's
-- shield store, future plugins). Events re-fire on every detection (e.g.
-- repeated " * X is floating around you:" report lines); consumers should
-- dedupe if they care about transitions vs. confirmations. The `silent`
-- flag is set when the player intentionally drops the floater (chain
-- counterwise orbit) — consumers may want to update state without flagging
-- it as an unexpected event.

-- ---------------------------------------------------------------------
-- 1. Module-local state.
-- ---------------------------------------------------------------------
--   eff_item    = item currently floating around you (""=none)
--   eff_state   = "up" | "down" | "unknown" | ""
--                 "unknown" is the post-connect default: the floater may have
--                 carried over from a prior session, but we haven't seen any
--                 wire signal yet to confirm. The clatters trigger fires
--                 drop_eff in this state so a server-side-persisted floater
--                 dropping before any up event still alerts. "" is the
--                 explicitly-cleared state set by the "Arcane protection
--                 status:" header — after that line we trust the follow-up
--                 status entries to repopulate, so clatters does NOT fire in
--                 "" state (avoids false positives mid-protections output).
--   eff_silent  = chain counterwise dance is in progress; suppress alarm on
--                 both the "direct hit" line AND the follow-up "clatters" line
--                 (the latter would otherwise fire drop_eff via the item-match
--                 branch and defeat the silent intent). Cleared by the clatters
--                 trigger at the end of the dance sequence.

local eff_item    = ""
local eff_state   = "unknown"
local eff_silent  = false

-- ---------------------------------------------------------------------
-- 2. set_eff / drop_eff — state transition + cross-plugin events.
-- ---------------------------------------------------------------------

local function set_eff(item)
  eff_item  = item or ""
  eff_state = "up"
  events.emit("net.mallard.discworld.shield.up", {
    subject = "self",
    type    = "eff",
    item    = eff_item,
  })
end

local function drop_eff()
  eff_state = "down"
  mud.note("***",                  { fg = "magenta", bold = true })
  mud.note("*** Floater down! ***",{ fg = "magenta", bold = true })
  mud.note("***",                  { fg = "magenta", bold = true })
  if settings.get("eff_drop_notify") then
    ui.notify("Floater down!",
      (eff_item ~= "") and ("Your " .. eff_item .. " hit the ground.") or "Your floater hit the ground.",
      { icon = "warning" })
  end
  if settings.get("eff_drop_sound") then
    mud.play_sound("mallard:ding-ding-low")
  end
  events.emit("net.mallard.discworld.shield.down", {
    subject = "self",
    type    = "eff",
    silent  = false,
  })
end

-- ---------------------------------------------------------------------
-- 3. State-tracking triggers (self) + combat-block highlight.
-- ---------------------------------------------------------------------

-- Bold-red highlight when the floater intercepts an attack. Source:
-- `#high {^In blocking the attack} {bold red}`.
mud.style([[^In blocking the attack]], { fg = "red", bold = true })

-- Floater begins orbiting (your own cast). Named items (e.g. "Steelwing")
-- print without a leading article; common items print with "A "/"An "/"The ".
-- Strip the article so eff_item stays comparable with the drop trigger,
-- which also strips it.
mud.trigger([[^(?:A |An |The )?(.+) begins to float around you\.$]], function(m)
  set_eff(m[1])
end)

-- Floater knocked out of orbit (combat hit takes it down).
mud.trigger([[floating around you is knocked out of orbit\.$]], drop_eff)

-- Floater wears off / dispelled.
mud.trigger([[^You realise that (.+) is no longer floating around you\.$]], drop_eff)

-- Status report line: " * <item> is floating around you:" (eff or
-- protections command). Initialises state on session resume. Strip the
-- article so eff_item matches the drop-trigger capture.
mud.trigger([[^ \* (?:A |An |The )?(.+) is floating around you:$]], function(m)
  set_eff(m[1])
end)

-- Generic "your floater item just hit the ground" — unexpected death.
-- Fires the alarm when the falling item matches the tracked eff, OR when
-- state is "unknown" (post-connect, no observed up/down event yet — a
-- session-carryover floater dropping in this window would otherwise be
-- silently missed; accept the false-positive risk on unrelated clattering
-- items in this narrow window). When eff_silent is set we're mid chain
-- counterwise dance: skip the alarm and clear the flag. Named items
-- (e.g. "Steelwing") print without a leading article; common items print
-- with "A "/"An "/"The ".
mud.trigger([[^(?:A |An |The )?(.+) clatters to the ground\.$]], function(m)
  if eff_silent then
    eff_silent = false
    return
  end
  if eff_item ~= "" and m[1] == eff_item then
    drop_eff()
  elseif eff_state == "unknown" then
    drop_eff()
  end
end)

-- ---------------------------------------------------------------------
-- 4. Chain counterwise-orbit silent path.
-- ---------------------------------------------------------------------
-- Chain counterwise-orbit dance: intentionally takes the floater down.
-- The follow-up "direct hit" AND "clatters" lines should both stay silent.

mud.trigger([[^You send the chain into a counterwise orbit around you\.$]], function()
  eff_silent = true
end)

mud.trigger([[^The chain scores a direct hit and falls to the ground!$]], function()
  if eff_silent then
    eff_state  = "down"
    -- eff_silent left set; the clatters handler clears it after suppressing
    -- the item-match branch (which would otherwise fire the alarm).
    -- Silent flag tells consumers (vitals) to update state without alarming.
    events.emit("net.mallard.discworld.shield.down", {
      subject = "self",
      type    = "eff",
      silent  = true,
    })
  end
end)

-- ---------------------------------------------------------------------
-- 5. Arcane-protection-status reset trigger.
-- ---------------------------------------------------------------------
-- "Arcane protection status:" header — clears EFF state; the " * ..."
-- lines that follow repopulate it via the per-protection triggers
-- registered here. TPA registers its own reset against this same line
-- in tpa.lua (anonymous triggers on a shared pattern all fire), and
-- CCC and Bugshield register their own resets in src/ccc.lua and
-- src/bug.lua against the same line.
-- Source: `magic.tin` (shared header for EFF/CCC/TPA/Bugshield).
mud.trigger([[^Arcane protection status:$]], function()
  eff_item  = ""
  eff_state = ""
end)

-- ---------------------------------------------------------------------
-- 6. !eff debug alias.
-- ---------------------------------------------------------------------

mud.alias([[^!eff$]], function()
  if eff_item == "" and eff_state == "" then
    mud.note("[eff] no floater tracked")
  else
    mud.note("[eff] item=" .. eff_item .. " state=" .. eff_state)
  end
end)
