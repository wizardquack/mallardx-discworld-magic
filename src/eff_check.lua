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

-- Fixed column widths (numeric columns right-aligned). Item name width is
-- computed per-set from the longest name so the table stays tight.
local WEIGHT_W, BLOCK_W, BONUS_W = 8, 7, 10

local function name_width(rows)
  local w = 4  -- min: len("Item")
  for _, r in ipairs(rows) do
    if #r.name > w then w = #r.name end
  end
  return w
end

local function fmt_row(prefix, name, weight, block, bonus, namew)
  return string.format("%s%-" .. namew .. "s  %" .. WEIGHT_W .. "s  %"
    .. BLOCK_W .. "s  %" .. BONUS_W .. "s", prefix, name, weight, block, bonus)
end

local USAGE = {
  eff  = "/eff [bonus] [N%] — rate wizard shields for your defensive bonus. "
      .. "Bare number overrides the bonus; N% adds weight (e.g. /eff 350 15%).",
  gshg = "/gshg [bonus] [N%] — rate witch kitchen utensils for your defensive bonus.",
}

local function run(guild, raw)
  local a = M.parse_args(raw)
  if a.help or a.error then
    mud.note(USAGE[guild], { fg = "cyan" })
    return
  end

  local bonus = M.resolve_bonus(a.bonus)
  if not bonus then
    mud.note("I don't know your defensive bonus yet.", { fg = "yellow" })
    mud.note(
      mud.span("Pass it — e.g. ", { fg = "yellow" }),
      mud.span(guild == "gshg" and "/gshg 350" or "/eff 350",
               { fg = "yellow", underline = true, send = (guild == "gshg" and "/gshg 350" or "/eff 350") }),
      mud.span(" — or run ", { fg = "yellow" }),
      mud.span("score", { fg = "yellow", underline = true, send = "score" }),
      mud.span(" (with discworld-vitals installed).", { fg = "yellow" }))
    return
  end

  local result = M.compute(guild, bonus, a.mod)
  local namew  = name_width(result.rows)

  local head = string.format("Defensive bonus: %.0f \u{2192} optimal floater weight ~%.1f lb",
    bonus, result.optimal_weight)
  if a.mod and a.mod > 0 then
    head = head .. string.format("   [+%g%% weight mod]", a.mod)
  end
  mud.note(head, { fg = "cyan", bold = true })

  mud.note(fmt_row("  ", "Item", "Weight", "Block %", "Rec. bonus", namew),
    { fg = "white", bold = true })

  for _, r in ipairs(result.rows) do
    local prefix = r.star and "* " or "  "
    local line = fmt_row(prefix, r.name,
      string.format("%.1f lb", r.weight), r.block, tostring(r.rec_bonus), namew)
    local style = { fg = r.style.fg, bold = r.style.bold or r.star or nil }
    mud.note(line, style)
  end
end

mud.command("eff", function(m) run("eff", m.args) end, {
  description = "Rate wizard floating shields for your defensive bonus.",
  usage = USAGE.eff,
})
mud.command("gshg", function(m) run("gshg", m.args) end, {
  description = "Rate witch floating kitchen utensils for your defensive bonus.",
  usage = USAGE.gshg,
})

return M
