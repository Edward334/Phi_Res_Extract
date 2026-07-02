#!/usr/bin/env python3
"""Check local prerequisites for updating and running the Phigros library app."""

from __future__ import annotations

import argparse
import importlib.util
import shutil
import subprocess
import sys
from dataclasses import dataclass

import phigros_updater


@dataclass
class Check:
    name: str
    ok: bool
    detail: str


def check_python_package(module: str) -> Check:
    found = importlib.util.find_spec(module) is not None
    return Check(module, found, "installed" if found else "missing")


def check_flutter() -> Check:
    flutter = shutil.which("flutter")
    if not flutter:
        return Check("flutter", False, "not found in PATH")
    result = subprocess.run(
        [flutter, "--version"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=20,
        check=False,
    )
    return Check(
        "flutter",
        result.returncode == 0,
        result.stdout.strip().splitlines()[0] if result.stdout.strip() else "no output",
    )


def check_typetree() -> Check:
    try:
        typetree = phigros_updater.fetch_json(phigros_updater.TYPETREE_URL)
    except Exception as exc:  # noqa: BLE001
        return Check("typetree", False, str(exc))
    ok = "GameInformation" in typetree
    return Check("typetree", ok, phigros_updater.TYPETREE_URL)


def check_taptap() -> Check:
    try:
        _, metadata = phigros_updater.latest_apk_url()
    except Exception as exc:  # noqa: BLE001
        return Check("taptap", False, str(exc))
    apk = phigros_updater.apk_info_from_metadata(metadata)
    detail = f"{apk.get('version_name', 'unknown')} ({apk.get('version_code', 'unknown')})"
    return Check("taptap", True, detail)


def print_checks(checks: list[Check]) -> int:
    width = max(len(check.name) for check in checks)
    failed = 0
    for check in checks:
        status = "ok" if check.ok else "fail"
        if not check.ok:
            failed += 1
        print(f"{check.name:<{width}}  {status:<4}  {check.detail}")
    return 1 if failed else 0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--network",
        action="store_true",
        help="Also check GitHub typetree and TapTap metadata endpoints.",
    )
    parser.add_argument(
        "--flutter",
        action="store_true",
        help="Also run flutter --version.",
    )
    args = parser.parse_args()

    checks = [
        check_python_package("UnityPy"),
        check_python_package("PIL"),
        check_python_package("fsb5"),
    ]
    if args.network:
        checks.extend([check_typetree(), check_taptap()])
    if args.flutter:
        checks.append(check_flutter())

    raise SystemExit(print_checks(checks))


if __name__ == "__main__":
    main()
