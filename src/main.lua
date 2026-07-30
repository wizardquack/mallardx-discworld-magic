-- Discworld Magic — Plan #9f flagship plugin.
--
-- Ports tt_dw's magic colour/style rules into a Mallard plugin using:
--   mud.replace  (text-mutating subs — adds inline scale annotations)
--   mud.style    (whole-line restyle + capture-targeted restyle)
--   mud.trigger  (state tracking + cross-plugin event emission)
--
-- Source files in this file (under ~/code/3p/tt_dw/scripts/magic/):
--   enchant.tin    — thaum / enchantment %
--   klein.tin      — Klein-bottle energy + pattern color
--   eha.tin        — Earhammer damage %
--   pfg.tin        — Protection-From-Fire damage %
--   delude.tin     — Delude octarine shadow (n/5)
--   other.tin      — other people's offensive casts + assorted
--   broomstick.tin — broomstick fuel-level annotations
--   gfr.tin        — Gryntard's Feathery Reliever highlights
--   obbk.tin       — Old Bellicus' Brazen Knuckles humming intensity
--   fnp.tin        — Fyodor's Nimbus of Porterage cloud highlights
--   magic.tin      — giant-fruitbat hunger alert
--
-- Larger subsystems live in their own files (`require`d at the bottom):
--   src/eff.lua    — Endorphin's Floating Friend (floater shield)
--                    state tracking + drop banner.
--   src/tpa.lua    — Transcendent Pneumatic Alleviator (impact shield)
--                    state tracking + stream-annotation rules.
--   src/ccc.lua    — Chrenedict's Corporeal Covering (skin shield)
--                    state tracking + dispel banner.
--   src/bug.lua    — Bugshield (insect cloud) state tracking +
--                    warn / gone / destroyed banners.
--   src/ms.lua     — Major Shield (divine protection) self-side
--                    state tracking + expiry banner.
--   src/protection_report.lua — `group shields` / `protections X`
--                    output parser; attributes anonymous body lines
--                    via a preceding "Arcane protection for X:-"
--                    header.
--
-- Tintin pattern translation rules (used throughout):
--   %*           → .*
--   {a|b|c}      → (?:a|b|c)
--   %1, %2, ...  → (.+?) capture groups (numbered left-to-right)
--   %.           → .
--   %w           → \w+
--   Anchors      → ^...$ stays as ^...$.
-- mud.replace template grammar:
--   %0  = whole match
--   %1..%9 = numbered captures (left-to-right in the regex)
--   %%  = literal %

-- ---------------------------------------------------------------------
-- === enchant.tin — thaum / enchantment % ===
-- ---------------------------------------------------------------------
-- Source: #sub {pattern} {%0 <color>(annotation%)} — appends annotation
-- in octarine (magenta), high-thaum warnings escalate to red/light red.
-- Each sub is a plain-string (no captures) match, so %0 = whole match.

-- Enchantment-level ladders. Two parallel sets of phrases (singular "It"
-- and plural "They") share the same percentage-band annotations + magenta
-- styling, so the rung tables here pair (singular, plural) per band and
-- the loop registers both variants from one entry.
local ENCHANT_BANDS = {
  { it = "It occasionally pulses with octarine light",   they = "They occasionally pulse with octarine light",   label = "(1-10%%)"   },
  { it = "It emits a slight octarine glow",              they = "They emit a slight octarine glow",              label = "(11-20%%)"  },
  { it = "It softly pulses in dull octarine shades",     they = "They softly pulse in dull octarine shades",     label = "(21-30%%)"  },
  { it = "It gives off a steady but dull octarine glow", they = "They give off a steady but dull octarine glow", label = "(31-40%%)"  },
  { it = "It gives off a steady octarine glow",          they = "They give off a steady octarine glow",          label = "(41-50%%)"  },
  { it = "It glows an intense octarine",                 they = "They glow an intense octarine",                 label = "(51-60%%)"  },
  { it = "It emits a bright octarine colour",            they = "They emit a bright octarine colour",            label = "(61-70%%)"  },
  { it = "It brightly pulses octarine",                  they = "They brightly pulse octarine",                  label = "(71-80%%)"  },
  { it = "It glows brilliant octarine shades",           they = "They glow brilliant octarine shades",           label = "(81-90%%)"  },
  { it = "It radiates pure octarine brilliance",         they = "They radiate pure octarine brilliance",         label = "(91-100%%)" },
}
for _, band in ipairs(ENCHANT_BANDS) do
  mud.replace(band.it,   "%0 " .. band.label, { fg = "magenta" })
  mud.replace(band.they, "%0 " .. band.label, { fg = "magenta" })
