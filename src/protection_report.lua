-- Discworld Magic — `group shields` / `protections X` report parser.
--
-- Discworld's `group shields` command (and `protections <player>` for a
-- single target) emits per-player blocks shaped like:
--
--     Arcane protection for Brodfist:-
--       * Brodfist is surrounded by a bright red magical impact shield.
--       * His skin has been covered with a thin layer of chalk, although ...
--       * Mithril shield is floating around him:
--       * He is surrounded by a cloud of bees.
--       * He is protected by the power of Pishe.  You will be protected for ...
--
--     Arcane protection for Greyling:-
--       * Greyling has no arcane or divine protection.
--
-- The body lines use 3rd-person pronouns ("his", "her", "its", "him")
-- and don't carry the player name. To attribute them we hold the
-- player name from the most recent header line in `current_target`.
-- The per-type self modules (`tpa.lua`, `ccc.lua`, `bug.lua`, `ms.lua`,
-- `eff.lua`) already handle the SELF body lines via the established
-- `Arcane protection status:` reset hook + the `* You/Your ...`
-- triggers; this module covers OTHER players that the single-player
-- paths can't reach.
--
-- Events emitted:
--   net.mallard.discworld.shield.cleared { subject }
--       Fired on every header (`Arcane protection for X:-`) and on every
--       "X has no arcane or divine protection." line. Grouping plugin
--       handler wipes all five cells for that subject. No banner /
--       notification path consumes this — only the chip grid.
--   net.mallard.discworld.shield.up { subject, type, … }
--       Mirrors the events emitted by the live-cast modules (tpa.lua,
--       ccc.lua, …); the payload shape is identical so grouping's
--       existing subscriber works with no changes.
--
-- Scope deferrals:
--   - The user themselves can appear inside this report as
--     "Arcane protection for <YourName>:-" (Discworld doesn't relabel
--     the user to "You" in the group context). Magic doesn't know the
--     user's name, so self attribution is left to the grouping plugin —
--     it already maps the `is_self` row's wire name onto the stable
--     `"self"` shield-store sentinel (commit 407edc0).
--   - Unrelated `look <player>` output between two report blocks would
--     misattribute body lines to the previous header's target. This
--     module accepts the same correlation limitation Quow does and
--     resets `current_target` only on the next header (or on the
--     no-protection line).

local SIZES   = [[handful|cloud|small swarm|large swarm|vast swarm|plague]]
local SPECIES = [[lacewings|stick insects|mayflies|praying mantids|butterflies|ladybirds|dragonflies|damselflies|moths|grasshoppers|winged termites|termites|sandflies|mosquitoes|gnats|crickets|flying ants|ants|locusts|horseflies|cicadas|bees|wasps|hornets|elephant beetles|assassin bugs]]
local DEITIES = [[Pishe|Gufnork|Gapp|Sandelfon|Fish|Hat|Sek|Aegadon|Cubal|Reebox]]
local VIA     = [[power|protective armour|grace]]
-- Both the leading word and any subsequent words allow either case —
-- Discworld accepts non-title-case character and family names (e.g.
-- `sYa`, `aVocado`, lowercase-leading surnames). `Arcane protection
-- for sYa:-` is what the wire produces for such characters.
local NAME    = [[[A-Za-z][a-zA-Z'-]+(?: [A-Za-z][a-zA-Z'-]+){0,3}]]

local TPA_PERCENT = {
  ["invisible"]         = 100,
  ["dull red"]          = 80,
  ["bright red"]        = 60,
  ["wobbling orange"]   = 40,
  ["flickering yellow"] = 20,
}

local current_target = ""

local function clear(subject)
  if type(subject) ~= "string" or subject == "" then return end
  events.emit("net.mallard.discworld.shield.cleared", { subject = subject })
end

local function up(type_, details)
  if current_target == "" then return end
  details.subject = current_target
  details.type    = type_
  events.emit("net.mallard.discworld.shield.up", details)
end

-- ---------------------------------------------------------------------
-- Headers — set current_target, emit shield.cleared.
-- ---------------------------------------------------------------------

mud.trigger(string.format([[^Arcane protection for (%s):-$]], NAME),
  function(m)
    current_target = m[1] or ""
    clear(current_target)
  end)

-- "X has no arcane (or divine) protection." — terminal line for an
-- empty member; clear and reset target so a stray body line afterwards
-- doesn't misattribute.
mud.trigger(string.format(
  [[^(%s) has no arcane(?: or divine)? protection\.$]], NAME),
  function(m)
    local subject = m[1] or ""
    clear(subject)
    current_target = ""
  end)

