-- "magic stuff" / "portal failures" / "octograving" highlight blocks
-- from tt_dw's ~/code/3p/tt_dw/scripts/misc/high.tin.
--
-- These bands of `#high` rules live in misc/high.tin upstream but cover
-- spell effects, portal-traversal feedback, and necromancy-circle
-- activation — so they belong here, in discworld-magic, rather than
-- discworld-misc/src/high.lua (which gets the rest of misc/high.tin).
--
-- Skipped:
-- - JPCT solidifies / disappears (already covered in main.lua under
--   the JPCT lifecycle section — see lines 250-252 there).
-- - `#sub {^You prepare to cast %1 %2 %3.$}` and KOF fire-bunnies subs:
--   both route through tintin's `@_spell_target{}` macro to recolour
--   the captured target's name, which has no Mallard analog.
-- - The nugget rule's `#act` half (`/speak Your nugget is now %2.`)
--   matches the discworld-magic convention of dropping audible
--   side-effects; only the visual recolour is ported.

-- The X nugget flickers and goes Y. (Pridelight readout). Upstream
-- wraps both colour words in fixed (not @color_code) palette entries,
-- so we apply static fg via the per-target `captures = { [N] = {...} }`
-- form to colour them differently.
mud.style([[^The (.+) nugget flickers and goes (.+)\.$]], {
  captures = {
    [1] = { fg = "yellow" },
    [2] = { fg = "magenta", bold = true },
  },
})

-- Sourcery imp returns home (`bold red`).
mud.style([[^The imp waves and departs for its own dimensions\.$]], { fg = "red", bold = true })

-- Imp sentry vocalisation (`b red` = bg red, default fg).
mud.style([[^The imp cries out excitedly:]], { bg = "red" })

-- Torqvald's Many Colours (TMC) end.
mud.style([[^You feel suddenly colourless\.$]], { fg = "magenta" })

-- Undirected Pest Distraction Display (UPDD) end — moth vanishes.
mud.style([[^The tiny .* moth vanishes in a gout of .* flame\.$]], { fg = "magenta" })

-- Calming Bouquet of Blossoms (CBB) end — strange flame dies.
mud.style([[^The strange .* flame flickers and dies\.$]], { fg = "magenta" })

-- Pragi's Molten Gaze (PMG) end — eyes return.
mud.style([[^Your eyes return to normal\.$]], { fg = "magenta" })

-- Kamikaze Oryctolagus Flammula (KOF) — fiery-carrot expiry. Upstream
-- attaches `{4}` priority to this rule; Mallard's surface doesn't
-- expose trigger priority at this layer, so the hint is dropped.
mud.style([[^The fiery carrot above .* flickers and goes out\.$]], { fg = "magenta" })

-- Finneblaugh's Thaumic Float (FTF) — float / land.
mud.style([[^You float gently off the ground\.$]],  { fg = "cyan", bold = true })
mud.style([[^Your feet touch the ground again\.$]], { fg = "cyan", bold = true })

-- Old Bellicus' Brazen Knuckles (OBBK) buff lifecycle — initiation /
-- mid-buff status / wear-off. Distinct from the *during-cast humming*
-- ladder ported from obbk.tin in main.lua (which fires while attacking).
mud.style([[^Your knuckles become slightly brassier\.$]],      { fg = "yellow", bold = true })
mud.style([[^Your knuckles become brassy, and seem to hum ]],  { fg = "yellow", bold = true })
mud.style([[^Your knuckles return to their natural state\.$]], { fg = "yellow", bold = true })

-- Hag's Blessing end — fireflies disperse.
mud.style([[^The swarm of fireflies buzzes off\.$]], { fg = "magenta" })

-- Banishing of Unnatural Urges (BUU) — resolve up / down.
mud.style([[^You feel more able to withstand temptation\.$]],   { fg = "red" })
mud.style([[^Your resolve to withstand temptation weakens\.$]], { fg = "red" })

-- Grisald's Reanimated Guardian (GRG) — corpse / skeleton lifecycle.
mud.style([[^The corpse of .* crumbles and rots before your very eyes\.$]],        { fg = "red" })
mud.style([[^The corpse animates, but you lose your control over the skeleton!$]], { fg = "red", bold = true })
mud.style([[^You mentally take control of the skeleton\.$]],                        { fg = "green", bold = true })
mud.style([[^The skeleton warrior dissolves into dust\. .*]],                       { fg = "red", bold = true })

-- Gillimer's Ring of Temperate Weather (GRTW).
mud.style([[^You feel protected from the elements\.$]], { fg = "green" })

-- Wizard's Greater Strength (WGS) — vitality wave.
mud.style([[^You feel vitality course through your veins\.$]], { fg = "green" })

-- ───────────────────────────────────────────────────────────────
-- Portal failures — magic-circle / room state warnings when traversing
-- a portal in poor condition. Fragment matches (no anchors) — these
-- phrases appear mid-sentence in different failure descriptions.
-- ───────────────────────────────────────────────────────────────

mud.style([[(It is burning)]],   { capture = 1, fg = "red", bold = true })
mud.style([[(rumbling sound)]],  { capture = 1, fg = "red", bold = true })
mud.style([[(rumbles faintly)]], { capture = 1, fg = "red", bold = true })

-- ───────────────────────────────────────────────────────────────
-- Octograving — necromancy circle activation feedback.
-- ───────────────────────────────────────────────────────────────

mud.style([[^An octogram begins to glow on the .*\.$]],            { fg = "magenta" })
mud.style([[^The octogram pulses for a moment\.$]],                { fg = "magenta" })
mud.style([[^An octogram on the .* glows in eldritch fashion\.$]], { fg = "magenta" })
