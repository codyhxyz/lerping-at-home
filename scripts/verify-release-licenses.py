#!/usr/bin/env python3
"""Audit the commercial release inventory, or audit real staged bundles/ZIP/DMG.

With no arguments (or --dry-run), check the source inventory and show what
will be excluded. --filter-staged applies that policy to bundle copies before
signing, then audits them. Every other mode is read-only on its inputs.
"""

import argparse
from contextlib import contextmanager
import json
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
from tempfile import TemporaryDirectory
from zipfile import BadZipFile, ZipFile

ROOT = Path(__file__).resolve().parent.parent
SAVER = "Lerping@Home.saver"
PLAYGROUND = "LerpPlayground.app"
BUNDLES = {SAVER, PLAYGROUND}
CAPTURE_LICENSES = {
    "CC BY 4.0": "https://creativecommons.org/licenses/by/4.0/",
    "CC BY-SA 4.0": "https://creativecommons.org/licenses/by-sa/4.0/",
}
SHADER_LICENSES = {"AGPL-3.0-or-later", "Apache-2.0", "MIT", "CC-BY-4.0", "CC0-1.0", "Unlicense"}
RESTRICTED = re.compile(
    r"\bCC[- ]BY[- ]NC\b|\bnon[-\s]?commercial\b|\blicen[cs]e\s*[:=]\s*none\b|\bpublished with no licen[cs]e\b", re.I
)
SLUG = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
SPLAT_FILE = re.compile(r"(.+)\.(?:lsplat|path\.json)$", re.I)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def directive(source_lines, name):
    # Match the first directive in the runtime's 40-line metadata header.
    for line in source_lines[:40]:
        match = re.match(r"^\s*//\s*" + name + r":\s*(.*)$", line, re.I)
        if match:
            return match[1].strip()
    return ""


