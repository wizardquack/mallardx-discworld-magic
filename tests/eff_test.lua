-- Behaviour tests for src/eff.lua.
-- Run from project root: `lua tests/eff_test.lua`.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")

local passed = 0
local function test(name, fn)
  h.reset()
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

local function count_emits(event_name)
  local n = 0
  for _, e in ipairs(h.emits) do if e.name == event_name then n = n + 1 end end
  return n
end

local function last_emit(event_name)
  for i = #h.emits, 1, -1 do
    if h.emits[i].name == event_name then return h.emits[i].data end
  end
end

local function assert_alarm_fired(ctx)
  ctx = ctx or ""
  assert(#h.notes == 3,
    (ctx .. ": expected 3 banner notes, got " .. #h.notes))
  assert(h.notes[2].text == "*** Floater down! ***",
    (ctx .. ": middle banner mismatch: " .. tostring(h.notes[2].text)))
end

local function assert_alarm_silent(ctx)
  ctx = ctx or ""
  assert(#h.notes == 0,
    (ctx .. ": expected no banner notes, got " .. #h.notes))
  assert(#h.notifies == 0,
    (ctx .. ": expected no OS notifications, got " .. #h.notifies))
  assert(#h.sounds == 0,
    (ctx .. ": expected no sounds, got " .. #h.sounds))
end

-- ---------------------------------------------------------------------
-- 1. The four chain-dance / fresh-connect scenarios from the recent
--    behaviour matrix.
-- ---------------------------------------------------------------------

test("chain dance on fresh connect stays silent", function()
  -- state = "unknown", eff_item = "", eff_silent = false
  h.fire("send the chain into a counterwise orbit")
  h.fire("chain scores a direct hit")
  h.fire("clatters to the ground", { "Steelwing" })

  assert_alarm_silent("fresh-connect chain dance")
  -- The direct-hit handler emits one silent shield.down for vitals.
  assert(count_emits("net.mallard.discworld.shield.down") == 1,
    "expected exactly one shield.down emit, got " ..
    count_emits("net.mallard.discworld.shield.down"))
  assert(last_emit("net.mallard.discworld.shield.down").silent == true,
    "shield.down should be silent")
end)

test("chain dance after cast stays silent (regression: item-match leak)", function()
  h.fire("begins to float around you", { "Steelwing" })
  -- precondition: shield.up emitted, state now "up", item known
  assert(count_emits("net.mallard.discworld.shield.up") == 1)

  h.fire("send the chain into a counterwise orbit")
  h.fire("chain scores a direct hit")
  h.fire("clatters to the ground", { "Steelwing" })

  assert_alarm_silent("post-cast chain dance")
  assert(count_emits("net.mallard.discworld.shield.down") == 1)
  assert(last_emit("net.mallard.discworld.shield.down").silent == true)
end)

test("combat drop on fresh connect (carried-over EFF) fires alarm", function()
  -- state = "unknown" — the orbit-knock trigger is unconditional and
  -- fires drop_eff regardless of item.
  h.fire("knocked out of orbit")

  assert_alarm_fired("fresh-connect combat drop")
  assert(count_emits("net.mallard.discworld.shield.down") == 1)
  assert(last_emit("net.mallard.discworld.shield.down").silent == false)
end)

test("combat drop after cast fires alarm with item-named notification", function()
  h.fire("begins to float around you", { "Steelwing" })
  h.fire("knocked out of orbit")

  assert_alarm_fired("post-cast combat drop")
  assert(#h.notifies == 1, "expected 1 OS notification")
  assert(h.notifies[1].body == "Your Steelwing hit the ground.",
    "notification body should include item name; got: " ..
    tostring(h.notifies[1].body))
end)

test("wear-off (no-longer-floating) fires alarm on any state", function()
  -- Fresh connect, no cast — wear-off trigger is unconditional.
  h.fire("no longer floating around you", { "Steelwing" })

  assert_alarm_fired("fresh-connect wear-off")
end)

test("bare clatters on fresh connect fires alarm via 'unknown' fallback", function()
  -- The original bug: this used to be silently dropped.
  h.fire("clatters to the ground", { "Steelwing" })

  assert_alarm_fired("fresh-connect bare clatters")
end)

-- ---------------------------------------------------------------------
-- 2. The protection-status header gap: "" state is distinct from
--    "unknown" and must NOT fire on clatters (avoids mid-protections
--    false positives).
-- ---------------------------------------------------------------------

test("clatters after 'Arcane protection status:' (state='') does NOT fire", function()
  -- Header transitions state from "unknown" to "" (cleared, awaiting
  -- repopulation by the * X is floating around you: lines that follow).
  h.fire("Arcane protection status:")
  h.fire("clatters to the ground", { "Steelwing" })

  assert_alarm_silent("post-header bare clatters")
end)

test("clatters after status repopulates eff_item fires alarm with name", function()
  h.fire("Arcane protection status:")
  h.fire("is floating around you:", { "Steelwing" })
  h.fire("clatters to the ground", { "Steelwing" })

  assert_alarm_fired("post-status clatters")
  assert(h.notifies[1].body == "Your Steelwing hit the ground.")
end)

test("clatters of unrelated item after status with known floater is ignored", function()
  h.fire("Arcane protection status:")
  h.fire("is floating around you:", { "Steelwing" })
  h.fire("clatters to the ground", { "a tin can" })

  assert_alarm_silent("unrelated-item clatters")
end)

-- ---------------------------------------------------------------------
-- 3. Settings gates on the OS notification and sound side-effects.
-- ---------------------------------------------------------------------

test("eff_drop_notify=false suppresses OS notification but keeps banner", function()
  h.settings.eff_drop_notify = false
  h.fire("knocked out of orbit")

  assert(#h.notes == 3, "banner should still print")
  assert(#h.notifies == 0, "OS notification gated off")
end)

test("eff_drop_sound=true triggers play_sound with mallard chime", function()
  h.settings.eff_drop_sound = true
  h.fire("knocked out of orbit")

  assert(#h.sounds == 1, "expected one sound; got " .. #h.sounds)
  assert(h.sounds[1].name == "mallard:ding-ding-low",
    "sound name mismatch: " .. tostring(h.sounds[1].name))
end)

test("eff_drop_sound=false suppresses sound", function()
  h.settings.eff_drop_sound = false
  h.fire("knocked out of orbit")

  assert(#h.sounds == 0, "sound should be gated off")
end)

-- ---------------------------------------------------------------------
-- 4. !eff debug alias.
-- ---------------------------------------------------------------------

test("!eff on fresh connect reports state=unknown", function()
  h.fire_alias("!eff")

  assert(#h.notes == 1)
  assert(h.notes[1].text == "[eff] item= state=unknown",
    "unexpected !eff output: " .. tostring(h.notes[1].text))
end)

test("!eff after cast reports item + up state", function()
  h.fire("begins to float around you", { "Steelwing" })
  -- Clear note recorder so we only see the alias's output.
  h.notes = {}
  h.fire_alias("!eff")

  assert(#h.notes == 1)
  assert(h.notes[1].text == "[eff] item=Steelwing state=up",
    "unexpected !eff output: " .. tostring(h.notes[1].text))
end)

test("!eff after protections header reports no-floater-tracked", function()
  h.fire("Arcane protection status:")
  h.notes = {}
  h.fire_alias("!eff")

  assert(#h.notes == 1)
  assert(h.notes[1].text == "[eff] no floater tracked",
    "unexpected !eff output: " .. tostring(h.notes[1].text))
end)

-- ---------------------------------------------------------------------
-- 5. Cross-plugin event payload shape (consumed by discworld-vitals /
--    discworld-grouping — schema drift here breaks downstream).
-- ---------------------------------------------------------------------

test("set_eff emits shield.up with subject=self, type=eff, item", function()
  h.fire("begins to float around you", { "Steelwing" })

  local up = last_emit("net.mallard.discworld.shield.up")
  assert(up.subject == "self", "subject: " .. tostring(up.subject))
  assert(up.type    == "eff",  "type: "    .. tostring(up.type))
  assert(up.item    == "Steelwing", "item: " .. tostring(up.item))
end)

test("drop_eff emits shield.down with subject=self, type=eff, silent=false", function()
  h.fire("knocked out of orbit")

  local down = last_emit("net.mallard.discworld.shield.down")
  assert(down.subject == "self",  "subject: " .. tostring(down.subject))
  assert(down.type    == "eff",   "type: "    .. tostring(down.type))
  assert(down.silent  == false,   "silent: "  .. tostring(down.silent))
end)

print("---")
print(passed .. " passed")
