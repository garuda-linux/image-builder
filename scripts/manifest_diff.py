#!/usr/bin/env python3
"""Lists the package changes between two mkosi manifests (ManifestFormat=json).

Usage: manifest-diff <old.manifest> <new.manifest>
"""

import json
import sys

USAGE = "usage: manifest-diff <old.manifest> <new.manifest>"


def packages(path):
    try:
        with open(path) as f:
            manifest = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit(f"manifest-diff: cannot read {path}: {e}")
    return {p["name"]: p["version"] for p in manifest.get("packages", [])}


def diff(old, new):
    lines = []
    for name in sorted(old.keys() | new.keys()):
        if name not in old:
            lines.append(f"added    {name} {new[name]}")
        elif name not in new:
            lines.append(f"removed  {name} {old[name]}")
        elif old[name] != new[name]:
            lines.append(f"updated  {name} {old[name]} -> {new[name]}")
    return lines


def main():
    args = sys.argv[1:3]
    if len(args) < 2 or not all(args):
        sys.exit(USAGE)
    lines = diff(packages(args[0]), packages(args[1]))
    print("\n".join(lines) if lines else "no package changes")


if __name__ == "__main__":
    main()
