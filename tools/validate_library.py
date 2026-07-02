#!/usr/bin/env python3
"""Validate that a generated Phigros library catalog points to real files."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def validate_library(library: Path) -> int:
    catalog_path = library / "catalog" / "songs.json"
    if not catalog_path.exists():
        raise FileNotFoundError(f"catalog not found: {catalog_path}")

    catalog = json.loads(catalog_path.read_text(encoding="utf8"))
    missing: list[str] = []
    chart_count = 0
    illustration_count = 0
    music_count = 0

    for song in catalog.get("songs", []):
        for rel in song.get("chartPaths", {}).values():
            chart_count += 1
            if not (library / rel).exists():
                missing.append(rel)

        illustration = song.get("illustrationPath")
        if illustration:
            illustration_count += 1
            if not (library / illustration).exists():
                missing.append(illustration)

        music = song.get("musicPath")
        if music:
            music_count += 1
            if not (library / music).exists():
                missing.append(music)

    print(f"songs: {len(catalog.get('songs', []))}")
    print(f"charts: {chart_count}")
    print(f"illustrations: {illustration_count}")
    print(f"music: {music_count}")

    if missing:
        print(f"missing referenced files: {len(missing)}")
        for rel in missing[:50]:
            print(f"  {rel}")
        return 1

    print("missing referenced files: 0")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", default=".phigros_library")
    args = parser.parse_args()
    raise SystemExit(validate_library(Path(args.library)))


if __name__ == "__main__":
    main()
