-- /spell — Discworld spell info command.
--
-- Ported from tt_dw's `/spell` (~/code/3p/tt_dw/scripts/magic/spellinfo.tin).
-- The original supports lookups by nickname, name fragment, description
-- fragment, tome, or skill/method (the last → TM probability list, which
-- needs the player's skill levels). v1 here keeps the lookup paths and
-- drops the TM/spellcheck path — that requires tracking skills from the
-- server, out of scope for this command alone.
--
-- Usage at runtime:
--   /spell           → multi-column list of nicknames grouped by type
--   /spell help      → usage banner
--   /spell <nick>    → full info card for that spell
--   /spell <text>    → fuzzy match across nick / name / description.
--                       Exactly one match → full card. Many → summary list.
--                       None → error.
--
-- Type → colour tier mirrors main.lua's spell-name highlighting so the
-- /spell output is visually consistent with the colour treatment applied
-- to spell names appearing in the regular MUD stream.
--   Offensive     → red, bold
--   Defensive     → green
--   Miscellaneous → cyan

local spells = require("spelldata")

-- Type → mud.note style. Used for both inline spell-name colouring inside
-- the info card and for the per-type headers in the list view.
local TYPE_STYLE = {
  Offensive     = { fg = "red",   bold = true },
  Defensive     = { fg = "green" },
  Miscellaneous = { fg = "cyan"  },
}

local function style_for(spell_type)
  return TYPE_STYLE[spell_type] or { fg = "white" }
end

-- ---------------------------------------------------------------------
-- Lookup helpers
-- ---------------------------------------------------------------------

-- Stable sort order: by full name. Built once at module load.
local SORTED_NICKS = {}
for nick in pairs(spells) do
  table.insert(SORTED_NICKS, nick)
end
table.sort(SORTED_NICKS, function(a, b)
  return spells[a].name < spells[b].name
end)

local function lower(s) return string.lower(s or "") end

-- Substring match across nick, name, and description. Case-insensitive.
local function fuzzy_matches(query)
  local q = lower(query)
  local hits = {}
  for _, nick in ipairs(SORTED_NICKS) do
    local s = spells[nick]
    if lower(s.nick):find(q, 1, true)
      or lower(s.name):find(q, 1, true)
      or lower(s.description or ""):find(q, 1, true)
    then
      table.insert(hits, nick)
    end
  end
  return hits
end

-- ---------------------------------------------------------------------
-- Output formatting
-- ---------------------------------------------------------------------
--
-- Mallard's `mud.note` styles the whole line at once (no inline span
-- API in v1), so the card uses per-line colour tiers instead of mixing
-- colours within a line:
--
--   - Spell-name header   → type-tier (red / green / cyan) + bold +
--                           underline (acts as the visual divider between
--                           the title and the body of the card)
--   - Description         → type-tier + italic
--   - Stat / label lines  → light green (the "field-name" colour in
--                           tt_dw's /spellinfo output; reads as a band
--                           of metadata against the white wire text)
--   - Tome                → yellow
--   - Spellcheck header   → light green + bold
--   - Spellcheck columns  → bold header row, cyan body rows
--
-- TM / probability columns (Chance, Bonus, Level, Hint) from tt_dw are
-- intentionally omitted — they require the player's skill levels.

local LABEL_STYLE = { fg = "light green" }
local TOME_STYLE  = { fg = "yellow" }
local SC_HEADER_STYLE = { fg = "light green", bold = true }
local SC_COL_STYLE    = { fg = "white", bold = true }
local SC_ROW_STYLE    = { fg = "cyan" }

