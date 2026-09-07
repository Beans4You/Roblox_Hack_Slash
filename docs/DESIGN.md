# Design

## The world

**The Verge** is the edge of a world that was unmade and never finished falling
apart. It reassembles itself on a cycle called **the Reforging**, and anything
that dies inside it is re-knit at the next turn — including you.

You are **the Unspent**: a warrior whose death does not take. Nobody, including
you, knows why. The Wardens — the people who were supposed to shut the cycle
down, still at their posts a very long time later — have started to notice.

Nothing here is borrowed. No Greek pantheon, no existing mythology, no
characters, places, weapons or systems taken from another game. The structural
inspiration is stated plainly (a run-based roguelite with a hub, permanent
progression between runs, and gods who hand you temporary powers), and every
noun is original.

### The pieces

| | |
|---|---|
| **Emberhold** | The hub. A ruined waystation at the world's seam that gets rebuilt as you feed it. |
| **the Faded** | Seven dead things too stubborn to stop giving advice. They grant **Graces**. |
| **Wardens** | Three corrupted guardians, one per region. Bosses. |
| **Motes** | In-run currency. Gone when the run ends. |
| **Sable** | Permanent currency. |
| **Keepsakes** | Permanent collectibles, in three sets. |
| **Tempers** | Permanent weapon variants, bought at the smith. |

### The story, in one paragraph

The Reforging does not bring people back — it re-knits the *place*. People are
what the place is being rebuilt around. So every time you die, Emberhold gets one
thing back: a wall, a door, once a person. You are not surviving the cycle; you
are feeding it. The Guest, who arrived before you did and whom nobody remembers
letting in, was the first Unspent. He stopped. Everyone in the hold forgot him so
completely that they cannot remember letting him in. That is what stopping costs.

Told in nine beats gated on what you have actually done, in
`Config/DialogueConfig.lua`. Nothing is a cutscene; the longest beat is five
lines.

---

## What this game is trying to be

The brief it was built from is explicit about the trade: **a small amount of
content that feels excellent, over a large amount that does not.** Four weapons,
not twenty. Eight enemies, not fifty. Everything below follows from that.

### Weapons are characters, not stat lines

Each weapon owns its entire moveset. The combat system contains no
weapon-specific code — adding a fifth means adding a table and some clips.

The number that separates them most is not damage, it is the **cancel window**:
the fraction of a swing's recovery you must sit through before the next input is
legal.

| | cancel | what that feels like |
|---|---|---|
| Quarrel | 0.12 | you are never not attacking |
| Thresh | 0.30 | you can always back out of a poke |
| Vigil | 0.40 | forgiving, but you notice |
| Grudge | 0.60 | you live with your decisions |

Damage is back-loaded differently too. Quarrel's five-hit chain puts most of its
damage in swings four and five specifically so that bailing out early is a real
loss — the weapon is about staying attached to a target.

### Eight enemies, eight questions

Each one is built around exactly one thing the player has to answer:

| | |
|---|---|
| **Marchman** | can you keep a combo going while something interrupts you? |
| **Cutter** | can you punish something faster than you? |
| **Bulwark** | can you get around a front? |
| **Fletcher** | are you willing to leave the melee to deal with it? |
| **Drudge** | can you stay patient through a long telegraph? |
| **Vesper** | can you fight something you cannot reach on the ground? |
| **Censer** | can you kill something without being next to it? |
| **Tallier** | all of the above, at once, on a timer. |

They are combined by weight rather than by list, so the same eight produce very
different fights across the three regions.

### Readability is a mechanic

In a game where you dodge on reaction, being unable to read the fight is the same
as the fight being unfair. Concretely:

- **Attack tokens.** Two enemies may be attacking; everyone else circles in the
  open. This one rule is most of why a room can hold nine enemies.
- **Telegraphs are the attack.** The warning shape is built from the attack's own
  hitbox data, so it cannot describe something different from what lands. Bigger,
  slower enemies get longer telegraphs; that is the difficulty curve.
- **Undodgeable attacks are a different colour, always.** "Get out of the way"
  and "you cannot dodge this" must be distinguishable at a glance.
- **Silhouettes differ before palettes do.** Horns, pauldrons, cloaks, halos —
  you should be able to tell a Cutter from a Brute at forty studs.
