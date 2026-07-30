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

-- ---------------------------------------------------------------------
-- 2. compute(): optimal weight, tiers, star, weight-mod, multiplier.
-- ---------------------------------------------------------------------

test("compute optimal weight uses guild multiplier", function()
  local ec = h.load("eff_check")
  local r_eff  = ec.compute("eff", 375, 0)
  assert(approx(r_eff.optimal_weight, 10), "eff optimal: " .. r_eff.optimal_weight)
  local r_gshg = ec.compute("gshg", 550, 0)
  assert(approx(r_gshg.optimal_weight, 10), "gshg optimal: " .. r_gshg.optimal_weight)
end)

test("compute rec_bonus is round(weight * multiplier)", function()
  local ec = h.load("eff_check")
  local r = ec.compute("eff", 375, 0)
  -- small wooden shield: weight 2 * 37.5 = 75
  assert(r.rows[1].rec_bonus == 75, "rec_bonus: " .. r.rows[1].rec_bonus)
  -- giant turtle shell: 17.222 * 37.5 = 645.825 -> 646
  assert(r.rows[25].rec_bonus == 646, "rec_bonus: " .. r.rows[25].rec_bonus)
end)

test("compute tiers hit documented boundaries", function()
  local ec = h.load("eff_check")
  -- Choose an optimal weight of 10 (bonus 375 / 37.5) so ratio == weight/10.
  local r = ec.compute("eff", 375, 0)
  local function tier_at(weight)
    for _, row in ipairs(r.rows) do
      if approx(row.weight, weight) then return row.block end
    end
    error("no row with weight " .. weight)
  end
  -- ratio 0.95 boundary: weight 9.111 (oval bronze) ratio 0.9111 -> 99.9%+
  assert(tier_at(9.111) == "99.9%+", "9.111 tier")
  -- weight 10.111 (black iron) ratio 1.0111 -> 90%+
  assert(tier_at(10.111) == "90%+", "10.111 tier")
  -- weight 11 (three star) ratio 1.10 -> 80%+  (<=1.10 inclusive)
  assert(tier_at(11) == "80%+", "11 tier")
  -- weight 11.444 (large metal) ratio 1.1444 -> <80%
  assert(tier_at(11.444) == "<80%", "11.444 tier")
end)

test("compute tier colours match spec", function()
  local ec = h.load("eff_check")
  local r = ec.compute("eff", 375, 0)
  local function style_at(weight)
    for _, row in ipairs(r.rows) do
      if approx(row.weight, weight) then return row.style end
    end
  end
  assert(style_at(2).fg == "green" and style_at(2).bold == true, "great = green bold")
  assert(style_at(11).fg == "light red", "bad = light red")   -- ratio 1.10
  assert(style_at(11.444).fg == "red" and style_at(11.444).bold == true, "horrible = red bold")
end)

test("compute stars first Good/OK item (0.95 < ratio <= 1.05)", function()
  local ec = h.load("eff_check")
  local r = ec.compute("eff", 375, 0)  -- optimal 10
  local starred, star_count = nil, 0
  for _, row in ipairs(r.rows) do
    if row.star then starred = row.name; star_count = star_count + 1 end
  end
  assert(star_count == 1, "exactly one star, got " .. star_count)
  -- First item with ratio > 0.95: black iron shield (10.111 -> 1.0111).
  -- Everything up to oval bronze (9.111 -> 0.9111) is <=0.95 (great).
  assert(starred == "black iron shield", "starred: " .. tostring(starred))
end)

test("compute applies weight modifier before ratio", function()
  local ec = h.load("eff_check")
  local base = ec.compute("eff", 375, 0)
  local mod  = ec.compute("eff", 375, 10)   -- +10% weight
  assert(approx(mod.rows[1].weight, base.rows[1].weight * 1.1), "weight scaled")
  -- 2 * 1.1 * 37.5 = 82.5; round(82.5) with floor(x+0.5) = 83.
  assert(mod.rows[1].rec_bonus == 83, "rec_bonus with mod: " .. mod.rows[1].rec_bonus)
end)

-- ---------------------------------------------------------------------
-- 3. parse_args(): bonus vs %-weight vs help vs garbage.
-- ---------------------------------------------------------------------

test("parse_args empty -> no bonus, zero mod", function()
  local ec = h.load("eff_check")
  local a = ec.parse_args("")
  assert(a.bonus == nil and a.mod == 0 and not a.help and not a.error)
end)

test("parse_args bare number is bonus", function()
  local ec = h.load("eff_check")
  local a = ec.parse_args("350")
  assert(a.bonus == 350 and a.mod == 0)
end)

test("parse_args %-suffixed number is weight mod", function()
  local ec = h.load("eff_check")
  local a = ec.parse_args("15%")
  assert(a.bonus == nil and a.mod == 15)
end)

test("parse_args accepts both, order-independent", function()
  local ec = h.load("eff_check")
  local a = ec.parse_args("350 15%")
  local b = ec.parse_args("15% 350")
  assert(a.bonus == 350 and a.mod == 15, "a")
  assert(b.bonus == 350 and b.mod == 15, "b")
end)

test("parse_args help flag", function()
  local ec = h.load("eff_check")
  assert(ec.parse_args("help").help == true)
end)

