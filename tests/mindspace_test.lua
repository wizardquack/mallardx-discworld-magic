-- Behaviour tests for src/mindspace.lua.
-- Run from project root: `lua tests/mindspace_test.lua`.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")

local SKILLS_UPDATED = "net.mallard.discworld.skills.updated"
local MS_UPDATED     = "net.mallard.discworld.mindspace.updated"
local SPECIAL_PATH   = "magic.spells.special"

-- Spell names (sizes/types verified against spelldata.lua).
local TPA = "Transcendent Pneumatic Alleviator"  -- 25, Defensive
local EFF = "Endorphin's Floating Friend"        -- 20, Defensive
local PFG = "Pragi's Fiery Gaze"                  -- 30, Offensive
local WGS = "Wungle's Great Sucking"             -- 35, Offensive

local ms  -- the loaded module (for its debug surface)

local passed = 0
local function test(name, fn)
  h.reset()
  for _, m in ipairs({ "char_switch", "spell_tiers", "mindspace" }) do package.loaded[m] = nil end
  require("char_switch")
  ms = require("mindspace")
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
-- Simulation helpers.
-- ---------------------------------------------------------------------

local function set_char(name)
  h.fire_gmcp("char.info", { name = name })
end

local function set_special(bonus, charname)
  h.dispatch(SKILLS_UPDATED, {
    charname = charname or "Quackpaddle",
    snapshot = { bonus = { [SPECIAL_PATH] = bonus }, level = {} },
  })
end

-- Fire the (single, un-anchored) spell-name capture trigger for one name.
-- Needle just locates the trigger; the capture drives which spell it saw.
local function see_spell(name)
  h.fire(TPA, { name })
end

-- Simulate a `spells` listing over the given category then let the
-- debounced commit fire.
local function list_category(category, names)
  h.fire("You know the following", { category })
  for _, n in ipairs(names) do see_spell(n) end
  h.flush_delays()
end

