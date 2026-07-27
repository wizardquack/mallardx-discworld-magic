-- Behaviour tests for src/shield_state.lua — the self shield-state
-- recorder, per-character persistence, and replay-on-switch.
-- Run from project root: `lua tests/shield_state_test.lua`.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")

local UP      = "net.mallard.discworld.shield.up"
local DOWN    = "net.mallard.discworld.shield.down"
local CLEARED = "net.mallard.discworld.shield.cleared"

local passed = 0

-- Fresh char_switch + shield_state per test (both hold module-local state
-- and are cached between requires). h.reset() must run first so the
-- gmcp/storage stubs the load-time code reads are clean.
local function setup()
  h.reset()
  package.loaded["char_switch"]  = nil
  package.loaded["shield_state"] = nil
end

local function load_modules()
  local cs = require("char_switch")
  require("shield_state")
  return cs
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS: " .. name)
  else
    print("FAIL: " .. name .. " — " .. tostring(err))
    os.exit(1)
  end
end

local function last_emit(name)
  local list = h.emits_for(name)
  return list[#list]
end

-- ---------------------------------------------------------------------

test("records a self shield.up and persists it under the current char", function()
  setup()
  local cs = load_modules()
  cs.apply({ name = "Wizard" })
  h.dispatch(UP, { subject = "self", type = "eff", item = "Steelwing" })

  local saved = h.storage["shields/Wizard"]
  assert(type(saved) == "table" and saved.eff, "expected persisted eff record")
  assert(saved.eff.item == "Steelwing", "expected item Steelwing, got " .. tostring(saved.eff.item))
end)

test("ignores non-self shield events", function()
  setup()
  local cs = load_modules()
  cs.apply({ name = "Wizard" })
  h.dispatch(UP, { subject = "Brodfist", type = "eff", item = "Steelwing" })
  local saved = h.storage["shields/Wizard"]
  assert(not saved or not saved.eff, "other-player shield must not be recorded for self")
end)

test("shield.down removes a type from the persisted set", function()
  setup()
  local cs = load_modules()
  cs.apply({ name = "Wizard" })
  h.dispatch(UP,   { subject = "self", type = "eff", item = "Steelwing" })
  h.dispatch(DOWN, { subject = "self", type = "eff" })
  local saved = h.storage["shields/Wizard"]
  assert(not (saved and saved.eff), "eff should be cleared from persistence after down")
end)

test("shield.cleared wipes the persisted set", function()
  setup()
  local cs = load_modules()
  cs.apply({ name = "Wizard" })
  h.dispatch(UP,      { subject = "self", type = "eff", item = "Steelwing" })
  h.dispatch(UP,      { subject = "self", type = "tpa", glow = "bright red", percent = 60 })
  h.dispatch(CLEARED, { subject = "self", target_kind = "self" })
  local saved = h.storage["shields/Wizard"]
  assert(saved and not saved.eff and not saved.tpa, "cleared should empty the set")
end)

test("first login with nothing saved does not replay (no forced cleared)", function()
  setup()
  local cs = load_modules()
  cs.apply({ name = "Wizard" })
  assert(#h.emits == 0, "fresh login must not emit anything, got " .. #h.emits)
end)

test("first login with a saved grid replays cleared + up (relog restore)", function()
  setup()
  h.storage["shields/Wizard"] = { eff = { subject = "self", type = "eff", item = "Steelwing" } }
  local cs = load_modules()
  cs.apply({ name = "Wizard" })

  assert(#h.emits_for(CLEARED) == 1, "expected one cleared on restore")
  local up = last_emit(UP)
  assert(up and up.type == "eff" and up.item == "Steelwing" and up.subject == "self",
    "expected replayed eff up for Wizard")
end)

test("su to an unseen character replays only a cleared", function()
  setup()
  local cs = load_modules()
  cs.apply({ name = "Wizard" })                 -- login (no replay)
  h.dispatch(UP, { subject = "self", type = "eff", item = "Steelwing" })
  local before_cleared = #h.emits_for(CLEARED)
  local before_up      = #h.emits_for(UP)

  cs.apply({ name = "Warrior" })                -- switch to unseen char

  assert(#h.emits_for(CLEARED) == before_cleared + 1, "switch should emit one cleared")
  assert(#h.emits_for(UP) == before_up, "switch to unseen char must not emit an up")
end)

test("su back to a character replays its saved shields verbatim", function()
  setup()
  local cs = load_modules()
  cs.apply({ name = "Wizard" })
  h.dispatch(UP, { subject = "self", type = "eff", item = "Steelwing" })
  h.dispatch(UP, { subject = "self", type = "tpa", glow = "bright red", percent = 60 })
  cs.apply({ name = "Warrior" })                -- away
  cs.apply({ name = "Wizard" })                 -- su back

  -- The last replay (Wizard) emits one cleared then an up per active type.
  local ups = h.emits_for(UP)
  local eff, tpa
  for _, u in ipairs(ups) do
    if u.type == "eff" then eff = u elseif u.type == "tpa" then tpa = u end
  end
  assert(eff and eff.item == "Steelwing", "expected restored eff/Steelwing")
  assert(tpa and tpa.percent == 60 and tpa.glow == "bright red", "expected restored tpa 60/bright red")
end)

test("reload mid-session restores the mirror's current character", function()
  setup()
  -- Simulate a plugin reload: the GMCP mirror already knows us and a grid
  -- was persisted last session. char_switch seeds `current` from the
  -- mirror at load; shield_state's load-time hydrate must restore it.
  h.gmcp_values["char.info.name"] = "Wizard"
  h.storage["shields/Wizard"] = { bug = { subject = "self", type = "bug", size = "cloud", bugs = "bees" } }
  load_modules()   -- char_switch seeds current=Wizard, shield_state hydrates

  local up = last_emit(UP)
  assert(up and up.type == "bug" and up.bugs == "bees", "expected reload restore of bug shield")
end)

print("---")
print(passed .. " passed")
