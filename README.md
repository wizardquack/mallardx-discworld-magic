# Discworld Magic

Colour highlights and inline annotations for Discworld magic spell output
(enchantment levels, Klein-bottle energy, Earhammer / PfG damage,
Delude shadow depth, and other people's offensive casts).

Also tracks magic states/events and emits relevant events for other
interested plugins to consume. Two initial consumers are the
discworld-grouping plugin, and the discworld-vitals plugin, both of
which can display richer magical shielding info if you also have this
plugin installed and active.

## `/spell` — spell info lookup

A `/spell` slash command for the ~115 Discworld spells.

```
/spell              list every spell, grouped by type, in columns
/spell <nick>       full info card — e.g. /spell wgs
/spell <fragment>   fuzzy match across nick / name / description
/spell help         usage banner
```

The full card shows name, type, GP, casting size, components, tome,
and the per-stage spellcheck table — each threshold cell colour-coded
so you can see at a glance which bonus tier you'd land in. Nicks in
list views are clickable; they drill straight into the full card.

With [discworld-vitals](https://github.com/wizardquack/mallardx-discworld-vitals)
installed and a snapshot captured (run its `/skills-refresh`), the
spellcheck table gains four extra columns per stage: success chance,
your current level + bonus in the stage's skill, and a hint at the
bonus delta needed to reach the next chance tier.

## Cross-plugin events in depth

This plugin emits `net.mallard.discworld.shield.up` and
`net.mallard.discworld.shield.down` for both self and other-player
shield state changes. Payload shape:

```
subject  = "self" | "<PlayerName>"
type     = "tpa" | "eff" | "ccc" | "bug" | "ms"
# optional, populated by type:
percent, glow, previous_glow, previous_percent  -- tpa
item                                            -- eff
hits, duration_seconds                          -- tpa (and eff for self)
silent                                          -- eff (intentional drops)
```

v1 implements TPA and EFF for both subjects. CCC/BUG/MS are reserved in
the event grammar and will be added in a follow-up plan.

Consumers today:
- `discworld-vitals` — self-only; filters by `subject == "self"` and
  drives the EFF indicator + TPA stat cells.
- `discworld-grouping` — self + other; drives the five-pill shield row
  per group member.
