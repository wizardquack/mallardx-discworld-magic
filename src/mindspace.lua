-- Discworld Magic — Mindspace tracking + annotations.
--
-- "Mindspace" is a wizard's / witch's total spell-memory capacity. Every
-- spell has a fixed *size* (its Mindspace cost); the sum of the sizes of
-- the spells you keep memorised may not exceed your available mindspace,
-- which is `magic.spells.special` bonus + 30. Go over and you can't learn
-- more until you forget something.
--
-- NOTE: this is unrelated to src/ms.lua, which tracks *Major Shield*
-- (divine protection). Different "ms". Mindspace lives here.
--
-- What this module does (mirrors tt_dw's spellsizes.tin + tip_mindspace):
--   1. Tracks your total available mindspace from discworld-vitals' skill
--      snapshot (special bonus + 30). Same snapshot spell.lua consumes.
--   2. Tracks the set of spells you currently know, sourced from the
--      `spells` listing and kept live by remember / forget / "do not know"
--      lines. Persisted per-character under this plugin's storage.
--   3. Annotates the `spells` output: each spell name gains a "(size)"
--      tag, and a colour-coded "Total spell size: used / total (free)"
--      summary is printed after the listing settles.
--   4. Exposes `/mindspace` (alias `/ms`... taken — `/mind`) and a
--      `!mindspace` debug alias for an on-demand breakdown.
--   5. Emits `net.mallard.discworld.mindspace.updated` on every change so
--      other plugins (vitals, grouping) can surface it.
--
-- Sources (tt_dw scripts/magic/spellsizes.tin, scripts/tips/misc.tin):
--   totalmindspace = @bonus{magic.spells.special;raw} + 30
--   totalspellsize = sum of known spell sizes
--   `^You know the following {offensive|defensive|misc} magic spell{s?}:$`
--   `^You successfully remember %1 from %*.$`
--   `^You forget %1.$`  /  `^You do not know "%1".$`

local spelldata   = require("spelldata")
local char_switch = require("char_switch")
local spell_tiers = require("spell_tiers")

local M = {}

local SPECIAL_PATH = "magic.spells.special"
local BASE_MINDSPACE = 30
-- Debounce window: the `spells` listing arrives as one burst, so we wait
-- a beat after the last spell / header line before committing + summarising.
local COMMIT_MS = 400

-- ---------------------------------------------------------------------
-- 1. Spell tables derived from spelldata.
-- ---------------------------------------------------------------------
-- name → { nick, size, type } and nick → size, plus the category-word →
-- spelldata `type` map used to scope a partial (single-category) listing.

local BY_NAME = {}          -- full spell name → { nick, size, type }
local SIZE_OF = {}          -- nick → numeric size
local TYPE_OF = {}          -- nick → spelldata `type` string

for nick, s in pairs(spelldata) do
  local size = tonumber(s.size) or 0
  SIZE_OF[nick] = size
  TYPE_OF[nick] = s.type
  if type(s.name) == "string" and s.name ~= "" then
    BY_NAME[s.name] = { nick = nick, size = size, type = s.type }
  end
end

local CATEGORY_TYPE = {
  offensive = "Offensive",
  defensive = "Defensive",
  misc      = "Miscellaneous",
}

-- ---------------------------------------------------------------------
-- 2. Module-local state.
-- ---------------------------------------------------------------------

local special_bonus   = nil   -- from vitals snapshot; nil until we hear one
local known           = {}    -- nick → true, for the CURRENT character
local loaded_char     = nil   -- character `known` was hydrated for

-- Listing-capture state (a `spells` burst in progress).
local capturing       = false
local accum           = {}    -- nick → true, spells seen this burst
local seen_categories = {}    -- spelldata `type` → true, categories in this burst
local commit_gen      = 0     -- bumps on each re-arm; stale timers no-op

-- ---------------------------------------------------------------------
-- 3. Helpers.
-- ---------------------------------------------------------------------

local function has_storage()
  return _G.storage and storage.get and storage.set
end

local function storage_key(char)
  return "mindspace/known/" .. (char or "?")
end

-- Total available mindspace, or nil if we don't have the special bonus yet.
local function total_mindspace()
  if type(special_bonus) ~= "number" then return nil end
  return special_bonus + BASE_MINDSPACE
end

-- Sum of the sizes of currently-known spells.
local function used_size(set)
  local total = 0
  for nick in pairs(set or known) do
    total = total + (SIZE_OF[nick] or 0)
  end
  return total
end

-- Snapshot of the current numbers for the update event + summary.
local function metrics()
  local used  = used_size(known)
  local total = total_mindspace()
  local count = 0
  for _ in pairs(known) do count = count + 1 end
  return {
    charname    = char_switch.current(),
    total       = total,                       -- nil if unknown
    used        = used,
    free        = total and (total - used) or nil,
    known_count = count,
  }
end

local function emit_updated()
  events.emit("net.mallard.discworld.mindspace.updated", metrics())
end

local function persist()
  if not has_storage() then return end
  local char = char_switch.current()
  if not char then return end
  loaded_char = char
  -- Persist a plain nick→true table (host storage serialises tables).
  local copy = {}
  for nick in pairs(known) do copy[nick] = true end
  storage.set(storage_key(char), copy)
end

-- Hydrate `known` for the current character from storage (idempotent per
-- character — only reloads when the character actually changed).
local function hydrate(char)
  char = char or char_switch.current()
  if char == loaded_char then return end
  known = {}
  if has_storage() and char then
    local saved = storage.get(storage_key(char))
    if type(saved) == "table" then
      for nick in pairs(saved) do
        if SIZE_OF[nick] ~= nil then known[nick] = true end
      end
    end
  end
  loaded_char = char
end

-- ---------------------------------------------------------------------
-- 4. Skills snapshot (special bonus → total mindspace).
-- ---------------------------------------------------------------------
-- Same wiring as spell.lua: cache the latest snapshot's special bonus and
-- request a replay so a plugin reload mid-session self-heals.

events.on("net.mallard.discworld.skills.updated", function(data)
  if type(data) ~= "table" or type(data.snapshot) ~= "table" then return end
  local b = data.snapshot.bonus and data.snapshot.bonus[SPECIAL_PATH]
  if type(b) == "number" then
    local changed = (b ~= special_bonus)
    special_bonus = b
    if changed then emit_updated() end
  end
end)

local function request_skills()
  -- Pass charname: vitals' `skills.request` handler keys its replay by it.
  events.emit("net.mallard.discworld.skills.request",
    { charname = char_switch.current() })
end

-- ---------------------------------------------------------------------
-- 5. Summary line + `/mindspace` card.
-- ---------------------------------------------------------------------

-- Colour for a used/total pair: green under, yellow exactly at, red over.
local function budget_fg(used, total)
  if not total then return "cyan" end
  if used > total then return "red" end
  if used == total then return "yellow" end
  return "green"
end

-- The one-line "Total spell size: X / Y (Z free)" summary, mirroring
-- tt_dw's show_spells_total. Printed after a `spells` listing settles.
local function print_summary()
  local used  = used_size(known)
  local total = total_mindspace()
  if not total then
    mud.note(string.format("Total spell size: %d", used), { fg = "cyan", bold = true })
    mud.note(
      mud.span("  (run discworld-vitals' ", { fg = "cyan" }),
      mud.span("/skills-refresh", { fg = "cyan", underline = true, send = "/skills-refresh" }),
      mud.span(" for your mindspace total)", { fg = "cyan" }))
    return
  end
  local free = total - used
  local fg   = budget_fg(used, total)
  local tail
  if free > 0 then
    tail = string.format("(%d free)", free)
  elseif free == 0 then
    tail = "(full)"
  else
    tail = string.format("(%d OVER)", -free)
  end
  mud.note(string.format("Total spell size: %d / %d  %s", used, total, tail),
    { fg = fg, bold = true })
end

-- `/mindspace` — full breakdown card.
local function mindspace_card()
  local total = total_mindspace()
  local used  = used_size(known)
  local count = 0
  for _ in pairs(known) do count = count + 1 end

  mud.note("Mindspace", { fg = "magenta", bold = true })
  if total then
    mud.note(string.format("  Available: %d  (special bonus %d + %d)",
      total, special_bonus, BASE_MINDSPACE), { fg = "cyan" })
  else
    mud.note(
      mud.span("  Available: unknown — run discworld-vitals' ", { fg = "yellow" }),
      mud.span("/skills-refresh", { fg = "yellow", underline = true, send = "/skills-refresh" }))
  end

  if count == 0 then
    mud.note("  Known spells: none tracked yet — run `spells` to populate.",
      { fg = "yellow" })
    return
  end

  local fg = budget_fg(used, total)
  if total then
    local free = total - used
    local tail = (free > 0) and string.format("%d free", free)
              or (free == 0) and "full"
              or  string.format("%d OVER", -free)
    mud.note(string.format("  Used: %d / %d  (%s)  across %d spell%s",
      used, total, tail, count, count == 1 and "" or "s"), { fg = fg, bold = true })
  else
    mud.note(string.format("  Used: %d  across %d spell%s",
      used, count, count == 1 and "" or "s"), { fg = fg })
  end

  -- List known spells, largest first, so the mindspace hogs are obvious.
  local rows = {}
  for nick in pairs(known) do
    rows[#rows + 1] = { nick = nick, size = SIZE_OF[nick] or 0,
                        name = (spelldata[nick] and spelldata[nick].name) or nick }
  end
  table.sort(rows, function(a, b)
    if a.size ~= b.size then return a.size > b.size end
    return a.name < b.name
  end)
  for _, r in ipairs(rows) do
    -- Colour the spell NAME with its in-game tier colour (from main.lua's
    -- highlight registry); size + nick stay a muted cyan. Falls back to
    -- cyan if the tier isn't known (e.g. main.lua not loaded).
    local name_style = spell_tiers[r.name] or { fg = "cyan" }
    mud.note(
      mud.span(string.format("    %3d  ", r.size), { fg = "cyan" }),
      mud.span(r.name, name_style),
      mud.span(string.format(" (%s)", r.nick), { fg = "cyan" }))
  end
end

-- ---------------------------------------------------------------------
-- 6. Listing capture (the `spells` burst).
-- ---------------------------------------------------------------------

-- Commit the accumulated burst into `known`. A listing may be full (all
-- three categories) or partial (`spells offensive`), so we only replace
-- the categories we actually saw: drop known spells whose type was listed,
-- then union in everything we accumulated.
local function commit_listing()
  capturing = false
  hydrate()  -- ensure `known` is for the current character before mutating
  for nick in pairs(known) do
    if seen_categories[TYPE_OF[nick]] then known[nick] = nil end
  end
  for nick in pairs(accum) do known[nick] = true end
  accum = {}
  seen_categories = {}
  persist()
  print_summary()
  emit_updated()
end

-- (Re)arm the debounced commit. Each header / spell line during the burst
-- pushes the commit out COMMIT_MS; when it finally fires we summarise.
local function arm_commit()
  commit_gen = commit_gen + 1
  local my = commit_gen
  if _G.mud and mud.delay then
    mud.delay(COMMIT_MS, function()
      if my == commit_gen then commit_listing() end
    end)
  else
    -- No timer available (only a host older than mud.delay). Committing
    -- inline here would fire on the *header*, before any spell line, and
    -- wipe the just-listed category. Degrade to inert instead — the known
    -- set then stays driven purely by remember / forget lines.
    capturing = false
    accum = {}
    seen_categories = {}
  end
end

-- Category header. Starts a burst (fresh accum) on the first header, and
-- records which category this is so a partial listing scopes correctly.
mud.trigger([[^You know the following (offensive|defensive|misc) magic spells?:$]],
  function(m)
    if not capturing then
      accum = {}
      seen_categories = {}
      capturing = true
    end
    local ty = CATEGORY_TYPE[m[1]]
    if ty then seen_categories[ty] = true end
    arm_commit()
  end)

-- Escape Rust-regex metacharacters. Spell names contain apostrophes and
-- spaces (literal in regex), but be defensive about the rest.
local function rx_escape(s)
  return (s:gsub("([%(%)%[%]%{%}%.%*%+%-%?%^%$%|\\])", "\\%1"))
end

-- Spell-name capture. One UN-anchored trigger over an alternation of every
-- spell name (longest first so a name that prefixes another wins the
-- leftmost-alternative race). Un-anchored so the engine's `captures_iter`
-- finds *every* spell on a multi-column listing line, not just the last.
-- Only counts while a listing burst is active; incidental mentions
-- elsewhere are ignored.
local function build_name_alternation()
  local names = {}
  for name in pairs(BY_NAME) do names[#names + 1] = name end
  table.sort(names, function(a, b)
    if #a ~= #b then return #a > #b end
    return a < b
  end)
  local escaped = {}
  for _, name in ipairs(names) do
    escaped[#escaped + 1] = rx_escape(name)
  end
  return "(" .. table.concat(escaped, "|") .. ")"
end

mud.trigger(build_name_alternation(), function(m)
  if not capturing then return end
  local hit = BY_NAME[m[1]]
  if hit then
    accum[hit.nick] = true
    arm_commit()
  end
end)

-- ---------------------------------------------------------------------
-- 7. Live known-set maintenance (remember / forget / do-not-know).
-- ---------------------------------------------------------------------

local function add_spell(name)
  local hit = BY_NAME[name]
  if not hit then return end
  hydrate()
  if not known[hit.nick] then
    known[hit.nick] = true
    persist()
    emit_updated()
  end
end

local function remove_spell(name)
  local hit = BY_NAME[name]
  if not hit then return end
  hydrate()
  if known[hit.nick] then
    known[hit.nick] = nil
    persist()
    emit_updated()
  end
end

mud.trigger([[^You successfully remember (.+) from .+\.$]], function(m) add_spell(m[1]) end)
mud.trigger([[^You forget (.+)\.$]],                        function(m) remove_spell(m[1]) end)
mud.trigger([[^You do not know "(.+)"\.$]],                 function(m) remove_spell(m[1]) end)

-- ---------------------------------------------------------------------
-- 8. Per-spell size annotations — see src/main.lua.
-- ---------------------------------------------------------------------
-- The inline "(size)" tag after each spell name is NOT registered here.
-- main.lua already recolours every spell name by tier via a capture=1
-- rule; the size is folded into THAT same rewrite so the two don't target
-- the same byte range (overlapping byte mods conflict — the engine keeps
-- one and drops the other). This module owns the tracking + summary +
-- `/mindspace`; main.lua owns the per-name colour+size rendering.

-- ---------------------------------------------------------------------
-- 9. Character switch / establish.
-- ---------------------------------------------------------------------
-- Re-hydrate the known set for the new character and re-request skills so
-- the total reflects who we are now.

char_switch.on(function(_new, _old)
  special_bonus = nil          -- previous char's bonus is meaningless now
  loaded_char   = nil          -- force a re-hydrate under the new name
  hydrate()
  request_skills()
  emit_updated()
end)

char_switch.on_char(function(_name, _is_first)
  hydrate()
  request_skills()
end)

-- ---------------------------------------------------------------------
-- 10. Commands.
-- ---------------------------------------------------------------------

mud.command("mindspace", function(_m)
  request_skills()   -- pull a fresh total in case vitals updated
  mindspace_card()
end, {
  description = "Show your mindspace budget: available capacity, used spell-size, and per-spell breakdown.",
  usage = "mindspace — show your mindspace usage and known-spell breakdown.",
  aliases = "mind",
})

mud.alias([[^!mindspace$]], function()
  local mt = metrics()
  mud.note(string.format(
    "[mindspace] char=%s special=%s total=%s used=%d free=%s known=%d capturing=%s",
    tostring(mt.charname),
    special_bonus and tostring(special_bonus) or "?",
    mt.total and tostring(mt.total) or "?",
    mt.used,
    mt.free and tostring(mt.free) or "?",
    mt.known_count,
    tostring(capturing)))
end)

-- ---------------------------------------------------------------------
-- 11. Load-time hydrate.
-- ---------------------------------------------------------------------

hydrate()
request_skills()

-- Test/debug surface.
M.total_mindspace = total_mindspace
M.used_size       = function() return used_size(known) end
M.metrics         = metrics
M._commit_listing = commit_listing   -- exposed so tests can flush without a real timer

return M
