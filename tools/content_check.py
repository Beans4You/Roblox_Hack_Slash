#!/usr/bin/env python3
"""
Content consistency checks for HOLLOW VERGE.

These are the invariants that hold this project together and that are invisible
in code review. Most are also checked at server boot by each config's Validate();
running them here keeps them out of the branch in the first place, and catches
the cross-file ones (registry wiring, remote declarations) that a single module
cannot check for itself.

    python3 tools/content_check.py

Non-zero exit if anything fails, so it works in CI.

This is a text-level checker, not a Lua interpreter. It reads the configs as
source. That means it can be fooled by heavy refactoring of how the tables are
written -- if a check starts reporting zero items where there should be dozens,
suspect the parser rather than trusting the pass.
"""

from __future__ import annotations

import re
import sys
import pathlib
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

problems: list[str] = []
counts: dict[str, int] = {}


def fail(message: str) -> None:
    problems.append(message)


def read(relative: str) -> str:
    return (SRC / relative).read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# 1. Animation clip durations
# ---------------------------------------------------------------------------

def clip_durations() -> dict[str, float]:
    """Every clip in PoseLibrary, whether built from an archetype or authored."""
    text = read("shared/Config/PoseLibrary.lua")
    durations: dict[str, float] = {}
    for match in re.finditer(
        r"Clips\.(\w+) = (?:overhead|sweep|thrust|uppercut|spin)\(([\d.]+)", text
    ):
        durations[match.group(1)] = float(match.group(2))
    for match in re.finditer(r"Clips\.(\w+) = \{\s*\n\s*duration = ([\d.]+)", text):
        durations[match.group(1)] = float(match.group(2))
    return durations


ACTION_PATTERN = re.compile(
    r'clip = "(\w+)",\s*\n\s*(?:telegraph = ([\d.]+), )?'
    r"windup = ([\d.]+), active = ([\d.]+), recovery = ([\d.]+),"
)


def check_action_timing() -> None:
    """
    A swing's phases must sum to its clip's duration.

    This is the invariant that makes damage land on the frame the blade looks
    like it connects. Getting it wrong is invisible in code and extremely
    obvious in play.
    """
    durations = clip_durations()
    counts["clips"] = len(durations)
    total = 0

    for name in ("WeaponConfig", "EnemyConfig", "BossConfig"):
        text = read(f"shared/Config/{name}.lua")
        for match in ACTION_PATTERN.finditer(text):
            total += 1
            clip = match.group(1)
            phases = sum(float(match.group(i)) for i in (3, 4, 5))

            if clip not in durations:
                fail(f"{name}: action references missing clip {clip!r}")
                continue
            if abs(durations[clip] - phases) > 5e-4:
                fail(
                    f"{name}/{clip}: phases sum to {phases:.3f}s but the clip is "
                    f"{durations[clip]:.3f}s"
                )

            # A telegraph is a slice of the windup, never an extension of it.
            if match.group(2) is not None:
                telegraph = float(match.group(2))
                windup = float(match.group(3))
                if telegraph > windup + 1e-4:
                    fail(
                        f"{name}/{clip}: telegraph {telegraph:.2f}s exceeds its "
                        f"windup {windup:.2f}s"
                    )

    counts["actions"] = total
    if total < 50:
        fail(f"only {total} actions found; the parser is probably not matching")


# ---------------------------------------------------------------------------
# 2. Grace descriptions
# ---------------------------------------------------------------------------

def check_boon_placeholders() -> None:
    """
    Every `{}` in a description must be filled by a value at every rarity the
    Grace can roll at, or the player reads "?" in game.
    """
    text = read("shared/Config/BoonConfig.lua")
    body = text[: text.index("-- SYNERGIES")]
    total = 0

    for block in re.split(r"\nB\.", body)[1:]:
        boon_id = block.split(" ", 1)[0]
        total += 1

        description_match = re.search(
            r'description = ((?:"[^"]*"\s*(?:\.\.\s*)?)+)', block
        )
        values_match = re.search(r"values = \{(.*?)\},\n", block, re.S)
        if not description_match or not values_match:
            fail(f"BoonConfig/{boon_id}: could not parse description or values")
            continue

        description = "".join(re.findall(r'"([^"]*)"', description_match.group(1)))
        expected = description.count("{}")

        rarities = re.findall(r"(\w+) = \{ ([^}]*) \}", values_match.group(1))
        if not rarities:
            fail(f"BoonConfig/{boon_id}: no rarity rows, so it can never roll")

        for rarity, values in rarities:
            supplied = len([v for v in values.split(",") if v.strip()])
            if supplied != expected:
                fail(
                    f"BoonConfig/{boon_id}/{rarity}: {supplied} values for "
                    f"{expected} placeholders"
                )

    counts["graces"] = total


