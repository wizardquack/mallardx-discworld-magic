# Discworld Magic

A Mallard port of six `~/code/3p/tt_dw/scripts/magic/` colour files
— highlights and inline annotations for Discworld magic spell output
(enchantment levels, Klein-bottle energy, Earhammer / PfG damage,
Delude shadow depth, and other people's offensive casts).

## What it does

- Uses `mud.replace(pattern, template, { fg = "color" })` to insert inline
  scale annotations into spell-feedback lines (e.g. "It radiates pure
  octarine brilliance" → "It radiates pure octarine brilliance (91-100%)").
- Uses `mud.style(pattern, { fg = "color" })` for whole-line recolors that
  mirror `#HIGH` rules in the source files.
- Uses `mud.style(pattern, { capture = N, fg = "color" })` for
  capture-targeted recolors (e.g. portal name in a room, armchair color word).
- World-matched to `discworld.starturtle.net:*` — triggers are only installed
  when the active world is Discworld.

## Source files and what each contributes

| Source file    | Rules ported | What it highlights |
|----------------|--------------|--------------------|
| `enchant.tin`  | 28 `#sub`    | Enchantment level (1–100 %) on items + thaum density of the room |
| `klein.tin`    | 11 `#sub` + 5 `#sub` (capture) | Klein-bottle accumulated energy level + sphere pattern name |
| `eha.tin`      | 6 `#sub`     | Earhammer damage band (<15 % … >90 %) |
| `pfg.tin`      | 6 `#sub`     | Protection-From-Fire damage band (<15 % … >90 %) |
| `delude.tin`   | 5 `#sub` + 2 `#high` | Delude octarine-shadow depth (1/5 … 5/5) + deepens/fades |
| `other.tin`    | 36 `#high` + 7 `#sub` | Other people's offensive casts (KOF, NES, MVC, DKDD, TPA), JPCT portals, funnel/staff feedback |
| `eff.tin`      | 1 `#high` + 7 triggers | Endorphin's Floating Friend: bold-red "In blocking the attack" + state tracking (orbits, knocked out, dispelled, chain counterwise dance) with a magenta "*** Floater down! ***" banner. Combat-block counter intentionally omitted (lives in tt_dw's `combat.tin` framework). Debug: `!eff`. |
| Quack's `SpellHighlights.xml` | 116 triggers | Wizard + witch spell names, recolored by offensive (bold red) / defensive (green) / standard (cyan) |
| `misc/high.tin` (magic blocks) | ~25 `#high` | Spell-effect lifecycles (TMC / UPDD / CBB / PMG / KOF / OBBK buff / Hag's / BUU / GRG / GRTW / WGS / FTF), portal-traversal warnings (`It is burning` / `rumbling sound`), and necromancy octogram activation. The non-magic remainder of `misc/high.tin` is ported in `discworld-misc/src/high.lua`. |

## Translation rules

| Tintin token | Rust regex  |
|--------------|-------------|
| `%*`         | `.*`        |
| `{a\|b\|c}`  | `(?:a\|b\|c)` |
| `%1`, `%2`, … | `(.+?)` capture groups (left-to-right) |
| `%.`         | `.`         |
| `%w`         | `\w+`       |
| `^…$`        | stays `^…$` |

## Omissions and v1 limitations

- **`#action` rules dropped** — the source files contain side-effect actions
  (sound playback, `/hold`, `/unhold` item management). These are not visual
  highlights and are intentionally excluded from this plugin.
- **`@color_code{%1}` dynamic coloring** — two subs in `other.tin` (`PMG`:
  "Your eyes start to glow %1." and `RTFM`: "luxurious %1-coloured armchair")
  and five subs in `klein.tin` (sphere "tracing a %* pattern") used
  `@color_code{%1}` to dynamically color a captured word in its own color.
  Function-valued `fg` (shipped 2026-05-29 with the match-object API) now
  makes this expressible — `mud.style(pattern, { capture = 1, fg = function(m) return m[1] end })`
  routes the capture through the colour-name resolver. These call sites
  still carry the original `NOTE: v1 limitation` comments in `src/main.lua`
  and were not migrated as part of the API redesign; a follow-up pass will
  swap them to the dynamic form.

## Cross-plugin events

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

(Prior to 2026-05-28 these were `net.mallard.discworld.{tpa,eff}.{up,down}`.
The unified surface was introduced alongside the discworld-grouping
shield-row work — see
`docs/superpowers/specs/2026-05-28-discworld-group-shields-design.md`.)

## Dev rebuild

```sh
bash scripts/reinstall.sh
```
