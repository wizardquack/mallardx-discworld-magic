-- Discworld Magic — EFF / GSHG floater weight-efficiency calculator.
--
-- /eff  (wizard) and /gshg (witch) print a rated table of candidate
-- floating-shield items for your current magic.spells.defensive bonus:
-- heavier items block more but need more defensive skill. Ported from
-- tt_dw scripts/tips/floaters.tin.

local items       = require("floater_items")
local char_switch = require("char_switch")

local DEFENSIVE_PATH = "magic.spells.defensive"

local M = {}

-- Guild config: multiplier + which baked item list to rate.
local GUILDS = {
  eff  = { multiplier = 37.5, items = items.shields  },
  gshg = { multiplier = 55.0, items = items.utensils },
}

-- Ratio tiers, ascending ceilings — first whose `max` the ratio is <= wins.
local TIERS = {
  { max = 0.95, block = "99.9%+", style = { fg = "green",     bold = true } },
  { max = 0.99, block = "98%+",   style = { fg = "green" } },
  { max = 1.05, block = "90%+",   style = { fg = "yellow" } },
  { max = 1.10, block = "80%+",   style = { fg = "light red" } },
  { max = math.huge, block = "<80%", style = { fg = "red", bold = true } },
}

local function tier_for(ratio)
  for _, t in ipairs(TIERS) do
    if ratio <= t.max then return t end
  end
  return TIERS[#TIERS]
end

local function round(x) return math.floor(x + 0.5) end

-- Rate every candidate item for a guild at a given bonus and weight-mod %.
-- Items are pre-sorted ascending by weight, so the first Good/OK item we
-- meet (ratio in (0.95, 1.05]) is the lightest one — that gets the star.
function M.compute(guild, bonus, mod_pct)
  local cfg   = GUILDS[guild]
  local scale = 1 + (mod_pct or 0) / 100
  local optimal = bonus / cfg.multiplier
  local rows, starred = {}, false
  for _, it in ipairs(cfg.items) do
    local w     = it.weight * scale
    local ratio = w / optimal
    local t     = tier_for(ratio)
    local star  = false
    if not starred and ratio > 0.95 and ratio <= 1.05 then
      star, starred = true, true
    end
    rows[#rows + 1] = {
      name      = it.name,
      weight    = w,
      ratio     = ratio,
      block     = t.block,
      style     = t.style,
      rec_bonus = round(w * cfg.multiplier),
      star      = star,
    }
  end
  return { optimal_weight = optimal, rows = rows }
end

-- Parse raw command args. `%`-suffixed token -> weight mod; bare
-- non-negative number -> bonus override; `help` -> usage; else error.
function M.parse_args(raw)
  local out = { bonus = nil, mod = 0 }
  for tok in (raw or ""):gmatch("%S+") do
    if tok == "help" then
      out.help = true
    else
      local pct = tok:match("^(%d+%.?%d*)%%$")
      if pct then
        out.mod = tonumber(pct)
      else
        local n = tonumber(tok)
        if n and n >= 0 then
          out.bonus = n
        else
          out.error = true
        end
      end
    end
  end
  return out
end

-- Cached defensive bonus, sourced from discworld-vitals' skills snapshot —
-- the same wiring mindspace.lua uses for the special bonus. nil until we
-- hear a snapshot (or the caller passes an override).
local cached_bonus = nil

events.on("net.mallard.discworld.skills.updated", function(data)
  if type(data) ~= "table" or type(data.snapshot) ~= "table" then return end
  local b = data.snapshot.bonus and data.snapshot.bonus[DEFENSIVE_PATH]
  if type(b) == "number" then cached_bonus = b end
end)

-- An explicit override wins; otherwise use the cached snapshot value.
function M.resolve_bonus(override)
  if type(override) == "number" then return override end
  return cached_bonus
end

local function request_skills()
  events.emit("net.mallard.discworld.skills.request",
    { charname = char_switch.current() })
end

-- On a true switch (`su`) the previous character's bonus is meaningless.
char_switch.on(function()
  cached_bonus = nil
  request_skills()
end)
char_switch.on_char(function() request_skills() end)

-- Load-time pull so a mid-session plugin reload self-heals.
request_skills()

return M
