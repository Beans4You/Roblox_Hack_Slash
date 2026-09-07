# Architecture

## The shape of it

```
ReplicatedStorage/HollowVerge          shared: config, utils, net, combat maths
ServerScriptService/HollowVerge        14 services, one registry, one heartbeat
StarterPlayerScripts/HollowVerge       10 controllers, one registry, two loops
```

Server and client are structured identically on purpose: modules are plain tables
with optional `Init`, `Start` and `Tick`/`Update`, loaded in a fixed order and
wired through one registry passed to `Init`.

**Why a registry instead of direct requires.** `CombatService` and `EnemyService`
genuinely need each other. A require cycle between them is a boot-time crash, and
the usual workarounds (lazy requires, a mediator, events for everything) are all
worse than passing one table. Nothing in this codebase requires a peer service
directly.

**Why one heartbeat.** Ordering between per-frame systems is a correctness
question, not an implementation detail. Statuses tick before combat reads them;
combat resolves before the AI decides what to do about it. A dozen services each
connecting their own `Heartbeat` makes that ordering accidental.

---

## Server

Load order (from `src/server/init.server.lua`), which is also dependency order:

```
DataService          profiles, session locking, retries
ProgressionService   the only place anything permanent is granted
StatusService        burns, chills, bleeds, buffs
WeaponService        weapon geometry; resolving mastery + Temper into a moveset
CombatService        the state machine; the only place damage happens
EnemyService         spawning, elites, projectiles, encounter budgets
BossService          Warden phase machines and arena effects
RoomBuilder          layout descriptions to geometry
RunGenerator         route skeleton + per-junction door rolls
BoonService          Grace offers, held state, and 32 effect handlers
RewardService        room payouts, event outcomes, run summary
RunManager           the run loop; owns everything a run creates
HubService           Emberhold, NPCs, hub actions
PlayerService        the character: spawn, dress, arm, die
```

Ticked each heartbeat, in this order: `StatusService`, `CombatService`,
`EnemyService`, `BossService`, `BoonService`, `RunManager`.

### The combat state machine

One machine drives players, enemies and bosses. They differ only in who supplies
the intent — a client, an `EnemyAgent`, a boss phase — and which move table they
read from.

```
Idle ──intent──► Windup ──► Active ──► Recovery ──► Idle
                    │          │           │
                    │          │           └─ cancel window opens here
                    │          └─ hitbox exists ONLY here
                    └─ telegraph shows here (enemies)
```

Legality has exactly one source: a character in `Idle` can start anything it can
afford; a character mid-action can only start what the current swing's `cancel`
table allows, at the time that table specifies. There is no other path into an
action.

`CombatService.ApplyDamage` is the only function in the game that reduces a
Humanoid's health. Invulnerability, parries, blocks, faction checks and status
multipliers therefore each exist in exactly one place.

### Damage pipeline

Fixed order, defined and explained in `Shared/Combat/DamageMath.lua`:

```
base → mastery → additive bonuses (summed) → positional → crit
     → true multipliers → defensive → global scaling
```

Grace bonuses are **summed**, not multiplied. Four damage Graces multiplying
would be 4×, eight would be 16×, and the game would come apart exactly where it
should get interesting. Multiplication is reserved for the handful of moments
that should feel enormous — a stagger, a boss phase, an ultimate.

### Enemies

`EnemyAgent` is a small state machine (Idle, Approach, Circle, Attack, Recover,
Reposition) with two rules layered on top that do most of the work:

- **Attack tokens.** A room has `GameConfig.Enemies.AttackTokens` (2). An enemy
  cannot enter `Attack` without holding one; it releases on finishing, on being
  staggered, and on losing its target. Everything else circles at its preferred
  range where the player can see it.
- **Range bands.** An attack is only legal inside its own `minRange`/`maxRange`,
  so nothing starts a slam from thirty studs away and walks in with the hitbox
  open.

Encounters are budgeted, not listed. A room says "spend N points"; the service
buys from the region's weighted pool until the budget runs out. Difficulty stays
roughly constant while composition varies.

### Bosses