-- Build the spellcheck table from the parsed rows. Each row in
-- `s.spellcheck` is { stage, skill, nums = { 10 strings } }. tt_dw
-- groups the ten thresholds visually as Fail (1-4) / Maybe (5-8) /
-- Success (9-10), separating bands with extra space.
local function render_spellcheck(rows)
  if not rows or #rows == 0 then return end

  -- Compute column widths. Skill column hugs the widest skill name.
  -- Number columns are uniform width sized to the widest threshold so
  -- the bands line up across stages.
  local skill_w, num_w = #"Skill", 4
  for _, r in ipairs(rows) do
    if #r.skill > skill_w then skill_w = #r.skill end
    for _, n in ipairs(r.nums) do
      if #n > num_w then num_w = #n end
    end
  end

  local function num_cell(n) return string.format("%" .. num_w .. "s", n or "") end
  local function band(start_i, end_i, nums)
    local parts = {}
    for i = start_i, end_i do
      table.insert(parts, num_cell(nums[i]))
    end
    return table.concat(parts, " ")
  end

  -- Group widths for header band labels (Fail / Maybe / Success).
  local fail_w    = 4 * num_w + 3   -- 4 cells, 3 gaps
  local maybe_w   = 4 * num_w + 3
  local success_w = 2 * num_w + 1

  mud.note("  Spellcheck:", SC_HEADER_STYLE)

  -- Header row: "Skill   Fail   Maybe   Success" — band labels are
  -- aligned to the first *digit* of each band's first cell, not its
  -- left edge. Each number cell is right-justified within `num_w`, so
  -- the first cell of a band like " 170" has a leading pad space; we
  -- prepend a matching space to each band label so "Fail" lines up
  -- over "170" rather than over the pad space.
  local header = string.format(
    "    %-" .. skill_w .. "s   %-" .. fail_w .. "s  %-" .. maybe_w .. "s  %-" .. success_w .. "s",
    "Skill", "Fail", "Maybe", "Success")
  mud.note(header, SC_COL_STYLE)

  for _, r in ipairs(rows) do
    local row = string.format(
      "    %-" .. skill_w .. "s  %s  %s  %s",
      r.skill,
      band(1, 4,  r.nums),
      band(5, 8,  r.nums),
      band(9, 10, r.nums))
    mud.note(row, SC_ROW_STYLE)
  end
end

-- Print one full info card. Per-line colour tiers compensate for the
-- lack of inline span styling in mud.note.
local function show_card(s)
  -- Header: NAME (nick)  — bold + underlined + type-coloured. The
  -- underline acts as the visual rule between the spell title and the
  -- rest of the card; we copy the base type-tier style so the bold
  -- flag from `style_for()` carries through.
  local header_style = { underline = true }
  for k, v in pairs(style_for(s.type)) do header_style[k] = v end
  mud.note(s.name .. " (" .. s.nick .. ")", header_style)
  -- Description: same tier as the header but italicised so it reads as
  -- subtitle rather than a duplicate header.
  if s.description and s.description ~= "" then
    local desc_style = {}
    for k, v in pairs(style_for(s.type)) do desc_style[k] = v end
    desc_style.bold = nil
    desc_style.italic = true
    mud.note("  " .. s.description, desc_style)
  end
  -- Stats line: Type / Gp / Size on one line. tt_dw shows these as
  -- separate "field: value" pairs in two colours; we collapse to a
  -- single light-green metadata line.
  mud.note(string.format("  Type: %s   Gp: %s   Size: %s",
    s.type or "?", s.gp or "?", s.size or "?"), LABEL_STYLE)
  if s.components and s.components ~= "" then
    mud.note("  Components: " .. s.components, LABEL_STYLE)
  end
  if s.octogram == "yes" then
    mud.note("  Requires: an octogram", LABEL_STYLE)
  end
  if s.tome and s.tome ~= "" then
    -- Tome gets its own colour because tt_dw renders it as a clickable
    -- linkified element; underlined yellow is the closest static
    -- approximation.
    mud.note("  Tome: " .. s.tome, TOME_STYLE)
  end
  if s.learnt_at and s.learnt_at ~= "" then
    mud.note("  Learnt at: level " .. s.learnt_at, LABEL_STYLE)
  end
  if s.notes and s.notes ~= "" then
    mud.note("  Notes: " .. s.notes, LABEL_STYLE)
  end
  render_spellcheck(s.spellcheck)
end

-- Summary line for the multi-match path. One-liner per spell, type-coloured.
local function show_summary_row(nick)
  local s = spells[nick]
  local style = style_for(s.type)
  mud.note(string.format("  %-7s %s", s.nick, s.name), style)
end

-- ---------------------------------------------------------------------
-- /spells — multi-column nickname list grouped by type
-- ---------------------------------------------------------------------
-- Widths derive from `mud.viewport().cols` (live character-column count).
-- We pick column count so each cell fits the longest nickname + padding;
-- fall back to a single column if the viewport is unusually narrow.
--
-- Type order matches tt_dw's /spells (Offensive → Defensive → Misc) so
-- the most actionable list (offensive) is closest to the player's eye.

