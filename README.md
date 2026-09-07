# HOLLOW VERGE

An original roguelite hack-and-slash for Roblox. Four weapons that play like four
different characters, eight enemies that each ask a different question, three
Wardens that change what the fight *is* between phases, and a hub that grows.

*Death is the cheapest thing you own.*

---

## State of this build

This is the **vertical slice architecture and content, complete as code**. Every
system described below is implemented and wired. What it has not had is time in
Studio with a controller in someone's hands, which is the only thing that
actually tells you whether a game feels good.

**Verified here** — by two checkers in `tools/`, both of which were tested
against deliberately broken input before being trusted:

```sh
python3 tools/luau_check.py      # structure: 55 files, 0 problems
python3 tools/content_check.py   # consistency: 11 checks, 0 problems
```

- All 55 Luau files pass a structural check — balanced blocks, matched brackets,
  terminated strings, every ModuleScript returns.
- All 68 authored actions (weapon swings, enemy attacks, boss attacks) have
  timing that sums exactly to their animation clip's duration, so damage lands
  on the frame the blade looks like it connects.
- Every enemy and boss telegraph fits inside the windup it warns about.
- All 26 Grace effect kinds have runtime handlers, and all 6 synergies are wired.
- Every `registry.<Service>.<member>` cross-reference resolves to a real
  function. Every remote used is declared; every remote declared is used.
- Every room type has at least one layout that can host it; every Grace's
  description placeholders match its value rows at every rarity.

**Not verified here:** anything that requires actually running it. No frame
timings, no feel, no balance. See *Known gaps* at the bottom.

---

## Running it

```sh
rokit install          # or: aftman install
rojo serve             # then connect from Roblox Studio
```

Or build a place file directly:

```sh
rojo build -o HollowVerge.rbxl
```

There are no uploaded assets to fetch. Every enemy, weapon, room and cosmetic in
this game is built from primitives at runtime, so the entire game is text you
can read and diff. Open the place and press play.

For a fast look at the systems, set `GameConfig.Debug.UnlockEverything = true`
to start with all weapons and regions available.

---

## The loop

```
EMBERHOLD ──► pick a weapon at the gate ──► descend
    ▲                                          │
    │                                          ▼
    │                                 fight a room, choose a door
    │                                          │
    │                              ┌───────────┴───────────┐
    │                              │  combat · grace · elite│
    │                              │  cache · well · event  │
    │                              │  forge · mini-boss     │
    │                              └───────────┬───────────┘
    │                                          │
    │                                    the Warden
    │                                          │
    └────────── run summary ◄──────────────────┘
               (leads with what you keep)
```

Short-term progression happens inside a run: Graces, Motes, a temporary temper.
Long-term progression happens in the hub: weapons, Tempers, Keepsakes,
cosmetics, mastery, story. Dying loses only the first kind.

---

## The four weapons

They are not stat variations. Each owns its entire moveset — every swing's
timing, hitbox shape, root motion, cancel window, camera kick and animation
clip. The combat system contains no weapon-specific code at all.

| | reach | speed | the idea |
|---|---|---|---|
| **VIGIL** the longsword | medium | medium | Four-hit chain with real cancels. Teaches the game; has no bad matchup and no ceiling. |
| **GRUDGE** the great axe | long | very slow | Commitment. 2.5× the stagger of anything else, and recovery you have to live inside. |
| **QUARREL** the twin blades | very short | very fast | Five swings under a third of a second each. Damage is back-loaded, so bailing out early is a real loss. |
| **THRESH** the spear | very long | medium | Spacing. Out-ranges every basic enemy attack, and is helpless once that range is crossed. |

The number that separates them most is the cancel window — the fraction of
recovery you have to sit through before the next input is legal. Quarrel is at
0.12. Grudge is at 0.6.

---

## What is worth reading first

If you want to understand this codebase quickly, read these four files in order:

1. **`src/shared/Config/WeaponConfig.lua`** — how a moveset is expressed as data.
2. **`src/server/Services/CombatService.lua`** — the one state machine that drives
   players, enemies and bosses, and the one function all damage passes through.
3. **`src/server/Services/EnemyAgent.lua`** — the attack-token rule, which is the
   single biggest reason a room with nine enemies stays readable.
4. **`src/client/Controllers/ProceduralAnimator.lua`** — a complete small animator
   built on Motor6D offsets, since this project ships no animation assets.

Full map in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
World and design reasoning in [`docs/DESIGN.md`](docs/DESIGN.md).
How to add content in [`docs/CONTENT.md`](docs/CONTENT.md).

---

## A few decisions worth stating up front

**Everything is built from code.** No `.rbxm` assets. A room is a list of
geometry primitives; an enemy is a palette and a silhouette; a weapon is a list
of parts. This means a content change is a readable diff, and it means anyone can
contribute without opening Studio.

**Animation is procedural.** `PoseLibrary` holds every clip as keyframe data and
`ProceduralAnimator` drives Motor6D `C0` offsets from it. The timing is therefore
shared between the visible swing and the server's hitbox window, which is why
they cannot drift apart.

**The server owns everything that matters.** The client sends which button was
pressed and roughly which way it is facing. Facing is honoured inside a tolerance
(so turning as you swing feels responsive) and clamped beyond it (so it cannot be
used to hit things behind you). Damage, currency, unlocks and rewards are
computed server-side only.

**Configs validate themselves at boot.** Every content module has a `Validate()`
that runs at server start and prints problems to the console. A mistyped Grace id
is a loud message, not a nil index forty minutes into a playtest.

**Attack tokens.** A room hands out two; an enemy cannot attack without one.
Everyone else circles in the open, visibly waiting. This one rule is most of what
separates "a fight" from "twelve things running at your face".

---

## Known gaps

Stated plainly, because the difference between "done" and "compiles" matters:

- **No audio.** `AudioConfig` declares every sound the game asks for, its bus,
  volume, pitch variance and rolloff — but every `assetId` is empty, because
  audio cannot live in a git repository as reviewable text. The game runs
  silent and correct; filling in ids turns the sound on already balanced.
- **Never run.** This was built in an environment without Roblox Studio. It is
  statically verified (see above) but not playtested. Expect to spend the first
  session fixing things only a running game reveals.
- **Balance is a first guess.** Every number in `GameConfig` and the content
  configs is a considered starting point, not a tuned one.
- **Co-op is designed for, not implemented.** Run sessions are keyed per player
  but nothing assumes one player per session, rooms are placed on per-session
  lanes, and kill credit and boss handles are already attributed per session.
  Making it real means keying sessions by party rather than by player.
- **Regions 2 and 3 share region 1's room layouts** with different dressing,
  hazards and enemy weights. That is the intended design (see `RoomConfig`), but
  they would benefit from two or three bespoke layouts each.
- **The mastery track's moveset rewards are partly declarative.** Level gates,
  Temper unlocks and stat scaling are applied; a few of the "new combo step"
  payloads are read by `WeaponService.Resolve` and a few are not yet.