end

-- Thaum density of the current room. Four magenta low bands, one red
-- mid band, three light-red high bands — colour follows the band's
-- {pat, label, fg} fields so the escalation reads top-down.
local THAUM_BANDS = {
  { pat = [[There is the residual taste of magic in this place]],                                                            label = "(50-149 thaums)",    fg = "magenta"   },
  { pat = [[This place has seen some use of magic]],                                                                         label = "(150-299 thaums)",   fg = "magenta"   },
  { pat = [[A considerable amount of magic has been used here]],                                                             label = "(300-499 thaums)",   fg = "magenta"   },
  { pat = [[A very large quantity of magic has been manipulated here]],                                                      label = "(500-749 thaums)",   fg = "magenta"   },
  { pat = [[You can feel the Dungeon Dimensions trying to push in]],                                                         label = "(750-1000 thaums)",  fg = "red"       },
  { pat = [[Little sparks flash in from the Dungeon Dimensions]],                                                            label = "(1001-1500 thaums)", fg = "light red" },
  { pat = [[Apparations of things with lots of tentacles seem to be on the edge of your vision]],                            label = "(1501-2000 thaums)", fg = "light red" },
  { pat = [[So much magic has been expended here that the area is in danger of dumping itself into the Dungeon Dimensions]], label = "(2001-5000 thaums)", fg = "light red" },
}
for _, band in ipairs(THAUM_BANDS) do
  mud.replace(band.pat, "%0 " .. band.label, { fg = band.fg })
end

-- ---------------------------------------------------------------------
-- === klein.tin — Klein-bottle energy + sphere pattern color ===
-- ---------------------------------------------------------------------
-- Source: #sub {... %* energy} {%0 (<cyan>range<reset>)} — annotates the
-- current accumulated-energy level. The "%*" before "energy" matches any
-- energy-type word (e.g. "magical", "etheric").
--
-- These lines are embedded mid-sentence in the bottle's look description,
-- so each pattern is anchored ^(.*)(phrase)(.*)$ and the prefix/suffix
-- captures are re-emitted around the annotation. Without that, mud.replace's
-- whole-line target drops the un-matched head and tail of the line (see the
-- pfg.tin note below). The (.*) guards are no-ops when the phrase is alone.
--
-- The five "tracing a %* pattern" subs *both* (a) insert a thaum-count
-- annotation after the sphere-size phrase and (b) recolour the pattern
-- name via @color_code{%1}. v1 Mallard can't replicate the dynamic
-- per-pattern colour, and combining the count insertion (whole-line
-- Rewrite) with a fixed-cyan capture restyle in two separate rules
-- doesn't compose cleanly — the Rewrite's pre-computed replacement
-- spans don't carry the restyle and byte ranges aren't re-mapped
-- across mods. We ship the count annotation only.

mud.replace([[^(.*)(barely noticeable wisp of .* energy)(.*)$]], "%1%2 (5-25)%3",          { fg = "cyan" })
mud.replace([[^(.*)(a tiny swirl of .* energy)(.*)$]],           "%1%2 (30-55)%3",         { fg = "cyan" })
mud.replace([[^(.*)(ripple of .* energy)(.*)$]],                 "%1%2 (60-85)%3",         { fg = "cyan" })
mud.replace([[^(.*)(small waves of .* energy)(.*)$]],            "%1%2 (90-115 (+1))%3",   { fg = "green" })
mud.replace([[^(.*)(eddying currents of .* energy)(.*)$]],       "%1%2 (120-145 (+1))%3",  { fg = "green" })
mud.replace([[^(.*)(a turbulence of .* energy)(.*)$]],           "%1%2 (150-175 (+1))%3",  { fg = "green" })
mud.replace([[^(.*)(a whirlpool of .* energy)(.*)$]],            "%1%2 (180-205 (+1))%3",  { fg = "green" })
mud.replace([[^(.*)(a maelstrom of .* energy)(.*)$]],            "%1%2 (210-235 (+1))%3",  { fg = "green" })
mud.replace([[^(.*)(a tempest of .* energy)(.*)$]],              "%1%2 (240-265 (+2); Don't capture any more substantial spheres, smaller is still ok though.)%3", { fg = "yellow" })
mud.replace([[^(.*)(a vortex of .* energy)(.*)$]],               "%1%2 (270-295 (+2); Don't capture any more spells.)%3", { fg = "light red" })
mud.replace([[^(.*)(an impossible chaos of .* energy)(.*)$]],    "%1%2 (300+ (+2); STOP CAPTURING SPELLS!)%3", { fg = "light red" })

