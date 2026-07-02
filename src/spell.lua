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
-- mud.span(text, opts) returns a styled span; mud.note(span1, span2, ...)
-- takes varargs and concatenates them into a single output line, so each
-- column / sub-region can carry its own colour. Spans reject empty text
-- and newlines — inter-column gutters MUST be at least one space.
--
-- Colour scheme (matches tt_dw's /spellinfo + /spellcheck):
--
--   - Spell name        → type-tier (red bold / green / cyan) + underline
--   - " (nick)" suffix  → type-tier, no bold/underline (title vs metadata)
--   - Description       → type-tier + italic
--   - Field labels      → light green; values in default/white
--   - Components item   → magenta; "(consumed)" parenthetical → light magenta
--   - Tome value        → yellow + underline (tt_dw renders it as a link)
--   - Band labels       → Fail red, Maybe yellow, Succeed light green +bold
--   - Threshold cells   → per-cell tier colour (see threshold_style below)
--   - Chance %          → tier-coloured by chance level
--   - Hint              → tier colour matching the current Chance
--   - Clickable nicks   → underlined; on_click drills into /spell <nick>

local PALETTE = {
  -- Tier colours for spellcheck table cells & chance %.
  --   tier_low  — failing this threshold (player's bonus is below it)
  --   tier_mid  — boundary / 50% chance
  --   tier_high — passing this threshold (player's bonus meets/exceeds it)
  tier_low  = { fg = "light red" },
  tier_mid  = { fg = "yellow" },
  tier_high = { fg = "light green" },

  -- Field-label / value scheme used across the card body.
  label     = { fg = "light green" },
  bold_label = { fg = "light green", bold = true },

  -- Spellcheck non-band column headers (Skill / Chance / Level / Bonus / Hint).
  col_header = { fg = "white", bold = true },

  -- Skill name column in spellcheck rows.
  skill_name = { fg = "cyan" },

  -- Components: split into body and parenthetical accent.
  comp_body  = { fg = "magenta" },
  comp_paren = { fg = "light magenta", bold = true },

  -- Tome: yellow + underline. tt_dw renders it as a clickable book lookup;
  -- the underline at least signals "this is the canonical name to search".
  tome      = { fg = "yellow", underline = true },

  -- "max" hint cell: green bold (you're done; nothing left to chase).
  hint_max  = { fg = "light green", bold = true },
}

-- ---------------------------------------------------------------------
-- Style helpers (skills-aware coloring)
-- ---------------------------------------------------------------------

-- chance_style(passed) → style for the Chance % cell (and the Hint cell,
-- which we colour by current chance tier to draw the eye to advancement
-- opportunities). Buckets match tt_dw's /spellcheck:
--   passed = 0      → red bold      ("<1%", can't even try meaningfully)
--   passed 1..4     → red           ("10%-40%")
--   passed 5        → yellow        ("50%" — boundary)
--   passed 6..9     → light green   ("60%-90%")
--   passed = 10     → light green bold (">99%", max)
local function chance_style(passed)
  if passed == 0     then return { fg = "light red",   bold = true } end
  if passed < 5      then return { fg = "light red"                } end
  if passed == 5     then return { fg = "yellow"                   } end
  if passed < 10     then return { fg = "light green"              } end
  return                  { fg = "light green", bold = true }
end

-- threshold_style(bonus, threshold, passed_last, position) → (style, new_passed_last)
-- Mirrors tt_dw's per-cell colouring in /spellcheck (spellinfo.tin §409-420):
--   bonus >= threshold        → tier_high (you pass this)
--   else, immediately after a pass → tier_mid (boundary marker)
--   else                      → tier_low (clearly failing)
-- When bonus is nil (no skills snapshot for this skill), fall back to the
-- per-band position tier so the table still has visual structure: Fail
-- positions red, Maybe yellow, Succeed light green.
local function threshold_style(bonus, threshold, passed_last, position)
  if bonus ~= nil then
    local t = tonumber(threshold)
    if t and bonus >= t then
      return PALETTE.tier_high, true
    elseif passed_last then
      return PALETTE.tier_mid, false
    else
      return PALETTE.tier_low, false
    end
  else
    if     position == "fail"  then return PALETTE.tier_low,  false
    elseif position == "maybe" then return PALETTE.tier_mid,  false
    else                            return PALETTE.tier_high, false
    end
  end
end

-- Tier position for a 1-based threshold index. Bands 1-4 = Fail,
-- 5-8 = Maybe, 9-10 = Succeed.
local function position_for(i)
  if i <= 4 then return "fail"
  elseif i <= 8 then return "maybe"
  else return "succeed" end
end

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
-- Success (9-10), separating bands with extra space, and colours each
-- threshold cell by whether the player's current bonus passes it.
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

  local fail_w    = 4 * num_w + 3   -- 4 cells, 3 gaps (1 char each)
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

  -- Trailing column widths (skills-aware columns).
  local chance_w = 6   -- ">99%" / "<1%" / "100%" all fit; header "Chance" = 6
  local level_w  = 5   -- "Level"
  local bonus_w  = 5   -- "Bonus"

  -- Pre-compute every row's per-cell views so we can:
  --   (a) size the Hint column to the widest actual hint
  --   (b) drive the per-threshold colouring in the row render loop
  -- row_view.passed_seq[i] = (style, _) for threshold i — built once.
  local computed = {}
  local hint_w   = #"Hint"
  for _, r in ipairs(rows) do
    local row_view = { skill = r.skill, nums = r.nums }
    local _level, bonus = nil, nil
    if show_skills_cols then
      _level, bonus = skill_lookup(r.skill)
      if bonus then
        local passed, chance_label = compute_chance(bonus, r.nums)
        row_view.passed   = passed
        row_view.chance   = chance_label
        row_view.level_s  = _level and tostring(_level) or "-"
        row_view.bonus_s  = tostring(bonus)
        row_view.hint     = compute_hint(bonus, passed, r.nums)
        if #row_view.hint > hint_w then hint_w = #row_view.hint end
      end
    end
    -- Per-threshold style sequence — built whether or not we have a
    -- bonus, because position-tier fallback still wants per-cell colour
    -- when no skills snapshot is available.
    local styles = {}
    local passed_last = false
    for i = 1, #r.nums do
      local style, new_pl = threshold_style(bonus, r.nums[i], passed_last, position_for(i))
      styles[i]    = style
      passed_last  = new_pl
    end
    row_view.cell_styles = styles
    computed[#computed + 1] = row_view
  end

  -- ---------- Spellcheck: heading ----------
  mud.note(mud.span("  Spellcheck:", PALETTE.bold_label))

  -- ---------- Header row ----------
  -- Spans are constructed per region. Band labels are tier-coloured
  -- (Fail red, Maybe yellow, Succeed green) — that gives the user an
  -- at-a-glance legend for the cell colouring below. The leading space
  -- inside " Fail" / " Maybe" lines them up over their band's first
  -- digit (each band cell is right-justified within `num_w` and starts
  -- with a pad space); "Succeed" is right-aligned in its field so its
  -- "d" lands over the max-success-chance bonus (last cell of the
  -- Success band).
  do
    local spans = {
      mud.span(string.format("    %-" .. skill_w .. "s", "Skill"), PALETTE.col_header),
      mud.span("  "),
      mud.span(string.format("%-" .. fail_w  .. "s", " Fail"),    { fg = "light red",   bold = true }),
      mud.span("  "),
      mud.span(string.format("%-" .. maybe_w .. "s", " Maybe"),   { fg = "yellow",      bold = true }),
      mud.span("  "),
      mud.span(string.format("%"  .. success_w .. "s", "Succeed"), { fg = "light green", bold = true }),
    }
    if show_skills_cols then
      table.insert(spans, mud.span("  "))
      table.insert(spans, mud.span(string.format("%" .. chance_w .. "s", "Chance"), PALETTE.col_header))
      table.insert(spans, mud.span("  "))
      table.insert(spans, mud.span(string.format("%" .. level_w  .. "s", "Level"),  PALETTE.col_header))
      table.insert(spans, mud.span("  "))
      table.insert(spans, mud.span(string.format("%" .. bonus_w  .. "s", "Bonus"),  PALETTE.col_header))
      table.insert(spans, mud.span("  "))
      table.insert(spans, mud.span(string.format("%" .. hint_w   .. "s", "Hint"),   PALETTE.col_header))
    end
    mud.note(table.unpack(spans))
  end

  -- ---------- Data rows ----------
  for _, rv in ipairs(computed) do
    local spans = {
      mud.span(string.format("    %-" .. skill_w .. "s", rv.skill), PALETTE.skill_name),
    }

    -- Bands: emit each threshold cell as its own span, separated by
    -- single-space gutters. Between bands (after cells 4 and 8) use a
    -- double-space gutter to match the band-label widths above.
    for i = 1, #rv.nums do
      local pre
      if     i == 1 then pre = "  "          -- after skill column
      elseif i == 5 or i == 9 then pre = "  "  -- between bands
      else  pre = " "                          -- within a band
      end
      table.insert(spans, mud.span(pre))
      table.insert(spans, mud.span(string.format("%" .. num_w .. "s", rv.nums[i]), rv.cell_styles[i]))
    end

    if show_skills_cols then
      if rv.chance then
        local ch_style = chance_style(rv.passed)
        table.insert(spans, mud.span("  "))
        table.insert(spans, mud.span(string.format("%" .. chance_w .. "s", rv.chance), ch_style))
        table.insert(spans, mud.span("  "))
        table.insert(spans, mud.span(string.format("%" .. level_w  .. "s", rv.level_s)))
        table.insert(spans, mud.span("  "))
        table.insert(spans, mud.span(string.format("%" .. bonus_w  .. "s", rv.bonus_s)))
        table.insert(spans, mud.span("  "))
        -- Hint shares Chance's tier colour so the eye reads "this is where
        -- the +Nb gets you". "max" gets the green-bold treatment.
        local hint_style = (rv.hint == "max") and PALETTE.hint_max or ch_style
        table.insert(spans, mud.span(string.format("%" .. hint_w .. "s", rv.hint), hint_style))
      else
        -- Skill not in the snapshot — leave the trailing cells blank so
        -- the column grid stays aligned. We emit at least one space per
        -- cell because mud.span rejects empty text.
        local blank = string.rep(" ", chance_w + level_w + bonus_w + hint_w + 8)  -- 4 inter-cell gutters
        table.insert(spans, mud.span(blank))
      end
    end
    mud.note(table.unpack(spans))
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

-- Helper: a "field: value" line where the label is light-green and the
-- value gets its own style. Single space between label and value.
local function field_line(label, value, value_style)
  mud.note(
    mud.span("  " .. label .. ": ", PALETTE.label),
    mud.span(value, value_style)
  )
end

-- Split a components string into a span list, accenting each
-- parenthetical (e.g. "(consumed)") in a brighter magenta so the eye
-- catches which items are consumed by the cast. Anything outside parens
-- is rendered in regular magenta.
--
-- Examples handled correctly:
--   "a human heart (consumed)"
--   "a quill (consumed), a lightable torch (consumed)"
--   "none"               (just one magenta span)
local function components_spans(components)
  local out = {}
  local pos = 1
  while pos <= #components do
    local open_p = components:find("%(", pos)
    if not open_p then
      table.insert(out, mud.span(components:sub(pos), PALETTE.comp_body))
      break
    end
    if open_p > pos then
      table.insert(out, mud.span(components:sub(pos, open_p - 1), PALETTE.comp_body))
    end
    local close_p = components:find("%)", open_p) or #components
    table.insert(out, mud.span(components:sub(open_p, close_p), PALETTE.comp_paren))
    pos = close_p + 1
  end
  return out
end

-- Print one full info card. Per-region styling via mud.span — each line
-- mixes a light-green label with a value coloured by what it represents.
local function show_card(s)
  local type_style = style_for(s.type)

  -- Header: spell name (type-tier + bold + underline) + " (nick)" suffix
  -- (type-tier, no bold/underline, so the nick reads as quieter metadata
  -- next to the title). Build the suffix style by copying the type tier
  -- and stripping the prominence flags.
  local name_style = {}
  for k, v in pairs(type_style) do name_style[k] = v end
  name_style.bold = true
  name_style.underline = true
  local nick_style = {}
  for k, v in pairs(type_style) do nick_style[k] = v end
  nick_style.bold = nil
  mud.note(
    mud.span(s.name, name_style),
    mud.span(" (" .. s.nick .. ")", nick_style)
  )

  -- Description in type-tier + italic. tt_dw renders the description in
  -- the same colour family as the spell name; italic differentiates it
  -- from the heading without changing colour.
  if s.description and s.description ~= "" then
    local desc_style = {}
    for k, v in pairs(type_style) do desc_style[k] = v end
    desc_style.bold = nil
    desc_style.italic = true
    mud.note(mud.span("  " .. s.description, desc_style))
  end

  -- Stats line: Type / Gp / Size — three "label: value" pairs in one
  -- visual row. Labels are light-green; values are default-coloured so
  -- they stand out against the metadata band.
  mud.note(
    mud.span("  Type: ",  PALETTE.label),
    mud.span(s.type or "?"),
    mud.span("   Gp: ",   PALETTE.label),
    mud.span(s.gp   or "?"),
    mud.span("   Size: ", PALETTE.label),
    mud.span(s.size or "?")
  )

  -- Components: label green, item body magenta, "(consumed)" parens in
  -- brighter magenta + bold. We build the value-side spans first then
  -- prepend the label span.
  if s.components and s.components ~= "" then
    local spans = { mud.span("  Components: ", PALETTE.label) }
    for _, sp in ipairs(components_spans(s.components)) do
      table.insert(spans, sp)
    end
    mud.note(table.unpack(spans))
  end

  if s.octogram == "yes" then
    field_line("Requires", "an octogram", { fg = "magenta" })
  end

  if s.tome and s.tome ~= "" then
    field_line("Tome", s.tome, PALETTE.tome)
  end

  if s.learnt_at and s.learnt_at ~= "" then
    -- "level N" — show the number in bold for quick scan.
    mud.note(
      mud.span("  Learnt at: ", PALETTE.label),
      mud.span("level ",        PALETTE.label),
      mud.span(s.learnt_at,     { bold = true })
    )
  end

  if s.notes and s.notes ~= "" then
    field_line("Notes", s.notes)
  end

  render_spellcheck(s.spellcheck)
end

-- Summary line for the multi-match path. One-liner per spell, type-coloured.
-- One-line summary in match lists. The nickname is clickable — clicking
-- it drills into the full info card (same as typing /spell <nick>). We
-- underline the nickname to signal it's interactive, but ONLY the nick
-- text itself — the trailing padding gets its own un-styled span so the
-- underline doesn't extend across empty space (and the clickable region
-- doesn't extend through it either).
local SUMMARY_NICK_W = 7
local function show_summary_row(nick)
  local s = spells[nick]
  local style = style_for(s.type)
  local click_style = {}
  for k, v in pairs(style) do click_style[k] = v end
  click_style.underline = true
  click_style.on_click = function() show_card(s) end
  local pad = SUMMARY_NICK_W - #s.nick
  local spans = {
    mud.span("  "),
    mud.span(s.nick, click_style),
  }
  if pad > 0 then
    table.insert(spans, mud.span(string.rep(" ", pad)))
  end
  table.insert(spans, mud.span(" "))
  table.insert(spans, mud.span(s.name, style))
  mud.note(table.unpack(spans))
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
      -- Each nick is wrapped in its own span with on_click so clicking
      -- the nick drills into the full info card; the underline cue is
      -- attached to the nick text ONLY, not the trailing pad — emitting
      -- the pad as a separate un-styled span keeps the link region (and
      -- the underline) tight to the actual word.
      local type_style = style_for(t)
      for r = 1, rows do
        local spans = { mud.span("  ") }
        for c = 0, per_row - 1 do
          local idx = c * rows + r
          if idx <= n then
            local nick = nicks[idx]
            local click_style = {}
            for k, v in pairs(type_style) do click_style[k] = v end
            click_style.underline = true
            click_style.on_click = function() show_card(spells[nick]) end
            table.insert(spans, mud.span(nick, click_style))
            local pad = cell_w - #nick
            if pad > 0 then
              table.insert(spans, mud.span(string.rep(" ", pad)))
            end
          end
        end
        mud.note(table.unpack(spans))
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

-- `mud.command` matches on the exact name `spell`, so the natural
-- pluralisation `/spells` no longer collides — only `/spell` (with
-- optional whitespace-delimited args) dispatches here.
mud.command("spell", function(m)
  local arg = m.args
  if arg == "" then
    dispatch(nil)
  else
    dispatch(arg)
  end
end, {
  description = "Show information about a spell: source, components, and skill requirements.",
  usage = "spell — list all known spells; spell <query> — match by name, acronym, description, or skill; spell help — usage examples.",
  -- `/sp` shortcut. Ignored by Mallard < 0.15 (unknown opts keys are silently
  -- dropped), so this stays backward-compatible without a minimum_app_version bump.
  aliases = "sp",
})
