-- Test harness for Discworld Magic plugin modules.
--
-- The plugin modules (eff.lua, tpa.lua, …) register triggers and aliases
-- against host globals (`mud`, `events`, `settings`, `ui`) provided by
-- Mallard's Lua sandbox. This harness installs recording stubs for those
-- globals so a test can:
--
--   1. h.reset()          -- wipe recorders, reinstall stubs.
--   2. h.load("eff")      -- re-require the module against the fresh stubs.
--   3. h.fire("needle")   -- find a registered trigger whose pattern
--                            contains `needle` and invoke its callback.
--   4. assert on h.notes / h.notifies / h.sounds / h.emits.
--
-- The harness does NOT execute the trigger regexes — it dispatches
-- callbacks directly. That's fine for behaviour-matrix tests (regex
-- correctness is Mallard's responsibility), and avoids needing a PCRE
-- engine in the test runner. Tests pass synthetic capture arrays for
-- triggers that use `m[1]` etc.
--
-- Usage from a test file:
--   package.path = "./src/?.lua;./tests/?.lua;" .. package.path
--   local h = require("harness")

local M = {}

-- Run from project root: `lua tests/<file>_test.lua`
package.path = "./src/?.lua;./tests/?.lua;" .. package.path

-- Default settings (a manifest-aware mock — tests can override before load).
local DEFAULT_SETTINGS = {
  eff_drop_notify   = true,
  eff_drop_sound    = true,
  jpct_create_sound = true,
}

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

function M.reset()
  M.triggers = {}
  M.aliases  = {}
  M.styles   = {}
  M.notes    = {}
  M.notifies = {}
  M.sounds   = {}
  M.commands = {}
  M.emits    = {}
  M.event_listeners = {}
  M.settings = copy(DEFAULT_SETTINGS)

  _G.mud = {
    trigger    = function(pattern, callback) table.insert(M.triggers, { pattern = pattern, callback = callback }) end,
    alias      = function(pattern, callback) table.insert(M.aliases,  { pattern = pattern, callback = callback }) end,
    style      = function(pattern, opts)     table.insert(M.styles,   { pattern = pattern, opts = opts }) end,
    note       = function(text, style)       table.insert(M.notes,    { text = text, style = style }) end,
    play_sound = function(name, opts)        table.insert(M.sounds,   { name = name, opts = opts }) end,
    replace    = function() end,
    send       = function() end,
    command    = function(name, callback) table.insert(M.commands, { name = name, callback = callback }) end,
  }
  _G.events = {
    emit = function(name, data) table.insert(M.emits, { name = name, data = data }) end,
    on   = function(name, cb)   table.insert(M.event_listeners, { name = name, callback = cb }) end,
  }
  _G.settings = {
    get      = function(key) return M.settings[key] end,
    snapshot = function()    return copy(M.settings) end,
  }
  _G.ui = {
    notify = function(title, body, opts)
      table.insert(M.notifies, { title = title, body = body, opts = opts })
    end,
  }
end

-- (Re)load a plugin module against the current stubs. Clears the
-- `package.loaded` cache so module-local state initialises fresh on
-- each call — essential for state-machine tests.
function M.load(name)
  package.loaded[name] = nil
  return require(name)
end

-- Find the registered trigger whose pattern contains `needle` as a
-- literal substring. Errors if there is no match or more than one
-- (forces tests to pick a needle that uniquely identifies the trigger).
function M.find_trigger(needle)
  local hits = {}
  for _, t in ipairs(M.triggers) do
    if t.pattern:find(needle, 1, true) then table.insert(hits, t) end
  end
  if #hits == 0 then error("no trigger matches: " .. needle, 2) end
  if #hits > 1 then
    local pats = {}
    for _, h in ipairs(hits) do table.insert(pats, h.pattern) end
    error("ambiguous needle '" .. needle .. "' matched " .. #hits ..
          " triggers: " .. table.concat(pats, " | "), 2)
  end
  return hits[1]
end

-- Find the registered alias whose pattern contains `needle`.
function M.find_alias(needle)
  for _, a in ipairs(M.aliases) do
    if a.pattern:find(needle, 1, true) then return a end
  end
  error("no alias matches: " .. needle, 2)
end

-- Invoke the unique trigger matching `needle` with the supplied capture
-- table (defaults to empty). `captures[1]`, `captures[2]`, … are what
-- the plugin code reads as `m[1]`, `m[2]`, ….
function M.fire(needle, captures)
  local t = M.find_trigger(needle)
  t.callback(captures or {})
end

function M.fire_alias(needle)
  M.find_alias(needle).callback()
end

return M