-- "tracing a %* pattern" subs — insert thaum-count annotation after
-- the sphere-size phrase (see header comment for the pattern-name
-- colour trade-off). Backref structure splits the line around the
-- size phrase so the literal " (N)" annotation lands between the
-- captures and gets the cyan style; the rest is pass-through.
mud.replace([[^( tiny speck of energy)( is tracing a .+? pattern)$]],
  "%1 (5)%2", { fg = "cyan" })
mud.replace([[^( small point of energy)( is tracing a .+? pattern)$]],
  "%1 (10-15)%2", { fg = "cyan" })
mud.replace([[^( moderately-sized ball of energy)( is tracing a .+? pattern)$]],
  "%1 (20-25)%2", { fg = "cyan" })
mud.replace([[^( large orb of energy)( is tracing a .+? pattern)$]],
  "%1 (30-35)%2", { fg = "cyan" })
mud.replace([[^( substantial sphere of energy)( is tracing a .+? pattern)$]],
  "%1 (40-60)%2", { fg = "cyan" })

-- Klein-bottle charge feedback — the bottle holds a limited number of
-- captured spells and reports its state with these deliberately vague
-- lines: the two "gain" phrases confirm the current charge level (green),
-- while the "forgotten something" line fires when it's full and the
-- oldest charge is quietly shed (yellow loss warning).
mud.replace([[^Your mind races with new and exciting ideas\.$]],
  "%0 (klein: +2 int)", { fg = "green" })
mud.replace([[^You sense unimagined possibilities\.$]],
  "%0 (klein: +1 int)", { fg = "green" })
