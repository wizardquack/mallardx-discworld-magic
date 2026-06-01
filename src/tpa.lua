-- Discworld Magic — Transcendent Pneumatic Alleviator (impact shield).
--
-- Split out of main.lua so TPA owns its concept end-to-end in one file:
-- absorption-ladder state, transition callbacks, the *** TPA broken! ***
-- banner, cross-plugin events, AND the stream-annotation rules that
-- paint the percentage into the line.
--
-- Sections in this file:
--   1. Absorption ladder + module-local state.
--   2. set_tpa / break_tpa — state transition + cross-plugin events.
--   3. State-tracking triggers (self).
--   4. Stream annotations — OTHERS' TPA state changes
--      (tt_dw tpa.tin lines 39-48).
--   5. Stream annotations — `protections` / `arcane protection status`
--      report (self + others; tt_dw tpa.tin lines 201-203).
--   6. Arcane-protection-status reset trigger (clears local state).
--   7. !tpa debug alias.

-- ---------------------------------------------------------------------
-- 1. Absorption ladder + module-local state.
-- ---------------------------------------------------------------------
-- TPA is a magical impact shield with a six-rung absorption ladder.
-- Each hit the shield absorbs shifts the glow one rung down; when the
-- shield reaches 0% (after the next hit at flickering yellow) it
-- breaks. The ladder + percentages are ported from tt_dw's `tpa_perc`:
--
--   invisible          = 100%   (just cast / lapsed back to full)
--   dull red           =  80%
--   bright red         =  60%
--   wobbling orange    =  40%
--   flickering yellow  =  20%
--   broken             =   0%   (shield down)
--
-- We track more than just up/down because (a) future consumers (a
-- richer vitals cell, an audio-alert plugin) will want the ladder
-- without re-parsing the wire, and (b) the break event is more useful
-- when it carries the hit count + duration of the shield's life.
--
-- Cross-plugin events emitted on every transition:
--   net.mallard.discworld.shield.up {
--       subject          = "self",
--       type             = "tpa",
--       glow             = "<current colour>",
--       percent          = 0..100,
--       previous_glow    = "<previous colour>" or "" if first transition,
--       previous_percent = 0..100 or nil,
--       hits             = total hits absorbed this shield's life,
--   }
--   net.mallard.discworld.shield.down {
--       subject          = "self",
--       type             = "tpa",
--       silent           = false,                  -- TPA has no silent-drop path
--       hits             = absorbed hit count,
--       duration_seconds = lifetime of the shield (nil if untracked),
--       previous_glow    = last glow before break,
--       previous_percent = last percent before break,
--   }
-- This plugin owns the shield concept end-to-end: it detects state from
-- the wire, fires the *** TPA broken! *** banner + OS notification, and
-- emits events for downstream consumers. Consumers that only care
-- about up-vs-down can read `state` from the event-bus directly;
-- consumers that want richer behaviour (e.g. an "audible warning at
-- 40%" plugin) have everything they need in the payloads above.

local TPA_PERCENT = {
  ["invisible"]         = 100,
  ["dull red"]          = 80,
  ["bright red"]        = 60,
  ["wobbling orange"]   = 40,
  ["flickering yellow"] = 20,
  ["broken"]            = 0,
}

local tpa_glow       = ""
local tpa_percent    = nil
local tpa_state      = ""
local tpa_hits       = 0
local tpa_started_at = nil

-- ---------------------------------------------------------------------
-- 2. State transitions.
-- ---------------------------------------------------------------------

local function set_tpa(glow)
  local new_glow    = glow or ""
  local new_percent = TPA_PERCENT[new_glow]   -- nil if glow is unrecognized
  local prev_glow   = tpa_glow
  local prev_pct    = tpa_percent

  if tpa_state ~= "up" then
    -- Fresh shield (first cast, or recast after a break / clean state).
    -- Reset the per-shield counters; preserve them otherwise so the
    -- status-report trigger doesn't blow them away.
    tpa_started_at = os.time()
    tpa_hits       = 0
  elseif new_percent and prev_pct and new_percent < prev_pct then
    -- Shield weakened a rung — this absorbs one more hit.
    tpa_hits = tpa_hits + 1
  end

  tpa_glow    = new_glow
  tpa_percent = new_percent
  tpa_state   = "up"

  events.emit("net.mallard.discworld.shield.up", {
    subject          = "self",
    type             = "tpa",
    glow             = new_glow,
    percent          = new_percent,
    previous_glow    = prev_glow,
    previous_percent = prev_pct,
    hits             = tpa_hits,
  })
end

local function break_tpa()
  local prev_glow = tpa_glow
  local prev_pct  = tpa_percent
  local hits      = tpa_hits
  local duration  = tpa_started_at and (os.time() - tpa_started_at) or nil

  tpa_glow    = "broken"
  tpa_percent = 0
  tpa_state   = "down"

  -- Visible banner — keep tt_dw's `*** TPA broken! ***` shape and add a
  -- hits + duration line when we have stats to report.
  mud.note("***",                { fg = "red", bold = true })
  mud.note("*** TPA broken! ***",{ fg = "red", bold = true })
  if hits > 0 and duration then
    mud.note(string.format("*** %d %s absorbed over %ds ***",
      hits, (hits == 1) and "hit" or "hits", duration),
      { fg = "red", bold = true })
  elseif duration then
    mud.note(string.format("*** Lasted %ds ***", duration), { fg = "red", bold = true })
  end
  mud.note("***",                { fg = "red", bold = true })

  events.emit("net.mallard.discworld.shield.down", {
    subject          = "self",
    type             = "tpa",
    silent           = false,
    hits             = hits,
    duration_seconds = duration,
    previous_glow    = prev_glow,
    previous_percent = prev_pct,
  })

  tpa_hits       = 0
  tpa_started_at = nil
end

-- ---------------------------------------------------------------------
-- 3. State-tracking triggers (self).
-- ---------------------------------------------------------------------

-- First cast / refresh: shield is freshly invisible.
mud.trigger([[^With a noise that sounds like "Plink!", everything around you flashes red for a moment\.$]],
  function() set_tpa("invisible") end)

-- Shield absorbs a hit, going from invisible → glow.
mud.trigger([[^As your shield absorbs the impact, it becomes visible as a (.+?) glow\.$]],
  function(m) set_tpa(m[1]) end)

-- Shield absorbs another hit, glow weakens X → Y. We track the *new* glow.
mud.trigger([[^As your shield absorbs the impact, its glow changes from a (.+?) to a (.+?)\.$]],
  function(m) set_tpa(m[2]) end)

-- Shield glow shifts without an explicit absorption message (recovery /
-- between-casts state correction). Track the new glow.
mud.trigger([[^Your shield changes from a (.+?) to a (.+?)\.$]],
  function(m) set_tpa(m[2]) end)

-- Shield fully recovers back to invisible.
mud.trigger([[^Your shield stops glowing a (.+?) and lapses back into invisibility\.$]],
  function() set_tpa("invisible") end)

-- Shield breaks under a hit it can't absorb. Note the literal double
-- space between the two sentences — preserved from the wire text.
mud.trigger([[^There is a sudden white flash\.  Your magical shield has broken\.$]], break_tpa)

-- Status-report lines (from the `protections` / `arcane protection
-- status` command). Order matters: the invisible variant has no glow
-- adjective, so we register it first to win against the general one.
mud.trigger([[^ \* You are surrounded by a magical impact shield\.$]],
  function() set_tpa("invisible") end)
mud.trigger([[^ \* You are surrounded by a (.+?) magical impact shield\.$]],
  function(m) set_tpa(m[1]) end)

-- ---------------------------------------------------------------------
-- 4. Stream annotations — OTHERS' TPA state changes.
-- ---------------------------------------------------------------------
-- Source: 5 #sub rules (tpa.tin lines 39-48) that append
-- ` (tpa: <colour>NN%<reset>)` after every visible TPA state change on
-- another player, and colour-grade the glow word itself by the same
-- percentage mapping.
--
-- mud.replace template-segment behaviour we lean on here: in the third
-- argument, %N backrefs reproduce the original captured spans WITH
-- their wire styling intact, while literal segments receive the
-- `style` opt. So splitting the pattern as `(prefix)glow(suffix)` and
-- writing the template as `%1glow%2 (tpa: NN%%)` lets one rule both
-- recolour the glow word AND append a coloured annotation, leaving the
-- prefix/suffix untouched.
--
-- The four-glow ladder is expanded into separate rules per
-- (line-shape, glow) pair since the percentage and colour change with
-- the glow and the template needs them baked in.

-- Plink — freshly invisible, 100%; no glow word. Two variants:
-- self-cast ("everything around you …") and others' cast ("the air
-- around X …"). The self-cast state-tracking trigger lives in section
-- 3; this annotation fires independently on the same line.
mud.replace([[^With a noise that sounds like "Plink!", everything around you flashes red for a moment\.$]],
  "%0 (tpa: 100%%)", { fg = "yellow" })
mud.replace([[^With a noise that sounds like "Plink!", the air around .+ flashes red for a moment\.$]],
  "%0 (tpa: 100%%)", { fg = "yellow" })

-- A new shield-glow appears around someone (4 variants).
mud.replace([[^(A )dull red( glow appears around .+\.)$]],
  "%1dull red%2 (tpa: 80%%)", { fg = "red" })
mud.replace([[^(A )bright red( glow appears around .+\.)$]],
  "%1bright red%2 (tpa: 60%%)", { fg = "red", bold = true })
mud.replace([[^(A )wobbling orange( glow appears around .+\.)$]],
  "%1wobbling orange%2 (tpa: 40%%)", { fg = "yellow", bold = true })
mud.replace([[^(A )flickering yellow( glow appears around .+\.)$]],
  "%1flickering yellow%2 (tpa: 20%%)", { fg = "yellow" })

-- Existing glow weakens (or shifts) — keyed on the NEW glow (which
-- carries the current percentage); old glow left as a non-capturing
-- alternation in the leading backref so it stays styled by the wire.
mud.replace([[^(The (?:dull red|bright red|wobbling orange|flickering yellow) glow around .+ becomes )dull red(\.)$]],
  "%1dull red%2 (tpa: 80%%)", { fg = "red" })
mud.replace([[^(The (?:dull red|bright red|wobbling orange|flickering yellow) glow around .+ becomes )bright red(\.)$]],
  "%1bright red%2 (tpa: 60%%)", { fg = "red", bold = true })
mud.replace([[^(The (?:dull red|bright red|wobbling orange|flickering yellow) glow around .+ becomes )wobbling orange(\.)$]],
  "%1wobbling orange%2 (tpa: 40%%)", { fg = "yellow", bold = true })
mud.replace([[^(The (?:dull red|bright red|wobbling orange|flickering yellow) glow around .+ becomes )flickering yellow(\.)$]],
  "%1flickering yellow%2 (tpa: 20%%)", { fg = "yellow" })

-- Shield breaks under a hit (white flash around them; no glow word).
mud.replace([[^There is a sudden white flash around .+\.$]],
  "%0 (tpa: broken)", { fg = "magenta", bold = true })

-- Glow disappears — shield recovered back to invisible / 100%.
-- No replacement glow to recolour; the line ends with `disappears.`.
mud.replace([[^The (?:dull red|bright red|wobbling orange|flickering yellow) glow around .+ disappears\.$]],
  "%0 (tpa: 100%%)", { fg = "yellow" })

-- ---------------------------------------------------------------------
-- 5. Stream annotations — protections / arcane-status report.
-- ---------------------------------------------------------------------
-- Source: tpa.tin lines 201-203. One #high (plain "invisible" variant
-- → green) plus one #sub that colour-codes the glow word and appends
-- ` (NN%)`. Applies to both self ("You are surrounded by ...") and
-- others ("He/She/It/They is/are surrounded by ...").
--
-- Same backref/literal split as section 4 — the glow word becomes a
-- styled literal, the surrounding text stays as pass-through backrefs.

