# Adding content

Every system in this game is data-driven, and the configs validate themselves at
boot. Adding content is editing tables; the console tells you when you got it
wrong.

Run `python3 tools/luau_check.py` after any edit — it catches unbalanced blocks,
unterminated strings and modules that forgot to return, without needing a Lua
toolchain.

---

## A new weapon

**Files:** `Config/PoseLibrary.lua`, `Config/WeaponConfig.lua`

1. **Clips.** Add one per swing. Most melee is four shapes with different timing,
   so use the archetype builders:

   ```lua
   Clips.Cleaver_Light1 = sweep(0.5, 1.0, 1)      -- (duration, amplitude, direction)
   Clips.Cleaver_Light2 = overhead(0.6, 1.1, 1)   -- (duration, reach, side)
   Clips.Cleaver_Heavy  = uppercut(0.7)
   ```

   Go bespoke only where the archetypes do not fit.

2. **The weapon table.** Copy the shape of `WeaponConfig.Weapons.Vigil`. The
   fields that matter most:

   - `windup` / `active` / `recovery` **must sum to the clip's duration.** This is
     checked at boot and is why damage lands on the frame the blade connects.
   - `cancel` is the fraction of recovery that must elapse before each follow-up
     is legal. This is the number that decides how the weapon feels. Look at the
     table in `docs/DESIGN.md` before picking one.
   - `hitbox.shape` is `Arc` (a cone; needs `angle`), `Box` (needs `width`;
     thrusts and dashes) or `Sphere` (slams and spins).

3. **Geometry.** Add an entry to `WeaponConfig.Models` — a list of parts with
   sizes, offsets, colours and materials, relative to the grip, +Y along the
   blade. Set `mirrored = true` for a paired weapon and the offhand copy is built
   automatically.

4. **Mastery.** Add a track to `MasteryConfig.Tracks` using the shared gates
   (3, 5, 8, 10, 12, 15, 20, 25, 30).

5. Add the id to `WeaponConfig.Order`.

No combat code changes. The state machine has no weapon-specific branches.

---

## A new enemy

**File:** `Config/EnemyConfig.lua`

Start by answering: **what question does this enemy ask the player?** If the
answer duplicates one of the existing eight, it is a reskin, not an enemy.

```lua
E.Warden = {
    id = "Warden", displayName = "WARDEN", role = "...",
    threat = "One sentence: what the player must do about it.",
    tier = "Grunt",
    rig = { scale = 1.1, palette = DROWNED, silhouette = { "pauldrons", "cloak" } },
    stats = { maxHealth = 90, damageScale = 1, walkSpeed = 11, chaseSpeed = 16,
              poiseThreshold = 40, detectionRange = 60, aggression = 0.6, weight = 1.1 },
    behavior = { archetype = "Melee", preferredRange = 8, strafeBias = 0.4, patience = 1.5 },
    attacks = { --[[ ... ]] },
    rewards = { motes = 6, ultimateCharge = 4 },
    regions = { "SunkenMarch" },
}
```

Rules the boot check enforces:

- Attack timing sums to its clip duration.
- `telegraph <= windup`. A telegraph is a *slice* of the windup, never an
  extension of it. If the warning needs to start earlier (the Censer glowing as
  it approaches), that belongs in `behavior.primesOnApproach`.
- `minRange < maxRange`.

`archetype` picks the movement brain: `Melee`, `Charger`, `Ranged`, `Guard`,
`Flyer`, `Exploder`. Silhouette flags come from `RigBuilder`: `horns`,
`pauldrons`, `cloak`, `crest`, `tatters`, `halo`.

Encounter cost is derived from health and damage, so the enemy prices itself.

---

## A new Grace

**File:** `Config/BoonConfig.lua`

```lua
B.Cinder_Backdraft = {
    id = "Cinder_Backdraft",
    faded = "Cinder",
    name = "BACKDRAFT",
    description = "When something burning dies, it bursts for {} damage in {} studs.",
    trigger = "OnKill",
    values = { Common = { 40, 12 }, Rare = { 70, 14 }, Epic = { 120, 17 } },
    effect = { kind = "DeathBurst", requiresStatus = "Burn", damageIndex = 1, radiusIndex = 2 },
    requires = { boon = "Cinder_Kindling" },
    tags = { "Cinder", "Chain" },
}
```

- `{}` is the placeholder. The count must match every rarity row's value count —
  checked at boot.
- Omit a rarity to make the Grace unable to roll there. That is how a
  Legendary-only capstone avoids showing up as a grey.
- **If `effect.kind` already exists, you are done.** No code.
- If it is new, add a handler to the matching table in `BoonService` — `OnHit`,
  `OnKill`, `OnDodgeEffects`, `OnParryEffects`, `OnDamagedEffects`,
  `OnAbilityEffects` — or, for a pure passive, a branch in `recomputeAggregate`.
  Passives fold into one table on take; they are never recomputed per swing.

