-- Corpus test for the Bugshield patterns in src/bug_patterns.lua.
-- Run from project root: `lua tests/bug_regex_test.lua`.
--
-- The shared harness dispatches trigger callbacks directly and never
-- executes a pattern, which is the right call for behaviour tests but
-- leaves the regexes themselves unverified — and these regexes are the
-- entire bug that this module exists to fix. So this file checks them
-- against a corpus of real wire lines using ripgrep, which embeds the
-- same Rust `regex` crate Mallard compiles triggers with (see
-- src-tauri/src/engine/trigger.rs). Matching semantics are therefore the
-- host's, not a PCRE approximation: no lookaround, leftmost-first
-- alternation, line-anchored ^ and $.
--
-- Every line below is either observed in-game or a deliberate near-miss.
-- When adding a phrasing, add it here first and watch it fail.

package.path = "./src/?.lua;./tests/?.lua;" .. package.path
local P = require("bug_patterns")

local SELF_UP_HITS = {
  -- Reported verbatim from a live cast sequence.
  "The plague of assassin bugs begins to circle you slowly.",
  -- Size omitted entirely.
  "The assassin bugs begin to circle you slowly.",
  -- Plural verb agreement.
  "The plague of ladybirds begin to buzz around you happily.",
  -- Plural verb AND "about" rather than "around".
  "The plague of moths flutter into a chaotic formation about you.",
  -- Mood prefix containing its own comma — the old `[^,]+, ` could not
  -- span this one.
  "With a low, menacing buzzing, the cloud of gnats begins to circle you.",
  -- Longest known mood prefix.
  "With a buzzing sound so loud and meaty it's almost like a dog growling, the vast swarm of praying mantids flutters into a loosely-formed orbit around you, buzzing hungrily.",
  -- Species spellings that disagree between sources.
  "The cloud of mosquitos starts to hover near you.",
  "The plague of elephant bugs clusters haphazardly around you.",
  -- The remaining verb phrases Quow documents.
  "The vast swarm of bees forms a chaotic web of small white bodies around you.",
  "The handful of gnats begins to buzz erratically around you.",
  "The cloud of moths begins to cluster around you.",
  "The small swarm of bees begins to orbit you.",
  "The cloud of gnats begins to circle around you.",
  "The plague of wasps flutters into a chaotic formation around you, chirping gently.",
}

local SELF_UP_MISSES = {
  -- Ambient lines that name a species and address you, but describe no
  -- shield forming. The attachment rule (around/about/near, or
  -- circle/orbit taking you directly) is what rejects these.
  "The bees buzz angrily at you.",
  "The moths flutter away from you.",
  "The bees ignore you completely.",
  "The gnats bite you.",
  "The locusts descend upon the field.",
  -- Verb outside the closed stem list.
  "The bees fly around you.",
  "The wasps swarm around you.",
  -- Flavour text from inside the plugin's OWN cast sequence, before any
  -- shield exists. This is why the species vocabulary stays closed.
  "The insects eagerly cluster around you, fighting for the sugar.",
  -- Other players' shields belong to bug_others.lua.
  "The plague of assassin bugs begins to circle Brodfist slowly.",
  "The cloud of bees begins to circle Youssef.",
  -- Channel spillover: a player quoting a shield line at you.
  "Brodfist tells you, \"the plague of locusts gather around you\"",
  "Brodfist says: the cloud of bees begins to circle you.",
  -- Owned by the upgrade trigger; matching here would record the
  -- DEPARTING swarm as the shield.
  "The gnats make a hasty retreat and the assassin bugs gather around you victoriously.",
}

