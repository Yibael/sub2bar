#!/usr/bin/env python3
"""Convert the pinned LobeHub SVGs to native SwiftUI paths.

Only needed when updating icons: pip install reportlab==4.4.9
Default: print generated Swift. --check: verify the checked-in Swift is current.
App builds and CI do not require ReportLab or access the network.
"""
import argparse
import hashlib
import pathlib
import sys
import xml.etree.ElementTree as ET

import reportlab
from reportlab.graphics.svgpath import SvgPath

ROOT = pathlib.Path(__file__).resolve().parents[1]
REVISION = "a94750e3f5f8fc33757b839d85030e742284e43a"
ICONS = {
    "openai": "a595df6b423920c67a7f8f73c063e4bfb72d415948097b6cac063a2366bb5186",
    "claude": "365a70a7eb3956d9b9a96086058ebe04e1dbd8e291a756ad964e8a283fbd6d38",
    "gemini": "87d5b3c4be75a66f54c1936482a263df68185545b741129badd1b7c2449c18d3",
    "antigravity": "43f551fd125c17fb54c8c74eb461924fb97f32bb64ac89f73bb73852753a6461",
}


def point(x, y):
    return f"CGPoint(x: {x:.6f}, y: {y:.6f})"


def generate():
    if reportlab.Version != "4.4.9":
        raise ValueError("Use reportlab==4.4.9 for reproducible conversion")
    lines = ["// Generated from LobeHub Icons (MIT), copyright (c) 2023 LobeHub.",
             f"// Upstream: {REVISION}. See THIRD_PARTY_NOTICES.md.",
             "// Do not hand-edit; source SVGs are in Resources/ProviderIcons.",
             "import SwiftUI", "", "enum LobeBrandPaths {"]
    for name, digest in ICONS.items():
        source = (ROOT / "Resources" / "ProviderIcons" / f"{name}.svg").read_bytes()
        if hashlib.sha256(source).hexdigest() != digest:
            raise ValueError(f"Unexpected SVG content: {name}")
        svg = ET.fromstring(source)
        if svg.get("viewBox") != "0 0 24 24" or svg.get("fill-rule") != "evenodd":
            raise ValueError(f"Unsupported SVG viewport/fill rule: {name}")
        lines.append(f"    static let {name} = Path {{ p in")
        for node in svg:
            kind = node.tag.rsplit("}", 1)[-1]
            if kind == "title":
                continue
            if kind != "path" or set(node.attrib) != {"d"}:
                raise ValueError(f"Unsupported SVG element: {name}/{kind}")
            path = SvgPath(node.attrib["d"])
            cursor = 0
            for operation in path.operators:
                count = {0: 2, 1: 2, 2: 6, 3: 0}[operation]
                values = path.points[cursor:cursor + count]
                cursor += count
                if operation == 0:
                    command = f"move(to: {point(*values)})"
                elif operation == 1:
                    command = f"addLine(to: {point(*values)})"
                elif operation == 2:
                    command = f"addCurve(to: {point(*values[4:6])}, control1: {point(*values[0:2])}, control2: {point(*values[2:4])})"
                else:
                    command = "closeSubpath()"
                lines.append(f"        p.{command}")
            if cursor != len(path.points):
                raise ValueError(f"Unconsumed path coordinates: {name}")
        lines.append("    }")
    lines.append("}")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = generate()
    if args.check:
        actual = (ROOT / "Sources" / "Sub2Bar" / "LobeBrandPaths.swift").read_text()
        if actual != output:
            sys.exit("Generated provider paths do not match the pinned SVGs")
        print("Provider vector paths verified: 4 icons")
    else:
        print(output, end="")
