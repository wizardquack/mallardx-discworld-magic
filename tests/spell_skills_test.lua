-- Behaviour tests for /spellskill (src/spell.lua's skill-listing half).
-- Run from project root: `lua tests/spell_skills_test.lua`.
--
-- The command reads its skill levels from the discworld-vitals snapshot
-- broadcast on `net.mallard.discworld.skills.updated`, so every test that
-- wants the Chance/Need columns injects one via `set_skills` first. Tests
-- that omit it exercise the no-snapshot fallback.
--
-- Assertions run against the reconstructed `.text` of each recorded
-- mud.note — that is the line the player actually sees, column padding
-- and all, which is exactly what these tests are about.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")
local SKILL_PATHS = require("skill_paths")

local SKILLS_UPDATED = "net.mallard.discworld.skills.updated"

local passed = 0
local function test(name, fn)
  h.reset()
  package.loaded["spell"] = nil
  require("spell")
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS: " .. name)
  else
    print("FAIL: " .. name .. " — " .. tostring(err))
    os.exit(1)
  end
end

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

-- Inject a skills snapshot: { fire = { level = 128, bonus = 150 }, ... }.
local function set_skills(tbl)
  local level, bonus = {}, {}
  for short, v in pairs(tbl) do
    local path = SKILL_PATHS[short] or error("no path for skill: " .. short)
    level[path], bonus[path] = v.level, v.bonus
  end
  h.dispatch(SKILLS_UPDATED, {
    charname = "Quackpaddle",
    snapshot = { level = level, bonus = bonus },
  })
end

local function run(cmd, args)
  h.notes = {}
  h.fire_command(cmd, args)
end

-- All recorded lines as plain text.
local function lines()
  local out = {}
  for _, n in ipairs(h.notes) do out[#out + 1] = n.text end
  return out
end

-- The data rows only: indented two spaces and starting with a nick, i.e.
-- everything between the header row and the footers.
local function data_rows()
  local out, started = {}, false
  for _, text in ipairs(lines()) do
    if text:match("^  nick%s") then started = true
    elseif started then
      if text:match("^  %(") then break end   -- a footer / tip
      out[#out + 1] = text
    end
  end
  return out
end

-- Nick of each data row, in render order.
local function row_nicks()
  local out = {}
  for _, r in ipairs(data_rows()) do out[#out + 1] = r:match("^  (%S+)") end
  return out
end

local function find_row(nick)
  for _, r in ipairs(data_rows()) do
    if r:match("^  " .. nick .. "%s") then return r end
  end
  return nil
end

local function has_line(pattern)
  for _, text in ipairs(lines()) do
    if text:find(pattern, 1, true) then return text end
  end
  return nil
end

local function assert_eq(got, want, what)
  if got ~= want then
    error(string.format("%s: got %q, want %q", what or "value",
      tostring(got), tostring(want)), 2)
  end
end

local function index_of(list, value)
  for i, v in ipairs(list) do if v == value then return i end end
  return nil
end

-- ---------------------------------------------------------------------
-- Listing contents
-- ---------------------------------------------------------------------

test("lists every spell that checks the skill, one row per stage", function()
  set_skills({ fire = { level = 128, bonus = 150 } })
  run("spellskill", "fire")
  -- 16 spells check fire; `kof` checks it at two stages, so 17 rows.
  assert_eq(#data_rows(), 17, "row count")
  assert(has_line("Spells using fire (16 spells, 17 stages)"), "header counts")

  -- The multi-stage spell appears once per stage, each with its own
  -- Stage cell — that is the whole reason rows are per-stage.
  local kof = {}
  for _, r in ipairs(data_rows()) do
    if r:match("^  kof%s") then kof[#kof + 1] = r end
  end
  assert_eq(#kof, 2, "kof row count")
  assert(kof[1]:find(" 2/4 ", 1, true), "kof stage 2 of 4")
  assert(kof[2]:find(" 4/4 ", 1, true), "kof stage 4 of 4")
end)

test("a single-stage-per-spell skill omits the stage count from the header", function()
  set_skills({ staff = { level = 170, bonus = 200 } })
  run("spellskill", "staff")
  assert(has_line("Spells using staff (6 spells)"), "no stage suffix")
end)

test("uses the spelldata table key as the nick, not the alias list", function()
  set_skills({ staff = { level = 170, bonus = 200 } })
  run("spellskill", "staff")
  -- spelldata's nick field for this spell is "cmseq cms2"; the key is
  -- `cmseq`, and the key is what /spell looks up.
  assert(find_row("cmseq"), "cmseq row present")
  assert(not has_line("cmseq cms2"), "alias list not rendered")
end)

-- ---------------------------------------------------------------------
-- Chance / Max / Need columns
-- ---------------------------------------------------------------------

test("chance, max and need reflect the current bonus", function()
  set_skills({ fire = { level = 128, bonus = 150 } })
  run("spellskill", "fire")
  assert(has_line("Bonus: 150"), "bonus in header")
  assert(has_line("Level: 128"), "level in header")

  -- fnp's fire stage tops out at 160: bonus 150 passes 9 of 10 thresholds.
  local fnp = find_row("fnp")
  assert(fnp, "fnp row")
  assert(fnp:find("90%", 1, true), "fnp chance 90%: " .. fnp)
  assert(fnp:find("160", 1, true), "fnp max 160: " .. fnp)
  assert(fnp:find("+10b", 1, true), "fnp need +10b: " .. fnp)
end)

test("edge chance labels match the /spell card's wording", function()
  set_skills({ fire = { level = 1, bonus = 1 } })
  run("spellskill", "fire")
  assert(find_row("fnp"):find("<1%", 1, true), "floor label")

  h.notes = {}
  set_skills({ fire = { level = 999, bonus = 999 } })
  run("spellskill", "fire")
  local fnp = find_row("fnp")
  assert(fnp:find(">99%", 1, true), "ceiling label: " .. fnp)
  assert(fnp:find("done", 1, true), "nothing left to need: " .. fnp)
end)

-- ---------------------------------------------------------------------
-- Consumes column
-- ---------------------------------------------------------------------

test("consumes column marks only spells that cost you a component", function()
  set_skills({ fire = { level = 128, bonus = 150 } })
  run("spellskill", "fire")
  -- Each row's last cell is the Consumes value.
  local function consumes(nick) return find_row(nick):match("(%S+)$") end

  -- "a quill (consumed), a lightable torch (consumed)"
  assert_eq(consumes("aiw"), "yes", "aiw consumes")
  -- "none" — nothing needed at all.
  assert_eq(consumes("dtld"), "-", "dtld consumes")
  -- "candle, wet towel" — a reusable prop, folded in with "none" because
  -- the column asks whether a cast COSTS you something.
  assert_eq(consumes("fnp"), "-", "fnp consumes")

  set_skills({ staff = { level = 170, bonus = 200 } })
  run("spellskill", "staff")
  -- "a wooden staff" — held, not consumed.
  assert_eq(find_row("fetch"):match("(%S+)$"), "-", "fetch consumes")
end)

-- ---------------------------------------------------------------------
-- Ordering
-- ---------------------------------------------------------------------

test("default order is chance descending, then cheapest max bonus", function()
  set_skills({ fire = { level = 128, bonus = 150 } })
  run("spellskill", "fire")
  assert(has_line("Ordered by: success chance"), "order named in header")

  local nicks = row_nicks()
  -- 90% band ahead of the 80% band ahead of the 60% band.
  assert(index_of(nicks, "fnp") < index_of(nicks, "aiw"), "90% before 80%")
  assert(index_of(nicks, "aiw") < index_of(nicks, "pmg"), "80% before 60%")
  -- Within the tied 60% band, the cheaper max bonus wins: pmg 199, buu 224.
  assert(index_of(nicks, "pmg") < index_of(nicks, "buu"), "tie broken by max")
end)

test("tm mode ranks the near-coin-flip stages first", function()
  set_skills({ fire = { level = 128, bonus = 150 } })
  run("spellskill", "fire tm")
  assert(has_line("Ordered by: TM likelihood"), "order named in header")

  local nicks = row_nicks()
  -- sss2 sits at 50% — the peak of p*(1-p) — so it outranks every row
  -- the default view put above it (90% and 80% bands).
  assert_eq(nicks[1], "sss2", "top TM row")
  assert(index_of(nicks, "sss2") < index_of(nicks, "fnp"), "50% beats 90%")
  assert(index_of(nicks, "pmg") < index_of(nicks, "aiw"), "60% beats 80%")
  -- Same row set as the default view, only reordered.
  assert_eq(#data_rows(), 17, "row count unchanged")
end)

test("each mode points at the other", function()
  set_skills({ fire = { level = 128, bonus = 150 } })
  run("spellskill", "fire")
  assert(has_line("(/spellskill fire tm for TM-likelihood order)"), "tm pointer")

  run("spellskill", "fire tm")
  assert(has_line("(/spellskill fire for success-chance order)"), "cast pointer")
end)

-- ---------------------------------------------------------------------
-- No-snapshot fallback
-- ---------------------------------------------------------------------

test("without a snapshot, chance columns are dropped for a bonus ladder", function()
  run("spellskill", "fire")                       -- no set_skills call
  assert(has_line("/skills-refresh"), "refresh tip shown")
  assert(not has_line("Bonus: "), "no bonus header")
  assert(not has_line("Chance"), "no chance column")
  assert(not has_line("Need"), "no need column")
  -- Neither mode can rank by chance, so both fall back to max ascending
  -- rather than to an arbitrary order — and the mode pointer is
  -- suppressed, since it would promise a distinction that cannot exist.
  assert(not has_line("for TM-likelihood order)"), "mode pointer suppressed")

  local nicks = row_nicks()
  assert_eq(nicks[1], "fnp", "cheapest max first")
  assert_eq(nicks[#nicks], "jhsd", "priciest max last")
end)

test("a skill missing from an otherwise-present snapshot still renders", function()
  set_skills({ staff = { level = 170, bonus = 200 } })   -- no fire
  run("spellskill", "fire")
  assert_eq(#data_rows(), 17, "row count")
  assert(not has_line("Bonus: "), "no bonus for an unlisted skill")
end)

-- ---------------------------------------------------------------------
-- Argument handling
-- ---------------------------------------------------------------------

test("accepts the full dotted skill path", function()
  set_skills({ fire = { level = 128, bonus = 150 } })
  run("spellskill", "magic.methods.elemental.fire")
  assert(has_line("Spells using fire (16 spells, 17 stages)"), "resolved via path")
  assert(has_line("Bonus: 150"), "bonus still resolved")
end)

test("a real skill that no spell checks says so", function()
  run("spellskill", "brewing")
  assert(has_line("No spells use brewing."), "empty-but-valid skill")
end)

test("an unknown word suggests near misses", function()
  run("spellskill", "chan")
  assert(has_line("Unknown skill: chan"), "rejected")
  local hint = has_line("Did you mean:")
  assert(hint, "suggestions offered")
  assert(hint:find("channeling", 1, true), "channeling suggested: " .. hint)
  assert(hint:find("chanting", 1, true), "chanting suggested: " .. hint)
end)

test("an unknown word with no near miss points at help", function()
  run("spellskill", "zzzz")
  assert(has_line("Unknown skill: zzzz"), "rejected")
  assert(has_line("/spellskill help"), "help pointer")
end)

test("an unrecognised option is rejected rather than ignored", function()
  set_skills({ fire = { level = 128, bonus = 150 } })
  run("spellskill", "fire wibble")
  assert(has_line("Unknown option: wibble"), "rejected")
  assert_eq(#data_rows(), 0, "no listing rendered")
end)

test("bare and help both show the banner with the skill list", function()
  run("spellskill", "")
  assert(has_line("Usage: /spellskill <skill> [tm]"), "banner")
  assert(has_line("channeling"), "skill list included")

  run("spellskill", "help")
  assert(has_line("Usage: /spellskill <skill> [tm]"), "banner via help")
end)

-- ---------------------------------------------------------------------
-- /spell delegation
-- ---------------------------------------------------------------------

test("/spell <skill> delegates to the default skill view", function()
  set_skills({ fire = { level = 128, bonus = 150 } })
  run("spell", "fire")
  assert(has_line("Spells using fire (16 spells, 17 stages)"), "delegated")
  assert(has_line("Ordered by: success chance"), "default mode")
end)

test("delegation footers the fuzzy hits it swallowed, minus the ones it lists", function()
  set_skills({ fire = { level = 128, bonus = 150 } })
  run("spell", "fire")
  -- "fire" fuzzy-matches hb, pfg, kof and baf. The last three are fire-stage
  -- spells already in the listing, so only hb is actually shadowed.
  local footer = has_line("by name or description")
  assert(footer, "footer present")
  assert(footer:find("1 more spell matches", 1, true), "count: " .. footer)
  assert(footer:find("hb", 1, true), "hb offered: " .. footer)
  assert(not footer:find("pfg", 1, true), "listed spell not repeated: " .. footer)
end)

test("delegation omits the footer when nothing was shadowed", function()
  run("spell", "binding")
  assert(has_line("Spells using binding"), "delegated")
  assert(not has_line("by name or description"), "no footer")
end)

test("a skill in skill_paths but unused by any spell still falls through to fuzzy", function()
  -- `brewing` has a path but no spellcheck row. /spell must NOT route it to
  -- an empty skill listing — it routes on the spellcheck-derived index.
  run("spell", "brewing")
  assert(not has_line("No spells use brewing."), "not treated as a skill")
  assert(has_line("No spells match brewing"), "fell through to fuzzy")
end)

-- ---------------------------------------------------------------------
-- /spell regressions — the new branch sits in its dispatch chain
-- ---------------------------------------------------------------------

test("/spell <nick> still shows the full card", function()
  run("spell", "wgs")
  assert(has_line("Wungle's Great Sucking"), "card header")
  assert(has_line("Spellcheck:"), "spellcheck table")
  assert(not has_line("Spells using"), "not a skill listing")
end)

test("/spell with no argument still lists every spell", function()
  run("spell", "")
  assert(has_line("All spells (115 total):"), "full list")
end)

test("/spell <fragment> still fuzzy-matches", function()
  run("spell", "gaze")
  -- Three spells carry "Gaze" in their name; none of them is a skill.
  assert(has_line("spells match \"gaze\""), "fuzzy match list")
  assert(not has_line("Spells using"), "not a skill listing")
end)

print(string.format("\n%d tests passed.", passed))
