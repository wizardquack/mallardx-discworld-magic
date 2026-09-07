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
-- Viewport width
-- ---------------------------------------------------------------------
-- `mud.viewport()` is absent in older hosts (and in the test harness), so
-- every caller guards on it. Centralised here because both /spells and
-- /spellskill size their columns from it.
local function viewport_cols()
  local cols = 80
  if type(mud.viewport) == "function" then
    local vp = mud.viewport()
    if type(vp) == "table" and type(vp.cols) == "number" and vp.cols > 0 then
      cols = vp.cols
    end
  end
  -- Leave a small right margin so cells never wrap on the terminal.
  return math.max(20, cols - 2)
end

-- ---------------------------------------------------------------------
-- /spellskill <skill> [tm] — every spell that uses a skill
-- ---------------------------------------------------------------------
--
-- Answers the inverse of /spell <nick>: instead of "what skills does this
-- spell check?", it asks "what spells check this skill, and how close am I
-- to each?". Ported in spirit from tt_dw's /spell_tm_list (spellinfo.tin
-- §532-655), which routes `/spell <skill>` to a TM-ordered listing.
--
-- One row PER STAGE, not per spell: a spell may check the same skill at
-- two different stages with different thresholds (e.g. `kof` checks fire
-- at stages 2 and 4; `binding` spans 45 stages across 43 spells), and the
-- stage is what you're actually being graded on. The Stage column shows
-- `2/4` — this stage out of the spell's total.
--
-- Your bonus is CONSTANT down the whole listing (it's a single skill), so
-- it lives in the header rather than eating a column. That's what frees
-- the width for Max (the bonus for >99%) and Need (the delta to it).

-- Skills that actually appear in a spellcheck row, built from spelldata at
-- load. This — NOT skill_paths.lua — is what /spell routes on, for two
-- reasons: a skill no spell uses would route to an empty listing (worse
-- than falling through to fuzzy), and adding a craft skill to skill_paths
-- must never silently shadow a fuzzy search term. /spellskill validates
-- against skill_paths instead, so it can distinguish "not a skill" from
-- "a real skill that no spell uses".
local SKILLS_IN_SPELLCHECK = {}
for _, s in pairs(spells) do
  for _, r in ipairs(s.spellcheck or {}) do
    SKILLS_IN_SPELLCHECK[r.skill] = true
  end
end

-- Full dotted path → short name, so `/spellskill magic.methods.elemental.fire`
-- works as well as `/spellskill fire`. The dotted form is what the vitals
-- snapshot and the game's own `skills` output use, so people have it to hand.
local PATH_TO_SKILL = {}
for short, path in pairs(SKILL_PATHS) do
  PATH_TO_SKILL[path] = short
end

-- Sorted skill list, for the help banner and did-you-mean suggestions.
local SORTED_SKILLS = {}
for skill in pairs(SKILLS_IN_SPELLCHECK) do
  table.insert(SORTED_SKILLS, skill)
end
table.sort(SORTED_SKILLS)

-- Does casting this spell COST you a component?
--
-- Deliberately binary, which folds "needs nothing at all" (33 spells)
-- together with "needs a reusable prop you must be holding" (18 — a staff,
-- a mirror, a shield, a potato). That matches tt_dw's `!` marker, which
-- likewise only asks whether a cast is repeatable without restocking.
--
-- The six patterns below classify every one of the 115 spells correctly
-- (64 consuming / 51 not) against spelldata's free-text components field.
-- Judgement call: `pmg`'s "a shimmering glass nugget (temporarily drained)"
-- counts as NOT consumed — you keep the nugget.
local CONSUMED_PATTERNS = {
  "consumed", "blorple", "turned into", "degrades", "transferred", "becomes",
}

local function consumes_components(s)
  local c = lower(s.components)
  if c == "" or c == "none" then return false end
  for _, p in ipairs(CONSUMED_PATTERNS) do
    if c:find(p, 1, true) then return true end
  end
  return false
end

-- Resolve a user-supplied argument to a canonical short skill name.
-- Accepts the short name ("fire") or the full dotted path. Returns nil if
-- it isn't a skill at all.
local function resolve_skill(arg)
  local a = lower(arg)
  if SKILL_PATHS[a] then return a end
  return PATH_TO_SKILL[a]
end

-- Skill names that look like what the user meant — substring either way,
-- so `chan` offers {chanting, channeling} and `elemental` offers nothing
-- (it's a path segment, not a skill). Capped so a one-letter typo can't
-- print the whole table.
local function skill_suggestions(arg)
  local a = lower(arg)
  if a == "" then return {} end
  local out = {}
  for _, skill in ipairs(SORTED_SKILLS) do
    if skill:find(a, 1, true) or a:find(skill, 1, true) then
      table.insert(out, skill)
      if #out >= 5 then break end
    end
  end
  return out
end

-- Every (spell, stage) pair that checks `skill`, unsorted.
local function skill_rows(skill)
  local rows = {}
  for _, nick in ipairs(SORTED_NICKS) do
    local s = spells[nick]
    local total = #(s.spellcheck or {})
    for _, r in ipairs(s.spellcheck or {}) do
      if r.skill == skill then
        table.insert(rows, {
          -- The TABLE KEY, not s.nick. Four spells carry a space-separated
          -- alias list in that field ("cmseq cms2", "ehai eham eha2"), which
          -- both widens the column and isn't what /spell looks up — dispatch
          -- indexes `spells[arg]`, i.e. the key. The key is the canonical
          -- single handle, so it's what the click-through needs too.
          nick     = nick,
          name     = s.name,
          type     = s.type,
          spell    = s,
          stage    = r.stage,
          stages   = total,
          nums     = r.nums,
          max      = tonumber(r.nums[10]),
          consumes = consumes_components(s),
        })
      end
    end
  end
  return rows
end

-- TM likelihood for one stage, mirroring tt_dw's @spell_tm_chance
-- (spellinfo.tin §743-768): a teaching moment needs the check to be a
-- near-miss, so the odds peak at a coin-flip and fall off towards both
-- certain success and certain failure. tt_dw clamps each stage to 1..99%
-- so a >99% or <1% stage still scores above zero.
--
-- Divergence from tt_dw, deliberate: it combines a spell's same-skill
-- stages into one per-SPELL figure. We render one row per stage, so this
-- is per-STAGE — which matches the row granularity and is the more
-- actionable number (it tells you which stage is the one teaching you).
local function tm_score(passed)
  local p = passed * 10
  if p < 1  then p = 1  end
  if p > 99 then p = 99 end
  p = p / 100
  return p * (1 - p)
end

-- Sort in place. `bonus` is nil when we have no skills snapshot, which
-- collapses the chance/TM keys for every row — so both modes degrade to
-- the same max-bonus ladder rather than to an arbitrary order.
--
-- Every mode ends with the same tiebreakers (max bonus ascending, then
-- name) because the primary keys tie constantly: five rows share 90% in a
-- typical fire listing. Max-ascending continues the same "closest to done"
-- gradient the primary key establishes, so ties read as a continuation
-- rather than as noise.
local function sort_rows(rows, mode, bonus)
  table.sort(rows, function(a, b)
    if bonus then
      if mode == "tm" then
        if a.tm ~= b.tm then return a.tm > b.tm end
      else
        if a.passed ~= b.passed then return a.passed > b.passed end
      end
    end
    if a.max ~= b.max then return (a.max or 0) < (b.max or 0) end
    if a.name ~= b.name then return a.name < b.name end
    return a.stage < b.stage
  end)
end

-- Render the listing. `opts.also` is the /spell delegation footer: the
-- nicks that a fuzzy search for this word would have found but this
-- listing does not contain (see dispatch).
local function show_skill_list(skill, mode, opts)
  opts = opts or {}
  refresh_skills_snapshot()

  local rows = skill_rows(skill)
  if #rows == 0 then
    mud.note("No spells use " .. skill .. ".", { fg = "yellow" })
    return
  end

  local level, bonus = skill_lookup(skill)

  -- Per-row derived values. Only computed when we have a bonus; without
  -- one the Chance and Need columns are dropped entirely (same treatment
  -- render_spellcheck gives its skill-aware columns).
  for _, r in ipairs(rows) do
    if bonus then
      r.passed, r.chance = compute_chance(bonus, r.nums)
      r.tm = tm_score(r.passed)
      local delta = (r.max or 0) - bonus
      r.need = delta > 0 and string.format("+%db", delta) or "done"
    end
  end
  sort_rows(rows, mode, bonus)

  -- ---------- Header ----------
  local spell_count = 0
  do
    local seen = {}
    for _, r in ipairs(rows) do
      if not seen[r.nick] then seen[r.nick] = true; spell_count = spell_count + 1 end
    end
  end
  local counts = spell_count .. (spell_count == 1 and " spell" or " spells")
  if #rows ~= spell_count then
    counts = counts .. ", " .. #rows .. " stages"
  end
  mud.note(
    mud.span("Spells using ", { bold = true }),
    mud.span(skill, PALETTE.skill_name),
    mud.span(" (" .. counts .. ")", { bold = true })
  )

  if bonus then
    local spans = {
      mud.span("  Bonus: ", PALETTE.label),
      mud.span(tostring(bonus)),
    }
    if level then
      table.insert(spans, mud.span("   Level: ", PALETTE.label))
      table.insert(spans, mud.span(tostring(level)))
    end
    table.insert(spans, mud.span("   Ordered by: ", PALETTE.label))
    table.insert(spans, mud.span(mode == "tm" and "TM likelihood" or "success chance"))
    mud.note(table.unpack(spans))
  else
    mud.note("  (Tip: run /skills-refresh with the discworld-vitals plugin installed to additionally see success chance and the bonus you still need.)",
      { italic = true })
  end

  -- ---------- Column widths ----------
  local nick_w, name_w, stage_w = #"nick", #"Spell", #"Stage"
  for _, r in ipairs(rows) do
    if #r.nick > nick_w then nick_w = #r.nick end
    if #r.name > name_w then name_w = #r.name end
    local st = #(r.stage .. "/" .. r.stages)
    if st > stage_w then stage_w = st end
  end

  local chance_w, max_w, need_w, cons_w = 6, #"Max", #"Need", #"Consumes"
  for _, r in ipairs(rows) do
    local m = #tostring(r.max or "?")
    if m > max_w then max_w = m end
    if r.need and #r.need > need_w then need_w = #r.need end
  end

  -- Spell name is the elastic column: everything else is sized to its
  -- content, and the name absorbs whatever the viewport has left. Clamped
  -- to a floor so a very narrow terminal truncates rather than producing
  -- a negative width.
  local fixed = 2 + nick_w + 2 + 2 + stage_w + 2 + max_w + 2 + cons_w
  if bonus then fixed = fixed + 2 + chance_w + 2 + need_w end
  name_w = math.max(12, math.min(name_w, viewport_cols() - fixed))

  local function pad_l(text, w) return string.format("%-" .. w .. "s", text) end
  local function pad_r(text, w) return string.format("%"  .. w .. "s", text) end
  -- ASCII ellipsis on purpose: pad_l measures with `#`, which counts BYTES,
  -- so a multi-byte "…" would silently desync padding from visual width.
  -- Spell names run to 47 chars, so this does fire on an 80-column terminal.
  local function clip(text, w)
    if #text <= w then return text end
    return text:sub(1, math.max(1, w - 3)) .. "..."
  end

  -- ---------- Header row ----------
  do
    local spans = {
      mud.span("  " .. pad_l("nick", nick_w), PALETTE.col_header),
      mud.span("  "),
      mud.span(pad_l("Spell", name_w),        PALETTE.col_header),
      mud.span("  "),
      mud.span(pad_r("Stage", stage_w),       PALETTE.col_header),
    }
    if bonus then
      table.insert(spans, mud.span("  "))
      table.insert(spans, mud.span(pad_r("Chance", chance_w), PALETTE.col_header))
    end
    table.insert(spans, mud.span("  "))
    table.insert(spans, mud.span(pad_r("Max", max_w), PALETTE.col_header))
    if bonus then
      table.insert(spans, mud.span("  "))
      table.insert(spans, mud.span(pad_r("Need", need_w), PALETTE.col_header))
    end
    table.insert(spans, mud.span("  "))
    -- Last column: unpadded, so rows carry no trailing whitespace.
    table.insert(spans, mud.span("Consumes", PALETTE.col_header))
    mud.note(table.unpack(spans))
  end

  -- ---------- Data rows ----------
  -- The nick is clickable and drills into the full card, matching the
  -- affordance in /spell's list and match views. Only the nick text
  -- carries the underline + handler; its padding is a separate plain span
  -- so the link region stays tight to the word.
  for _, r in ipairs(rows) do
    local type_style = style_for(r.type)
    local click_style = {}
    for k, v in pairs(type_style) do click_style[k] = v end
    click_style.underline = true
    click_style.on_click = function() show_card(r.spell) end

    local spans = { mud.span("  "), mud.span(r.nick, click_style) }
    local pad = nick_w - #r.nick
    if pad > 0 then table.insert(spans, mud.span(string.rep(" ", pad))) end
    table.insert(spans, mud.span("  "))
    table.insert(spans, mud.span(pad_l(clip(r.name, name_w), name_w), type_style))
    table.insert(spans, mud.span("  "))
    table.insert(spans, mud.span(pad_r(r.stage .. "/" .. r.stages, stage_w)))

    local ch_style
    if bonus then
      ch_style = chance_style(r.passed)
      table.insert(spans, mud.span("  "))
      table.insert(spans, mud.span(pad_r(r.chance, chance_w), ch_style))
    end
    table.insert(spans, mud.span("  "))
    table.insert(spans, mud.span(pad_r(tostring(r.max or "?"), max_w)))
    if bonus then
      -- Need shares Chance's tier colour so the eye reads "this is what
      -- the +Nb buys you"; "done" gets the green-bold max treatment.
      table.insert(spans, mud.span("  "))
      local need_style = (r.need == "done") and PALETTE.hint_max or ch_style
      table.insert(spans, mud.span(pad_r(r.need, need_w), need_style))
    end
    table.insert(spans, mud.span("  "))
    table.insert(spans, mud.span(r.consumes and "yes" or "-",
      r.consumes and PALETTE.comp_body or { fg = "light green" }))
    mud.note(table.unpack(spans))
  end

  -- ---------- Footers ----------
  -- Offer the other ordering. Suppressed without a snapshot, where both
  -- modes produce the identical max-bonus ladder and the pointer would
  -- be a lie.
  if bonus then
    if mode == "tm" then
      mud.note("  (/spellskill " .. skill .. " for success-chance order)", { italic = true })
    else
      mud.note("  (/spellskill " .. skill .. " tm for TM-likelihood order)", { italic = true })
    end
  end

  -- /spell delegation only: the fuzzy hits this listing swallowed. Nicks
  -- are clickable so nothing is actually out of reach.
  if opts.also and #opts.also > 0 then
    local n = #opts.also
    local spans = {
      mud.span(string.format("  (%d more %s match%s ", n,
        n == 1 and "spell" or "spells", n == 1 and "es" or ""), { italic = true }),
      mud.span(string.format("%q", opts.query), { italic = true }),
      mud.span(" by name or description: ", { italic = true }),
    }
    for i, nick in ipairs(opts.also) do
      if i > 1 then table.insert(spans, mud.span(" ")) end
      local s = spells[nick]
      local st = style_for(s.type)
      local cs = {}
      for k, v in pairs(st) do cs[k] = v end
      cs.underline = true
      cs.on_click = function() show_card(s) end
      table.insert(spans, mud.span(nick, cs))
    end
    table.insert(spans, mud.span(")", { italic = true }))
    mud.note(table.unpack(spans))
  end
end

local function show_skill_help()
  mud.note("Usage: /spellskill <skill> [tm]", { bold = true })
  mud.note("       /spellskill fire       spells checking fire, likeliest cast first")
  mud.note("       /spellskill fire tm    same rows, ordered by TM likelihood")
  mud.note("       /spellskill help       show this banner")
  mud.note("A full dotted path works too: /spellskill magic.methods.elemental.fire")
  mud.note("Skills:", { bold = true })
  -- Reuse the /spells column layout so the two listings look related.
  local cell_w = 0
  for _, s in ipairs(SORTED_SKILLS) do
    if #s > cell_w then cell_w = #s end
  end
  cell_w = cell_w + 2
  local per_row = math.max(1, math.floor(viewport_cols() / cell_w))
  local n = #SORTED_SKILLS
  local rows = math.ceil(n / per_row)
  for r = 1, rows do
    local spans = { mud.span("  ") }
    for c = 0, per_row - 1 do
      local idx = c * rows + r
      if idx <= n then
        local skill = SORTED_SKILLS[idx]
        table.insert(spans, mud.span(skill, PALETTE.skill_name))
        -- Pad as a separate plain span, and skip it entirely on the last
        -- cell of a row so no line carries trailing whitespace.
        local pad = cell_w - #skill
        if pad > 0 and (c + 1) * rows + r <= n then
          table.insert(spans, mud.span(string.rep(" ", pad)))
        end
      end
    end
    mud.note(table.unpack(spans))
  end
end

-- /spellskill dispatch. Validates against skill_paths (not the
-- spellcheck-derived index) so a real-but-unused skill reports "no spells
-- use it" rather than "unknown skill".
local function skill_dispatch(arg)
  arg = arg or ""
  local word, rest = arg:match("^(%S+)%s*(.*)$")
  if not word or word == "" or lower(word) == "help" then
    show_skill_help()
    return
  end

  local skill = resolve_skill(word)
  if not skill then
    mud.note("Unknown skill: " .. word, { fg = "red" })
    local hints = skill_suggestions(word)
    if #hints > 0 then
      mud.note("Did you mean: " .. table.concat(hints, ", ") .. "?")
    else
      mud.note("Try /spellskill help for the list of skills spells check.")
    end
    return
  end

  local mode = (lower(rest) == "tm") and "tm" or "chance"
  if rest ~= "" and mode ~= "tm" then
    mud.note("Unknown option: " .. rest .. " — expected 'tm'.", { fg = "yellow" })
    return
  end
  show_skill_list(skill, mode)
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
  local usable = viewport_cols()

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
  mud.note("       /spell <skill>   every spell that checks that skill")
  mud.note("       /spell help      show this banner")
  mud.note("Examples:")
  mud.note("  /spell wgs           full info for Wungle's Great Sucking")
  mud.note("  /spell fire          every spell checking the fire method")
  mud.note("  /spell gaze          all spells matching 'gaze'")
  mud.note("See also /spellskill (alias /ss) for TM-likelihood ordering.")
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

  -- Exact skill name second, delegating to /spellskill's default view.
  -- Safe to put ahead of the fuzzy search: no skill name collides with any
  -- spell nick (checked across all 115 spells), so this can only ever
  -- shadow SUBSTRING hits, never an exact lookup.
  --
  -- Eight skill words do fuzzy-match something today (`ring`, `fire`,
  -- `talisman`, `air`, `scrying`, `banishing`, `rod`, `staff`), mostly
  -- substring noise like "E-ring-yas'". Rather than lose them we pass the
  -- ones this listing does NOT already contain to the footer, where they
  -- render as clickable nicks. Nothing becomes unreachable.
  local skill = SKILLS_IN_SPELLCHECK[lower(arg)] and lower(arg) or nil
  if skill then
    local in_listing = {}
    for _, r in ipairs(skill_rows(skill)) do in_listing[r.nick] = true end
    local also = {}
    for _, nick in ipairs(fuzzy_matches(arg)) do
      if not in_listing[nick] then table.insert(also, nick) end
    end
    show_skill_list(skill, "chance", { also = also, query = arg })
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

-- The inverse lookup. `/spell <skill>` already reaches the default view;
-- this is the canonical surface, and the only way to reach `tm` ordering.
-- `/ss` is unclaimed across the plugin set — note `/skill` and `/sk` belong
-- to discworld-vitals' skill-goal tracker, which is a different thing.
mud.command("spellskill", function(m)
  skill_dispatch(m.args)
end, {
  description = "List every spell that checks a given skill, with your success chance and the bonus needed to max it.",
  usage = "spellskill <skill> — spells checking that skill, likeliest cast first; spellskill <skill> tm — ordered by TM likelihood; spellskill help — usage and the list of skills.",
  aliases = "ss",
})
