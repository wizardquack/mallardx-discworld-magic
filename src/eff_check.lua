-- Discworld Magic — EFF / GSHG floater weight-efficiency calculator.
--
-- /eff  (wizard) and /gshg (witch) print a rated table of candidate
-- floating-shield items for your current magic.spells.defensive bonus:
-- heavier items block more but need more defensive skill. Ported from
-- tt_dw scripts/tips/floaters.tin.

local items = require("floater_items")

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

return M
