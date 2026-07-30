-- Baked candidate floater items for the /eff (shields) and /gshg (utensils)
-- weight-efficiency calculator. Ported verbatim from tt_dw
-- scripts/tips/floaters.tin (materials dropped — unused by the calc/output).
-- Each list is ordered ascending by weight.
--
-- Side-effect-free data module: a bare return, safe under Mallard's
-- non-caching require.

return {
  shields = {
    { name = "small wooden shield",            weight = 2 },
    { name = "wooden Djelian shield",          weight = 2.444 },
    { name = "small metal shield",             weight = 3.888 },
    { name = "Ephebian round shield",          weight = 4.333 },
    { name = "medium wooden shield",           weight = 4.777 },
    { name = "medium bone shield",             weight = 5.333 },
    { name = "crescent moon shield",           weight = 6.222 },
    { name = "antique round shield",           weight = 6.666 },
    { name = "thousand rose shield",           weight = 7.222 },
    { name = "medium metal shield",            weight = 7.666 },
    { name = "slice of black pudding",         weight = 7.777 },
    { name = "portable running water shield",  weight = 8.111 },
    { name = "large wooden shield",            weight = 8.666 },
    { name = "oval bronze shield",             weight = 9.111 },
    { name = "black iron shield",              weight = 10.111 },
    { name = "three star shield",              weight = 11 },
    { name = "large metal shield",             weight = 11.444 },
    { name = "Tsortean metal shield",          weight = 12 },
    { name = "emerald studded shield",         weight = 12.444 },
    { name = "ornate bone shield",             weight = 12.888 },
    { name = "sapphire studded shield",        weight = 13.333 },
    { name = "bronze tower shield",            weight = 13.888 },
    { name = "Klatchian steel tower shield",   weight = 14.333 },
    { name = "enormous spider carapace",       weight = 15.333 },
    { name = "giant turtle shell",             weight = 17.222 },
  },
  utensils = {
    { name = "potato peeler",         weight = 0.222 },
    { name = "old iron saucepan",     weight = 0.555 },
    { name = "small B'cket's bucket", weight = 1.555 },
    { name = "meat cleaver",          weight = 1.777 },
    { name = "large bucket",          weight = 2.444 },
    { name = "deluxe steel pan",      weight = 2.666 },
    { name = "rolling pin",           weight = 3.333 },
    { name = "crystal ladle",         weight = 3.888 },
    { name = "antique washing dolly", weight = 4.222 },
    { name = "small cauldron",        weight = 4.444 },
    { name = "large battered kettle", weight = 4.666 },
    { name = "frying pan",            weight = 5 },
    { name = "flatiron",              weight = 6.111 },
    { name = "coal scuttle",          weight = 7 },
    { name = "giant spatula",         weight = 8 },
    { name = "plain washboard",       weight = 8.888 },
    { name = "majmar",                weight = 9.444 },
    { name = "old rusty saucepan",    weight = 10 },
    { name = "huge bucket",           weight = 15.111 },
    { name = "enormous bucket",       weight = 28.444 },
  },
}
