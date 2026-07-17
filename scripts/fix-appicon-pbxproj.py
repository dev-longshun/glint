#!/usr/bin/env python3
"""Ensure AppIcon.icon is a single wrapper.icon resource in the Xcode project.

XcodeGen (and naive pbxproj regenerations) recurse into AppIcon.icon and add
icon.json / background.png / foreground.png as loose Copy Bundle Resources.
Icon Composer packages must stay as one `lastKnownFileType = wrapper.icon`
file reference so actool compiles them into AppIcon.icns.

Idempotent: safe to run after every `xcodegen generate`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBX = ROOT / "Glint.xcodeproj" / "project.pbxproj"

BUILD_ID = "A91EFEF0FEA392A0745724DE"
FILE_ID = "89B8883C4456681F07B6D662"

BUILD_LINE = (
    f"\t\t{BUILD_ID} /* AppIcon.icon in Resources */ = "
    f"{{isa = PBXBuildFile; fileRef = {FILE_ID} /* AppIcon.icon */; }};\n"
)
FILE_LINE = (
    f"\t\t{FILE_ID} /* AppIcon.icon */ = "
    f"{{isa = PBXFileReference; lastKnownFileType = wrapper.icon; "
    f"path = AppIcon.icon; sourceTree = \"<group>\"; }};\n"
)


def die(msg: str) -> None:
    print(f"fix-appicon-pbxproj: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if not PBX.is_file():
        die(f"missing {PBX}")

    text = PBX.read_text()
    original = text

    # Drop loose pieces of the Icon Composer package from Resources.
    loose_patterns = [
        r"^\t\t[0-9A-F]+ /\* background\.png in Resources \*/ = \{isa = PBXBuildFile;.*\n",
        r"^\t\t[0-9A-F]+ /\* foreground\.png in Resources \*/ = \{isa = PBXBuildFile;.*\n",
        r"^\t\t[0-9A-F]+ /\* icon\.json in Resources \*/ = \{isa = PBXBuildFile;.*\n",
        r"^\t\t[0-9A-F]+ /\* background\.png \*/ = \{isa = PBXFileReference;.*path = background\.png;.*\n",
        r"^\t\t[0-9A-F]+ /\* foreground\.png \*/ = \{isa = PBXFileReference;.*path = foreground\.png;.*\n",
        r"^\t\t[0-9A-F]+ /\* icon\.json \*/ = \{isa = PBXFileReference;.*path = icon\.json;.*\n",
        r"^\t\t\t\t[0-9A-F]+ /\* background\.png in Resources \*/,\n",
        r"^\t\t\t\t[0-9A-F]+ /\* foreground\.png in Resources \*/,\n",
        r"^\t\t\t\t[0-9A-F]+ /\* icon\.json in Resources \*/,\n",
    ]
    for pat in loose_patterns:
        text = re.sub(pat, "", text, flags=re.M)

    # Remove expanded PBXGroup for AppIcon.icon / nested Assets if present.
    text = re.sub(
        r"\t\t[0-9A-F]+ /\* Assets \*/ = \{\n"
        r"\t\t\tisa = PBXGroup;\n"
        r"\t\t\tchildren = \(\n"
        r"(?:\t\t\t\t[0-9A-F]+ /\* (?:background|foreground)\.png \*/,\n)*"
        r"\t\t\t\);\n"
        r"\t\t\tpath = Assets;\n"
        r"\t\t\tsourceTree = \"<group>\";\n"
        r"\t\t\};\n",
        "",
        text,
    )
    text = re.sub(
        r"\t\t[0-9A-F]+ /\* AppIcon\.icon \*/ = \{\n"
        r"\t\t\tisa = PBXGroup;\n"
        r"\t\t\tchildren = \(\n"
        r"(?:.*\n)*?"
        r"\t\t\t\);\n"
        r"\t\t\tpath = AppIcon\.icon;\n"
        r"\t\t\tsourceTree = \"<group>\";\n"
        r"\t\t\};\n",
        "",
        text,
    )

    # Ensure single wrapper.icon file reference.
    if "lastKnownFileType = wrapper.icon" not in text:
        anchor = (
            "\t\t3023490E670A10EC38870B12 /* Assets.xcassets */ = "
            "{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; "
            "path = Assets.xcassets; sourceTree = \"<group>\"; };\n"
        )
        if anchor in text:
            text = text.replace(anchor, anchor + FILE_LINE)
        else:
            # Fallback: insert at start of PBXFileReference section.
            m = re.search(r"/\* Begin PBXFileReference section \*/\n", text)
            if not m:
                die("PBXFileReference section not found")
            text = text[: m.end()] + FILE_LINE + text[m.end() :]
    elif FILE_ID not in text:
        # wrapper.icon exists under another id — leave it, still add ours only if needed.
        pass

    # Ensure PBXBuildFile for AppIcon.icon.
    if "AppIcon.icon in Resources */ = {isa = PBXBuildFile" not in text:
        anchor = (
            "\t\t942ED7C1C1A2E823BA52F67A /* Assets.xcassets in Resources */ = "
            "{isa = PBXBuildFile; fileRef = 3023490E670A10EC38870B12 /* Assets.xcassets */; };\n"
        )
        if anchor in text:
            text = text.replace(anchor, BUILD_LINE + anchor)
        else:
            m = re.search(r"/\* Begin PBXBuildFile section \*/\n", text)
            if not m:
                die("PBXBuildFile section not found")
            text = text[: m.end()] + BUILD_LINE + text[m.end() :]

    # Resources group children: prefer our FILE_ID.
    # Replace any group-style AppIcon.icon child with FILE_ID.
    text = re.sub(
        r"\t\t\t\t[0-9A-F]+ /\* AppIcon\.icon \*/,\n",
        f"\t\t\t\t{FILE_ID} /* AppIcon.icon */,\n",
        text,
        count=1,
    )
    if f"{FILE_ID} /* AppIcon.icon */," not in text:
        # Insert into Resources group children after Assets.xcassets if possible.
        resources_child_anchor = (
            "\t\t\t\t3023490E670A10EC38870B12 /* Assets.xcassets */,\n"
        )
        if resources_child_anchor in text:
            text = text.replace(
                resources_child_anchor,
                resources_child_anchor + f"\t\t\t\t{FILE_ID} /* AppIcon.icon */,\n",
                1,
            )

    # Resources build phase: ensure AppIcon.icon is first resource entry.
    if f"{BUILD_ID} /* AppIcon.icon in Resources */," not in text:
        phase_anchor = (
            "\t\t\t\t942ED7C1C1A2E823BA52F67A /* Assets.xcassets in Resources */,\n"
        )
        if phase_anchor not in text:
            die("Assets.xcassets in Resources phase entry not found")
        text = text.replace(
            phase_anchor,
            f"\t\t\t\t{BUILD_ID} /* AppIcon.icon in Resources */,\n" + phase_anchor,
            1,
        )

    if "lastKnownFileType = wrapper.icon" not in text:
        die("failed to install wrapper.icon file reference")
    if "AppIcon.icon in Resources" not in text:
        die("failed to install AppIcon.icon resource build file")
    if re.search(r"background\.png in Resources", text):
        die("loose background.png still in Resources")
    if re.search(r"icon\.json in Resources", text):
        die("loose icon.json still in Resources")

    if text != original:
        PBX.write_text(text)
        print("fix-appicon-pbxproj: rewrote AppIcon.icon as wrapper.icon")
    else:
        print("fix-appicon-pbxproj: already correct")


if __name__ == "__main__":
    main()
