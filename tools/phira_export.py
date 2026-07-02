#!/usr/bin/env python3
"""Generate Phira .pez packages from an extracted Phigros library."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


LEVELS = ("EZ", "HD", "IN", "AT")


def load_catalog(library: Path) -> dict:
    catalog = library / "catalog" / "songs.json"
    if not catalog.exists():
        raise FileNotFoundError(f"catalog not found: {catalog}")
    return json.loads(catalog.read_text(encoding="utf8"))


def add_if_exists(package: ZipFile, source: Path, arcname: str) -> bool:
    if not source.exists():
        return False
    package.write(source, arcname)
    return True


def export_song(
    library: Path,
    out_dir: Path,
    song: dict,
    allow_incomplete: bool = False,
) -> tuple[list[Path], list[str]]:
    exported: list[Path] = []
    skipped: list[str] = []
    song_id = song["id"]
    for index, difficulty in enumerate(song.get("difficulties", [])):
        if index >= len(LEVELS):
            continue
        level = LEVELS[index]
        level_dir = out_dir / level
        level_dir.mkdir(parents=True, exist_ok=True)
        target = level_dir / f"{song_id}-{level}.pez"
        chart_rel = song.get("chartPaths", {}).get(level)
        music_rel = song.get("musicPath")
        image_rel = song.get("illustrationPath")
        music_name = f"{song_id}{Path(music_rel).suffix if music_rel else '.ogg'}"
        required = {
            f"{song_id}.json": library / chart_rel if chart_rel else None,
            f"{song_id}.png": library / image_rel if image_rel else None,
            music_name: library / music_rel if music_rel else None,
        }
        missing = [name for name, path in required.items() if path is None or not path.exists()]
        if missing and not allow_incomplete:
            skipped.append(f"{song_id}-{level}: missing {', '.join(missing)}")
            continue

        charter = song.get("charters", [""] * len(LEVELS))
        info_txt = "\n".join(
            [
                "#",
                f"Name: {song.get('title', song_id)}",
                f"Song: {music_name}",
                f"Picture: {song_id}.png",
                f"Chart: {song_id}.json",
                f"Level: {level} Lv.{difficulty}",
                f"Composer: {song.get('composer', '')}",
                f"Illustrator: {song.get('illustrator', '')}",
                f"Charter: {charter[index] if index < len(charter) else ''}",
            ]
        )

        with ZipFile(target, "w", compression=ZIP_DEFLATED) as package:
            package.writestr("info.txt", info_txt)
            for arcname, path in required.items():
                if path:
                    add_if_exists(package, path, arcname)
        exported.append(target)
    return exported, skipped


def run(args: argparse.Namespace) -> None:
    library = Path(args.library)
    out_dir = Path(args.out)
    catalog = load_catalog(library)
    selected = set(args.song or [])
    count = 0
    skipped: list[str] = []
    for song in catalog.get("songs", []):
        if selected and song["id"] not in selected:
            continue
        exported, song_skipped = export_song(
            library,
            out_dir,
            song,
            allow_incomplete=args.allow_incomplete,
        )
        count += len(exported)
        skipped.extend(song_skipped)
    print(f"exported {count} packages to {out_dir}")
    if skipped:
        print(f"skipped {len(skipped)} incomplete package(s)")
        for item in skipped:
            print(f"  {item}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", default=".phigros_library")
    parser.add_argument("--out", default=".phigros_library/phira")
    parser.add_argument("--song", action="append", help="Export one song id; repeat for multiple songs.")
    parser.add_argument(
        "--allow-incomplete",
        action="store_true",
        help="Write .pez files even when chart, image, or music is missing.",
    )
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