class Policy:
    def __init__(self):
        manifest = read_json(ROOT / "Packaging/release-allowlist.json")
        captures = read_json(ROOT / "Sources/Splats/captures.json")["captures"]
        self.notice = (ROOT / "NOTICE.txt").read_bytes()
        notice = " ".join(self.notice.decode("utf-8").split())
        for dependency, anchors in manifest["dependency_notices"].items():
            require(anchors and all(anchor in notice for anchor in anchors), f"NOTICE.txt: missing {dependency} attribution")
        midi = read_json(ROOT / "Sources/MIDIDeps/Package.resolved")
        for pin in midi["pins"]:
            label = f"{pin['identity']} {pin['state']['version']}"
            require(label in notice, f"NOTICE.txt: missing versioned attribution for {label}")
        mediapipe_version = re.search(r"^MEDIAPIPE_VERSION\s*:=\s*(\S+)", (ROOT / "Makefile").read_text(), re.M)
        require(mediapipe_version and f"@mediapipe/tasks-vision {mediapipe_version[1]}" in notice,
                "NOTICE.txt: missing versioned MediaPipe attribution")
        self.capture_ids = set()
        self.excluded_captures = {}
        for name, data in captures.items():
            require(SLUG.fullmatch(name), f"invalid capture ID: {name}")
            license_name = data.get("license", "none").strip()
            if license_name.casefold() in {"none", "", "nc"} or RESTRICTED.search(license_name):
                require(name not in manifest["captures"], f"{name}: restricted license {license_name!r} is in the release allowlist")
                self.excluded_captures[name] = license_name
                continue
            require(license_name in CAPTURE_LICENSES and manifest["captures"].get(name) == license_name,
                    f"{name}: unreviewed license {license_name!r}; reconcile the allowlist and NOTICE.txt")
            for field in ("title", "author", "page"):
                require(data[field] and data[field] in notice, f"NOTICE.txt: missing {field} for {name}")
            require(CAPTURE_LICENSES[license_name] in notice, f"NOTICE.txt: missing {license_name} license link")
            self.capture_ids.add(name)
        require(set(manifest["captures"]) == self.capture_ids, "release allowlist contains unknown capture IDs")

        reviewed_shaders = {}
        for license_name, names in manifest["shaders_by_license"].items():
            require(license_name in SHADER_LICENSES, f"unreviewed shader license: {license_name}")
            for name in names:
                require(name not in reviewed_shaders, f"shader is listed more than once: {name}")
                reviewed_shaders[name] = license_name
        self.shaders = {}
        self.excluded_shaders = {}
        self.still_exclusions = set()
        for path in sorted((ROOT / "Sources/Shaders").glob("*.metal")):
            name = path.stem
            require(SLUG.fullmatch(name), f"invalid shader ID: {name}")
            text = path.read_text(encoding="utf-8")
            lines = text.splitlines()
            data = directive(lines, "lerp-data").split(":")
            if data[0] == "splat":
                require(len(data) >= 3 and data[2] in captures, f"{path.name}: unknown splat capture")
                capture = data[2]
                if capture in self.excluded_captures:
                    self.excluded_shaders[name] = capture
                    continue
                require(captures[capture]["license"] in text, f"{path.name}: capture license absent from shader credits")
            else:
                require(not name.startswith("splat-"), f"{path.name}: missing splat directive")
                license_name = reviewed_shaders.pop(name, None)
                require(license_name, f"{path.name}: missing shader review in allowlist")
                if license_name not in {"AGPL-3.0-or-later", "Apache-2.0"}:
                    require(f"Sources/Shaders/{path.name}" in notice, f"NOTICE.txt: missing attribution for {path.name}")
                if license_name == "Apache-2.0":
                    require("paper-design/shaders (Apache-2.0)" in lines[0], f"{path.name}: missing Paper Shaders license credit")
                    require(lines[0][3:].split(" — ", 1)[0] in notice,
                            f"NOTICE.txt: missing Paper Shaders port {path.name}")
            require(not RESTRICTED.search(text), f"{path.name}: restricted license in a release shader")
            self.shaders[name] = path.read_bytes()
            # These looks are our code, but their locally rendered stills can
            # include assets extracted from the user's copy of Minecraft.
            if re.match(r"^minecraft\b", directive(lines, "lerp-requires")):
                self.still_exclusions.add(name)
        require(not reviewed_shaders, f"release allowlist contains unknown shaders: {', '.join(sorted(reviewed_shaders))}")
        self.still_exclusions.update(self.excluded_shaders)
        # Keep in sync with LerpThumbnailRecipe's filename slug (IDs are ASCII).
        self.blocked_still_prefixes = tuple(name[:28] + "-" for name in sorted(self.still_exclusions))
        self.allowed_still_prefixes = tuple(name[:28] + "-" for name in sorted(self.shaders))

    def restricted_asset(self, path):
        name = path.name.casefold()
        capture = SPLAT_FILE.fullmatch(name)
        return (capture is not None and capture[1] in self.excluded_captures
                or name.endswith(".metal") and name[:-6] in self.excluded_shaders
                or name.endswith((".heic", ".png")) and name.startswith(self.blocked_still_prefixes))

    def audit_bundle(self, bundle, remove_restricted=False):
        require(bundle.name in BUNDLES and bundle.is_dir() and not bundle.is_symlink(), f"not a release bundle: {bundle}")
        resources = bundle / "Contents/Resources"
        require(resources.is_dir(), f"missing bundle resources: {resources}")
        shaders, captures = set(), set()
        for path in sorted(bundle.rglob("*")):
            require(not path.is_symlink(), f"unexpected symlink in release bundle: {path}")
            if path.is_dir():
                continue
            if self.restricted_asset(path):
                require(remove_restricted, f"restricted asset in release: {path}")
                path.unlink()
                print(f"release licenses: excluded {bundle.name}/{path.relative_to(bundle)}")
                continue
            if path.suffix.lower() == ".metal" or path.parent == resources / "Shaders":
                require(path.parent == resources / "Shaders" and path.name == f"{path.stem}.metal"
                        and self.shaders.get(path.stem) == path.read_bytes(), f"unexpected shader in release: {path}")
                shaders.add(path.stem)
            elif SPLAT_FILE.fullmatch(path.name) or path.parent == resources / "Splats":
                match = SPLAT_FILE.fullmatch(path.name)
                require(path.parent == resources / "Splats" and match and match[1] in self.capture_ids
                        and path.name == path.name.lower(), f"unexpected splat asset in release: {path}")
                if path.suffix == ".lsplat":
                    captures.add(match[1])
            elif resources / "Thumbnails" in path.parents:
                require(path.parent == resources / "Thumbnails"
                        and path.name.startswith(self.allowed_still_prefixes) and path.suffix == ".heic",
                        f"unexpected gallery still in release: {path}")
        require(shaders == self.shaders.keys(), f"{bundle.name}: missing shaders: {', '.join(sorted(self.shaders.keys() - shaders))}")
        require(captures == self.capture_ids, f"{bundle.name}: missing captures: {', '.join(sorted(self.capture_ids - captures))}")
        require((resources / "NOTICE.txt").read_bytes() == self.notice, f"{bundle.name}: staged NOTICE.txt is stale")
        print(f"release licenses: {bundle.name}: {len(shaders)} shaders, {len(captures)} captures")


