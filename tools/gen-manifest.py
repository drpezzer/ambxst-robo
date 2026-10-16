#!/usr/bin/env python3
"""Writes mod/ambxst.mod.json: one overlay per payload file + the patch.

The version and the compatibility block (the Ambxst bases the patch was
tested on) are kept from the manifest already there; bump the version with
`--version X.Y.Z`, add a tested base with `--tested-base <commit>`.

`--public` writes the public repo's manifest (no private-build notice,
AGPL-3.0-or-later); the public repo's copy of this file (tools/export-public.sh)
has PUBLIC_REPO = True and no private-build branch. payload/assets/robo/sounds-public (the public repo's
built-in sounds, kept here for the export) is never an overlay here.

It also writes payload/modules/robo/core/RELEASE (version=, build=public or
personal): the daemon version the mod installs and expects (RoboCore.qml,
robo-core-install.sh); a personal build never installs one.
"""
import argparse, json, os, subprocess

root = os.path.join(os.path.dirname(__file__), "..", "mod")
path = os.path.join(root, "ambxst.mod.json")

ap = argparse.ArgumentParser()
ap.add_argument("--version")
ap.add_argument("--tested-base", action="append", default=[])
ap.add_argument("--public", action="store_true")
args = ap.parse_args()
PUBLIC_REPO = True
public = args.public or PUBLIC_REPO

old = {}
if os.path.exists(path):
    with open(path) as fh:
        old = json.load(fh)
compat = old.get("compatibility") or {"api": 1, "ambxst": ">=1.3.10 <2.0.0", "testedBaseCommits": []}
for c in args.tested_base:
    if c not in compat.setdefault("testedBaseCommits", []):
        compat["testedBaseCommits"].append(c)

# Tracked files only: work in progress lying in payload/ (new sounds…) stays out.
tracked = set(subprocess.run(["git", "ls-files", "-z", "payload"], cwd=root, check=True,
                             capture_output=True, text=True).stdout.split("\0")) - {""}
ops = [{"type": "patch", "source": "patches/ambxst-robo.patch"}]
for d, _, files in sorted(os.walk(os.path.join(root, "payload"))):
    for f in sorted(files):
        full = os.path.join(d, f)
        if os.path.relpath(full, root) not in tracked:
            continue
        if os.path.relpath(full, os.path.join(root, "payload")).startswith(os.path.join("assets", "robo", "sounds-public") + os.sep):
            continue
        rel = os.path.relpath(full, root)
        ops.append({"type": "overlay", "source": rel, "target": os.path.relpath(full, os.path.join(root, "payload"))})
LICENSE = "AGPL-3.0-or-later"
NOTE = ""
DESCRIPTION = "Ambxst Robo in Ambxst's notch, a port of Coucou (Louis-CFM/coucou): Robo watches your AI coding agents, lets you approve and answer from the notch, chat, drop files and keep an eye on your services."
manifest = {
    "$schema": "https://raw.githubusercontent.com/Axenide/Ambxst/dev/docs/mods/manifest.schema.json",
    "manifestVersion": 1,
    "id": "drpezzer.ambxst-robo",
    "name": "Ambxst Robo",
    "version": args.version or old.get("version") or "0.1.0",
    "description": DESCRIPTION + NOTE,
    "license": LICENSE,
    "author": "drpezzer",
    "homepage": "https://github.com/drpezzer/ambxst-robo",
    "compatibility": compat,
    "dependencies": [],
    "conflicts": [],
    # Not "ambxst-robo": the mod installs its daemon itself (modules/robo/core),
    # and a command missing on PATH would stop Ambxst from enabling it at all.
    "commands": [],
    "permissions": [
        "Installs and updates its daemon itself: downloads ambxst-robo from this project's GitHub release for the mod's version (sha256-checked; built with cargo where no download fits), puts it in ~/.local/bin and runs it as the systemd user service ambxst-robo.service",
        "Talks to ambxst-robo (a user service) over $XDG_RUNTIME_DIR/ambxst-robo-core.sock",
        "Takes over SUPER+A (`ambxst run assistant`) and the bar's logo",
        "Opens the notch on its own for permission requests and questions, without taking the keyboard",
    ],
    "operations": ops,
}
# The version the mod's core installer (payload/modules/robo/core) installs
# and the shell expects from the daemon; a personal build never installs one.
release = os.path.join(root, "payload", "modules", "robo", "core", "RELEASE")
with open(release, "w") as fh:
    fh.write(f"version={manifest['version']}\nbuild={'public' if public else 'personal'}\n")
with open(path, "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
print(len(ops), "operations, version", manifest["version"])
