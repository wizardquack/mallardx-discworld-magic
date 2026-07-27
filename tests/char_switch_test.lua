-- Behaviour tests for src/char_switch.lua and its wiring into the shield
-- modules. Run from project root: `lua tests/char_switch_test.lua`.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")

local passed = 0

-- Each test gets a fresh coordinator: clear its cache so listeners and
-- last_name don't leak across tests (the harness only clears the module
-- it loads, and modules keep char_switch cached between loads).
local function fresh_char_switch()
  package.loaded["char_switch"] = nil
  return require("char_switch")
end

local function test(name, fn)
  h.reset()
  local cs = fresh_char_switch()
  local ok, err = pcall(fn, cs)
  if ok then
    passed = passed + 1
    print("PASS: " .. name)
  else
    print("FAIL: " .. name .. " — " .. tostring(err))
    os.exit(1)
  end
end

-- ---------------------------------------------------------------------
-- 1. Pure apply() logic, via a spy listener.
-- ---------------------------------------------------------------------

test("first char.info seeds last_name without firing", function(cs)
  local fired = 0
  cs.on(function() fired = fired + 1 end)
  cs.apply({ name = "Wizard" })
  assert(fired == 0, "first frame must not fire, fired " .. fired)
end)

test("same-name frame does not fire", function(cs)
  local fired = 0
  cs.on(function() fired = fired + 1 end)
  cs.apply({ name = "Wizard" })
  cs.apply({ name = "Wizard" })
  assert(fired == 0, "same name must not fire, fired " .. fired)
end)

test("a name change fires every registered listener once", function(cs)
  local a, b = 0, 0
  cs.on(function() a = a + 1 end)
  cs.on(function() b = b + 1 end)
  cs.apply({ name = "Wizard" })   -- seed
  cs.apply({ name = "Warrior" })  -- switch
  assert(a == 1 and b == 1, "expected both listeners fired once, got " .. a .. "/" .. b)
end)

test("consecutive switches each fire", function(cs)
  local fired = 0
  cs.on(function() fired = fired + 1 end)
  cs.apply({ name = "Wizard" })
  cs.apply({ name = "Warrior" })
  cs.apply({ name = "Priest" })
  assert(fired == 2, "expected 2 fires across 2 switches, got " .. fired)
end)

test("malformed frames are ignored", function(cs)
  local fired = 0
  cs.on(function() fired = fired + 1 end)
  cs.apply(nil)
  cs.apply({})
  cs.apply({ name = "" })
  cs.apply({ name = 42 })
  assert(fired == 0, "malformed frames must not fire, fired " .. fired)
end)

test("a switch back to a prior name still fires (it is a change)", function(cs)
  local fired = 0
  cs.on(function() fired = fired + 1 end)
  cs.apply({ name = "Wizard" })
  cs.apply({ name = "Warrior" })
  cs.apply({ name = "Wizard" })   -- su back
  assert(fired == 2, "expected 2 fires, got " .. fired)
end)

-- ---------------------------------------------------------------------
-- 2. Integration: eff.lua drops its floater state on a switch.
-- ---------------------------------------------------------------------

local function last_note()
  return h.notes[#h.notes] and h.notes[#h.notes].text
end

test("su resets eff.lua's tracked floater state", function()
  -- Load eff against the fresh coordinator; it self-registers its reset.
  package.loaded["eff"] = nil
  h.load("eff")
  local cs = require("char_switch")

  h.fire("begins to float around you", { "Steelwing" })   -- floater up
  h.fire_alias("!eff")
  assert(last_note() == "[eff] item=Steelwing state=up",
    "precondition: eff up, got " .. tostring(last_note()))

  cs.apply({ name = "Wizard" })    -- seed (login)
  cs.apply({ name = "Warrior" })   -- su

  h.fire_alias("!eff")
  assert(last_note() == "[eff] no floater tracked",
    "expected eff reset after su, got " .. tostring(last_note()))
end)

print("---")
print(passed .. " passed")