local CASES = {
  {
    name    = "self up",
    pattern = P.up(P.SELF),
    hit     = SELF_UP_HITS,
    miss    = SELF_UP_MISSES,
  },
  {
    name    = "self upgrade (hasty retreat)",
    pattern = P.retreat(P.SELF),
    hit     = { "The gnats make a hasty retreat and the assassin bugs gather around you victoriously." },
    miss    = {
      "The plague of assassin bugs begins to circle you slowly.",
      "The gnats make a hasty retreat and the assassin bugs gather around Brodfist victoriously.",
    },
  },
  {
    name    = "self report",
    pattern = P.report(P.SELF_SUBJECT),
    hit     = {
      " * You are surrounded by a small swarm of sandflies.",
      " * You are surrounded by a cloud of mosquitos.",
      -- Species-agnostic: an unlisted species still registers.
      " * You are surrounded by a plague of some new bug we have never seen.",
    },
    miss    = {
      -- TPA's self report line. Requiring the size is what keeps it out.
      " * You are surrounded by a magical impact shield.",
      " * You are surrounded by a bright red magical impact shield.",
    },
  },
  {
    name    = "self scatter",
    pattern = P.scatter(P.SELF),
    hit     = { "The assassin bugs surrounding you scatter in different directions and fly off." },
    miss    = { "The bees surrounding Brodfist scatter in different directions and fly off." },
  },
  {
    name    = "self crash",
    pattern = P.crash(P.SELF),
    hit     = {
      "The last of the injured gnats surrounding you crash to the ground.",
      -- tt_dw's reference action has no "injured"; accept both.
      "The last of the gnats surrounding you crash to the ground.",
    },
    miss    = { "The last of the injured gnats surrounding Brodfist crash to the ground." },
  },
  {
    -- Same builder, other subject: a member block in `group shields`.
    name    = "others report",
    pattern = P.report(P.OTHER_SUBJECT),
    hit     = {
      " * He is surrounded by a cloud of bees.",
      " * She is surrounded by a vast swarm of elephant bugs.",
      " * It is surrounded by a plague of some new bug we have never seen.",
    },
    miss    = {
      " * He is surrounded by a magical impact shield.",
      " * She is surrounded by a bright red magical impact shield.",
      -- The self subject must not fall through to the others handler.
      " * You are surrounded by a cloud of bees.",
    },
  },
  {
    name    = "others up",
    pattern = P.up("(" .. P.NAME .. ")"),
    hit     = {
      "The plague of assassin bugs begins to circle Brodfist slowly.",
      "The cloud of bees begins to circle Youssef.",
      "With a low, menacing buzzing, the cloud of gnats begins to buzz around Brodfist happily.",
    },
    miss    = {
      "The plague of assassin bugs begins to circle you slowly.",
      "The assassin bugs begin to circle you slowly.",
    },
  },
  {
    name    = "others scatter",
    pattern = P.scatter("(" .. P.NAME .. ")"),
    hit     = { "The bees surrounding Brodfist scatter in different directions and fly off." },
    miss    = { "The bees surrounding you scatter in different directions and fly off." },
  },
}

-- ---------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------

local function write_file(path, lines)
  local f = assert(io.open(path, "w"))
  for _, l in ipairs(lines) do f:write(l, "\n") end
  f:close()
end

-- Pattern and corpus both go through files, so nothing is exposed to
-- shell quoting — these patterns are full of quotes, braces and
-- backslashes.
local function rg_matches(pattern, lines)
  local pat_path, corpus_path = os.tmpname(), os.tmpname()
  write_file(pat_path, { pattern })
  write_file(corpus_path, lines)
  -- --no-config / --no-ignore so a stray user config can't change the
  -- verdict; default engine (NOT --pcre2) is the one Mallard uses.
  local cmd = string.format(
    "rg --no-config --no-ignore --no-heading --no-line-number --color never -f %s %s 2>/dev/null",
    pat_path, corpus_path)
  local pipe = assert(io.popen(cmd, "r"))
  local out = pipe:read("a")
  pipe:close()
  os.remove(pat_path)
  os.remove(corpus_path)
  local matched = {}
  for line in out:gmatch("[^\n]+") do matched[line] = true end
  return matched
end

if not os.execute("command -v rg >/dev/null 2>&1") then
  print("FAIL: ripgrep (rg) not found — required to evaluate patterns with " ..
        "the same regex engine Mallard uses. Install with `brew install ripgrep`.")
  os.exit(1)
end

local failures, checked = 0, 0
for _, case in ipairs(CASES) do
  local corpus = {}
  for _, l in ipairs(case.hit)  do corpus[#corpus + 1] = l end
  for _, l in ipairs(case.miss) do corpus[#corpus + 1] = l end
  local matched = rg_matches(case.pattern, corpus)

  for _, l in ipairs(case.hit) do
    checked = checked + 1
    if not matched[l] then
      failures = failures + 1
      print(string.format("FAIL: [%s] should MATCH but did not:\n        %s", case.name, l))
    end
  end
  for _, l in ipairs(case.miss) do
    checked = checked + 1
    if matched[l] then
      failures = failures + 1
      print(string.format("FAIL: [%s] should NOT match but did:\n        %s", case.name, l))
    end
  end
  if failures == 0 then
    print(string.format("PASS: %s (%d hit / %d miss)", case.name, #case.hit, #case.miss))
  end
end

if failures > 0 then
  print(string.format("\n%d/%d corpus lines wrong", failures, checked))
  os.exit(1)
end
print(string.format("\nAll %d corpus lines classified correctly.", checked))
