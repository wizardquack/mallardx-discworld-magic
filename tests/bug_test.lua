-- Behaviour tests for src/bug.lua.
-- Run from project root: `lua tests/bug_test.lua`.
--
-- Pattern correctness lives in tests/bug_regex_test.lua (the harness
-- dispatches callbacks directly and never evaluates a regex). This file
-- covers what happens once a line HAS matched: the carry-forward of an
-- attribute the line didn't mention, the upgrade path, the two distinct
-- drop causes, and the two state resets.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")

local passed = 0
local function test(name, fn)
  h.reset()
  -- bug.lua caches char_switch; clear it so listeners and last_name
  -- don't leak between tests (same dance as char_switch_test.lua).
  package.loaded["char_switch"] = nil
  local cs = require("char_switch")
  h.load("bug")
  local ok, err = pcall(fn, cs)
  if ok then
    passed = passed + 1
    print("PASS: " .. name)
  else
    print("FAIL: " .. name .. " — " .. tostring(err))
    os.exit(1)
  end
end

local UP   = "net.mallard.discworld.shield.up"
local DOWN = "net.mallard.discworld.shield.down"

local function last(event_name)
  local all = h.emits_for(event_name)
  return all[#all]
end

local function count(event_name)
  return #h.emits_for(event_name)
end

-- Needles that uniquely identify each registered trigger.
local CAST    = "about|near"              -- the generic up line
local UPGRADE = "hasty retreat"
local REPORT  = "surrounded by a"
local WARN    = "fly off"
local SCATTER = "scatter"
local CRASH   = "crash"
local RESET   = "Arcane protection status"

-- ---------------------------------------------------------------------
-- 1. Recording a shield.
-- ---------------------------------------------------------------------

test("cast line records size and species", function()
  h.fire(CAST, { "plague", "assassin bugs" })
  local up = last(UP)
  assert(up, "expected a shield.up emit")
  assert(up.subject == "self" and up.type == "bug",
    "wrong subject/type: " .. tostring(up.subject) .. "/" .. tostring(up.type))
  assert(up.size == "plague", "size: " .. tostring(up.size))
  assert(up.bugs == "assassin bugs", "bugs: " .. tostring(up.bugs))
  assert(up.previous_size == "" and up.previous_bugs == "",
    "first cast should report empty previous_*")
end)

test("report line records the shield", function()
  h.fire(REPORT, { "small swarm", "sandflies" })
  local up = last(UP)
  assert(up and up.size == "small swarm" and up.bugs == "sandflies",
    "report line did not record: " .. tostring(up and up.size))
end)

-- ---------------------------------------------------------------------
-- 2. Carry-forward — the fix for lines that omit an attribute.
-- ---------------------------------------------------------------------

test("a line without a size keeps the last known size", function()
  h.fire(CAST, { "plague", "assassin bugs" })
  -- "The gnats begin to circle you slowly." — no size on the wire.
  h.fire(CAST, { "", "gnats" })
  local up = last(UP)
  assert(up.size == "plague",
    "size should carry forward, got: " .. tostring(up.size))
  assert(up.bugs == "gnats", "bugs: " .. tostring(up.bugs))
  assert(up.previous_bugs == "assassin bugs",
    "previous_bugs: " .. tostring(up.previous_bugs))
end)

test("upgrade line takes the new species and keeps the size", function()
  h.fire(CAST, { "plague", "gnats" })
  -- "The gnats make a hasty retreat and the assassin bugs gather around
  -- you victoriously." — captures the INCOMING swarm, carries no size.
  h.fire(UPGRADE, { "", "assassin bugs" })
  local up = last(UP)
  assert(up.bugs == "assassin bugs",
    "upgrade must record the incoming species, got: " .. tostring(up.bugs))
  assert(up.size == "plague",
    "upgrade must keep the known size, got: " .. tostring(up.size))
  assert(up.previous_bugs == "gnats",
    "previous_bugs: " .. tostring(up.previous_bugs))
end)

-- ---------------------------------------------------------------------
-- 3. The two drop causes.
-- ---------------------------------------------------------------------

test("scatter drops the shield with cause=scatter", function()
  h.fire(CAST, { "plague", "assassin bugs" })
  h.fire(SCATTER)
  local down = last(DOWN)
  assert(down, "expected a shield.down emit")
  assert(down.cause == "scatter", "cause: " .. tostring(down.cause))
  assert(down.silent == false, "a wire-observed drop is not silent")
  assert(down.previous_size == "plague" and down.previous_bugs == "assassin bugs",
    "previous_* should carry the last known cloud")
  assert(h.notes[2] and h.notes[2].text == "*** Bugshield gone! ***",
    "banner: " .. tostring(h.notes[2] and h.notes[2].text))
end)

test("crash drops the shield with cause=destroyed", function()
  h.fire(CAST, { "plague", "assassin bugs" })
  h.fire(CRASH)
  local down = last(DOWN)
  assert(down.cause == "destroyed", "cause: " .. tostring(down.cause))
  assert(h.notes[2] and h.notes[2].text == "*** Bugshield destroyed! ***",
    "banner: " .. tostring(h.notes[2] and h.notes[2].text))
  assert(h.notes[2].style and h.notes[2].style.fg == "red",
    "destroyed banner should be red")
  assert(#h.notifies == 1 and h.notifies[1].title == "Bugshield destroyed!",
    "expected one OS notification for a destroyed shield")
end)

-- ---------------------------------------------------------------------
-- 4. Warn is cosmetic — the shield is still up.
-- ---------------------------------------------------------------------

test("warn banners without changing state", function()
  h.fire(CAST, { "plague", "assassin bugs" })
  local ups_before = count(UP)
  h.fire(WARN)
  assert(count(DOWN) == 0, "warn must not drop the shield")
  assert(count(UP) == ups_before, "warn must not re-emit shield.up")
  assert(h.notes[1].text == "*** Bugshield warning! ***",
    "banner: " .. tostring(h.notes[1].text))
end)

-- ---------------------------------------------------------------------
-- 5. Resets.
-- ---------------------------------------------------------------------

test("arcane protection status clears tracked state", function()
  h.fire(CAST, { "plague", "assassin bugs" })
  h.fire(RESET)
  h.fire_alias("!bug")
  local note = h.notes[#h.notes]
  assert(note.text == "[bug] no shield tracked",
    "expected cleared state, got: " .. tostring(note.text))
end)

test("a character switch drops the previous character's cloud", function(cs)
  h.fire(CAST, { "plague", "assassin bugs" })
  cs.apply({ name = "Wizard" })   -- first frame only seeds
  cs.apply({ name = "Alt" })      -- the actual switch
  h.fire_alias("!bug")
  local note = h.notes[#h.notes]
  assert(note.text == "[bug] no shield tracked",
    "expected cleared state after su, got: " .. tostring(note.text))
end)

-- ---------------------------------------------------------------------
-- 6. bug_others.lua — the up-line pattern attaches the player name in
--    one of two alternative branches, so exactly one of the two name
--    groups is populated and the other arrives as "".
-- ---------------------------------------------------------------------

local function test_others(name, fn)
  h.reset()
  package.loaded["char_switch"] = nil
  h.load("bug_others")
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS: " .. name)
  else
    print("FAIL: " .. name .. " — " .. tostring(err))
    os.exit(1)
  end
end

test_others("other-player name read from the positional branch", function()
  -- "... begins to buzz around Brodfist happily." — name in group 3.
  h.fire(CAST, { "plague", "bees", "Brodfist", "" })
  local up = last(UP)
  assert(up and up.subject == "Brodfist",
    "subject: " .. tostring(up and up.subject))
  assert(up.size == "plague" and up.bugs == "bees", "payload mismatch")
end)

test_others("other-player name read from the circle/orbit branch", function()
  -- "... begins to circle Brodfist slowly." — name in group 4.
  h.fire(CAST, { "cloud", "gnats", "", "Brodfist" })
  local up = last(UP)
  assert(up and up.subject == "Brodfist",
    "subject: " .. tostring(up and up.subject))
end)

test_others("other-player shield drops on scatter", function()
  h.fire(CAST, { "cloud", "gnats", "Brodfist", "" })
  h.fire(SCATTER, { "gnats", "Brodfist" })
  local down = last(DOWN)
  assert(down and down.subject == "Brodfist" and down.cause == "scatter",
    "down: " .. tostring(down and down.subject) .. "/" .. tostring(down and down.cause))
  assert(down.previous_bugs == "gnats", "previous_bugs: " .. tostring(down.previous_bugs))
end)

print(string.format("\n%d tests passed.", passed))
