#!/usr/bin/env python3
"""Export only source, tests, resources and public documentation."""
from pathlib import Path
import sys
import zipfile

root = Path(__file__).resolve().parent.parent
destination = Path(sys.argv[1]).resolve()
if destination.exists():
    raise SystemExit("Destination already exists")
allowed = ["Sources", "Tests", "Resources", "scripts", ".github", "Package.swift",
           "Package.resolved", "README.md", "BUILDING.md", "LICENSE", "THIRD_PARTY_NOTICES.md", ".gitignore"]
files = []
for name in allowed:
    path = root / name
    files.extend(sorted(path.rglob("*")) if path.is_dir() else [path])
files = [p for p in files if p.is_file() and not p.is_symlink() and p.name != ".DS_Store"]
for path in files:
    if path.suffix in {".pem", ".p12", ".p8", ".key", ".keychain-db"}:
        raise SystemExit("Private signing material cannot be exported")
destination.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in files:
        archive.write(path, Path("Langg") / path.relative_to(root))
print(f"Exported {len(files)} files")
