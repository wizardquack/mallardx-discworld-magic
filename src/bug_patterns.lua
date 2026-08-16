-- Discworld Magic — shared Bugshield wire vocabulary + pattern builders.
--
-- bug.lua (self) and bug_others.lua (other players) match the same wire
-- lines differing only in what they attach to — `you` vs a player name —
-- and tests/bug_regex_test.lua checks these exact patterns against a line
-- corpus using ripgrep, which embeds the same Rust `regex` crate Mallard
-- compiles triggers with. One source of truth keeps the three in step.
--
-- NOTE: Mallard's `require` re-evaluates a module on every call (there is
-- no package.loaded cache), so this module holds immutable data and pure
-- builders only — never mutable shared state.
--
-- ---------------------------------------------------------------------
-- Why the up-line pattern is shaped the way it is
-- ---------------------------------------------------------------------
-- The cast line varies a LOT: the size is sometimes absent, the verb is
-- sometimes plural ("The plague of ladybirds BEGIN to buzz"), the
-- preposition is "around" or "about" or "near", and the trailing mood
-- suffix is open-ended (" slowly", " happily", " victoriously",
-- ", chirping gently", …). The old port enumerated whole verb phrases in
-- the singular and anchored on a closed suffix list, so it missed four of
-- the five cast lines seen in the wild.
--
-- Widening this has to stop well short of "any sentence mentioning bugs
-- and you", because the plugin's OWN cast sequence contains
--
--     The insects eagerly cluster around you, fighting for the sugar.
--
-- which is pre-shield flavour text, and because a missed line is
-- self-correcting (a `shields` report resyncs the chip) while a false
-- positive paints a shield the player does not have. So every degree of
-- freedom stays bounded:
--
--   * mood prefix   — <=80 chars and no . ! ? : " , so a channel line
--                     ('Bob tells you, "…"') cannot spill into a match.
--   * species       — a closed vocabulary; this is what rejects the
--                     "insects" flavour line above.
--   * filler        — <=24 chars between species and verb. Real fillers
--                     are "begins to " / "starts to " / empty; the
--                     upgrade line below needs 42, which is how the
--                     generic pattern keeps its hands off it.
--   * verb          — a closed stem list, singular and plural.
--   * attachment    — the cloud must position itself AROUND/ABOUT/NEAR
--                     you, or circle/orbit you directly. This is what
--                     rejects ambient lines like "The bees buzz angrily
--                     at you." and "The moths flutter away from you."
--
-- Deliberately NOT anchored at end-of-line: the mood suffix is
-- open-ended, so the pattern stops as soon as the target is identified.

local M = {}

-- Cloud magnitudes, smallest to biggest.
M.SIZES = [[handful|cloud|small swarm|large swarm|vast swarm|plague]]

-- Species union of Quow's list and the in-game list a player reported.
-- Both spellings of the two that disagree are accepted rather than
-- picking a winner ("mosquitos"/"mosquitoes", "elephant bugs"/"elephant
-- beetles") — guessing wrong costs a silently dead chip. Alternatives
-- that share a prefix are ordered longest-first, since Mallard's regex
-- engine takes the leftmost-first alternative.
M.SPECIES = [[lacewings|stick insects|mayflies|praying mantids|butterflies|ladybirds|dragonflies|damselflies|moths|grasshoppers|winged termites|termites|sandflies|mosquitoes|mosquitos|gnats|crickets|flying ants|ants|locusts|horseflies|cicadas|bees|wasps|hornets|elephant beetles|elephant bugs|assassin bugs]]

-- Verbs a forming cloud uses, singular and plural. Discworld is not
-- consistent about agreement even within one sentence shape: "The plague
-- of assassin bugs BEGINS to circle you" and "The plague of ladybirds
-- BEGIN to buzz around you" both occur.
M.VERBS = [[circles?|orbits?|hovers?|clusters?|buzz(?:es)?|flutters?|forms?|gathers?]]

-- A player name: capitalised words. Discworld accepts odd casing in
-- names, but the leading capital is what separates an other-player line
-- from a self line, so it stays strict here.
M.NAME = [[[A-Z][a-zA-Z'-]+(?: [A-Z][a-zA-Z'-]+){0,3}]]

-- Optional leading mood clause ("Buzzing drowsily, ", "With a low,
-- menacing buzzing, "). Allows internal commas — the previous
-- `[^,]+, ` form could not span one, so every mood containing a comma
-- silently failed to match.
local MOOD = [[(?:[^.!?:"]{0,80}, )?]]

-- Optional clause between the species and the verb ("begins to ").
local FILLER = [[(?:[a-z][^.!?]{0,24}? )?]]

-- The shield forming around `target`. Captures: [1] = size (empty when
-- the line omits it), [2] = species, then whatever `target` captures.
function M.up(target)
  return string.format(
    [[^%s[Tt]he (?:(%s) of )?(%s) %s(?:(?:%s)\b[^.!?]{0,40}?(?:around|about|near) %s|(?:circles?|orbits?) %s)]],
    MOOD, M.SIZES, M.SPECIES, FILLER, M.VERBS, target, target)
end

-- Upgrade line: the current cloud is driven off and a better species
-- takes its place ("The gnats make a hasty retreat and the assassin bugs
-- gather around you victoriously."). The shield is the SECOND species —
-- matching the first would record the swarm that just left. No size is
-- carried, so callers keep the last known one.
-- Captures: [1] = size (usually empty), [2] = new species.
function M.retreat(target)
  return string.format(
    [[^The (?:%s) make a hasty retreat and the (?:(%s) of )?(%s) gather around %s]],
    M.SPECIES, M.SIZES, M.SPECIES, target)
end

-- A body line from an arcane-protection report. `subject` is the clause
-- naming whose shield it is: "You are" for the self report, or
-- "(?:He|She|It) is" for another player's block in `group shields`.
--
-- Species-agnostic (as Quow's is) so an unlisted species still
-- registers — safe only because the size is mandatory here, which is
-- what keeps TPA's "… is surrounded by a magical impact shield." out.
-- Captures: [1] = size, [2] = species.
function M.report(subject)
  return string.format(
    [[^ \* %s surrounded by a (%s) of ([a-z][a-z ]*)\.$]], subject, M.SIZES)
end

-- The two report subjects.
M.SELF_SUBJECT  = [[You are]]
M.OTHER_SUBJECT = [[(?:He|She|It) is]]

-- Wore off / destroyed in combat. Species-agnostic: the species is not
-- needed (callers report the last known one) and the surrounding phrase
-- is distinctive on its own. Unanchored tails, since only the head of
-- these lines is documented.
function M.scatter(target)
  return string.format([[^The ([a-z][a-z ]*) surrounding %s scatter\b]], target)
end

function M.crash(target)
  return string.format(
    [[^The last of the (?:injured )?([a-z][a-z ]*) surrounding %s crash\b]], target)
end

-- The literal `you`, as an up/scatter/crash target. Word-bounded so a
-- player named "Youssef" cannot be mistaken for the user.
M.SELF = [[you\b]]

return M
