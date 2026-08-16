-- Discworld Magic — Bugshield (insect cloud / swarm shield).
--
-- Ported from tt_dw's bugshield.tin and Quow's BUG triggers. Tracks the
-- cloud's size (handful → plague) and bug species, fires three distinct
-- banners along its lifecycle (warn / gone / destroyed), and emits the
-- unified shield.up / shield.down events for downstream consumers
-- (grouping pill, future audio plugins).
--
-- Sections in this file:
--   1. Vocabulary + module-local state.
--   2. set_bug / drop_bug + warn banner.
--   3. State-tracking triggers (self).
--   4. Arcane-protection-status reset trigger.
--   5. !bug debug alias.

-- ---------------------------------------------------------------------
-- 1. Vocabulary + module-local state.
-- ---------------------------------------------------------------------
-- Bug shield has two attributes: size (the cloud's magnitude) and bugs
-- (the species). Neither is present on every wire line — a cast line may
-- omit the size ("The assassin bugs begin to circle you slowly."), and
-- the upgrade line changes the species while omitting the size — so
-- set_bug carries the last known value forward for whichever the line
-- didn't mention.
--
-- Two `down` paths share one event: "scatter" = timed-out / wore off;
-- "crash" = destroyed in combat. The on-screen banner distinguishes
-- them but the shield.down payload is the same shape — `previous_*`
-- carries the last known size + bugs, and a `cause` field tags which
-- path fired so future consumers can branch (warn alarm, etc.).
--
-- Events emitted on every transition:
--   net.mallard.discworld.shield.up {
--       subject         = "self",
--       type            = "bug",
--       size            = "<cloud size>",
--       bugs            = "<species>",
--       previous_size   = previous size or "",
--       previous_bugs   = previous species or "",
--   }
--   net.mallard.discworld.shield.down {
--       subject          = "self",
--       type             = "bug",
--       silent           = false,
--       cause            = "scatter" | "destroyed",
--       duration_seconds = lifetime in seconds (nil if untracked),
--       previous_size    = last size before drop,
--       previous_bugs    = last species before drop,
--   }

-- The wire vocabulary and pattern shapes are shared with bug_others.lua
-- (and checked against a line corpus by tests/bug_regex_test.lua) — see
-- src/bug_patterns.lua for why each part is bounded the way it is.
local P = require("bug_patterns")

local char_switch = require("char_switch")

local bug_size       = ""
local bug_bugs       = ""
local bug_state      = ""
local bug_started_at = nil

-- ---------------------------------------------------------------------
-- 2. Transitions + warn banner.
-- ---------------------------------------------------------------------

local function set_bug(size, bugs)
  local prev_size = bug_size
  local prev_bugs = bug_bugs
  -- Not every line carries both attributes. "The assassin bugs begin to
  -- circle you slowly." omits the size, and the upgrade line omits it
  -- while changing the species. Carry the last known value forward
  -- rather than blanking the chip's detail on a line that simply didn't
  -- mention it.
  local new_size = (size ~= nil and size ~= "") and size or prev_size
  local new_bugs = (bugs ~= nil and bugs ~= "") and bugs or prev_bugs

  if bug_state ~= "up" then
    bug_started_at = os.time()
  end
  bug_size  = new_size
  bug_bugs  = new_bugs
  bug_state = "up"

  events.emit("net.mallard.discworld.shield.up", {
    subject       = "self",
    type          = "bug",
    size          = new_size,
    bugs          = new_bugs,
    previous_size = prev_size,
    previous_bugs = prev_bugs,
  })
end

local function drop_bug(cause)
  local prev_size = bug_size
  local prev_bugs = bug_bugs
  local duration  = bug_started_at and (os.time() - bug_started_at) or nil

  bug_size  = ""
  bug_bugs  = ""
  bug_state = "down"

  -- Banner shape mirrors `*** TPA broken! ***` and `*** Floater down! ***`.
  -- Two visually distinct prefixes per cause so the player can tell at a
  -- glance whether the shield wore off (orange) or was destroyed in
  -- combat (red).
  local title = (cause == "destroyed") and "*** Bugshield destroyed! ***" or "*** Bugshield gone! ***"
  local fg    = (cause == "destroyed") and "red" or "yellow"
  mud.note("***",  { fg = fg, bold = true })
  mud.note(title,  { fg = fg, bold = true })
  if duration then
    mud.note(string.format("*** Lasted %ds ***", duration), { fg = fg, bold = true })
  end
  mud.note("***",  { fg = fg, bold = true })

  ui.notify((cause == "destroyed") and "Bugshield destroyed!" or "Bugshield gone!",
    (prev_size ~= "" and prev_bugs ~= "")
      and string.format("Your %s of %s is gone.", prev_size, prev_bugs)
      or  "Your bug shield is gone.",
    { icon = "warning" })

  events.emit("net.mallard.discworld.shield.down", {
    subject          = "self",
    type             = "bug",
    silent           = false,
    cause            = cause or "scatter",
    duration_seconds = duration,
    previous_size    = prev_size,
    previous_bugs    = prev_bugs,
  })

  bug_started_at = nil
end

-- "Some of the bugs ... fly off / break away and disperse" — the cloud
-- is thinning out but still up. tt_dw fires a warning banner; we mirror
-- it and leave state alone.
local function warn_bug()
  mud.note("*** Bugshield warning! ***", { fg = "yellow", bold = true })
end

-- ---------------------------------------------------------------------
-- 3. State-tracking triggers (self).
-- ---------------------------------------------------------------------

-- Active status from `protections` / `look at self`.
-- Captures: [1] = size, [2] = bugs.
mud.trigger(P.report(P.SELF_SUBJECT), function(m) set_bug(m[1], m[2]) end)

-- Cast line. Captures: [1] = size (empty on lines that omit it),
-- [2] = bugs.
mud.trigger(P.up(P.SELF), function(m) set_bug(m[1], m[2]) end)

-- Upgrade — the current cloud is driven off and a better species takes
-- over. Captures the INCOMING species; the size is carried forward by
-- set_bug. This has to stay a separate trigger: the generic cast line
-- above would capture the departing swarm.
mud.trigger(P.retreat(P.SELF), function(m) set_bug(m[1], m[2]) end)

-- Warn — cloud thinning out, still up.
mud.trigger([[^Some of the [a-z][a-z ]* around you fly off\b]],
  function() warn_bug() end)
mud.trigger([[^Some of the [a-z][a-z ]* orbiting you break away\b]],
  function() warn_bug() end)

-- Drop — wore off (timed out). Capture: [1] = bugs.
mud.trigger(P.scatter(P.SELF), function() drop_bug("scatter") end)

-- Drop — destroyed in combat. Capture: [1] = bugs.
mud.trigger(P.crash(P.SELF), function() drop_bug("destroyed") end)

-- ---------------------------------------------------------------------
-- 4. Arcane-protection-status reset.
-- ---------------------------------------------------------------------
-- Same shared hook as tpa.lua / ccc.lua / main.lua's EFF reset.

local function reset_bug_state()
  bug_size       = ""
  bug_bugs       = ""
  bug_state      = ""
  bug_started_at = nil
end

mud.trigger([[^Arcane protection status:$]], reset_bug_state)

-- Drop stale cloud state on a character switch (`su`). See char_switch.lua.
char_switch.on(reset_bug_state)

-- ---------------------------------------------------------------------
-- 5. Debug alias.
-- ---------------------------------------------------------------------

mud.alias([[^!bug$]], function()
  if bug_size == "" and bug_state == "" then
    mud.note("[bug] no shield tracked")
    return
  end
  local age = bug_started_at and (os.time() - bug_started_at) or nil
  mud.note(string.format(
    "[bug] size=%s bugs=%s state=%s%s",
    (bug_size ~= "") and bug_size or "?",
    (bug_bugs ~= "") and bug_bugs or "?",
    bug_state,
    age and (" age=" .. age .. "s") or ""))
end)