local TYPE_ORDER = { "Offensive", "Defensive", "Miscellaneous" }

local function group_by_type()
  local groups = {}
  for _, t in ipairs(TYPE_ORDER) do groups[t] = {} end
  for _, nick in ipairs(SORTED_NICKS) do
    local s = spells[nick]
    local bucket = groups[s.type] or groups.Miscellaneous
    table.insert(bucket, nick)
  end
  return groups
end

local function widest_nick(nicks)
  local w = 0
  for _, n in ipairs(nicks) do
    if #n > w then w = #n end
  end
  return w
end

local function show_list()
  local cols = 80
  if type(mud.viewport) == "function" then
    local vp = mud.viewport()
    if type(vp) == "table" and type(vp.cols) == "number" and vp.cols > 0 then
      cols = vp.cols
    end
  end
  -- Leave a small right margin so cells don't ever wrap on the
  -- terminal — 2 chars padding is enough for most fonts.
  local usable = math.max(20, cols - 2)

  mud.note("All spells (" .. #SORTED_NICKS .. " total):", { bold = true })

  local groups = group_by_type()
  for _, t in ipairs(TYPE_ORDER) do
    local nicks = groups[t]
    if nicks and #nicks > 0 then
      mud.note(t .. ":", style_for(t))

      local cell_w = widest_nick(nicks) + 2          -- nick + " " gutter
      local per_row = math.max(1, math.floor(usable / cell_w))
      local n = #nicks
      local rows = math.ceil(n / per_row)

      -- Column-major layout: read the first column top-to-bottom, then
      -- the next, etc. Easier to skim alphabetically than row-major.
      for r = 1, rows do
        local parts = {}
        for c = 0, per_row - 1 do
          local idx = c * rows + r
          if idx <= n then
            table.insert(parts, string.format("%-" .. cell_w .. "s", nicks[idx]))
          end
        end
        mud.note("  " .. table.concat(parts), style_for(t))
      end
    end
  end
end

-- ---------------------------------------------------------------------
-- /spell help
-- ---------------------------------------------------------------------

local function show_help()
  mud.note("Usage: /spell <nickname | name fragment | description fragment>", { bold = true })
  mud.note("       /spell           list all spells, grouped by type")
  mud.note("       /spell help      show this banner")
  mud.note("Examples:")
  mud.note("  /spell wgs           full info for Wungle's Great Sucking")
  mud.note("  /spell fire          all spells matching 'fire'")
end

-- ---------------------------------------------------------------------
-- /spell <arg> — dispatch
-- ---------------------------------------------------------------------

local function show_no_match(query)
  mud.note("No spells match " .. query .. " — try /spell for the full list.",
    { fg = "red" })
end

local function show_many_matches(query, hits)
  mud.note(string.format("%d spells match %q:", #hits, query), { bold = true })
  for _, nick in ipairs(hits) do
    show_summary_row(nick)
  end
end

local function dispatch(arg)
  if not arg or arg == "" then
    show_list()
    return
  end
  if arg == "help" then
    show_help()
    return
  end

  -- Exact-nick first. /spell wgs should never get confused by a partial
  -- name match somewhere else in the data.
  local exact = spells[lower(arg)]
  if exact then
    show_card(exact)
    return
  end

  local hits = fuzzy_matches(arg)
  if #hits == 0 then
    show_no_match(arg)
  elseif #hits == 1 then
    show_card(spells[hits[1]])
  else
    show_many_matches(arg, hits)
  end
end

-- ---------------------------------------------------------------------
-- Alias registration
-- ---------------------------------------------------------------------
-- Single pattern handles both /spell and /spell <anything>. The
-- non-capturing space-and-arg group lets the no-arg form fall through
-- to the list view.

-- The `\s+` between `/spell` and the captured argument is load-bearing:
-- it forces a word boundary so `/spells` (the natural pluralisation a
-- user might type) does NOT match this alias as `/spell` + "s". The
-- optional outer group still lets the bare `/spell` form trigger the
-- list view. Trailing whitespace is tolerated.
mud.alias([[^/spell(?:\s+(.*?))?\s*$]], function(m)
  local arg = m[1] or ""
  if arg == "" then
    dispatch(nil)
  else
    dispatch(arg)
  end
end, { name = "spell" })
