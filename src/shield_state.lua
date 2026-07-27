-- Discworld Magic — self shield-state recorder, persistence + replay.
--
-- Magic owns shield detection, so it's the natural source of truth for
-- "what self shields are up". This module mirrors that by observing
-- magic's OWN shield.up / shield.down / shield.cleared event stream
-- (subject == "self" only — the same slice discworld-vitals paints),
-- persists it per character under this plugin's storage, and REPLAYS it
-- to consumers whenever the current character is (re)established:
--
--   * on `su` / alt switch — clear, then re-emit an up per shield that
--     was active for the character you switched TO,
--   * on relog / plugin reload — same, restoring the last-known grid.
--
-- Consumers (discworld-vitals' chip grid, discworld-grouping's self row,
-- future plugins) stay pure event reactors: they need no persistence of
-- their own and get restore-on-switch/relog for free. Restore is
-- verbatim — "what was up when you left shows up" — and live wire
-- detection corrects anything that lapsed while you were away, the same
-- approximation discworld-vitals uses for its XP chart.
--
-- Host storage is scoped per (plugin, world), so the "shields/<char>"
-- keys never collide with another plugin's storage.

local char_switch = require("char_switch")

local M = {}

local TYPES = { "eff", "ccc", "bug", "ms", "tpa" }
local TYPE_SET = {}
for _, t in ipairs(TYPES) do TYPE_SET[t] = true end

-- active[type] = the last shield.up payload seen for that type (verbatim,
-- so replay re-emits an identical event), or nil when down. Reflects the
-- CURRENT character.
local active    = {}
local replaying = false   -- guard: don't re-record our own replayed events

local function has_storage()
  return _G.storage and storage.get and storage.set
end

local function key(char) return "shields/" .. char end

-- Persist the current character's active set. No-op until we know who we
-- are, or while replaying (the data we'd write is what we just loaded).
local function persist()
  if replaying then return end
  local char = char_switch.current()
  if type(char) ~= "string" or char == "" or not has_storage() then return end
  local snap = {}
  for _, t in ipairs(TYPES) do
    if active[t] then snap[t] = active[t] end
  end
  storage.set(key(char), snap)
end

-- Load a character's saved set into `active` (in memory only).
local function load_char(char)
  active = {}
  if type(char) ~= "string" or char == "" or not has_storage() then return end
  local saved = storage.get(key(char))
  if type(saved) ~= "table" then return end
  for _, t in ipairs(TYPES) do
    if type(saved[t]) == "table" then active[t] = saved[t] end
  end
end

-- True when nothing is active.
local function is_empty()
  for _, t in ipairs(TYPES) do
    if active[t] then return false end
  end
  return true
end

-- Replay the in-memory `active` set to consumers: a clean-slate cleared,
-- then an up per active shield carrying its stored details.
local function replay()
  replaying = true
  events.emit("net.mallard.discworld.shield.cleared",
    { subject = "self", target_kind = "self" })
  for _, t in ipairs(TYPES) do
    if active[t] then
      events.emit("net.mallard.discworld.shield.up", active[t])
    end
  end
  replaying = false
end

-- ---------------------------------------------------------------------
-- Record magic's own self shield events into `active` + persist.
-- ---------------------------------------------------------------------

events.on("net.mallard.discworld.shield.up", function(d)
  if replaying then return end
  if type(d) ~= "table" or d.subject ~= "self" then return end
  if not TYPE_SET[d.type] then return end
  active[d.type] = d          -- store the payload verbatim for faithful replay
  persist()
end)

events.on("net.mallard.discworld.shield.down", function(d)
  if replaying then return end
  if type(d) ~= "table" or d.subject ~= "self" then return end
  if not TYPE_SET[d.type] then return end
  active[d.type] = nil
  persist()
end)

events.on("net.mallard.discworld.shield.cleared", function(d)
  if replaying then return end
  if type(d) ~= "table" or d.subject ~= "self" then return end
  active = {}
  persist()
end)

-- ---------------------------------------------------------------------
-- Restore + replay when the current character is (re)established.
-- ---------------------------------------------------------------------

-- On a switch the outgoing character's set is already persisted (we save
-- on every change), so load the incoming character and replay it. On the
-- first char.info of a session, only replay when there's actually a saved
-- grid — a fresh character with nothing saved shouldn't force consumers
-- to a blank "cleared" state (and shouldn't wipe a live detection that
-- raced ahead of char.info); leave them at their defaults and let live
-- detection populate.
char_switch.on_char(function(name, is_first)
  load_char(name)
  if is_first and is_empty() then return end
  replay()
end)

-- Load-time hydrate for a plugin reload mid-session: char_switch seeds
-- `current` from the GMCP mirror at its own load (before on_char
-- listeners exist), so the live on_char above won't fire for the
-- already-current character. Pull that seeded name now and restore it.
do
  local cur = char_switch.current()
  if type(cur) == "string" and cur ~= "" then
    load_char(cur)
    if not is_empty() then replay() end
  end
end

return M
