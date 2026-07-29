-- Discworld Magic — curated spell-name -> tier highlight style.
--
-- Ported from Quack's MUSHclient SpellHighlights plugin
-- (https://quack.vnsf.xyz/SpellHighlights.xml). Tiers:
--   offensive / aggressive -> red, bold
--   defensive / support    -> green
--   standard  / utility     -> cyan
--
-- This is STATIC DATA, deliberately not a populate-on-load registry.
-- Mallard's plugin `require` re-evaluates a module on every call and does
-- NOT cache it (see the host sandbox), so main.lua and mindspace.lua each
-- get their own COPY. That is fine here precisely because the data is
-- deterministic and read-only: both copies are identical. Do NOT turn this
-- back into a `set()`/`get()` registry — writes from one file would never
-- be visible to another (they would land in separate instances), which is
-- exactly the bug that made /mindspace show no colours.
--
-- main.lua iterates this map to register the per-name colour + size rules;
-- src/mindspace.lua reads it to colour spell names in the /mindspace card
-- with the SAME in-game tier colour.

local OFFENSIVE = { fg = "red", bold = true }
local DEFENSIVE = { fg = "green" }
local STANDARD  = { fg = "cyan" }

local GROUPS = {
  { style = OFFENSIVE, names = {
    [[Calm Embrace of Illusionary Beauty]],
    [[Doctor Kelleflump's Deadly Demon]],
    [[Effermhor's Hypersonic Assault]],
    [[Fiddelmaker's Auriferous Embrace]],
    [[Frygellhan's Fiendish Orbit Disruptor]],
    [[G'flott's Olfactory Nightmare]],
    [[Journey of the Heavenly Storm Dragon]],
    [[Kamikaze Oryctolagus Flammula]],
    [[Kelleflump's Irritating Demon]],
    [[Malich's Penetrating Ocular Lance]],
    [[Memories of a Vicious Chicken]],
    [[Mugwuddle's Muddling Mirage]],
    [[Myrandil's Vicious Seizure]],
    [[Nargl'frob's Empyrean Spear]],
    [[Narquin's Mist of Doom]],
    [[Old Bellicus' Brazen Knuckles]],
    [[Pragi's Fiery Gaze]],
    [[Pragi's Lost Gaze]],
    [[Reckless Encouragement of Arcane Peacock]],
    [[Rugged Victor's Rodentia Vivisection]],
    [[Skeetbraskin's Fuliginous Perdition]],
    [[Sorsalsean's Seismic Eruption]],
    [[Stacklady's Morphic Resonator]],
    [[Von Hasselhoff's Skin Condition]],
    [[Wonker's Wicked Wobble]],
    [[Wungle's Body Part Suggestion]],
    [[Wungle's Great Sucking]],
    [[Gammer Shorga's Helpful Undergrowth]],
    [[Mother Brynda's Call of Gravity]],
    [[Mother Feelbright's Busy Bees]],
  } },
  { style = DEFENSIVE, names = {
    [[Chrenedict's Corporeal Covering]],
    [[Endorphin's Floating Friend]],
    [[Grisald's Reanimated Guardian]],
    [[Heezlewurst's Elemental Buffer]],
    [[Kipperwald's Perlustration Prevention]],
    [[Sageroff's Sentry Summoning]],
    [[Sorklin's Field of Protection]],
    [[Transcendent Pneumatic Alleviator]],
    [[Banishing of Prying Eyes]],
    [[Banishing of Unnatural Urges]],
    [[Grammer Scorbic's Household Guard]],
    [[Mama Kolydina's Instant Infestation]],
  } },
  { style = STANDARD, names = {
    [[A Cup of Tea and Sake]],
    [[Al'Hrahaz's Scintillating Blorpler]],
    [[Amazing Silicate Blorpler]],
    [[Atmospheric Inscription Wonder]],
    [[Bifram's Amazing Fireworks]],
    [[Booch's Extremal Polymorphism]],
    [[Boolywog's Forbidden Pleasures]],
    [[Brassica Oleracea Ambulata]],
    [[Brother Happalon's Elementary Enchanting]],
    [[Cherry Blossoms in Bloom]],
    [[Collatrap's Instant Pickling Stick]],
    [[Crondor's Fabulous Detection]],
    [[Crondor's Marvellous Sequestration]],
    [[Crondor's Mysterious Sparkling]],
    [[Dismal Digit of Doom]],
    [[Doctor Worblehat's Flaming Primate Premonition]],
    [[Duander's Thaumic Luminosity Disperser]],
    [[Ellamandyr's Hyaline Amulet]],
    [[Eringyas' Surprising Bouquet]],
    [[Fabrication Classification Identification]],
    [[Feyfirkin's Errant Trainee Collection Herbage]],
    [[Finneblaugh's Thaumic Float]],
    [[Floron's Fabulous Mirror]],
    [[Friddlefrod's Hydratic Extrusion]],
    [[Fyodor's Nimbus of Porterage]],
    [[Gillimer's Ring of Temperate Weather]],
    [[Grisald's Chilly Touch]],
    [[Gryntard's Feathery Reliever]],
    [[Independent Recurring Vocaliser]],
    [[Jogloran's Portal of Cheaper Travel]],
    [[Jorodin's Magnificent Communicator]],
    [[Luquayle's Longevity-Enhancing Ballast]],
    [[Malich's AshkEnte Circle]],
    [[Malich's AshkEnte Summoning Incantation]],
    [[Master Glimer's Amazing Glowing Thing]],
    [[Master Woddeley's Luminescent Companion]],
    [[Myrandil's Mask of Death]],
    [[Narquin's Hand of Acquisition]],
    [[Objandeller's Thaumic Funnel]],
    [[Patient Taming of the Quantum Weather Butterfly]],
    [[Polliwiggle's Puissancy Probe]],
    [[Pragi's Molten Gaze]],
    [[Professor Flambardie's Grim Amulet]],
    [[Rubayak's Power Dispenser]],
    [[Rubayak's Power Storage]],
    [[Ralstorphine's Refreshing Draught]],
    [[Ridcully's Travelling Furniture Manufactory]],
    [[Scolorid's Scintillating Scribbling]],
    [[Thousand Dancing Celestial Fates]],
    [[Torqvald's Illusion Generatrix]],
    [[Torqvald's Many Colours]],
    [[Turnwhistle's Effulgent Autiridescence]],
    [[Union of the Phoenix and Divine Dragon]],
    [[Worstler's Advanced Metallurgical Glance]],
    [[Worstler's Elementary Mineralogical Glance]],
    [[Wurphle's Midnight Snack]],
    [[Wurphle's Packed Lunch]],
    [[Yordon's Extremal Extension]],
    [[Banishing of Loquacious Spirits]],
    [[Biddy Amble's Bee Buzzer]],
    [[Delusions of Grandeur]],
    [[Gammer Shorga's Clever Creeper]],
    [[Gammer Tumult's Amalgamator]],
    [[Goodie Whemper's Apple Divination]],
    [[Granny Beedle's Cooperative Credits]],
    [[Granny Benedict's Bond of Loyalty]],
    [[Granny Lipintense's Layer of Lard]],
    [[Hag's Blessing]],
    [[Mama Adena's Burden of Responsibility]],
    [[Mama Blackwing's Potent Preserver]],
    [[Mother Harblist's Fruity Flyer]],
    [[Mother Twinter's Yarrow Enchantment]],
    [[Nanny Revere's Traitorous Talisman]],
    [[Wee Flaudia's Fluffy Ear Muffs]],
  } },
}

-- Flat spell-name -> style map (pairs()-iterable; no extra keys).
local M = {}
for _, g in ipairs(GROUPS) do
  for _, name in ipairs(g.names) do M[name] = g.style end
end

return M
