#!/usr/bin/env python3
"""Fetch a Phigros APK and build a local song/resource library.

This tool is based on the public extraction approach used by
https://github.com/7aGiven/Phigros_Resource, but emits a catalog tailored for
the Flutter client in this repository.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import random
import shutil
import string
import sys
import time
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, field
from http.client import HTTPSConnection
from io import BytesIO
from pathlib import Path
from typing import Any
from zipfile import ZipFile


APP_ID = 165287
LEVELS = ("EZ", "HD", "IN", "AT")
TAPTAP_SECRET = "PeCkE6Fu0B10Vm9BKfPfANwCUAn5POcs"
UPSTREAM_RAW_BASE = "https://raw.githubusercontent.com/7aGiven/Phigros_Resource/master"
TYPETREE_URL = f"{UPSTREAM_RAW_BASE}/typetree.json"


@dataclass
class SongInfo:
    id: str
    title: str
    composer: str
    illustrator: str
    charters: list[str] = field(default_factory=list)
    difficulties: list[float] = field(default_factory=list)


class ByteReader:
    def __init__(self, data: bytes):
        self.data = data
        self.position = 0

    def read_int(self) -> int:
        self.position += 4
        chunk = self.data[self.position - 4 : self.position]
        return chunk[0] ^ chunk[1] << 8 ^ chunk[2] << 16


def file_md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as file:
        while True:
            chunk = file.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def apk_info_from_metadata(metadata: dict[str, Any] | None) -> dict[str, Any]:
    if not metadata:
        return {}
    return metadata.get("apk", {}).get("data", {}).get("apk", {}) or {}


def load_taptap_metadata(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf8"))
    if "metadata" in payload:
        return payload["metadata"]
    return payload


def compact_apk_payload(url: str, metadata: dict[str, Any]) -> dict[str, Any]:
    app = metadata.get("app", {}).get("data", {}) or {}
    apk = apk_info_from_metadata(metadata)
    return {
        "url": url,
        "name": apk.get("name"),
        "versionName": apk.get("version_name"),
        "versionCode": apk.get("version_code"),
        "size": apk.get("size"),
        "md5": apk.get("md5"),
        "updateDate": app.get("update_date"),
    }


def fetch_json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"User-Agent": "phigros-library-updater"})
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status >= 400:
            raise RuntimeError(f"{url} returned HTTP {response.status}")
        return json.loads(response.read())


def load_typetree(out_dir: Path, typetree_path: Path | None = None) -> dict[str, Any]:
    resolved = resolve_typetree_path(out_dir, typetree_path)
    if resolved:
        return json.loads(resolved.read_text(encoding="utf8"))

    target = out_dir / "typetree.json"
    print(f"fetching typetree: {TYPETREE_URL}")
    typetree = fetch_json(TYPETREE_URL)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(typetree, ensure_ascii=False, indent=2), encoding="utf8")
    return typetree


def resolve_typetree_path(out_dir: Path, typetree_path: Path | None = None) -> Path | None:
    candidates = [
        typetree_path,
        out_dir / "typetree.json",
        Path(__file__).with_name("typetree.json"),
    ]
    for candidate in candidates:
        if candidate and candidate.exists():
            return candidate
    return None


def read_object(obj: Any) -> Any:
    try:
        return obj.read()
    except ValueError:
        return obj.read(check_read=False)


def read_script_name(mono_behaviour: Any) -> str:
    data = read_object(mono_behaviour)
    script_ref = data.m_Script
    if hasattr(script_ref, "get_obj"):
        script = read_object(script_ref.get_obj())
    else:
        script = script_ref.read()
    return getattr(script, "m_Name", None) or getattr(script, "name", "")


def text_asset_bytes(obj: Any) -> bytes:
    value = getattr(obj, "script", None)
    if value is None:
        value = getattr(obj, "m_Script")
    if isinstance(value, str):
        return value.encode("utf8")
    return bytes(value)


def audio_clip_data(obj: Any) -> tuple[bytes, str]:
    if getattr(obj, "m_AudioData", None):
        data = bytes(obj.m_AudioData)
    elif getattr(obj, "m_Resource", None):
        from UnityPy.helpers.ResourceReader import get_resource_data

        resource = obj.m_Resource
        data = get_resource_data(
            resource.m_Source,
            obj.object_reader.assets_file,
            resource.m_Offset,
            resource.m_Size,
        )
    else:
        raise ValueError("AudioClip has neither m_AudioData nor m_Resource")

    magic = bytes(data[:8])
    if magic[:4] == b"OggS":
        return data, ".ogg"
    if magic[:4] == b"RIFF":
        return data, ".wav"
    if magic[4:8] == b"ftyp":
        return data, ".m4a"
    if magic[:4] == b"FSB5":
        from fsb5 import FSB5

        fsb = FSB5(data)
        return bytes(fsb.rebuild_sample(fsb.samples[0])), ".ogg"
    return data, ".bytes"


def taptap_user_agent() -> tuple[str, uuid.UUID]:
    uid = uuid.uuid4()
    return (
        "V=1&PN=TapTap&VN=2.40.1-rel.100000&VN_CODE=240011000&LOC=CN"
        f"&LANG=zh_CN&CH=default&UID={uid}&NT=1&SR=1080x2030"
        "&DEB=Xiaomi&DEM=Redmi+Note+5&OSV=9",
        uid,
    )


def request_json(
    method: str,
    host: str,
    path: str,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    conn = HTTPSConnection(host, timeout=30)
    conn.request(method, path, body=body, headers=headers or {})
    response = conn.getresponse()
    payload = response.read()
    if response.status >= 400:
        raise RuntimeError(f"{host}{path} returned HTTP {response.status}: {payload[:300]!r}")
    return json.loads(payload)


def find_first_url(value: Any) -> str | None:
    if isinstance(value, str) and value.startswith(("http://", "https://")):
        if ".apk" in value or "download" in value or "apk" in value:
            return value
    if isinstance(value, dict):
        preferred = (
            "download_url",
            "downloadUrl",
            "url",
            "uri",
            "apk_url",
            "apkUrl",
        )
        for key in preferred:
            url = find_first_url(value.get(key))
            if url:
                return url
        for item in value.values():
            url = find_first_url(item)
            if url:
                return url
    if isinstance(value, list):
        for item in value:
            url = find_first_url(item)
            if url:
                return url
    return None


def latest_apk_url() -> tuple[str, dict[str, Any]]:
    x_ua, uid = taptap_user_agent()
    detail = request_json(
        "GET",
        "api.taptapdada.com",
        f"/app/v2/detail-by-id/{APP_ID}?X-UA={urllib.parse.quote(x_ua)}",
        headers={"User-Agent": "okhttp/3.12.1"},
    )
    apk_id = detail["data"]["download"]["apk_id"]

    nonce = "".join(random.sample(string.ascii_lowercase + string.digits, 5))
    now = int(time.time())
    param = (
        "abi=arm64-v8a,armeabi-v7a,armeabi"
        f"&id={apk_id}&node={uid}&nonce={nonce}&sandbox=1"
        f"&screen_densities=xhdpi&time={now}"
    )
    sign_base = f"X-UA={x_ua}&{param}{TAPTAP_SECRET}"
    sign = hashlib.md5(sign_base.encode()).hexdigest()
    apk_detail = request_json(
        "POST",
        "api.taptapdada.com",
        f"/apk/v1/detail?X-UA={urllib.parse.quote(x_ua)}",
        body=f"{param}&sign={sign}".encode(),
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "okhttp/3.12.1",
        },
    )
    url = find_first_url(apk_detail)
    if not url:
        raise RuntimeError("TapTap response did not contain an APK download URL.")
    return url, {"app": detail, "apk": apk_detail}


def download(
    url: str,
    target: Path,
    expected_size: int | None = None,
    expected_md5: str | None = None,
    resume: bool = True,
) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and verify_apk(target, expected_size, expected_md5, quiet=True):
        print(f"using cached APK: {target}")
        return

    part = target.with_suffix(target.suffix + ".part")
    headers = {"User-Agent": "okhttp/3.12.1"}
    offset = part.stat().st_size if resume and part.exists() else 0
    if offset:
        headers["Range"] = f"bytes={offset}-"

    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        mode = "ab" if offset and response.status == 206 else "wb"
        if offset and response.status != 206:
            offset = 0
        downloaded = offset
        content_length = response.headers.get("Content-Length")
        total = expected_size or (offset + int(content_length) if content_length else None)
        last_log = 0.0
        with part.open(mode) as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
                downloaded += len(chunk)
                now = time.time()
                if now - last_log > 3:
                    last_log = now
                    if total:
                        percent = downloaded / total * 100
                        print(f"downloaded {downloaded}/{total} bytes ({percent:.1f}%)")
                    else:
                        print(f"downloaded {downloaded} bytes")

    part.replace(target)
    verify_apk(target, expected_size, expected_md5)


def verify_apk(
    apk_path: Path,
    expected_size: int | None = None,
    expected_md5: str | None = None,
    quiet: bool = False,
) -> bool:
    if expected_size and apk_path.stat().st_size != expected_size:
        if quiet:
            return False
        raise RuntimeError(
            f"APK size mismatch: expected {expected_size}, got {apk_path.stat().st_size}"
        )
    if expected_md5:
        actual_md5 = file_md5(apk_path)
        if actual_md5.lower() != expected_md5.lower():
            if quiet:
                return False
            raise RuntimeError(f"APK md5 mismatch: expected {expected_md5}, got {actual_md5}")
    return True


def read_addressables_table(apk_path: Path) -> list[tuple[str, str]]:
    with ZipFile(apk_path) as apk:
        with apk.open("assets/aa/catalog.json") as file:
            data = json.load(file)

    key_data = base64.b64decode(data["m_KeyDataString"])
    bucket_data = base64.b64decode(data["m_BucketDataString"])
    entry_data = base64.b64decode(data["m_EntryDataString"])

    table: list[list[Any]] = []
    reader = ByteReader(bucket_data)
    for _ in range(reader.read_int()):
        key_position = reader.read_int()
        key_type = key_data[key_position]
        key_position += 1
        if key_type == 0:
            length = key_data[key_position]
            key_position += 4
            key_value: str | int = key_data[key_position : key_position + length].decode()
        elif key_type == 1:
            length = key_data[key_position]
            key_position += 4
            key_value = key_data[key_position : key_position + length].decode("utf16")
        elif key_type == 4:
            key_value = key_data[key_position]
        else:
            raise RuntimeError(f"Unsupported addressable key type {key_type}")

        entry_value: int | None = None
        for _ in range(reader.read_int()):
            entry_position = reader.read_int()
            chunk = entry_data[4 + 28 * entry_position : 4 + 28 * entry_position + 28]
            entry_value = chunk[8] ^ chunk[9] << 8
        table.append([key_value, entry_value])

    for index, row in enumerate(table):
        if row[1] != 65535:
            row[1] = table[row[1]][0]

    result: list[tuple[str, str]] = []
    for key, bundle in table:
        if not isinstance(key, str) or not isinstance(bundle, str):
            continue
        if key.startswith("Assets/Tracks/#"):
            continue
        if key.startswith("Assets/Tracks/"):
            result.append((key.removeprefix("Assets/Tracks/"), bundle))
        elif key.startswith("avatar."):
            result.append((key, bundle))
    return result


def extract_game_information(
    apk_path: Path,
    out_dir: Path,
    typetree_path: Path | None = None,
) -> dict[str, SongInfo]:
    try:
        from UnityPy import Environment
    except ImportError as exc:
        raise RuntimeError("UnityPy is required: python -m pip install UnityPy") from exc

    env = Environment()
    with ZipFile(apk_path) as apk:
        for name in ("assets/bin/Data/globalgamemanagers.assets", "assets/bin/Data/level0"):
            with apk.open(name) as file:
                env.load_file(BytesIO(file.read()), name=name)

    game_information: dict[str, Any] | None = None
    for obj in env.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        if read_script_name(obj) != "GameInformation":
            continue
        try:
            game_information = obj.read_typetree()
        except (TypeError, ValueError):
            trees = load_typetree(out_dir, typetree_path)
            game_information = obj.read_typetree(trees["GameInformation"], check_read=False)
        break

    if not game_information:
        raise RuntimeError("GameInformation was not found in the APK.")

    songs: dict[str, SongInfo] = {}
    for group_name, group_songs in game_information["song"].items():
        if group_name == "otherSongs":
            continue
        for song in group_songs:
            song_id = str(song["songsId"]).removesuffix(".0")
            difficulties = [round(float(item), 1) for item in song["difficulty"] if float(item) > 0]
            charters = [str(item) for item in song["charter"][: len(difficulties)]]
            songs[song_id] = SongInfo(
                id=song_id,
                title=str(song["songsName"]),
                composer=str(song["composer"]),
                illustrator=str(song["illustrator"]),
                charters=charters,
                difficulties=difficulties[: len(LEVELS)],
            )
    return songs


def extract_track_assets(apk_path: Path, out_dir: Path, song_ids: set[str]) -> None:
    try:
        from UnityPy import Environment
        from UnityPy.enums import ClassIDType
    except ImportError as exc:
        raise RuntimeError("UnityPy is required: python -m pip install UnityPy") from exc

    chart_dir = out_dir / "chart"
    image_dir = out_dir / "illustration"
    music_dir = out_dir / "music"
    chart_dir.mkdir(parents=True, exist_ok=True)
    image_dir.mkdir(parents=True, exist_ok=True)
    music_dir.mkdir(parents=True, exist_ok=True)

    classes = (ClassIDType.TextAsset, ClassIDType.Sprite, ClassIDType.AudioClip)
    table = [
        (key, bundle)
        for key, bundle in read_addressables_table(apk_path)
        if should_extract_asset(key, song_ids)
    ]
    total = len(table)
    with ZipFile(apk_path) as apk:
        for index, (key, bundle) in enumerate(table, start=1):
            env = Environment()
            env.load_file(BytesIO(apk.read(f"assets/aa/Android/{bundle}")), name=key)
            for inner_key, entry in env.files.items():
                objects = entry.get_filtered_objects(classes)
                try:
                    obj = next(objects).read()
                except StopIteration:
                    continue
                save_resource(inner_key, obj, out_dir)
            if index == total or index == 1 or index % 12 == 0:
                percent = index / total * 100 if total else 100
                print(f"assets extracted {index}/{total} ({percent:.1f}%)", flush=True)


def should_extract_asset(key: str, song_ids: set[str]) -> bool:
    song_id = key.split(".0/", 1)[0]
    if song_id not in song_ids:
        return False
    return key.endswith(".json") or key.endswith(".0/music.wav") or ".0/Illustration" in key


def save_resource(key: str, obj: Any, out_dir: Path) -> None:
    if key.endswith(".json") and "/Chart_" in key:
        track_id = key.split("/Chart_", 1)[0]
        level = key.rsplit("Chart_", 1)[1].split(".", 1)[0]
        target = out_dir / "chart" / track_id / f"{level}.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text_asset_bytes(obj))
        return

    if ".0/IllustrationLowRes." in key or ".0/Illustration." in key:
        song_id = key.split(".0/", 1)[0]
        target = out_dir / "illustration" / f"{song_id}.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        obj.image.save(target)
        return

    if key.endswith(".0/music.wav"):
        song_id = key.removesuffix(".0/music.wav")
        data, extension = audio_clip_data(obj)
        target = out_dir / "music" / f"{song_id}{extension}"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


def apk_version_from_metadata(metadata: dict[str, Any] | None) -> tuple[str | None, int | None]:
    apk = apk_info_from_metadata(metadata)
    version_name = apk.get("version_name")
    version_code = apk.get("version_code")
    if version_code is not None:
        version_code = int(version_code)
    return version_name, version_code


def write_catalog(
    out_dir: Path,
    songs: dict[str, SongInfo],
    source: str,
    apk_metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    catalog_dir = out_dir / "catalog"
    catalog_dir.mkdir(parents=True, exist_ok=True)
    version_name, version_code = apk_version_from_metadata(apk_metadata)
    payload = {
        "schemaVersion": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": source,
        "apkVersionName": version_name,
        "apkVersionCode": version_code,
        "songs": [],
    }
    for song in songs.values():
        chart_paths = {}
        for index, level in enumerate(LEVELS[: len(song.difficulties)]):
            path = Path("chart") / f"{song.id}.0" / f"{level}.json"
            if (out_dir / path).exists():
                chart_paths[level] = path.as_posix()
        illustration = Path("illustration") / f"{song.id}.png"
        music_matches = sorted((out_dir / "music").glob(f"{song.id}.*")) if (out_dir / "music").exists() else []
        music_matches.sort(key=lambda path: {".ogg": 0, ".wav": 1, ".m4a": 2}.get(path.suffix, 99))
        music = music_matches[0].relative_to(out_dir) if music_matches else None
        payload["songs"].append(
            {
                "id": song.id,
                "title": song.title,
                "composer": song.composer,
                "illustrator": song.illustrator,
                "charters": song.charters,
                "difficulties": song.difficulties,
                "illustrationPath": illustration.as_posix() if (out_dir / illustration).exists() else None,
                "musicPath": music.as_posix() if music else None,
                "chartPaths": chart_paths,
            }
        )
    payload["songs"].sort(key=lambda item: item["title"])
    (catalog_dir / "songs.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf8",
    )
    return payload


def expected_resource_paths(catalog: dict[str, Any]) -> set[Path]:
    expected: set[Path] = set()
    for song in catalog["songs"]:
        for path in song.get("chartPaths", {}).values():
            expected.add(Path(path))
        if song.get("illustrationPath"):
            expected.add(Path(song["illustrationPath"]))
        if song.get("musicPath"):
            expected.add(Path(song["musicPath"]))
    return expected


def remove_empty_dirs(root: Path) -> None:
    if not root.exists():
        return
    for path in sorted(root.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if path.is_dir():
            try:
                path.rmdir()
            except OSError:
                pass


def cleanup_stale_resources(out_dir: Path, catalog: dict[str, Any]) -> list[str]:
    expected = expected_resource_paths(catalog)
    removed: list[str] = []
    for directory in ("chart", "illustration", "music"):
        root = out_dir / directory
        if not root.exists():
            continue
        for file in root.rglob("*"):
            if not file.is_file():
                continue
            relative = file.relative_to(out_dir)
            if relative not in expected:
                file.unlink()
                removed.append(relative.as_posix())
        remove_empty_dirs(root)
    return removed


def write_manifest(
    out_dir: Path,
    catalog: dict[str, Any],
    source: str,
    apk_path: Path,
    apk_metadata: dict[str, Any] | None,
    removed: list[str],
    typetree_path: Path | None = None,
) -> None:
    apk_info = apk_info_from_metadata(apk_metadata)
    chart_count = sum(len(song.get("chartPaths", {})) for song in catalog["songs"])
    illustration_count = sum(1 for song in catalog["songs"] if song.get("illustrationPath"))
    music_count = sum(1 for song in catalog["songs"] if song.get("musicPath"))
    manifest = {
        "schemaVersion": 1,
        "generatedAt": catalog["generatedAt"],
        "source": source,
        "apk": {
            "path": apk_path.as_posix(),
            "versionName": catalog.get("apkVersionName"),
            "versionCode": catalog.get("apkVersionCode"),
            "name": apk_info.get("name"),
            "size": apk_info.get("size") or (apk_path.stat().st_size if apk_path.exists() else None),
            "md5": apk_info.get("md5") or (file_md5(apk_path) if apk_path.exists() else None),
        },
        "resources": {
            "songs": len(catalog["songs"]),
            "charts": chart_count,
            "illustrations": illustration_count,
            "music": music_count,
            "removedStaleFiles": removed,
        },
        "upstream": {
            "resourceRepository": "https://github.com/7aGiven/Phigros_Resource",
            "typetreeUrl": TYPETREE_URL,
            "typetreePath": (
                resolve_typetree_path(out_dir, typetree_path) or out_dir / "typetree.json"
            ).as_posix(),
        },
    }
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf8",
    )


def run_update(args: argparse.Namespace) -> None:
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    apk_path = Path(args.apk) if args.apk else out_dir / "apk" / "phigros_latest.apk"
    metadata = None
    if args.metadata:
        metadata = load_taptap_metadata(Path(args.metadata))

    if args.apk:
        source = str(apk_path)
    else:
        print("fetching latest TapTap APK metadata")
        url, metadata = latest_apk_url()
        (out_dir / "apk").mkdir(parents=True, exist_ok=True)
        (out_dir / "apk" / "taptap_metadata.json").write_text(
            json.dumps(metadata, ensure_ascii=False, indent=2),
            encoding="utf8",
        )
        print(f"downloading APK: {url}")
        apk_info = apk_info_from_metadata(metadata)
        download(
            url,
            apk_path,
            expected_size=apk_info.get("size"),
            expected_md5=apk_info.get("md5"),
            resume=not args.no_resume,
        )
        source = url

    apk_info = apk_info_from_metadata(metadata)
    verify_apk(apk_path, apk_info.get("size"), apk_info.get("md5"))

    typetree_path = Path(args.typetree) if args.typetree else None

    print("extracting GameInformation")
    songs = extract_game_information(apk_path, out_dir, typetree_path)
    print(f"found {len(songs)} songs")

    if not args.catalog_only:
        print("extracting charts, illustrations, and music")
        selected_songs = set(args.song or songs)
        unknown = selected_songs.difference(songs)
        if unknown:
            raise RuntimeError(f"Unknown song id(s): {', '.join(sorted(unknown))}")
        extract_track_assets(apk_path, out_dir, selected_songs)

    catalog = write_catalog(out_dir, songs, source, metadata)
    removed = [] if args.no_clean else cleanup_stale_resources(out_dir, catalog)
    write_manifest(out_dir, catalog, source, apk_path, metadata, removed, typetree_path)
    print(f"wrote {out_dir / 'catalog' / 'songs.json'}")
    print(f"wrote {out_dir / 'manifest.json'}")
    if removed:
        print(f"removed {len(removed)} stale resource file(s)")


def run_resolve_apk(args: argparse.Namespace) -> None:
    out = Path(args.out) if args.out else None
    url, metadata = latest_apk_url()
    if args.compact:
        payload = compact_apk_payload(url, metadata)
    else:
        payload = {"url": url, "metadata": metadata}
    text = json.dumps(payload, ensure_ascii=False, indent=2)
    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf8")
    print(text)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve = subparsers.add_parser("resolve-apk")
    resolve.add_argument("--out", help="Optional path for latest APK metadata JSON.")
    resolve.add_argument(
        "--compact",
        action="store_true",
        help="Only print the APK download URL and fields needed by the app.",
    )
    resolve.set_defaults(func=run_resolve_apk)

    update = subparsers.add_parser("update")
    update.add_argument("--apk", help="Use an existing APK instead of downloading from TapTap.")
    update.add_argument("--metadata", help="TapTap metadata JSON from resolve-apk.")
    update.add_argument(
        "--typetree",
        help="Use a specific typetree.json instead of the cached/upstream copy.",
    )
    update.add_argument("--out", default=".phigros_library")
    update.add_argument(
        "--catalog-only",
        action="store_true",
        help="Only extract song metadata; skip charts, images, and audio.",
    )
    update.add_argument(
        "--song",
        action="append",
        help="Extract resources for one song id; repeat for multiple songs. Catalog still includes all songs.",
    )
    update.add_argument(
        "--no-clean",
        action="store_true",
        help="Keep stale chart, illustration, and music files after catalog generation.",
    )
    update.add_argument(
        "--no-resume",
        action="store_true",
        help="Disable partial APK download resume.",
    )
    update.set_defaults(func=run_update)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