- **Hit and whiff never sound alike.** Separate sound sets, deliberately.
- **The middle of the screen is empty.** Nothing is centred except the finisher
  prompt and the damage flash. The centre belongs to the enemy.

### Bosses change what the fight is

Not health bars. Each Warden's phases change the problem:

- **Vhalric, the Tallyman** breaks the hall so you cannot circle him, floods the
  ground you learned, then opens his core. He has one undodgeable attack with a
  safe ring, and it is the only one in the fight — the answer is position, not
  the dodge button.
- **Kessara, the Ashmother** does not need to hit you; she needs the floor to.
  Each phase burns away more of it.
- **The Hoarfrost Anchorite** does not move. It never moves. The whole fight is a
  puzzle about closing distance under fire and getting back out — until phase
  three, when it comes down.

Bosses also remember you. Their greeting is chosen by how many times they have
personally killed this player, from a table in `BossConfig`. Vhalric at seven
deaths: *"I have killed you seven times. Why do you refuse to stay dead?"* It
costs one table and it is the best mechanical expression of the premise the game
has.

### Runs should converge into builds

A sequence of uniform random Graces produces eight unrelated effects. So:

- Faded you have already taken from get a weight bonus, which pulls a run toward
  two or three elements.
- A Grace that would complete a synergy is 3.5× likelier to appear. Finding one
  should feel like luck; it is mostly not.
- Doors never offer the same room type twice — two identical doors is a
  non-choice.
- Offers are rolled **when you reach the junction**, from live state. Hurt
  players see more Wells; players with no Graces see more shrines; players with a
  full build see more elites, because that is what they are shopping for now.

### Death is progression

Stated as a rule and implemented as one:

- Everything permanent earned during a run is written to the profile as it is
  earned, not at the end. A disconnect costs nothing already banked.
- Depth pays Sable even on a loss, so a bad run is still worth finishing.
- The summary screen opens on **what you keep** — Sable, mastery, unlocks — and
  puts how far you got underneath.
- The word "died" does not appear on it.
- Dying to the same enemy five times grants A SECOND KNIFE, which survives one
  death per run. The game noticing you are stuck and helping.

### The best cosmetics are earned by playing well

Not by playing long, and never by paying. Every cosmetic names the specific act
that unlocks it:

- Defeat Vhalric without dying → **The Unbalanced Column**
- Defeat Kessara without stepping in fire → **The Banked Coal**
- Defeat the Anchorite using no Graces at all → **The Held Breath**
- Weapon mastery 30 → that weapon's aura, visible in the hub
- A full run at Heat 5+ without dying → **The Unspent Crown**
- Die 50 times → **Verge-Horn**. Not an achievement, exactly.

---

## Tuning notes

Things that were chosen rather than defaulted, and why:

**Input buffer: 0.25s.** Long enough that combo mashing is forgiving, short
enough that you never get an attack you had stopped wanting.

**Dodge i-frames start 0.06s late.** So a dodge pressed after an attack has
already connected does not retroactively save you.

**Perfect parry window: 0.18s**, degrading to a plain block for another 0.45s.
Two outcomes from one button, and the good one has to be earned.

**Hit stop scales down by √(targets hit).** A spin through six enemies would
otherwise stop the game dead.

**Enemy health scales +5.5% per room, damage +3.5%.** Linear, not exponential.
The difficulty should come from the room and the enemy mix, not from the numbers
running away.

**Legendary Graces are 2.5 weight against Common's 100.** A Legendary should be
the story of the run, not a Tuesday.

**Statuses on bosses last ~35–60% as long.** A boss frozen for two full seconds
would trivialise every phase transition.

---

## What a first session should feel like

The brief asks the first twenty minutes to teach the whole game. The content is
laid out for it:

| | |
|---|---|
| 0–3 min | Halvic hands you Vigil. Room one is always a plain fight. |
| 3–7 min | Room two offers a real door choice. Marchmen and a Bulwark: your first "go around it". |
| 7–12 min | First shrine. Weighted heavily toward showing up early if you have no Graces. |
| 12–17 min | An elite, or the Tallier mini-boss at room six. |
| 17–20 min | The Warden's Gate. Vhalric, phase one. |

Whatever happens next, you return to Emberhold, the summary leads with what you
kept, and Ilka's tent is standing where it was not before.

The intended thought at the end of that session is *"I want to try that again
with the axe."*