mud.replace([[^You get the feeling you've just forgotten something\.$]],
  "%0 (klein: +2 -> +1 int)", { fg = "yellow" })

-- wgs — constitution boost feedback. The cast confirms with a single
-- line; annotate the con gain range (green), matching the klein format.
mud.replace([[^You feel vitality course through your veins\.$]],
  "%0 (wgs: +1-3 con)", { fg = "green" })

-- ---------------------------------------------------------------------
-- === eha.tin — Earhammer damage % ===
-- ---------------------------------------------------------------------
-- Source: two-capture subs: {^{first phrase} {rest of sentence}} →
-- {%1 <annotation> %2}. The captures split the sentence so the annotation
-- can be inserted between them. Pattern translated: each {group} → (.+?).

mud.replace([[^(The sound grates) (.* nerves\.)$]],                                      "%1 (<15%%) %2",      { fg = "light red" })
mud.replace([[^(The sound hurts) (.* ears considerably\.)$]],                            "%1 (15-35%%) %2",    { fg = "light red" })
mud.replace([[^(The sound makes) (.* heads? shudder painfully\.)$]],                     "%1 (35-55%%) %2",    { fg = "light red" })
mud.replace([[^(The horrible sound) (makes .* eardrums burst with its sheer intensity\.)$]], "%1 (55-75%%) %2", { fg = "light red" })
mud.replace([[^(The sound makes) (blood ooze from .* ears and nostrils\.)$]],            "%1 (75-90%%) %2",    { fg = "light red" })
mud.replace([[^(The sound causes) (various bones in .* to explode\.)$]],                 "%1 (>90%%) %2",      { fg = "light red" })

-- ---------------------------------------------------------------------
-- === pfg.tin — Protection-From-Fire damage % ===
-- ---------------------------------------------------------------------
-- Source: single-capture subs: {^{The fire verb} } → {%1 <annotation> }.
-- Anchored ^...$ with a suffix capture so the rest of the sentence is
-- preserved (mud.replace's default target is the whole line, so a
-- prefix-only match would drop the tail).

mud.replace([[^(The fire singes) (.*)$]],      "%1 (<15%%) %2",      { fg = "light red" })
mud.replace([[^(The fire burns) (.*)$]],       "%1 (15-30%%) %2",    { fg = "light red" })
mud.replace([[^(The fire crisps) (.*)$]],      "%1 (30-60%%) %2",    { fg = "light red" })
mud.replace([[^(The fire melts) (.*)$]],       "%1 (60-75%%) %2",    { fg = "light red" })
mud.replace([[^(The fire incinerates) (.*)$]], "%1 (75-90%%) %2",    { fg = "light red" })
mud.replace([[^(The fire vaporises) (.*)$]],   "%1 (>90%%) %2",      { fg = "light red" })

-- ---------------------------------------------------------------------
-- === delude.tin — Delude octarine shadow (n/5) ===
-- ---------------------------------------------------------------------
-- Source: five plain-string subs appending a (n/5) annotation, plus two
-- #high rules for the shadow deepening/fading feedback.

mud.replace([[^It has a faint octarine shadow about it that disappears if you look at it squarely\.$]], "%0 (1/5)", { fg = "magenta" })
mud.replace([[^It has a faint octarine shadow about it\.$]],                                            "%0 (2/5)", { fg = "magenta" })
mud.replace([[^It has an octarine shadow about it that flickers occasionally out of the corner of your eye\.$]], "%0 (3/5)", { fg = "magenta" })
mud.replace([[^It has a flickering octarine shadow about it\.$]],                                       "%0 (4/5)", { fg = "magenta" })
mud.replace([[^It has a flickering octarine haze about it\.$]],                                         "%0 (5/5)", { fg = "magenta" })

-- #high rules: octarine shadow depth feedback
-- Tintin: {^The octarine shadow around %* deepens%*} {bold magenta}
-- %* → .*
mud.style([[^The octarine shadow around .* deepens.*]], { fg = "magenta", bold = true })
mud.style([[^The octarine shadow around .* fades.*]],   { fg = "magenta" })

-- ---------------------------------------------------------------------
-- === other.tin — other people's offensive casts + assorted ===
-- ---------------------------------------------------------------------
-- Source: 36 #high + 7 #sub rules.
-- Translation:
--   - All #high rules → mud.style(pattern, { fg = ..., bold = ... })
--   - JPCT subs (portal in room + look/go through) → mud.style with capture
--   - PMG / RTFM subs used @color_code{%1} (dynamic color) — v1 limitation:
--     ported as fixed cyan (flagged with NOTE comments below)
--   - All #action rules DROPPED — sound effects and /hold management are
--     side-effects, not visual highlights.
--
-- Tintin color codes used: bold red, green, bold green, yellow, cyan, bold cyan.

-- KOF — Kneel Or Feel
mud.style([[.* wiggles \w+ eyebrows around a bit\.]],                                    { fg = "red", bold = true })
mud.style([[.* wrinkles \w+ face in disgust\.]],                                         { fg = "red", bold = true })
mud.style([[.* points at you\.]],                                                        { fg = "red", bold = true })
mud.style([[.* sets fire to the carrot\.]],                                              { fg = "red", bold = true })

-- NES — Neshome E Shemo
mud.style([[.* stands still and thinks\.]],                                              { fg = "red", bold = true })
mud.style([[.* flaps \w+ arms and moves about while beeping\.]],                         { fg = "red", bold = true })
mud.style([[.* hurls a torch straight up into the air\.]],                               { fg = "red", bold = true })
mud.style([[.* shuffles \w+ feet\.]],                                                    { fg = "red", bold = true })
mud.style([[.* exclaims.*: Let there be light!]],                                        { fg = "red", bold = true })

-- MVC — Mama Voojas Curse
mud.style([[.* looks contemplative\.]],                                                  { fg = "red", bold = true })
mud.style([[.* clucks experimentally\.]],                                                { fg = "red", bold = true })
mud.style([[.* waves \w+ feather at you\.]],                                             { fg = "red", bold = true })

-- DKDD — Dk'Dg the Dagger
mud.style([[.* dances around in dizzying patterns\.]],                                   { fg = "red", bold = true })
mud.style([[.* sounds as if \w+ is choking on something\.]],                             { fg = "red", bold = true })
mud.style([[.* squeezes a human heart, blood running down \w+ arm\.]],                  { fg = "red", bold = true })
-- Note: ".* points at you." already added under KOF; duplicate in source, one call is sufficient.
mud.style([[.* screams: Avaunt, foul spirit!]],                                          { fg = "red", bold = true })

-- TPA — Triggered by Psychic Aura / Phylogenetic something
mud.style([[.* appears to be thinking about something\.]],                               { fg = "green" })
mud.style([[.* looks pensive for a few moments\.]],                                      { fg = "green" })
mud.style([[.* whispers something to .*self\.]],                                         { fg = "green" })
mud.style([[.* seems to be looking at something near you\.]],                            { fg = "green", bold = true })
mud.style([[.* blows some ash into the air around you\.]],                               { fg = "green", bold = true })
mud.style([[.* seems to be looking at something near .*self\.]],                         { fg = "green" })
mud.style([[.* stares at nothing much in the air around you\.]],                         { fg = "green", bold = true })
mud.style([[.* stares at nothing much in the air around .*self\.]],                      { fg = "green" })
mud.style([[.* scatters some ash around .*self\.]],                                      { fg = "green" })
mud.style([[.* concentrates for a moment\.]],                                            { fg = "green" })
mud.style([[.* appears to tense momentarily\.]],                                         { fg = "green" })

-- JPCT — highlight the portal object name (capture = 1)
-- Tintin: #sub {%i{a (mysterious|dirty) .*(door|archway|piece of fur)} is hanging in the air}
--              {<858>%1<898> is hanging in the air}
-- %i in tintin is case-insensitive flag — Rust regex: (?i)
mud.style([[(?i)(a (?:mysterious|dirty) .*(?:door|archway|piece of fur)) is hanging in the air]], { capture = 1, fg = "magenta" })
-- "glance enter door" and "look/go through the portal" subs
mud.style([[^You glance enter door and see:$]],                                          { fg = "magenta" })
mud.style([[^You look through the ((?:mysterious|dirty) .*(?:door|archway|piece of fur)):$]], { capture = 1, fg = "magenta" })
mud.style([[^You go through the ((?:mysterious|dirty) .*(?:door|archway|piece of fur))\.$]], { capture = 1, fg = "magenta" })

-- JPCT lifecycle (source: misc/high.tin lines 208-210, grouped under
-- `#nop JPCT;`). Portal forms / expires normally / pops out. The
-- %* in the source's "A %* solidifies" / "%* disappears" matches the
-- portal description (e.g., "burning bone archway", "glowing doorway").
mud.style([[^A .+ solidifies with a satisfying thump\.$]],          { fg = "green", bold = true })
mud.style([[^The portal disappears with a small clap of thunder\.$]], { fg = "red" })
mud.style([[^.+ disappears with a small pop of inrushing air\.$]],    { fg = "red" })

-- Optional audio cue when a JPCT portal solidifies (setting-gated,
-- mirrors the eff_drop_sound pattern in src/eff.lua).
mud.trigger([[.* solidifies with a satisfying thump\.]], function()
  if settings.get("jpct_create_sound") then
    mud.play_sound("mallard:ding-ding-high")
  end
end)

-- EHA2 — hyaline amulet melt feedback
mud.style([[^Your delicate hyaline amulet.*melts away]],                                 { fg = "cyan", bold = true })

-- Enchanting funnel feedback (actions dropped — only the visual highlights kept)
mud.style([[^The blue funnel sparkles and turns into a small yellow caterpillar\.$]],    { fg = "cyan", bold = true })
mud.style([[^The blue funnel spins slowly in mid-air, then vanishes with a small "pop!"$]], { fg = "cyan", bold = true })
mud.style([[^The funnel falls to the ground\.$]],                                        { fg = "cyan", bold = true })

-- CMSEQ staff catch / slip
mud.style([[^.* sails through a hole in the fabric of space and time and you catch it in .*\.$]], { fg = "green" })
mud.style([[^You tug gently on an arcane thread and hold up your .* hand for .* to sail into it\.$]], { fg = "green" })
mud.style([[^.* slips between the folds of reality\.$]],                                 { fg = "yellow" })
mud.style([[^.* you fail to hold on to it and it smacks you across the head and falls to the floor\.$]], { fg = "red", bold = true })

-- PMG — eyes glow color
-- NOTE: v1 limitation — original: @color_code{%1} colors the glow color name
-- dynamically. Here we use a fixed cyan for the captured color name.
mud.style([[^Your eyes start to glow (.+?)\.$]],                                         { capture = 1, fg = "cyan" })

-- RTFM — luxurious coloured armchair
-- NOTE: v1 limitation — original: @color_code{%1} colors the armchair color
-- name dynamically. Here we use a fixed cyan for the captured color name.
mud.style([[luxurious (.+?)-coloured armchair]],                                         { capture = 1, fg = "cyan" })
mud.style([[luxurious (.+?) armchair]],                                                  { capture = 1, fg = "cyan" })

-- ---------------------------------------------------------------------
-- === broomstick.tin — broomstick fuel level ===
-- ---------------------------------------------------------------------
-- Source: #sub rules colour-grade the trip-count phrase via
-- @broom_color{N}. Mapping (from the broom_color #function): 0=bold red,
-- 1=red, 2=yellow, 3=green, 4=bold green. broom_capacity returns 3 for
-- non-iron brooms; the four-trip case covers iron broomsticks.
--
-- NOTE: v1 limitation — the original /set_broomstick_level dynamically
-- recolours the broom's own name in the inventory line based on the
-- remaining charge count. v1 Mallard has no state-driven-sub API, so
-- that runtime recolouring is dropped here.

mud.style([[^You are not strong enough to fuel the broom with that much power\.$]], { fg = "red" })

mud.style([[^You shake .+ vigorously and from the sloshing inside you guess that there is fuel enough for (one trip)\.$]],    { capture = 1, fg = "red" })
mud.style([[^You shake .+ vigorously and from the sloshing inside you guess that there is fuel enough for (two trips)\.$]],   { capture = 1, fg = "yellow" })
mud.style([[^You shake .+ vigorously and from the sloshing inside you guess that there is fuel enough for (three trips)\.$]], { capture = 1, fg = "green" })
mud.style([[^You shake .+ vigorously and from the sloshing inside you guess that there is fuel enough for (four trips)\.$]],  { capture = 1, fg = "light green" })

mud.style([[^You shake .+ vigorously and from the sloshing inside you guess that there is (not enough fuel for even a single flight)\.$]], { capture = 1, fg = "red", bold = true })
mud.style([[^You shake .+ vigorously and, from the complete lack of sloshing inside, deduce that it's (quite empty)\.$]],                   { capture = 1, fg = "red", bold = true })

-- ---------------------------------------------------------------------
-- === gfr.tin — Gryntard's Feathery Reliever (lightness) ===
-- ---------------------------------------------------------------------
-- Source: three #high rules in {bold cyan} for the lightness-state
-- feedback lines. The companion #action rules track per-target start
-- time and emit a "GFR lasted ..." showme on expiry — that requires
-- state tracking and is out of scope here; only the highlights are
-- ported.

mud.style([[^.+ seems a bit lighter than before\.$]],      { fg = "cyan", bold = true })
mud.style([[^.+ seems like it will stay light longer\.$]], { fg = "cyan", bold = true })
mud.style([[^.+ becomes heavy again\.$]],                  { fg = "cyan", bold = true })

-- ---------------------------------------------------------------------
-- === obbk.tin — Old Bellicus' Brazen Knuckles (humming intensity) ===
-- ---------------------------------------------------------------------
-- Source: five #high rules with escalating tintin <NNN> colour codes
-- for the knuckle-humming feedback during an OBBK cast. The original
-- codes use a mix of standard and extended-palette sequences whose
-- precise rendering is hard to reproduce in v1; ported as a clean
-- intensity gradient (cyan → bold cyan → yellow → bold yellow → bold
-- red) that tracks the soft → strongly → loudly → vibrate → blurred
-- escalation.

mud.style([[^Your knuckles hum softly\.$]],                                   { fg = "cyan" })
mud.style([[^You feel your knuckles hum strongly\.$]],                        { fg = "cyan", bold = true })
mud.style([[^Your knuckles hum loudly\.$]],                                   { fg = "yellow" })
mud.style([[^Your knuckles hum so loudly your fists vibrate\.$]],             { fg = "yellow", bold = true })
mud.style([[^Your fists are blurred with your knuckles' intense humming\.$]], { fg = "red", bold = true })

-- ---------------------------------------------------------------------
-- === fnp.tin — Fyodor's Nimbus of Porterage (cloud) ===
-- ---------------------------------------------------------------------
-- Source: two #high rules in {cyan} for cloud-form / cloud-dissipate
-- messages, plus a dynamic #sub that recoloured cloud-name words to
-- match the cloud's stated colour via @color_code{%3} (and a similar
-- sub for the "<colour> cloud is floating in the air here" inventory
-- line).
--
-- NOTE: v1 limitation — the dynamic per-colour-name subs are not
-- ported; v1 Mallard has no @color_code equivalent (same situation as
-- klein's pattern-name colours and other.tin's PMG / RTFM rules). The
-- form / dissipate lines still get a uniform cyan highlight.

mud.style([[^A .+ cloud forms in front of you\.$]],                { fg = "cyan" })
mud.style([[^The .+ cloud gently dissipates into nothingness\.$]], { fg = "cyan" })

-- ---------------------------------------------------------------------
-- === magic.tin — giant-fruitbat hunger alert ===
-- ---------------------------------------------------------------------
-- Source: single #high rule (bold red) that flags when a summoned
-- giant fruitbat is about to wander off looking for food. The #action
-- half (bell + /speak alert) is intentionally not ported — sound /
-- audible side-effects are out of scope, matching the other.tin
-- convention.

mud.style([[.+ the giant fruitbat .* (?:hungrily|peckish|hungry|anxiously)\.$]], { fg = "red", bold = true })

-- ---------------------------------------------------------------------
-- === contemplation completion — zero gp on trance exit ===
-- ---------------------------------------------------------------------
-- "You emerge from your trance." fires when a spell contemplation ends
-- (natural completion OR interruption — movement, combat, etc.). In both
-- cases gp drops to 0, but the server doesn't push a fresh Char.Vitals
-- frame. Port of Quow's HandleContemplateEnd (QuowMinimap.xml:22990): on
-- emerge, force gp=0 in the vitals mirror via a cross-plugin event.
--
-- The trigger is armed only between contemplate-start and emerge so the
-- phrase can't misfire on stray text (mirrors Quow's pattern of enabling
-- the ContemplateEnd trigger from ContemplateStart). Idle state ignores
-- emerge lines entirely.

local contemplating = false

mud.trigger([[^With .+ at the forefront of your mind, you enter a deep trance\.$]], function()
  contemplating = true
end)

mud.trigger([[^You emerge from your trance\.$]], function()
  if not contemplating then return end
  contemplating = false
  events.emit("net.mallard.discworld.gp.zero", {
    subject = "self",
    reason  = "trance_emerge",
  })
end)

-- ---------------------------------------------------------------------
-- === spell names — wizard + witch ===
-- ---------------------------------------------------------------------
-- Ported from Quack's MUSHclient SpellHighlights plugin
-- (https://quack.vnsf.xyz/SpellHighlights.xml). Each entry recolors just
-- the spell name wherever it appears in a line (capture = 1).
--
-- Color tiers (MUSHclient custom_colour → Mallard fg):
--   "7" offensive / aggressive    → red, bold
--   "3" defensive / support        → green
--   "4" standard / utility         → cyan

-- Colour + size are registered as SEPARATE, non-overlapping rules:
--   * colour: a capture=1 `mud.style` on the bare name — applies wherever
--     the name appears (cast messages, chat, the `spells` listing).
--   * size:   a capture=1 `mud.replace` that appends " (N)", but ONLY when
--     the name is followed by 2+ spaces or end-of-line — i.e. the columnar
--     `spells` listing. That keeps sentences like "You prepare to cast
--     <name> on yourself." (single trailing space) size-free. The size
--     targets the trailing whitespace (group 1), which is DISJOINT from the
--     name's colour range, so both mods apply. (Folding colour+size into
--     one rewrite would tag the name EVERYWHERE; two rules let us gate the
--     size without losing the always-on colour.)
--
-- Tier styles + the curated name lists live in src/spell_tiers.lua, shared
-- read-only with /mindspace so the card can colour names identically. See
-- that file re: Mallard's non-caching `require` (why it must be static data).
local spell_tiers  = require("spell_tiers")
local ms_spelldata = require("spelldata")
local SPELL_SIZE = {}
for _, s in pairs(ms_spelldata) do
  if type(s.name) == "string" and s.name ~= "" then SPELL_SIZE[s.name] = s.size end
end

local function ms_escape(s)
  return (s:gsub("([%(%)%[%]%{%}%.%*%+%-%?%^%$%|\\])", "\\%1"))
end

local function highlight(name, style)
  local esc = ms_escape(name)
  -- Colour the name wherever it appears.
  local sopts = { capture = 1 }
  for k, v in pairs(style) do sopts[k] = v end
  mud.style("(" .. esc .. ")", sopts)
  -- Append its mindspace size, but only inside the columnar `spells`
  -- listing — i.e. the name sits at a COLUMN boundary: preceded by
  -- start-of-line or 2+ spaces, AND followed by 2+ spaces or end-of-line.
  -- Both sides matter: gating only the trailing side still tagged spell
  -- names at the end of chat lines ("... wisps: Endorphin's Floating
  -- Friend") — verified against real Discworld logs, where the leading
  -- boundary drops every such false positive to zero. The size rewrites
  -- the trailing whitespace (group 1), disjoint from the name's colour
  -- restyle above, so both apply and adjacent columns stay independent.
  local size = SPELL_SIZE[name]
  if size then
    mud.replace("(?:^| {2,})(?:" .. esc .. ")( {2,}|$)", " (" .. size .. ")%1",
      { capture = 1, fg = "cyan" })
  end
end

for name, style in pairs(spell_tiers) do
  highlight(name, style)
end

-- Character-switch (`su`) detection. Owns magic's char.info subscription
-- and resets each shield module's stale self state on a name change. The
-- shield modules require this themselves and self-register their resets;
-- requiring it here as well makes the dependency explicit and guarantees
-- its subscription is wired even if module load order shifts.
require("char_switch")

-- Self shield-state recorder: persists the self shield grid per character
-- and replays it to consumers (vitals/grouping/…) on switch + relog, so
-- they need no shield persistence of their own. Required before the
-- shield modules so it's recording from the first event they emit.
require("shield_state")

-- EFF (Endorphin's Floating Friend) state tracking + drop banner.
-- See src/eff.lua for self + src/eff_others.lua for other players.
require("eff")
require("eff_others")

-- TPA (impact-shield state tracking + stream annotations) lives in its
-- own file; see src/tpa.lua. require() runs its top-level registrations
-- once, the same as the inline sections above.
require("tpa")

-- Other-player TPA state tracking + events. See src/tpa_others.lua.
require("tpa_others")

-- CCC (Chrenedict's Corporeal Covering) state tracking + dispel banner.
-- See src/ccc.lua for self + src/ccc_others.lua for other players.
require("ccc")
require("ccc_others")

-- Bugshield (insect cloud) state tracking + warn / gone / destroyed
-- banners. See src/bug.lua for self + src/bug_others.lua for others.
require("bug")
require("bug_others")

-- Major Shield (divine protection) state tracking + expiry banner.
-- Self-only — Quow's only other-player MS line is a look-at status
-- report that doesn't carry a player name on the line itself.
require("ms")

-- `group shields` / `protections X` output parser. Attributes the
-- anonymous "* He is surrounded by ..." / "* His skin ..." body lines
-- to whichever player most recently fired the "Arcane protection for
-- X:-" header.
require("protection_report")

-- "magic stuff" / "portal failures" / "octograving" `#high` rules from
-- ~/code/3p/tt_dw/scripts/misc/high.tin — buff lifecycles (TMC, UPDD,
-- CBB, PMG, KOF, OBBK, BUU, GRG, GRTW, WGS, FTF, Hag's), portal-traversal
-- warnings, and necromancy-circle activation. See src/high.lua header
-- for the full rationale + skipped-rule list.
require("high")

-- `/spell` lookup command — ported subset of tt_dw's /spell. Baked spell
-- data lives in src/spelldata.lua; command surface + formatting lives in
-- src/spell.lua. v1 covers nickname / name / description lookups and a
-- type-grouped multi-column list view; TM/spellcheck path is deferred
-- (it needs the player's skill levels, which aren't in scope here).
require("spell")

-- Mindspace tracking + annotations — ports tt_dw's spellsizes.tin +
-- tip_mindspace. Tracks total available mindspace (magic.spells.special
-- bonus + 30, via discworld-vitals' skill snapshot) and the set of spells
-- you know (from the `spells` listing + remember/forget), annotates the
-- listing with per-spell sizes and a colour-coded used/total summary, and
-- exposes `/mindspace`. NB: unrelated to src/ms.lua (Major Shield).
require("mindspace")

-- /eff (wizard shields) + /gshg (witch utensils) weight-efficiency calculator.
require("eff_check")