def check_boon_effects_handled() -> None:
    """Every declared effect kind needs a runtime handler or an aggregate branch."""
    boons = read("shared/Config/BoonConfig.lua")
    service = read("server/Services/BoonService.lua")

    kinds = set(re.findall(r'effect = \{ kind = "(\w+)"', boons))
    synergy_kinds = {k for k in kinds if k.startswith("Synergy_")}
    effect_kinds = kinds - synergy_kinds

    handled = set(
        re.findall(
            r"^function (?:OnHit|OnKill|OnDodgeEffects|OnParryEffects"
            r"|OnDamagedEffects|OnAbilityEffects)\.(\w+)",
            service,
            re.M,
        )
    )
    aggregated = set(re.findall(r'if effect\.kind == "(\w+)" then', service))

    for kind in sorted(effect_kinds - handled - aggregated):
        fail(f"BoonService: effect kind {kind!r} has no handler")

    # Synergies are checked inline by flag rather than dispatched.
    for kind in sorted(synergy_kinds):
        flag = kind.replace("Synergy_", "")
        if f"synergies.{flag}" not in service:
            fail(f"BoonService: synergy {flag!r} is declared but never checked")

    counts["effect kinds"] = len(effect_kinds)
    counts["synergies"] = len(synergy_kinds)


# ---------------------------------------------------------------------------
# 3. Rooms
# ---------------------------------------------------------------------------

def check_room_coverage() -> None:
    """Every room type the generator can roll must have a layout that hosts it."""
    text = read("shared/Config/RoomConfig.lua")

    types = set(re.findall(r'^\t(\w+) = \{\n\t\tid = "\1",', text, re.M))
    supports: dict[str, list[str]] = {}
    for match in re.finditer(
        r"^R\.(\w+) = \{.*?supports = \{([^}]*)\},", text, re.S | re.M
    ):
        supports[match.group(1)] = [
            entry.strip().strip('"') for entry in match.group(2).split(",") if entry.strip()
        ]

    covered: set[str] = set()
    for room, hosted in supports.items():
        for room_type in hosted:
            covered.add(room_type)
            if room_type not in types:
                fail(f"RoomConfig/{room}: supports unknown room type {room_type!r}")

    for room_type in sorted(types - covered):
        fail(f"RoomConfig: no layout can host room type {room_type!r}")

    counts["room layouts"] = len(supports)
    counts["room types"] = len(types)


# ---------------------------------------------------------------------------
# 4. Cross-module wiring
# ---------------------------------------------------------------------------

def check_registry_references(directory: str, label: str, ambient: set[str]) -> None:
    """
    Services and controllers reach each other through the registry. A typo there
    is a nil-index at the worst possible moment, and nothing else catches it.
    """
    modules: dict[str, set[str]] = {}
    for path in (SRC / directory).glob("*.lua"):
        name, text = path.stem, path.read_text(encoding="utf-8")
        members = set(re.findall(rf"^function {name}[.:](\w+)", text, re.M))
        members |= set(re.findall(rf"^{name}\.(\w+) = ", text, re.M))
        modules[name] = members

    missing: dict[str, set[str]] = defaultdict(set)
    parent = (SRC / directory).parent
    for path in parent.rglob("*.lua"):
        for module, member in re.findall(
            r"registry\.(\w+)\.(\w+)", path.read_text(encoding="utf-8")
        ):
            if module in ambient:
                continue
            if module not in modules:
                missing["<unknown>"].add(f"{module}.{member} ({path.name})")
            elif member not in modules[module]:
                missing[module].add(f"{member} ({path.name})")

    for module, entries in sorted(missing.items()):
        for entry in sorted(entries):
            fail(f"{label}: unresolved registry reference {module}.{entry}")

    counts[label.lower()] = len(modules)


