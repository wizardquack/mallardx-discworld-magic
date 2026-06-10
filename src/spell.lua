-- /spell — Discworld spell info command.
--
-- Ported from tt_dw's `/spell` (~/code/3p/tt_dw/scripts/magic/spellinfo.tin).
-- The original supports lookups by nickname, name fragment, description
-- fragment, tome, or skill/method.
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
--
-- Skill awareness:
--   discworld-vitals owns the `skills raw` parser and emits
--   `net.mallard.discworld.skills.updated` { charname, snapshot } whenever
--   a fresh snapshot lands. We subscribe to it, cache the snapshot, and at
--   load time fire `net.mallard.discworld.skills.request` so we get any
--   already-stored snapshot replayed for us. The snapshot's `level[path]`
--   and `bonus[path]` tables let us add four skill-aware columns to the
--   spellcheck table: Chance / Bonus / Level / Hint. Without a snapshot
--   we render the bare threshold grid only — the user can run
--   `/skills-refresh` (vitals' alias) to populate it.

local spells      = require("spelldata")
local SKILL_PATHS = require("skill_paths")

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
-- When a skills snapshot from discworld-vitals is available, the table
-- gains four trailing columns:
--   Chance  passed*10 % (clamped to <1% / >99%; see compute_chance)
--   Bonus   current bonus in the skill
--   Level   current level in the skill
--   Hint    bonus delta needed to reach the next tier (50% / >99%)
-- Each spellcheck row still gets a single per-line colour (whole-line
-- styling only in v1) — Chance is NOT per-tier coloured, which is the
-- one visible departure from tt_dw's coloured-percentage rendering.

local LABEL_STYLE = { fg = "light green" }
local TOME_STYLE  = { fg = "yellow" }
local SC_HEADER_STYLE = { fg = "light green", bold = true }
local SC_COL_STYLE    = { fg = "white", bold = true }
local SC_ROW_STYLE    = { fg = "cyan" }

-- ---------------------------------------------------------------------
-- Skills snapshot (from discworld-vitals)
-- ---------------------------------------------------------------------
-- We hold the latest snapshot we've been told about in `skills_snapshot`,
-- updated whenever vitals broadcasts `net.mallard.discworld.skills.updated`
-- (live after a /skills-refresh, or as a replay in response to our
-- `skills.request`).
--
-- We request the snapshot in two places:
--   1. At module load — covers the common case of vitals already having
--      data cached on disk when our plugin starts up.
--   2. Every time we render an info card (see `refresh_skills_snapshot`
--      below) — covers the case where the load-time request raced with
--      vitals' own startup, OR where the user has hot-reloaded one of
--      the two plugins and the on-load handshake didn't complete. Mallard
--      delivers events synchronously, so vitals' replay reaches us before
--      `events.emit` returns — meaning the snapshot is populated in time
--      for the very render that just asked for it.
--
-- If vitals isn't loaded at all, or doesn't have a snapshot, the request
-- is a silent no-op and we fall back to the no-skills card layout.

local skills_snapshot = nil

events.on("net.mallard.discworld.skills.updated", function(data)
  if type(data) == "table" and type(data.snapshot) == "table" then
    skills_snapshot = data.snapshot
  end
end)

local function refresh_skills_snapshot()
  events.emit("net.mallard.discworld.skills.request", {})
end

refresh_skills_snapshot()

-- For a parsed spellcheck row, look up the current (level, bonus) in
-- the cached snapshot. Returns (level, bonus) — both nil if we don't
-- have data for that skill (no snapshot, or snapshot doesn't carry
-- the skill, or skill name isn't in our short→path map).
local function skill_lookup(skill_short_name)
  if not skills_snapshot then return nil, nil end
  local path = SKILL_PATHS[skill_short_name]
  if not path then return nil, nil end
  return skills_snapshot.level and skills_snapshot.level[path],
         skills_snapshot.bonus and skills_snapshot.bonus[path]
end

-- ---------------------------------------------------------------------
-- TM probability math — mirrors tt_dw's /spellcheck (spellinfo.tin
-- §321-460). Each spellcheck row carries 10 ascending bonus thresholds;
-- we count how many your current bonus meets-or-beats, multiply by 10
-- for the chance%, then bucket the extremes for readability:
--   passed = 0       → "<1%"      ("to even try")
--   passed = 10      → ">99%"     (max)
--   1..9             → "10%".."90%" linearly
-- ---------------------------------------------------------------------

local function compute_chance(bonus, thresholds)
  -- thresholds is the 10-string list from the spellcheck row.
  local passed = 0
  for _, t in ipairs(thresholds) do
    local n = tonumber(t)
    if n and bonus >= n then passed = passed + 1 end
  end
  -- Edge labels match tt_dw's wording.
  local label
  if     passed == 0  then label = "<1%"
  elseif passed >= 10 then label = ">99%"
  else                     label = tostring(passed * 10) .. "%"
  end
  return passed, label
end

-- Hint text targets the chance% you'd reach with the suggested bonus
-- bump. Chance = passed * 10, so each threshold N corresponds to an N*10%
-- chance band. The "next milestone" we point at depends on where you are:
--   passed = 0      → delta to threshold[1]  → 10% chance
--   passed 1..4     → delta to threshold[5]  → 50% chance
--   passed 5..9     → delta to threshold[10] → >99% chance
--   passed = 10     → "max" (nothing left to chase)
-- The original tt_dw additionally translates the bonus delta to a level
-- via @level_for_bonus, which depends on the skill's stat multiplicator.
-- We don't have stat data, so we just report the bonus delta — that's
-- the proximate, true number; mapping to levels is a derived display.
--
-- Layout note: number-first phrasing (`+Nb for X%`) reads as "spend +N
-- bonus to unlock X% chance". The trailing `b` is a unit suffix that
-- disambiguates +N from being a level delta — bonus and level are right
-- next to each other in the row. We left-align the column so every
-- row's "+" lands at the same column position.
local function compute_hint(bonus, passed, thresholds)
  local target_idx, target_label
  if passed == 0 then
    target_idx, target_label = 1, "10%"
  elseif passed < 5 then
    target_idx, target_label = 5, "50%"
  elseif passed < 10 then
    target_idx, target_label = 10, ">99%"
  else
    return "max"
  end
  local need = tonumber(thresholds[target_idx])
  if not need then return "" end
  local delta = need - bonus
  if delta <= 0 then return target_label end   -- shouldn't happen given passed semantics, but cheap guard
  return string.format("+%db for %s", delta, target_label)
end

-- Build the spellcheck table from the parsed rows. Each row in
-- `s.spellcheck` is { stage, skill, nums = { 10 strings } }. tt_dw
-- groups the ten thresholds visually as Fail (1-4) / Maybe (5-8) /
-- Success (9-10), separating bands with extra space.
local function render_spellcheck(rows)
  if not rows or #rows == 0 then return end

  -- Pull the latest snapshot from vitals right before we decide what to
  -- render. See refresh_skills_snapshot's header comment for why this
  -- isn't redundant with the on-load request.
  refresh_skills_snapshot()

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

  -- Decide whether to render the skill-aware trailing columns. We need
  -- a snapshot at all, AND at least one row whose skill resolves; if
  -- only some rows resolve, the resolved ones get filled cells and the
  -- rest get blanks (so the grid stays aligned).
  local show_skills_cols = false
  if skills_snapshot then
    for _, r in ipairs(rows) do
      local _, bonus = skill_lookup(r.skill)
      if bonus then show_skills_cols = true; break end
    end
  end

  mud.note("  Spellcheck:", SC_HEADER_STYLE)

  -- Column geometry:
  --   * Inter-column gap is a uniform 2 spaces everywhere (in both the
  --     header and the data rows). This keeps the right edge of every
  --     header label aligned with the right edge of every data cell, so
  --     "Chance" / "Level" / "Bonus" line up cleanly with their values.
  --   * Band labels "Fail" and "Maybe" sit one column right of their
  --     band's left edge so they land over the first *digit* of the
  --     band's first cell (each number cell is right-justified within
  --     `num_w` and starts with a pad space). We accomplish that by
  --     prepending a literal space INSIDE the label string before
  --     passing it to `%-Ns`. The third band label is the verb form
  --     "Succeed" (mnemonic for "what bonus succeeds at this stage")
  --     and is *right*-aligned in its field instead — its "d" lands
  --     under the rightmost digit of the band's last cell, which is
  --     the maximum-success-chance bonus.
  --   * Skill-aware trailing columns use widths sized to their worst-
  --     case content. The Hint column is right-aligned across the board
  --     (header + every value) — the bonus delta varies between 2 and
  --     3 digits ("+92b for 10%" vs "+117b for 10%"), and right-aligning
  --     keeps the trailing "%" / "x" of every row landing under the "t"
  --     of "Hint". Left-aligning instead left the "%" signs ragged.
  local chance_w = 6   -- ">99%" / "<1%" / "100%" all fit; header "Chance" = 6
  local level_w  = 5   -- "Level"
  local bonus_w  = 5   -- "Bonus"

  -- Pre-compute every row's chance/level/bonus/hint strings so we can
  -- size the Hint column to the widest actual hint we'll print.
  local computed = {}
  local hint_w   = #"Hint"
  for _, r in ipairs(rows) do
    local row_view = { skill = r.skill, nums = r.nums }
    if show_skills_cols then
      local level, bonus = skill_lookup(r.skill)
      if bonus then
        local passed, chance_label = compute_chance(bonus, r.nums)
        row_view.chance  = chance_label
        row_view.level_s = level and tostring(level) or "-"
        row_view.bonus_s = tostring(bonus)
        row_view.hint    = compute_hint(bonus, passed, r.nums)
        if #row_view.hint > hint_w then hint_w = #row_view.hint end
      else
        row_view.chance, row_view.level_s, row_view.bonus_s, row_view.hint = "", "", "", ""
      end
    end
    computed[#computed + 1] = row_view
  end

  if show_skills_cols then
    -- "Hint" header is right-aligned (no `-` flag on the last %Ns) so
    -- its "t" lands at the column's right edge — sitting over the
    -- right-aligned "max" value and over the trailing "%" of the longer
    -- "+Nb for X%" hints. "Succeed" is also right-aligned (its "d"
    -- lands over the max-chance bonus); Fail / Maybe stay left-aligned
    -- with a prepended space so they land over the first digit.
    local header = string.format(
      "    %-" .. skill_w .. "s  %-" .. fail_w .. "s  %-" .. maybe_w .. "s  %" .. success_w .. "s  %" .. chance_w .. "s  %" .. level_w .. "s  %" .. bonus_w .. "s  %" .. hint_w .. "s",
      "Skill", " Fail", " Maybe", "Succeed", "Chance", "Level", "Bonus", "Hint")
    mud.note(header, SC_COL_STYLE)
  else
    local header = string.format(
      "    %-" .. skill_w .. "s  %-" .. fail_w .. "s  %-" .. maybe_w .. "s  %" .. success_w .. "s",
      "Skill", " Fail", " Maybe", "Succeed")
    mud.note(header, SC_COL_STYLE)
  end

  for _, rv in ipairs(computed) do
    if show_skills_cols then
      local row = string.format(
        "    %-" .. skill_w .. "s  %s  %s  %s  %" .. chance_w .. "s  %" .. level_w .. "s  %" .. bonus_w .. "s  %" .. hint_w .. "s",
        rv.skill,
        band(1, 4,  rv.nums),
        band(5, 8,  rv.nums),
        band(9, 10, rv.nums),
        rv.chance, rv.level_s, rv.bonus_s, rv.hint)
      mud.note(row, SC_ROW_STYLE)
    else
      local row = string.format(
        "    %-" .. skill_w .. "s  %s  %s  %s",
        rv.skill,
        band(1, 4,  rv.nums),
        band(5, 8,  rv.nums),
        band(9, 10, rv.nums))
      mud.note(row, SC_ROW_STYLE)
    end
  end

  -- Footer hint when we don't have skills data: tell the user how to
  -- get the trailing columns. Silent if vitals isn't loaded at all —
  -- the request event simply went unanswered, and an unprompted "go
  -- install vitals" plug is more noise than help.
  if not show_skills_cols then
    mud.note("  (Tip: run /skills-refresh with the discworld-vitals plugin installed to additionally see success chance / current bonus / hint columns.)",
      { italic = true })
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
