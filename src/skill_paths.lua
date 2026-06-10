-- Short skill name → full dotted skill path. Mirrors tt_dw's
-- `spellskills` table (~/code/3p/tt_dw/scripts/magic/spelldata.tin).
--
-- Spellcheck rows in spelldata.lua key skills by short name (e.g.
-- "summoning", "chanting"); the snapshot we get from discworld-vitals'
-- `net.mallard.discworld.skills.updated` event keys skills by full
-- dotted path (e.g. "magic.methods.spiritual.summoning"). This map
-- bridges the two so /spell can pull a current level/bonus per stage.

return {
  -- magic.methods.elemental
  air         = "magic.methods.elemental.air",
  earth       = "magic.methods.elemental.earth",
  fire        = "magic.methods.elemental.fire",
  water       = "magic.methods.elemental.water",
  -- magic.methods.mental
  animating   = "magic.methods.mental.animating",
  channeling  = "magic.methods.mental.channeling",
  charming    = "magic.methods.mental.charming",
  convoking   = "magic.methods.mental.convoking",
  cursing     = "magic.methods.mental.cursing",
  -- magic.methods.physical
  binding     = "magic.methods.physical.binding",
  brewing     = "magic.methods.physical.brewing",
  chanting    = "magic.methods.physical.chanting",
  dancing     = "magic.methods.physical.dancing",
  enchanting  = "magic.methods.physical.enchanting",
  evoking     = "magic.methods.physical.evoking",
  healing     = "magic.methods.physical.healing",
  scrying     = "magic.methods.physical.scrying",
  -- magic.methods.spiritual
  abjuring    = "magic.methods.spiritual.abjuring",
  banishing   = "magic.methods.spiritual.banishing",
  conjuring   = "magic.methods.spiritual.conjuring",
  divining    = "magic.methods.spiritual.divining",
  summoning   = "magic.methods.spiritual.summoning",
  -- magic.items.held
  wand        = "magic.items.held.wand",
  rod         = "magic.items.held.rod",
  staff       = "magic.items.held.staff",
  -- magic.items.worn
  amulet      = "magic.items.worn.amulet",
  ring        = "magic.items.worn.ring",
  -- magic.items
  talisman    = "magic.items.talisman",
  -- crafts (some spells use craft skills as components)
  gold        = "crafts.smithing.gold",
  silver      = "crafts.smithing.silver",
  turning     = "crafts.carpentry.turning",
  whittling   = "crafts.carpentry.whittling",
  herbal      = "crafts.husbandry.plant.herbal",
  shaping     = "crafts.pottery.forming.shaping",
  weaving     = "crafts.materials.weaving",
}