-- Invisible / 100% — plain "magical impact shield" line, no glow word.
mud.style([[^ \* (?:He|She|It|You|They) (?:is|are) surrounded by a magical impact shield\.$]],
  { fg = "green" })

-- Visible-glow variants — recolour the glow word and append (NN%).
mud.replace(
  [[^( \* (?:He|She|It|You|They) (?:is|are) surrounded by a )dull red( magical impact shield\.)$]],
  "%1dull red%2 (80%%)", { fg = "red" })
mud.replace(
  [[^( \* (?:He|She|It|You|They) (?:is|are) surrounded by a )bright red( magical impact shield\.)$]],
  "%1bright red%2 (60%%)", { fg = "red", bold = true })
mud.replace(
  [[^( \* (?:He|She|It|You|They) (?:is|are) surrounded by a )wobbling orange( magical impact shield\.)$]],
  "%1wobbling orange%2 (40%%)", { fg = "yellow", bold = true })
mud.replace(
  [[^( \* (?:He|She|It|You|They) (?:is|are) surrounded by a )flickering yellow( magical impact shield\.)$]],
  "%1flickering yellow%2 (20%%)", { fg = "yellow" })

-- ---------------------------------------------------------------------
-- 6. Arcane-protection-status reset.
-- ---------------------------------------------------------------------
-- The `protections` / `arcane protection status` command prints a fresh
-- block of " * ..." lines. Resetting here lets those lines repopulate
-- TPA state cleanly; if no TPA line follows, state stays cleared. EFF
-- registers its own reset against this same header in main.lua —
-- multiple anonymous triggers on a pattern all fire.

mud.trigger([[^Arcane protection status:$]], function()
  tpa_glow       = ""
  tpa_percent    = nil
  tpa_state      = ""
  tpa_hits       = 0
  tpa_started_at = nil
end)

-- ---------------------------------------------------------------------
-- 7. Debug alias.
-- ---------------------------------------------------------------------

mud.alias([[^!tpa$]], function()
  if tpa_glow == "" and tpa_state == "" then
    mud.note("[tpa] no shield tracked")
    return
  end
  local age = tpa_started_at and (os.time() - tpa_started_at) or nil
  mud.note(string.format(
    "[tpa] glow=%s percent=%s state=%s hits=%d%s",
    tpa_glow,
    (tpa_percent ~= nil) and tostring(tpa_percent) or "?",
    tpa_state,
    tpa_hits,
    age and (" age=" .. age .. "s") or ""))
end)
