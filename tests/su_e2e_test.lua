-- End-to-end: wire → shield module → recorder → replay, across a `su`.
-- Exercises eff.lua + char_switch.lua + shield_state.lua wired together
-- through the harness's faithful event bus (emit dispatches to on()), the
-- way the host delivers a plugin's own events back to it.
-- Run from project root: `lua tests/su_e2e_test.lua`.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")

local UP      = "net.mallard.discworld.shield.up"
local CLEARED = "net.mallard.discworld.shield.cleared"

local passed = 0
local function test(name, fn)
  h.reset()
  for _, m in ipairs({ "char_switch", "shield_state", "eff" }) do
    package.loaded[m] = nil
  end
  -- Order mirrors main.lua: char_switch, then the recorder, then modules.
  require("char_switch")
  require("shield_state")
  h.load("eff")
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS: " .. name)
  else
    print("FAIL: " .. name .. " — " .. tostring(err))
    os.exit(1)
  end
end

local function last_note()
  return h.notes[#h.notes] and h.notes[#h.notes].text
end

local function last_emit(name)
  local l = h.emits_for(name)
  return l[#l]
end

test("su drops the floater, su-back restores it end-to-end", function()
  h.fire_gmcp("char.info", { name = "Wizard" })      -- login

  -- Floater goes up on the wire; eff emits shield.up, the recorder (a
  -- listener on the same bus) records + persists it under Wizard.
  h.fire("begins to float around you", { "Steelwing" })
  h.fire_alias("!eff")
  assert(last_note() == "[eff] item=Steelwing state=up",
    "precondition: eff up, got " .. tostring(last_note()))
  assert(h.storage["shields/Wizard"] and h.storage["shields/Wizard"].eff,
    "recorder should have persisted the floater under Wizard")

  -- su to Warrior: char_switch resets eff's internal state; the recorder
  -- replays Warrior's (empty) grid → a cleared, no ups.
  local ups_before = #h.emits_for(UP)
  h.fire_gmcp("char.info", { name = "Warrior" })
  h.fire_alias("!eff")
  assert(last_note() == "[eff] no floater tracked",
    "eff internal state should reset on su, got " .. tostring(last_note()))
  assert(#h.emits_for(UP) == ups_before, "switch to Warrior must not replay an up")
  assert(#h.emits_for(CLEARED) >= 1, "switch should replay a cleared")

  -- su back to Wizard: recorder replays cleared + the saved floater up.
  h.fire_gmcp("char.info", { name = "Wizard" })
  local up = last_emit(UP)
  assert(up and up.subject == "self" and up.type == "eff" and up.item == "Steelwing",
    "su-back should replay the saved eff up for Wizard")
end)

print("---")
print(passed .. " passed")