A boss is a phase machine that owns its arena, which is why it is a separate
service. Each phase has its own attacks, movement, aggression and tempo, and
crossing a threshold plays a transition: invulnerable, a clip, an arena change,
possibly adds, and a line of dialogue — the player gets a guaranteed breath and
the fight they were learning becomes a different one.

Bosses are never staggered. Poise fills a **break meter** instead; filling it
opens them for a fixed window at increased damage. Same reward as a stagger, but
it has to be earned in one sustained push rather than accumulated from chip
damage across a phase.

Arena effects are a handler table (`Shockwave`, `RingWave`, `Meteors`,
`IceLances`, `SafeRing`, `ThrownDebris`, `GroundFire`, plus the structural ones
used by transitions). A new boss attack shape adds one entry.

### Persistence

`DataService` uses `UpdateAsync` transforms — never get-then-set, which loses
data whenever two writes race, and they do race.

Session locking is enforced on **both** ends: a load refuses a profile another
server holds and steals a lock older than `SessionLockTimeout`; a save refuses to
write over a profile another server has since claimed. The second half is the one
people forget.

A load that exhausts its retries does **not** create a fresh profile. That would
hand the player an empty save and then write it over their real one. Instead the
session runs read-only and the player is told.

---

## Client

```
UiKit                the visual language, as constructors
AudioController      buses, pitch variance, throttling, crossfade
ProceduralAnimator   Motor6D clip playback
AnimationController  decides which clip everything should be playing
VfxController        hit sparks, damage numbers, telegraphs
CameraController     spring-driven third-person combat camera
HudController        the in-fight overlay
MenuController       every screen that is not the HUD
CombatController     intent, prediction, server state
InputController      raw input to intent
```

`RenderStepped` drives the camera and the animator — anything that must be
lockstep with the frame the player sees. `Heartbeat` drives everything else,
where a frame of latency is free.

### Prediction, and its limit

Pressing light attack plays the swing immediately. It does not compute damage,
spawn a hitbox, or decide legality. If the server disagrees, the next
`CombatState` packet overwrites the guess and the animation is cut.

Occasionally showing half a swing that gets cancelled is a much better trade than
making a melee player wait a round trip to see their own character move.

Input is buffered on both sides for different reasons: the client buffer decides
whether to *play* the next animation early (feel); the server buffer decides
whether the input *counts* (truth).

### Procedural animation

This project ships no uploaded animations. `PoseLibrary` holds every clip as
keyframe data — Euler offsets from each joint's rest pose, at normalised times —
and `ProceduralAnimator` samples and writes them to Motor6D `C0`.

Two layers. **Base** holds looping locomotion. **Action** holds everything else
and wins per joint while playing, so a swing clip can specify only the arms and
still look right on a running character. Both cross-fade, because snapping
between poses is the single most obvious tell that animation is procedural.

The payoff beyond "it works without assets": clip duration is shared data. The
server's hitbox window and the client's visible swing are computed from the same
numbers, and a boot-time check asserts that a swing's `windup + active + recovery`
equals its clip's duration. They cannot drift.

---

## The wire

Every remote is declared in one table in `Shared/Net/Net.lua` with its direction.
Binding a handler the wrong way round is a boot-time error. Client-fired remotes
carry per-player token-bucket rate limits that **drop** rather than queue — a
client firing faster than a human can is lagging or lying, and buffering that
into a later burst helps neither case.

What crosses from the client: which button, which facing, which door, which
Grace, which menu action. That is the complete list. No damage numbers, no
currency, no unlocks, no positions trusted without validation.

---

## Lifetime and cleanup

Every transient thing is owned by exactly one `Maid`: a run, a room, an
encounter, a character, a boss. Ending a run collapses the entire world it built
in one call. This is the only reason a game that assembles and discards levels
indefinitely does not leak.

Performance caps live in `GameConfig.Performance` and are treated as invariants,
not suggestions: exceeding `MaxActiveEnemies` is a content bug, and dropping the
extra is better than dropping frames. Rigs beyond `AnimationCullDistance` skip
the animator entirely; hit VFX are pooled and rate-limited; rooms more than one
behind the player are destroyed.
