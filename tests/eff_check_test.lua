-- Tests for src/floater_items.lua + src/eff_check.lua.
-- Run from project root: `lua tests/eff_check_test.lua`.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")

local passed = 0
local function test(name, fn)
  h.reset()
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS: " .. name)
  else
    print("FAIL: " .. name .. " — " .. tostring(err))
    os.exit(1)
  end
end

local function approx(a, b, eps)
  return math.abs(a - b) <= (eps or 1e-6)
end

-- ---------------------------------------------------------------------
-- 1. floater_items data shape.
-- ---------------------------------------------------------------------

test("floater_items has 25 shields and 20 utensils", function()
  local items = h.load("floater_items")
  assert(#items.shields == 25, "shields count: " .. #items.shields)
  assert(#items.utensils == 20, "utensils count: " .. #items.utensils)
end)

test("floater_items lists are ascending by weight", function()
  local items = h.load("floater_items")
  for _, list in ipairs({ items.shields, items.utensils }) do
    for i = 2, #list do
      assert(list[i].weight >= list[i - 1].weight,
        "not ascending at index " .. i)
    end
  end
end)

test("floater_items spot weights match tt_dw", function()
  local items = h.load("floater_items")
  assert(items.shields[1].name == "small wooden shield")
  assert(approx(items.shields[1].weight, 2))
  assert(items.shields[25].name == "giant turtle shell")
  assert(approx(items.shields[25].weight, 17.222))
  assert(items.utensils[1].name == "potato peeler")
  assert(approx(items.utensils[1].weight, 0.222))
  assert(items.utensils[20].name == "enormous bucket")
  assert(approx(items.utensils[20].weight, 28.444))
end)

print("---")
print(passed .. " passed")