-- Self no-protection — different wire wording. Self state is already
-- managed by per-type `Arcane protection status:` reset triggers, but
-- the grouping panel benefits from a hard "everything cleared" signal
-- here so the chips drop the moment the user confirms nothing's up.
mud.trigger([[^You do not have any arcane(?: or divine)? protection\.$]],
  function()
    events.emit("net.mallard.discworld.shield.cleared", { subject = "self" })
  end)

-- ---------------------------------------------------------------------
-- TPA — body lines attribute to current_target.
-- ---------------------------------------------------------------------

-- Invisible (no glow word).
mud.trigger([[^ \* (?:He|She|It) is surrounded by a magical impact shield\.$]],
  function() up("tpa", { glow = "invisible", percent = 100 }) end)

-- Colored glow.
mud.trigger([[^ \* (?:He|She|It) is surrounded by a (dull red|bright red|wobbling orange|flickering yellow) magical impact shield\.$]],
  function(m)
    local glow = m[1]
    up("tpa", { glow = glow, percent = TPA_PERCENT[glow] })
  end)

-- ---------------------------------------------------------------------
-- CCC — 15 substance × strength phrases. Mirrors ccc.lua's mapping
-- but keyed on `(?:His|Her|Its)` instead of "Your". `metal` rung 4 has
-- the irregular "has metal bands running ..." shape; rung 1 has its
-- own "Tiny threads of metal ..." shape (matched separately).
-- ---------------------------------------------------------------------

local function ccc(substance, strength)
  return function() up("ccc", { substance = substance, strength = strength }) end
end

-- Chalk ladder.
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) hardened to a rock-like form,]],                                          ccc("chalk", 5))
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) hardened with numerous layers of a mineral-like substance,]],             ccc("chalk", 4))
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) hardened with a chalk-like substance,]],                                  ccc("chalk", 3))
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) covered with several layers of a chalk-like substance,]],                 ccc("chalk", 2))
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) covered with a thin layer of chalk,]],                                    ccc("chalk", 1))

-- Latex ladder.
mud.trigger([[^ \* (?:His|Her|Its) skin has solidified into a rubberous form,]],                                                      ccc("latex", 5))
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) made elastic with numerous layers of a rubber-like substance,]],          ccc("latex", 4))
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) treated with a latex-like substance,]],                                   ccc("latex", 3))
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) covered with several layers of a latex-like substance,]],                 ccc("latex", 2))
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) covered with a thin layer of latex,]],                                    ccc("latex", 1))

-- Metal ladder.
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) covered with a thick metal net,]],                                        ccc("metal", 5))
mud.trigger([[^ \* (?:His|Her|Its) skin has metal bands running all over it, forming a kind of net,]],                                ccc("metal", 4))
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) covered with a thin metal net,]],                                         ccc("metal", 3))
mud.trigger([[^ \* (?:His|Her|Its) skin (?:has been|has|is) covered with a thin, net-like metal coating,]],                           ccc("metal", 2))
mud.trigger([[^ \* Tiny threads of metal run criss-cross all over (?:his|her|its) skin,]],                                            ccc("metal", 1))

-- ---------------------------------------------------------------------
-- BUG — "* He is surrounded by a <size> of <bugs>." Captures: [1] = size, [2] = bugs.
-- ---------------------------------------------------------------------

mud.trigger(string.format(
  [[^ \* (?:He|She|It) is surrounded by a (%s) of (%s)\.$]], SIZES, SPECIES),
  function(m) up("bug", { size = m[1], bugs = m[2] }) end)

-- ---------------------------------------------------------------------
-- EFF — "* <item> is floating around (him|her|it):" Capture: [1] = item.
-- ---------------------------------------------------------------------

mud.trigger([[^ \* (.+) is floating around (?:him|her|it):$]],
  function(m) up("eff", { item = m[1] }) end)

-- ---------------------------------------------------------------------
-- MS — "* He is [really ]protected by the (power|grace) of <deity>".
-- Quow stops the regex before the trailing "  You will be protected
-- for ..." suffix; we do the same so the timing tail can vary.
-- Captures: [1] = strength ("" / "really"), [2] = via, [3] = deity.
-- The ONA shape only ever uses "protected" form and only "power"/"grace"
-- via — "protective armour" / "shielded" don't appear in 3rd-person
-- reports per Quow's pattern, so we mirror that here.
-- ---------------------------------------------------------------------

mud.trigger(string.format(
  [[^ \* (?:He|She|It) is (?:(really) )?protected by the (%s) of (%s)]],
  [[power|grace]], DEITIES),
  function(m)
    up("ms", {
      strength = m[1] or "",
      form     = "protected",
      via      = m[2] or "",
      deity    = m[3] or "",
    })
  end)