local function last_note()
  return h.notes[#h.notes] and h.notes[#h.notes].text
end

local function last_emit(name)
  local l = h.emits_for(name)
  return l[#l]
end


-- ---------------------------------------------------------------------
-- 1. Total mindspace from the vitals skills snapshot.
-- ---------------------------------------------------------------------

test("special bonus + 30 = total mindspace", function()
  assert(ms.total_mindspace() == nil, "no snapshot yet → nil total")
  set_special(100)
  assert(ms.total_mindspace() == 130, "100 + 30 = 130, got " .. tostring(ms.total_mindspace()))
end)

test("skills snapshot without a special skill leaves total unknown", function()
  h.dispatch(SKILLS_UPDATED, { charname = "Q", snapshot = { bonus = { ["fighting.melee.sword"] = 200 } } })
  assert(ms.total_mindspace() == nil, "no special path → nil total")
end)

test("a changed special bonus emits a mindspace.updated", function()
  local before = #h.emits_for(MS_UPDATED)
  set_special(90)
  assert(#h.emits_for(MS_UPDATED) > before, "expected a mindspace.updated on bonus change")
  assert(last_emit(MS_UPDATED).total == 120, "total in event should be 120")
end)

-- ---------------------------------------------------------------------
-- 2. Listing capture → known set, used size, summary.
-- ---------------------------------------------------------------------

test("a full listing populates the known set and its used size", function()
  set_char("Quackpaddle")
  set_special(100)  -- total 130
  list_category("offensive", { PFG, WGS })   -- 30 + 35
  list_category("defensive", { TPA, EFF })   -- 25 + 20
  assert(ms.used_size() == 110, "30+35+25+20 = 110, got " .. tostring(ms.used_size()))
  assert(ms.metrics().known_count == 4, "expected 4 known spells")
  assert(ms.metrics().free == 20, "130 - 110 = 20 free")
end)

test("listing prints a colour-coded total-size summary", function()
  set_char("Quackpaddle")
  set_special(100)  -- total 130
  list_category("offensive", { PFG, WGS })   -- used 65
  assert(last_note():find("Total spell size: 65 / 130"), "summary text: " .. tostring(last_note()))
  assert(last_note():find("65 free"), "should report 65 free: " .. tostring(last_note()))
  assert(h.notes[#h.notes].style.fg == "green", "under budget → green")
end)

test("over-budget summary is red and flags the overflow", function()
  set_char("Quackpaddle")
  set_special(10)   -- total 40
  list_category("offensive", { PFG, WGS })   -- used 65 > 40
  assert(last_note():find("25 OVER"), "should report 25 over: " .. tostring(last_note()))
  assert(h.notes[#h.notes].style.fg == "red", "over budget → red")
end)

test("summary without a mindspace total shows used-only + clickable hint", function()
  set_char("Quackpaddle")
  list_category("offensive", { PFG })  -- 30, no special bonus known
  -- Two notes: the used-only line then the skills-refresh hint.
  assert(h.notes[#h.notes - 1].text:find("Total spell size: 30"), "used-only line")
  assert(last_note():find("skills%-refresh"), "hint line: " .. tostring(last_note()))
  -- The "/skills-refresh" mention is a clickable span that SENDS the command.
  local hint = h.notes[#h.notes]
  local sr
  for _, s in ipairs(hint.spans or {}) do
    if s.opts and s.opts.send == "/skills-refresh" then sr = s end
  end
  assert(sr, "/skills-refresh should be a clickable send span")
  assert(sr.text == "/skills-refresh", "clickable span text should be /skills-refresh")
  assert(sr.opts.underline == true, "clickable span should be underlined")
end)

-- ---------------------------------------------------------------------
-- 3. Category-scoped commit (partial listing keeps other categories).
-- ---------------------------------------------------------------------

test("a single-category listing only replaces that category", function()
  set_char("Quackpaddle")
  list_category("offensive", { PFG, WGS })   -- offensive: pfg, wgs
  list_category("defensive", { TPA })        -- defensive: tpa
  assert(ms.metrics().known_count == 3, "pfg+wgs+tpa retained, got " .. ms.metrics().known_count)
  -- Re-list offensive with a different set: defensive tpa must survive.
  list_category("offensive", { PFG })
  assert(ms.metrics().known_count == 2, "pfg + surviving tpa = 2, got " .. ms.metrics().known_count)
  assert(ms.used_size() == 30 + 25, "pfg(30) + tpa(25) = 55, got " .. ms.used_size())
end)

-- ---------------------------------------------------------------------
-- 4. Live maintenance: remember / forget / do-not-know.
-- ---------------------------------------------------------------------

test("remember adds a spell, forget removes it", function()
  set_char("Quackpaddle")
  set_special(100)
  h.fire("successfully remember", { TPA })
  assert(ms.used_size() == 25, "remembering tpa → 25")
  h.fire("successfully remember", { PFG })
  assert(ms.used_size() == 55, "+ pfg → 55")
  h.fire("You forget", { TPA })
  assert(ms.used_size() == 30, "forgetting tpa → 30")
  h.fire("do not know", { PFG })
  assert(ms.used_size() == 0, "do-not-know pfg → 0")
end)

test("remember of an unknown spell name is ignored", function()
  set_char("Quackpaddle")
  h.fire("successfully remember", { "Some Nonexistent Cantrip" })
  assert(ms.used_size() == 0, "unknown name must not change state")
end)

-- (Per-spell "(size)" inline annotation lives in src/main.lua, folded into
--  the existing tier-colour rule; see main_annotation_test.lua.)

-- ---------------------------------------------------------------------
-- 6. Persistence across a character switch.
-- ---------------------------------------------------------------------

test("known spells persist per character and hydrate on switch", function()
  set_char("Quackpaddle")
  list_category("offensive", { PFG, WGS })
  assert(ms.used_size() == 65, "Quackpaddle knows pfg+wgs")
  -- Switch to a fresh alt: its known set is empty.
  set_char("Flibbertigibbet")
  assert(ms.used_size() == 0, "new alt starts empty, got " .. ms.used_size())
  list_category("defensive", { EFF })
  assert(ms.used_size() == 20, "alt learns eff")
  -- Switch back: Quackpaddle's persisted set returns.
  set_char("Quackpaddle")
  assert(ms.used_size() == 65, "Quackpaddle's set restored, got " .. ms.used_size())
end)

-- ---------------------------------------------------------------------
-- 7. /mindspace command card.
-- ---------------------------------------------------------------------

test("/mindspace prints an available + used breakdown", function()
  set_char("Quackpaddle")
  set_special(100)   -- total 130
  list_category("offensive", { PFG, WGS })  -- used 65
  local before = #h.notes
  h.fire_command("mindspace")
  local produced = {}
  for i = before + 1, #h.notes do produced[#produced + 1] = h.notes[i].text end
  local blob = table.concat(produced, "\n")
  assert(blob:find("Mindspace"), "card header")
  assert(blob:find("Available: 130"), "available line: " .. blob)
  assert(blob:find("Used: 65 / 130"), "used line: " .. blob)
  assert(blob:find(WGS), "should list the largest spell first: " .. blob)
end)

test("/mindspace colours each spell name with its in-game tier colour", function()
  -- spell_tiers is the shared static tier map; PFG is an offensive spell,
  -- so /mindspace should colour its name red + bold (its in-game colour).
  assert(require("spell_tiers")[PFG], "PFG should be in the static tier map")
  set_char("Quackpaddle")
  list_category("offensive", { PFG })
  h.fire_command("mindspace")
  -- Find the note row whose reconstructed text carries the spell name,
  -- and assert the name span uses the recorded tier style.
  local row
  for i = #h.notes, 1, -1 do
    if h.notes[i].spans and h.notes[i].text:find(PFG, 1, true) then row = h.notes[i]; break end
  end
  assert(row, "expected a span-form note row for " .. PFG)
  local name_span
  for _, s in ipairs(row.spans) do if s.text == PFG then name_span = s end end
  assert(name_span, "row should carry the spell name as its own span")
  assert(name_span.opts and name_span.opts.fg == "red" and name_span.opts.bold == true,
    "name span should use the offensive tier style (red, bold)")
end)

test("/mindspace on a caster with no snapshot nudges to /skills-refresh", function()
  set_char("Quackpaddle")
  h.fire_command("mindspace")
  local blob = ""
  for _, n in ipairs(h.notes) do blob = blob .. n.text .. "\n" end
  assert(blob:find("skills%-refresh"), "should hint at /skills-refresh: " .. blob)
end)

print(passed .. " passed")