**Write the Grace to change a decision, not a number.** "+8% damage" is not
interesting. "Standing still for a moment charges your next attack" is, because
it changes what you do with the space between attacks.

### A synergy

Add to `BoonConfig.Synergies` with the ids it needs. They are granted the moment
their requirements are met, loudly. If it needs behaviour, check
`state.synergies.<Id>` inside the relevant handler.

---

## A new room layout

**File:** `Config/RoomConfig.lua`

A layout is a list of geometry primitives plus metadata:

```lua
R.Cistern = {
    id = "Cistern", name = "The Cistern",
    supports = { "Combat", "Elite" },
    footprint = Vector3.new(90, 30, 90),
    difficulty = 3,
    geometry = {
        floor(90, 90),
        walls(90, 90, 30),
        { kind = "PillarRing", count = 10, radius = 32, height = 26, thickness = 4 },
        { kind = "Depression", radius = 26, height = 5 },
    },
    entrance = Vector3.new(0, 0, 40),
    exits = { Vector3.new(0, 0, -40), Vector3.new(-40, 0, 0) },
    spawnPoints = { --[[ at least 4 for a combat room ]] },
    featureAnchor = Vector3.new(0, 0, -20),
    tags = { "Arena", "Cover" },
}
```

Available `kind`s: `Floor`, `Perimeter`, `PillarRing`, `PillarRow`, `Rubble`,
`Banners`, `Depression`, `Steps`, `Void`, `Railing`, `Alcoves`, `Platform`,
`Ramp`, `Braziers`, `Baffles`. Add a new one by adding a function to
`RoomBuilder.Builders`.

**Layouts are region-agnostic on purpose.** A shape is a combat problem; the
dressing tells you where you are. Add the id to each region's `roomPool` in
`RegionConfig`.

Braziers are the only light source in most rooms. Place them for legibility, not
decoration.

---

## A new region

**File:** `Config/RegionConfig.lua`

A region is a palette, a lighting block, a hazard, enemy weights, a room pool and
a boss. Reuse existing layouts; that is what makes a region an afternoon rather
than a project.

The **hazard** is what makes the region play differently with the same enemies.
The three that exist are worth reading as examples — shallow water that amplifies
Skein damage, ember patches that flare on a cycle, and a frictionless floor that
makes every dodge overshoot. Each retunes fights the player already knows.

---

## A new boss

**File:** `Config/BossConfig.lua`

The largest content item. Before writing numbers, decide **what changes between
phases.** If the answer is "it hits harder", it is not finished.

Each phase needs its own attack list, `moveSpeed`, `aggression` and `tempo`, and
a `transition` — a clip, a duration of invulnerability, an arena effect, optional
spawns, and a line. Attacks reaching past the boss's own reach use an
`arenaEffect` from `BossService.ArenaEffects`; add a handler there for a new
shape.

Two things not to skip:

- **`weakPoints`** and the `exposesFor` window on big attacks. This is how a good
  player shortens the fight, and a boss without it is a damage sponge.
- **`dialogue.meet`**, keyed by how many times this boss has killed this player.
  Ascending thresholds; highest match wins. This is the cheapest and best
  character work available.

---

## A new cosmetic

**File:** `Config/CosmeticConfig.lua`

Every entry must name the specific act that earns it in `source`, and encode it
in `unlock`. Supported kinds: `Default`, `Mastery`, `RelicSet`, `BossFlawless`,
`BossChallenge`, `Deaths`, `EnemyKills`, `RegionClear`, `Story`, `RunChallenge`.
`ProgressionService.EvaluateUnlocks` checks them all on any progression event.

**If a `source` could be satisfied by grinding, it is the wrong cosmetic.**

`build` is a list of part specs attached to the slot's joint — same format as
weapons and enemies.

---

## Continuous integration

Both checkers are dependency-free and exit non-zero on failure, so they drop
straight into CI. This workflow is not committed — the token used to build this
branch lacks GitHub's `workflow` scope — so paste it into
`.github/workflows/check.yml` yourself:

```yaml
name: check

on:
  push:
    branches: ["**"]
  pull_request:

jobs:
  structure:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Structural check
        run: python3 tools/luau_check.py src
      - name: Content consistency
        run: python3 tools/content_check.py
```

---

## Checklist before opening a PR

- [ ] `python3 tools/luau_check.py` passes
- [ ] Server console shows `content validation passed` at boot
- [ ] New swings/attacks: timing sums to the clip duration
- [ ] New enemy: `threat` says what the player must do about it, in one sentence
- [ ] New Grace: changes a decision, not a number
- [ ] New cosmetic: `source` cannot be satisfied by grinding
- [ ] Nothing new added to `GameConfig.Performance`'s budget without saying why
