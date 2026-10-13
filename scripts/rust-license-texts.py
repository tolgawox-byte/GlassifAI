#!/usr/bin/env python3
"""License texts of the crates.io packages in the native bridge (iOS target).

Reads `cargo metadata --filter-platform aarch64-apple-ios` (JSON) and the crate
sources Cargo already downloaded, and prints one text file:

  1. every package with its declared license and the texts that apply;
  2. each distinct license text once (Apache-2.0 is shared by hundreds of
     crates; MIT notices differ by their copyright line, so they stay apart).

Path packages (the bridge, the vendored Codex crates) are skipped: their
licenses are in the repository. A crate whose published package has no
license file gets the text from rust-license-supplements/ when that folder
has one for it: the license file of the crate's repository at the commit the
crate was published from (sources.json says where each came from). Used by
CI (JARVIS plan 1.16); never fails.
"""
import hashlib
import json
import pathlib
import sys

NAMES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT", "UNLICENSE")
SUPPLEMENTS = pathlib.Path(__file__).resolve().with_name("rust-license-supplements")


def license_files(root: pathlib.Path) -> list[pathlib.Path]:
    try:
        entries = sorted(root.iterdir())
    except OSError:
        return []
    return [entry for entry in entries if entry.is_file() and entry.name.upper().startswith(NAMES)]


def supplements() -> dict[str, dict]:
    try:
        return json.loads((SUPPLEMENTS / "sources.json").read_text(encoding="utf-8"))["crates"]
    except (OSError, ValueError, KeyError):
        return {}


def main() -> int:
    meta = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    packages = {package["id"]: package for package in meta.get("packages", [])}
    nodes = (meta.get("resolve") or {}).get("nodes") or []
    ids = [node["id"] for node in nodes] or list(packages)
    extra = supplements()

    texts: dict[str, tuple[str, str]] = {}  # digest -> (label, text)
    users: dict[str, list[str]] = {}
    lines = []
    for package_id in sorted(ids, key=lambda key: (packages[key]["name"], packages[key]["version"])):
        package = packages[package_id]
        if package.get("source") is None:
            continue
        name = f"{package['name']} {package['version']}"
        declared = package.get("license") or "not declared"
        found = [(path.name, f"{path.name} of {name}", path)
                 for path in license_files(pathlib.Path(package["manifest_path"]).parent)]
        supplement = extra.get(name) if not found else None
        if supplement and (SUPPLEMENTS / supplement["file"]).is_file():
            # Nothing in the published crate: the text from its repository.
            found = [(supplement["label"], f"{supplement['label']}, for {name}", SUPPLEMENTS / supplement["file"])]
        refs = []
        for ref_label, first_label, path in found:
            text = path.read_text(encoding="utf-8", errors="replace").strip()
            if not text:
                continue
            digest = hashlib.sha256(" ".join(text.split()).encode()).hexdigest()[:12]
            if digest not in texts:
                texts[digest] = (first_label, text)
            users.setdefault(digest, []).append(name)
            refs.append(f"[{digest}] {ref_label}")
        lines.append(f"{name} — {declared}" + (": " + ", ".join(refs) if refs else " (no license file in the published crate)"))

    out = [
        "Rust crates in the AutoLoom native bridge (iOS target), from Cargo.lock.",
        f"{len(lines)} packages, {len(texts)} distinct license texts.",
        "",
        "=" * 72,
        "Packages",
        "=" * 72,
        *lines,
    ]
    for digest, (label, text) in texts.items():
        used = users.get(digest, [])
        out += [
            "",
            "=" * 72,
            f"[{digest}] first seen as {label}; used by {len(used)} package(s)",
            "=" * 72,
            text,
        ]
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # CI must never fail on this
        print(f"license collection failed: {error}", file=sys.stderr)
        sys.exit(0)
