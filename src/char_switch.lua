-- Discworld Magic — character identity + switch detection.
--
-- Magic is the source of truth for self shield state, so it owns the
-- single char.info subscription and drives everything keyed on "who am I
-- right now". Two kinds of consumer register here:
--
--   on(fn)       — fires ONLY on a true switch (`su`, alt relog): the
--                  current character changed from a previously-known one.
--                  The shield modules (eff/ccc/bug/ms/tpa) use this to
--                  drop the previous character's stale self-shield
--                  detection state — the same reset they run on the
--                  `Arcane protection status:` header. Called fn(new, old).
--
--   on_char(fn)  — fires whenever the current character is (re)established:
--                  the first char.info of a session, each switch, and once
--                  at load if the GMCP mirror already knows us (plugin
--                  reload mid-session). shield_state.lua uses this to
--                  restore + replay that character's persisted shields to
--                  consumers. Called fn(name, is_first) where is_first is
--                  true when there was no previously-known character.
--
--   current()    — the current character name, or nil.
--
-- Fires on an actual name *change* only; a repeated same-name frame is a
-- no-op. Emits nothing to consumers itself — see shield_state.lua for the
-- restore/replay that rides on top of on_char.

local M = {}

local switch_listeners = {}
local char_listeners   = {}
local current          = nil

-- Register a switch-only reset (shield modules). fn(new_name, old_name).
function M.on(fn)
  if type(fn) == "function" then switch_listeners[#switch_listeners + 1] = fn end
end

-- Register a login-or-switch hook (recorder). fn(name, is_first).
function M.on_char(fn)
  if type(fn) == "function" then char_listeners[#char_listeners + 1] = fn end
end

-- Current character name (nil until the first char.info / mirror seed).
function M.current() return current end

-- Fire char-established hooks (guarded so one erroring can't block the rest).
local function fire_char(name, is_first)
  for _, fn in ipairs(char_listeners) do pcall(fn, name, is_first) end
end

-- Apply a char.info frame. Exposed for tests; the gmcp subscription below
-- forwards to it.
function M.apply(data)
  if type(data) ~= "table" then return end
  local name = data.name
  if type(name) ~= "string" or name == "" then return end
  if name == current then return end
  local old      = current
  local is_first = (old == nil)
  current = name
  if not is_first then
    for _, fn in ipairs(switch_listeners) do pcall(fn, name, old) end
  end
  fire_char(name, is_first)
end

-- Live subscription. Guarded so the module still loads under the unit-test
-- harness, which stubs mud/events/settings/ui but not gmcp.
if _G.gmcp and gmcp.on then
  gmcp.on("char.info", function(_pkg, data) M.apply(data) end)
  -- Seed from the mirror so a plugin reload mid-session knows who we are
  -- without waiting for the next (possibly never) char.info bump. We set
  -- `current` directly rather than routing through apply(): there was no
  -- switch, so the shield modules must NOT reset — but on_char consumers
  -- registered later can still pull the seeded name via current() and do a
  -- reload-time restore. See shield_state.lua's load-time hydrate.
  if gmcp.get then
    local seed = gmcp.get("char.info.name")
    if type(seed) == "string" and seed ~= "" then current = seed end
  end
end

return M
