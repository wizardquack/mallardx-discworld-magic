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
-- Bug shield has two attributes that change together: size (the cloud's
-- magnitude) and bugs (the species). Both are visible on every wire
-- line — the cast lines, the active-status report, and the scatter /
-- crash lines all carry the species (though only some carry size).
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

-- The species + size alternations are reused across triggers; built once
-- so a regex tweak (new bug species, new cloud size) only touches the
-- vocab.
local SIZES   = [[handful|cloud|small swarm|large swarm|vast swarm|plague]]
local SPECIES = [[lacewings|stick insects|mayflies|praying mantids|butterflies|ladybirds|dragonflies|damselflies|moths|grasshoppers|winged termites|termites|sandflies|mosquitoes|gnats|crickets|flying ants|ants|locusts|horseflies|cicadas|bees|wasps|hornets|elephant beetles|assassin bugs]]

local bug_size       = ""
local bug_bugs       = ""
local bug_state      = ""
local bug_started_at = nil

-- ---------------------------------------------------------------------
-- 2. Transitions + warn banner.
-- ---------------------------------------------------------------------

local function set_bug(size, bugs)
  local new_size = size or ""
  local new_bugs = bugs or ""
  local prev_size = bug_size
  local prev_bugs = bug_bugs

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
mud.trigger(string.format(
  [[^ \* You are surrounded by a (%s) of (%s)\.$]], SIZES, SPECIES),
  function(m) set_bug(m[1], m[2]) end)

-- Cast line — a single regex shaped after Quow's
-- ArcaneShield1_YNU_BUG: optional mood prefix ("Buzzing drowsily, "),
-- then "the <size> of <species> <verb-phrase> you" with an optional
-- trailing-mood suffix. Captures: [1] = size, [2] = bugs.
mud.trigger(string.format(
  [[^(?:[^,]+, )?[Tt]he (%s) of (%s) (?:flutters into a loosely-formed orbit around |forms a chaotic web of small white bodies around |starts to hover near |begins to circle |begins to circle around |begins to orbit |clusters haphazardly |begins to cluster around |begins to buzz erratically around |begins to buzz around |flutters into a chaotic formation around )you(?:| happily| slowly|, chirping gently|, buzzing hungrily)\.$]],
  SIZES, SPECIES),
  function(m) set_bug(m[1], m[2]) end)

-- Warn — cloud thinning out, still up.
mud.trigger(string.format(
  [[^Some of the (%s) around you fly off\.$]], SPECIES),
  function() warn_bug() end)
mud.trigger(string.format(
  [[^Some of the (%s) orbiting you break away and disperse\.$]], SPECIES),
  function() warn_bug() end)

-- Drop — wore off (timed out). Capture: [1] = bugs.
mud.trigger(string.format(
  [[^The (%s) surrounding you scatter in different directions and fly off\.$]], SPECIES),
  function() drop_bug("scatter") end)

-- Drop — destroyed in combat. Capture: [1] = bugs.
mud.trigger(string.format(
  [[^The last of the injured (%s) surrounding you crash to the ground\.$]], SPECIES),
  function() drop_bug("destroyed") end)

-- ---------------------------------------------------------------------
-- 4. Arcane-protection-status reset.
-- ---------------------------------------------------------------------
-- Same shared hook as tpa.lua / ccc.lua / main.lua's EFF reset.

mud.trigger([[^Arcane protection status:$]], function()
  bug_size       = ""
  bug_bugs       = ""
  bug_state      = ""
  bug_started_at = nil
end)

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
