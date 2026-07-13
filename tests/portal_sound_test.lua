-- Behaviour tests for the JPCT portal-created sound cue in src/main.lua.
-- Run from project root: `lua tests/portal_sound_test.lua`.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local h = require("harness")

local passed = 0
local function test(name, fn)
  h.reset()
  h.load("main")
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS: " .. name)
  else
    print("FAIL: " .. name .. " — " .. tostring(err))
    os.exit(1)
  end
end

test("jpct_create_sound=true plays mallard:ding-ding-high on portal solidify", function()
  h.settings.jpct_create_sound = true
  h.fire("solidifies with a satisfying thump")

  assert(#h.sounds == 1, "expected one sound; got " .. #h.sounds)
  assert(h.sounds[1].name == "mallard:ding-ding-high",
    "sound name mismatch: " .. tostring(h.sounds[1].name))
end)

test("jpct_create_sound=false suppresses the sound", function()
  h.settings.jpct_create_sound = false
  h.fire("solidifies with a satisfying thump")

  assert(#h.sounds == 0, "sound should be gated off")
end)

print(passed .. " passed")