def check_boot_order(path: str, list_name: str, directory: str, libraries: set[str]) -> None:
    """Everything in the folder is registered, and everything registered exists."""
    text = read(path)
    match = re.search(rf"local {list_name} = \{{(.*?)\}}", text, re.S)
    if not match:
        fail(f"{path}: could not find {list_name}")
        return

    listed = set(re.findall(r'"(\w+)"', match.group(1)))
    present = {p.stem for p in (SRC / directory).glob("*.lua")}

    for name in sorted(present - listed - libraries):
        fail(f"{path}: {name} exists but is never loaded")
    for name in sorted(listed - present):
        fail(f"{path}: {list_name} names {name}, which has no file")


def check_tick_wiring() -> None:
    """A service with a Tick that nothing calls is dead code pretending to work."""
    text = read("server/init.server.lua")
    match = re.search(r"local TICKED = \{(.*?)\}", text, re.S)
    if not match:
        fail("server bootstrap: could not find TICKED")
        return

    ticked = set(re.findall(r'"(\w+)"', match.group(1)))
    has_tick = {
        path.stem
        for path in (SRC / "server/Services").glob("*.lua")
        if re.search(rf"^function {path.stem}\.Tick", path.read_text(encoding="utf-8"), re.M)
    }

    for name in sorted(has_tick - ticked):
        fail(f"server bootstrap: {name}.Tick is defined but never called")
    for name in sorted(ticked - has_tick):
        fail(f"server bootstrap: {name} is ticked but has no Tick function")


def check_remotes() -> None:
    """
    Every remote used must be declared, and every remote declared must be used.

    The second half matters as much as the first: an unused remote is attack
    surface for nothing.
    """
    net = read("shared/Net/Net.lua")
    declared = set(re.findall(r'^\t(\w+) = \{\n\t\tname = "\1",', net, re.M))

    used: set[str] = set()
    for path in SRC.rglob("*.lua"):
        if path.name == "Net.lua":
            continue
        used |= set(
            re.findall(
                r'Net\.(?:OnServerEvent|OnClientEvent|FireClient|FireAllClients'
                r'|FireServer|OnServerInvoke|Event|Function)\("(\w+)"',
                path.read_text(encoding="utf-8"),
            )
        )

    for name in sorted(used - declared):
        fail(f"Net: {name!r} is used but not declared")
    for name in sorted(declared - used):
        fail(f"Net: {name!r} is declared but never used")

    counts["remotes"] = len(declared)


def check_unused_requires() -> None:
    """Dead requires are weight in a file people have to read."""
    for path in sorted(SRC.rglob("*.lua")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            match = re.match(r"local (\w+) = require\(", line)
            if not match:
                continue
            name = match.group(1)
            rest = "\n".join(lines[:index] + lines[index + 1 :])
            if not re.search(rf"\b{name}\b", rest):
                fail(f"{path.relative_to(ROOT)}: {name} is required but never used")


# ---------------------------------------------------------------------------

CHECKS = [
    ("action timing", check_action_timing),
    ("Grace descriptions", check_boon_placeholders),
    ("Grace effect handlers", check_boon_effects_handled),
    ("room coverage", check_room_coverage),
    ("server wiring", lambda: check_registry_references(
        "server/Services", "Services", {"World", "Shared"}
    )),
    ("client wiring", lambda: check_registry_references(
        "client/Controllers", "Controllers", {"Shared", "Player", "ScreenGui"}
    )),
    ("server boot order", lambda: check_boot_order(
        "server/init.server.lua", "SERVICE_ORDER", "server/Services",
        {"ProfileTemplate", "EnemyAgent"},
    )),
    ("client boot order", lambda: check_boot_order(
        "client/init.client.lua", "CONTROLLER_ORDER", "client/Controllers", set()
    )),
    ("tick wiring", check_tick_wiring),
    ("remotes", check_remotes),
    ("unused requires", check_unused_requires),
]


def main() -> int:
    for label, check in CHECKS:
        before = len(problems)
        try:
            check()
        except Exception as error:  # a broken check is itself a failure
            fail(f"{label}: check crashed: {error!r}")
        status = "ok" if len(problems) == before else f"{len(problems) - before} problem(s)"
        print(f"  {label:<24} {status}")

    if counts:
        print("\n" + "  ".join(f"{value} {key}" for key, value in sorted(counts.items())))

    if problems:
        print(f"\n{len(problems)} problem(s):\n")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print("\ncontent checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
