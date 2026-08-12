-- Behaviour tests for src/protection_report.lua — the report parser's
-- header handling, with focus on the SELF `Arcane protection status:`
-- resync path.
-- Run from project root: `lua tests/protection_report_test.lua`.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")

local UP           = "net.mallard.discworld.shield.up"
local REPORT_BEGIN = "net.mallard.discworld.shield.report_begin"

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

test("self `Arcane protection status:` header announces a self report", function()
  setup()
  require("protection_report")

  h.fire(SELF_HEADER)

  local begun = last_emit(REPORT_BEGIN)
  assert(begun, "expected a shield.report_begin emit on the self report header")
  assert(begun.subject == "self",
    "expected subject=self, got " .. tostring(begun.subject))
end)

test("self header does not clear chips outright (no flash on `shields`)", function()
  setup()
  require("protection_report")

  h.fire(SELF_HEADER)

  assert(#h.emits_for("net.mallard.discworld.shield.cleared") == 0,
    "header must not emit a blanket cleared — that's what made the grid blink")
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

print("---")
print(passed .. " passed")
