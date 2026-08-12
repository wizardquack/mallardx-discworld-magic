-- Behaviour tests for src/protection_report.lua — the report parser's
-- header handling, with focus on the SELF `Arcane protection status:`
-- resync path.
-- Run from project root: `lua tests/protection_report_test.lua`.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")

local UP      = "net.mallard.discworld.shield.up"
local CLEARED = "net.mallard.discworld.shield.cleared"

local passed = 0

-- Fresh modules per test — protection_report holds `current_target`, and
-- char_switch/shield_state hold the character + active grid.
local function setup()
  h.reset()
  package.loaded["char_switch"]       = nil
  package.loaded["shield_state"]      = nil
  package.loaded["protection_report"] = nil
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

-- Needles that uniquely identify a trigger within protection_report.
-- The two `Arcane protection for` headers differ only in their tail, so
-- the non-player one has to be matched on the NAME-pattern tail plus its
-- bare `:` — a plain `):$` also hits the EFF floater line.
local SELF_HEADER  = "Arcane protection status:"
local OTHER_HEADER = "{0,3}):$"
local OTHER_TPA    = "is surrounded by a magical impact shield"

-- ---------------------------------------------------------------------

test("self `Arcane protection status:` header emits a self shield.cleared", function()
  setup()
  require("protection_report")

  h.fire(SELF_HEADER)

  local cleared = last_emit(CLEARED)
  assert(cleared, "expected a shield.cleared emit on the self report header")
  assert(cleared.subject == "self",
    "expected subject=self, got " .. tostring(cleared.subject))
  assert(cleared.target_kind == "self",
    "expected target_kind=self, got " .. tostring(cleared.target_kind))
end)

test("self header resets current_target so later body lines don't misattribute", function()
  setup()
  require("protection_report")

  -- `mhas` reports the horse, then the user runs bare `shields`. A body
  -- line arriving after the self header must not be credited to the horse.
  h.fire(OTHER_HEADER, { "Crockpot the brown horse" })
  h.fire(SELF_HEADER)
  h.fire(OTHER_TPA)

  assert(#h.emits_for(UP) == 0,
    "expected no shield.up after the self header reset current_target")
end)

-- The regression this file exists for: a TPA that lapsed silently (no wire
-- message exists for TPA expiry) leaves a stale `up` in the persisted grid,
-- and the user's instinct is to run `shields` to resync. Before this fix the
-- header reset only cleared magic's module-local state, so consumers kept
-- painting the stale chip — and because a self shield.cleared was only
-- emitted on "You do not have any arcane or divine protection.", a report
-- that DID list other protections could never clear anything.
test("`shields` drops a stale shield that the report doesn't list", function()
  setup()
  local cs = require("char_switch")
  require("shield_state")
  require("protection_report")

  cs.apply({ name = "Quack" })
  h.dispatch(UP, { subject = "self", type = "tpa", glow = "invisible", percent = 100 })
  h.dispatch(UP, { subject = "self", type = "eff", item = "Klatchian steel tower shield" })
  assert(h.storage["shields/Quack"].tpa, "precondition: tpa should be recorded")

  -- `shields` output: header, then only the EFF line (no TPA line — it
  -- lapsed). EFF's own self trigger lives in eff.lua; simulate its event.
  h.fire(SELF_HEADER)
  h.dispatch(UP, { subject = "self", type = "eff", item = "Klatchian steel tower shield" })

  local saved = h.storage["shields/Quack"]
  assert(saved.tpa == nil, "expected the stale tpa record to be cleared by `shields`")
  assert(saved.eff and saved.eff.item == "Klatchian steel tower shield",
    "expected the eff record to survive the resync")
end)

print("---")
print(passed .. " passed")