test("parse_args garbage flags error", function()
  local ec = h.load("eff_check")
  assert(ec.parse_args("banana").error == true)
  assert(ec.parse_args("-5").error == true)   -- negative bonus rejected
end)

-- ---------------------------------------------------------------------
-- 4. Defensive-bonus cache from skills.updated + override.
-- ---------------------------------------------------------------------

local function skills_frame(defensive)
  return { snapshot = { bonus = { ["magic.spells.defensive"] = defensive } } }
end

test("bonus cached from skills.updated snapshot", function()
  local ec = h.load("eff_check")
  assert(ec.resolve_bonus(nil) == nil, "no bonus before any snapshot")
  h.dispatch("net.mallard.discworld.skills.updated", skills_frame(320))
  assert(ec.resolve_bonus(nil) == 320, "cached: " .. tostring(ec.resolve_bonus(nil)))
end)

test("override beats cached bonus", function()
  local ec = h.load("eff_check")
  h.dispatch("net.mallard.discworld.skills.updated", skills_frame(320))
  assert(ec.resolve_bonus(400) == 400)
end)

test("skills.request emitted at load", function()
  local ec = h.load("eff_check")
  assert(#h.emits_for("net.mallard.discworld.skills.request") >= 1,
    "expected a skills.request at load")
end)

test("malformed skills frame is ignored", function()
  local ec = h.load("eff_check")
  h.dispatch("net.mallard.discworld.skills.updated", { snapshot = "nope" })
  h.dispatch("net.mallard.discworld.skills.updated", nil)
  assert(ec.resolve_bonus(nil) == nil)
end)

-- ---------------------------------------------------------------------
-- 5. Command output: header, table, right-alignment, fallback, help.
-- ---------------------------------------------------------------------

local function find_note(needle)
  for _, n in ipairs(h.notes) do
    if n.text:find(needle, 1, true) then return n end
  end
end

test("/eff with no bonus prints fallback", function()
  h.load("eff_check")
  h.fire_command("eff", "")
  assert(find_note("defensive bonus"), "expected fallback mentioning defensive bonus")
  -- fallback is one message, not a 27-line table
  assert(#h.notes <= 3, "fallback should be short, got " .. #h.notes .. " notes")
end)

test("/eff help prints usage", function()
  h.load("eff_check")
  h.fire_command("eff", "help")
  assert(find_note("/eff"), "usage should mention /eff")
end)

test("/eff with cached bonus prints header + full table", function()
  h.load("eff_check")
  h.dispatch("net.mallard.discworld.skills.updated", skills_frame(375))
  h.fire_command("eff", "")
  -- header + column header + 25 rows = 27 notes
  assert(#h.notes == 27, "note count: " .. #h.notes)
  assert(h.notes[1].text:find("Defensive bonus: 375", 1, true), "header: " .. h.notes[1].text)
  assert(h.notes[1].text:find("~10.0 lb", 1, true), "optimal weight in header")
end)

test("/eff header shows weight mod when given", function()
  h.load("eff_check")
  h.fire_command("eff", "375 15%")
  assert(h.notes[1].text:find("15%", 1, true), "header should note the +15% mod")
end)

test("/eff numeric columns are right-aligned + star on recommended row", function()
  h.load("eff_check")
  h.fire_command("eff", "375")   -- override, optimal 10
  -- The starred row is black iron shield (see Task 2). Find it.
  local star = find_note("* ")
  assert(star, "expected a starred row")
  assert(star.text:find("black iron shield", 1, true), "starred: " .. star.text)
  -- Right-alignment: the weight cell ends in " lb" preceded by padding, and
  -- the shorter block label "<80%" and longer "99.9%+" share a right edge.
  local heavy = find_note("giant turtle shell")
  local light = find_note("small wooden shield")
  -- both rows have identical length (fixed-width columns)
  assert(#heavy.text == #light.text, "rows not fixed-width: "
    .. #heavy.text .. " vs " .. #light.text)
end)

test("/gshg uses utensils and witch multiplier", function()
  h.load("eff_check")
  h.fire_command("gshg", "550")   -- optimal 10
  assert(find_note("potato peeler"), "gshg should list utensils")
  assert(not find_note("giant turtle shell"), "gshg must not list shields")
end)

-- ---------------------------------------------------------------------
-- 6. I1 regression: fractional bonus override must not crash (%.0f fix).
-- ---------------------------------------------------------------------

test("/eff 350.5 (fractional override) does not crash and shows header", function()
  h.load("eff_check")
  h.fire_command("eff", "350.5")
  assert(#h.notes >= 1, "expected output notes")
  assert(h.notes[1].text:find("Defensive bonus:", 1, true),
    "first note should be header, got: " .. tostring(h.notes[1] and h.notes[1].text))
end)

-- ---------------------------------------------------------------------
-- 7. M2: mixed valid+garbage args shows usage, not a table.
-- ---------------------------------------------------------------------

test("/eff 350 banana shows usage note (parse error)", function()
  h.load("eff_check")
  h.fire_command("eff", "350 banana")
  assert(find_note("/eff"), "expected a usage note mentioning /eff")
  -- parse_args sees 'banana' -> error=true; run() returns after usage note
  assert(#h.notes <= 3, "should not print a table, got " .. #h.notes .. " notes")
end)

print("---")
print(passed .. " passed")
