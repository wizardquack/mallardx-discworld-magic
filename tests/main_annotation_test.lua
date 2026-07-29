-- Behaviour test for src/main.lua's spell-name rendering:
--   * colour: an always-on capture=1 mud.style on the bare name.
--   * size:   a capture=1 mud.replace that appends "(N)" ONLY when the name
--             is followed by 2+ spaces or end-of-line (the columnar `spells`
--             listing) — targeting the trailing whitespace so it stays
--             disjoint from the colour restyle.
-- Run from project root: `lua tests/main_annotation_test.lua`.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")

-- main.lua require()s the whole plugin; clear every module so it loads
-- fresh against the harness stubs.
local MODULES = {
  "main", "spelldata", "spell_tiers", "skill_paths", "char_switch", "shield_state",
  "eff", "eff_others", "tpa", "tpa_others", "ccc", "ccc_others",
  "bug", "bug_others", "ms", "protection_report", "high", "spell", "mindspace",
}

local passed = 0
local function test(name, fn)
  h.reset()
  for _, m in ipairs(MODULES) do package.loaded[m] = nil end
  local okload, errload = pcall(require, "main")
  assert(okload, "main.lua failed to load: " .. tostring(errload))
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS: " .. name)
  else
    print("FAIL: " .. name .. " — " .. tostring(err))
    os.exit(1)
  end
end

local function find_style(pattern)
  for _, s in ipairs(h.styles) do if s.pattern == pattern then return s end end
end
local function find_replace(pattern)
  for _, r in ipairs(h.replaces) do if r.pattern == pattern then return r end end
end

test("defensive spell: green colour rule (everywhere) + gated size rule", function()
  local name = "Endorphin's Floating Friend"  -- defensive, size 20
  local col = find_style("(" .. name .. ")")
  assert(col, "expected a colour mud.style for " .. name)
  assert(col.opts.capture == 1 and col.opts.fg == "green", "defensive → green, capture 1")

  local sz = find_replace("(?:^| {2,})(?:" .. name .. ")( {2,}|$)")
  assert(sz, "expected a gated size mud.replace for " .. name)
  assert(sz.template == " (20)%1", "size template should be ' (20)%1', got " .. tostring(sz.template))
  assert(sz.opts.capture == 1 and sz.opts.fg == "cyan", "size targets capture 1, cyan")
  -- Column-boundary gate on BOTH sides: preceded by SOL/2+ spaces AND
  -- followed by 2+ spaces/EOL. Excludes chat ("wisps: <name>") + prose
  -- ("cast <name> on ..."); verified zero false positives on real logs.
  assert(sz.pattern:find("(?:^| {2,})", 1, true), "size rule must gate the leading boundary")
  assert(sz.pattern:find("( {2,}|$)", 1, true), "size rule must gate the trailing boundary")
end)

test("offensive spell: red + bold colour rule", function()
  local col = find_style("(Wungle's Great Sucking)")
  assert(col, "expected a colour rule for Wungle's Great Sucking")
  assert(col.opts.fg == "red" and col.opts.bold == true, "offensive → red bold")
  assert(find_replace("(?:^| {2,})(?:Wungle's Great Sucking)( {2,}|$)"), "expected its size rule")
end)

test("hyphenated name is regex-escaped in both rules", function()
  local col = find_style("(Luquayle's Longevity\\-Enhancing Ballast)")
  assert(col, "colour rule should escape the hyphen")
  local sz = find_replace("(?:^| {2,})(?:Luquayle's Longevity\\-Enhancing Ballast)( {2,}|$)")
  assert(sz and sz.template == " (35)%1", "size rule should escape the hyphen and carry size 35")
end)

print(passed .. " passed")