@contextmanager
def staged_root(artifact):
    if artifact.is_dir():
        yield artifact, None
        return
    with TemporaryDirectory(prefix="lerp-license-") as tmp:
        work = Path(tmp)
        if artifact.suffix.lower() == ".zip":
            with ZipFile(artifact) as archive:
                entries = set()
                for info in archive.infolist():
                    path = PurePosixPath(info.filename)
                    require(path.parts and not path.is_absolute() and ".." not in path.parts and path not in entries,
                            f"unsafe or duplicate ZIP entry: {info.filename}")
                    entries.add(path)
                    require(not stat.S_ISLNK(info.external_attr >> 16), f"unexpected ZIP symlink: {info.filename}")
                    # ditto preserves notarization xattrs as AppleDouble files.
                    if path.parts[0] != "__MACOSX":
                        require(path.parts[0] == SAVER, f"unexpected file outside saver in release ZIP: {path}")
                        archive.extract(info, work)
            yield work, {SAVER}
        elif artifact.suffix.lower() == ".dmg":
            mount = work / "mounted"
            mount.mkdir()
            subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(artifact)],
                           check=True, stdout=subprocess.DEVNULL)
            try:
                payload = [p for p in mount.iterdir() if p.name != ".DS_Store"]
                require(len(payload) == 1 and payload[0].suffix == ".pkg" and payload[0].is_file(),
                        "expected only the installer package in the release DMG")
                expanded = work / "expanded"
                subprocess.run(["pkgutil", "--expand-full", str(payload[0]), str(expanded)], check=True)
                yield expanded, BUNDLES
            finally:
                subprocess.run(["hdiutil", "detach", str(mount)], check=True, stdout=subprocess.DEVNULL)
        else:
            raise ValueError(f"expected a staged directory, DMG or ZIP: {artifact}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="show planned release exclusions (the default)")
    mode.add_argument("--filter-staged", metavar="BUNDLE", nargs="+", type=Path,
                      help="filter and audit these unsigned staging copies under build/release")
    parser.add_argument("artifacts", nargs="*", type=Path, metavar="STAGE/DMG/ZIP")
    args = parser.parse_args()
    if args.artifacts and (args.dry_run or args.filter_staged):
        parser.error("pass artifact paths alone, or use --dry-run or --filter-staged")
    try:
        policy = Policy()
        if args.filter_staged:
            release = (ROOT / "build/release").resolve()
            for bundle in args.filter_staged:
                require(release in bundle.resolve().parents, f"filtering is only permitted under {release}")
                policy.audit_bundle(bundle, remove_restricted=True)
        elif args.artifacts:
            for artifact in args.artifacts:
                with staged_root(artifact.resolve()) as (root, expected):
                    bundles = [root] if root.name in BUNDLES else [p for p in root.rglob("*") if p.name in BUNDLES]
                    names = {p.name for p in bundles}
                    require(names and len(names) == len(bundles) and (expected is None or names == expected),
                            f"{artifact}: missing or duplicate release bundles")
                    for path in root.rglob("*"):
                        if not path.is_dir() and policy.restricted_asset(path):
                            raise ValueError(f"restricted asset in release: {path}")
                    for bundle in sorted(bundles):
                        policy.audit_bundle(bundle)
        else:
            print(f"release licenses: {len(policy.shaders)} allowed shaders, {len(policy.capture_ids)} allowed captures")
            for capture, license_name in sorted(policy.excluded_captures.items()):
                shaders = ", ".join(n for n, c in policy.excluded_shaders.items() if c == capture)
                print(f"  exclude {capture} ({license_name}): capture, camera path, shaders and stills [{shaders}]")
            print("  exclude locally generated Minecraft stills")
    except (OSError, ValueError, KeyError, TypeError, BadZipFile, subprocess.CalledProcessError) as exc:
        print(f"release licenses: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
