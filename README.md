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
/spell <skill>      every spell that checks that skill — e.g. /spell fire
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

## `/spellskill` — spells by skill

The inverse lookup. `/spell wgs` asks *what skills does this spell check?*;
`/spellskill fire` asks *what spells check fire, and how close am I to each?*

```
/spellskill <skill>       spells checking that skill, likeliest cast first
/spellskill <skill> tm    same rows, ordered by TM likelihood
/spellskill help          usage banner + the list of skills spells check
```

Aliased to `/ss`. `/spell <skill>` reaches the default view too — the
dedicated command is how you get the `tm` ordering.

```
Spells using fire (16 spells, 17 stages)
  Bonus: 150   Level: 128   Ordered by: success chance
  nick   Spell                             Stage  Chance  Max   Need  Consumes
  fnp    Fyodor's Nimbus of Porterage        2/6     90%  160   +10b  -
  kof    Kamikaze Oryctolagus Flammula       2/4     90%  160   +10b  yes
  kof    Kamikaze Oryctolagus Flammula       4/4     90%  160   +10b  yes
  ...
```

- **One row per stage, not per spell.** A spell can check the same skill
  at two different stages with different thresholds (`kof` above), and the
  stage is what you're actually graded on. `Stage` reads *this stage / the
  spell's total*.
- **`Chance`** is the same math as the `/spell` card's spellcheck table —
  how many of the stage's ten thresholds your bonus clears. **`Max`** is
  the bonus for `>99%`, and **`Need`** the delta to it.
- **`Consumes`** flags whether casting costs you a component. Spells
  needing a *reusable* prop (a staff, a mirror) read `-` alongside those
  needing nothing at all — the column asks what a cast costs, not what it
  requires.
- Your bonus is constant down the listing (it's one skill), so it sits in
  the header rather than repeating in a column.
- Nicks are clickable and drill into the full `/spell` card.

`tm` ordering ranks by `p × (1−p)`, so the stages nearest a coin-flip —
where a teaching moment is likeliest — float to the top. Without a
`/skills-refresh` snapshot both modes drop the chance columns and fall
back to a max-bonus ladder, cheapest to master first.

## `/mindspace` — spell-memory budget

Wizards and witches can only hold so many spells in their head at once:
each spell has a *size* (its Mindspace cost), and the sum of your known
spells' sizes may not exceed your available mindspace — which is your
`magic.spells.special` bonus + 30.

This plugin tracks both halves and annotates the `spells` command:

- **Per-spell sizes.** In the `spells` listing, each spell name is tagged
  with its mindspace cost (e.g. `Wungle's Great Sucking (35)`). The tag is
  gated to a column boundary — the name must sit at line start or after 2+
  spaces *and* be followed by 2+ spaces or line end — so it only fires in
  the columnar listing. Ordinary prose ("You prepare to cast … on
  yourself.") and chat mentions stay untagged (verified against real game
  logs). Spell names keep their usual by-tier colour everywhere.
- **Total summary.** After the listing settles, a colour-coded line —
  `Total spell size: 337 / 415  (78 free)` — reports how much of your
  mindspace you're using (green under budget, yellow at exactly full,
  red over).
- **`/mindspace`** (alias `/mind`) prints an on-demand breakdown: your
  available capacity, used size, and every known spell sorted
  largest-first so the mindspace hogs are obvious.

The known-spell set is seeded from the `spells` listing and kept live by
`remember` / `forget` lines, then persisted per character — so
`/mindspace` stays accurate between listings and across relogs. Running
`spells <category>` re-scopes only that category, leaving the others
intact.

The available-mindspace total comes from
[discworld-vitals](https://github.com/wizardquack/mallardx-discworld-vitals)'
skill snapshot (run its `/skills-refresh` once). Without it, sizes and the
used total still work — only the capacity figure is withheld, with a nudge
to refresh.

On every change the plugin emits `net.mallard.discworld.mindspace.updated`
`{ charname, total, used, free, known_count }` (`total`/`free` are `nil`
until a skill snapshot lands) so other plugins can surface the budget.

> Not to be confused with Major Shield (divine "ms" protection), which
> this plugin also tracks separately.

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

## Credit

Many thanks to Quow and Oki, whose work on similar plugins was
invaluable in designing and building this one. `/spellskill`'s TM
ordering follows tt_dw's `/spell_tm_list`.
