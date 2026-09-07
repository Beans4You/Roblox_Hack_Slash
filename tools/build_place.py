#!/usr/bin/env python3
"""
Builds a Roblox place file (.rbxlx) straight from the source tree.

WHY THIS EXISTS
    The normal way to get this project into Studio is Rojo. Rojo is the right
    tool and you should use it if you are going to work on the game. But it is a
    toolchain install, and if you only want to *look* at the thing, that is a
    lot of setup to ask for.

    .rbxlx is Roblox's XML place format: plain text, fully documented, and
    entirely writable from a script. So this produces a place you can
    double-click, with no dependencies beyond Python.

WHAT YOU GIVE UP versus Rojo
    Live sync. Rojo streams file edits into an open Studio session; this makes a
    snapshot. Edit the files, re-run this, reopen. Fine for looking, painful for
    developing.

USAGE
    python3 tools/build_place.py [-o HollowVerge.rbxlx]
"""

from __future__ import annotations

import argparse
import pathlib
import sys
import xml.etree.ElementTree as ElementTree

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

_referent = 0


def next_referent() -> str:
    global _referent
    _referent += 1
    return f"RBX{_referent}"


def item(parent: ElementTree.Element | None, class_name: str) -> ElementTree.Element:
    element = ElementTree.Element("Item", {"class": class_name, "referent": next_referent()})
    if parent is not None:
        parent.append(element)
    return element


def properties(element: ElementTree.Element) -> ElementTree.Element:
    existing = element.find("Properties")
    if existing is not None:
        return existing
    props = ElementTree.Element("Properties")
    # Properties must precede child Items in the XML, which is why this inserts
    # at the front rather than appending.
    element.insert(0, props)
    return props


def prop(element: ElementTree.Element, kind: str, name: str, value: str) -> None:
    node = ElementTree.SubElement(properties(element), kind, {"name": name})
    node.text = value


def prop_color(element: ElementTree.Element, name: str, rgb: tuple[float, float, float]) -> None:
    node = ElementTree.SubElement(properties(element), "Color3", {"name": name})
    for channel, value in zip("RGB", rgb):
        ElementTree.SubElement(node, channel).text = f"{value:.6f}"


def set_name(element: ElementTree.Element, name: str) -> None:
    prop(element, "string", "Name", name)


def set_source(element: ElementTree.Element, source: str) -> None:
    """
    Source goes in a ProtectedString. ElementTree has no CDATA support, so the
    text is escaped normally -- Roblox reads escaped text back correctly, and it
    sidesteps the `]]>` problem CDATA would have with Lua long-bracket syntax.
    """
    prop(element, "ProtectedString", "Source", source)


# ---------------------------------------------------------------------------
# Tree building
# ---------------------------------------------------------------------------

def add_directory(parent: ElementTree.Element, directory: pathlib.Path) -> None:
    """Mirrors a folder of .lua files into Folders and ModuleScripts."""
    for path in sorted(directory.iterdir()):
        if path.is_dir():
            folder = item(parent, "Folder")
            set_name(folder, path.name)
            add_directory(folder, path)
        elif path.suffix == ".lua":
            module = item(parent, "ModuleScript")
            set_name(module, path.stem)
            set_source(module, path.read_text(encoding="utf-8"))


def add_script_directory(
    parent: ElementTree.Element, directory: pathlib.Path, class_name: str, init_name: str
) -> None:
    """
    A directory containing `init.server.lua` or `init.client.lua` becomes a
    Script/LocalScript carrying that source, with the rest of the directory as
    its children. This is Rojo's init convention, reproduced.
    """
    script = item(parent, class_name)
    set_name(script, "HollowVerge")
    set_source(script, (directory / init_name).read_text(encoding="utf-8"))
    prop(script, "bool", "Disabled", "false")

    for path in sorted(directory.iterdir()):
        if path.is_dir():
            folder = item(script, "Folder")
            set_name(folder, path.name)
            add_directory(folder, path)


def build() -> ElementTree.Element:
    root = ElementTree.Element(
        "roblox",
        {
            "xmlns:xmime": "http://www.w3.org/2005/05/xmlmime",
            "xmlns:xsi": "http://www.w3.org/2001/XMLSchema-instance",
            "xsi:noNamespaceSchemaLocation": "http://www.roblox.com/roblox.xsd",
            "version": "4",
        },
    )
    ElementTree.SubElement(root, "External").text = "null"
    ElementTree.SubElement(root, "External").text = "nil"

    workspace = item(root, "Workspace")
    prop(workspace, "bool", "FilteringEnabled", "true")

    # Emberhold is built at runtime at Y=200, so the place ships empty. The
    # lighting here is the hub mood; RoomBuilder retunes it per region.
    lighting = item(root, "Lighting")
    prop_color(lighting, "Ambient", (0.13, 0.12, 0.16))
    prop_color(lighting, "OutdoorAmbient", (0.09, 0.08, 0.12))
    prop_color(lighting, "FogColor", (0.09, 0.08, 0.12))
    prop(lighting, "float", "Brightness", "2")
    prop(lighting, "float", "FogEnd", "480")
    prop(lighting, "float", "FogStart", "60")
    prop(lighting, "float", "ClockTime", "17.5")
    prop(lighting, "bool", "GlobalShadows", "true")
    prop(lighting, "token", "Technology", "3")  # ShadowMap
    prop(lighting, "float", "EnvironmentDiffuseScale", "0.6")
    prop(lighting, "float", "EnvironmentSpecularScale", "0.6")

    sound_service = item(root, "SoundService")
    prop(sound_service, "bool", "RespectFilteringEnabled", "true")

    replicated = item(root, "ReplicatedStorage")
    shared = item(replicated, "Folder")
    set_name(shared, "HollowVerge")
    add_directory(shared, SRC / "shared")

    server_scripts = item(root, "ServerScriptService")
    add_script_directory(server_scripts, SRC / "server", "Script", "init.server.lua")

    starter_player = item(root, "StarterPlayer")
    starter_scripts = item(starter_player, "StarterPlayerScripts")
    # Roblox matches services by class, but naming it keeps the Explorer tidy and
    # makes the file readable if anyone opens it in a text editor.
    set_name(starter_scripts, "StarterPlayerScripts")
    add_script_directory(starter_scripts, SRC / "client", "LocalScript", "init.client.lua")

    return root


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--output", default="HollowVerge.rbxlx")
    args = parser.parse_args()

    root = build()
    ElementTree.indent(root, space="\t")
    tree = ElementTree.ElementTree(root)

    destination = pathlib.Path(args.output)
    tree.write(destination, encoding="utf-8", xml_declaration=True)

    # Re-parse what we just wrote. A place file that Studio refuses to open is
    # worse than no place file, and malformed XML is the likeliest way to get one.
    try:
        ElementTree.parse(destination)
    except ElementTree.ParseError as error:
        print(f"generated file is not valid XML: {error}", file=sys.stderr)
        return 1

    scripts = len(root.findall(".//Item[@class='ModuleScript']"))
    scripts += len(root.findall(".//Item[@class='Script']"))
    scripts += len(root.findall(".//Item[@class='LocalScript']"))
    size_mb = destination.stat().st_size / 1024 / 1024

    print(f"wrote {destination}  ·  {scripts} scripts  ·  {size_mb:.1f} MB")
    print("Open it in Roblox Studio and press Play (F5).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
