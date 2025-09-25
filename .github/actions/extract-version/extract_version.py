#!/usr/bin/env python3
"""Utility for extracting version values from JSON or TOML files."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


def ensure_module(module: str, package: str | None = None) -> None:
    try:
        __import__(module)
    except ImportError:
        subprocess.check_call([sys.executable, "-m", "pip", "install", package or module])
        __import__(module)


def load_structured_file(path: Path) -> Any:
    suffix = path.suffix.lower()
    if suffix == ".json":
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    if suffix == ".toml":
        try:
            import tomllib  # type: ignore[attr-defined]
        except ModuleNotFoundError:
            ensure_module("tomli")
            import tomli as tomllib  # type: ignore
        with path.open("rb") as handle:
            return tomllib.load(handle)
    raise ValueError(f"Unsupported file type: {suffix}")


def extract_with_path(data: Any, key_path: str) -> Any:
    current = data
    for key in key_path.split('.'):
        if isinstance(current, dict) and key in current:
            current = current[key]
        else:
            raise KeyError(f"Path '{key_path}' not found.")
    return current


def find_first_version(data: Any) -> Any:
    if isinstance(data, dict):
        if "version" in data and isinstance(data["version"], (str, int, float)):
            return data["version"]
        for value in data.values():
            try:
                return find_first_version(value)
            except LookupError:
                continue
    elif isinstance(data, list):
        for item in data:
            try:
                return find_first_version(item)
            except LookupError:
                continue
    raise LookupError("No version value found.")


def coerce_to_string(value: Any) -> str:
    if isinstance(value, (str, int, float)):
        return str(value)
    raise TypeError("Version value must be a string or number.")


def get_version_from_file(path: Path, key: str | None) -> str:
    data = load_structured_file(path)
    if key:
        value = extract_with_path(data, key)
    else:
        value = find_first_version(data)
    return coerce_to_string(value)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract a version value from a structured file.")
    parser.add_argument("--file", required=True, help="Path to the file containing the version value.")
    parser.add_argument("--key", help="Dot-delimited path to the desired version entry.")
    return parser.parse_args()


def main() -> int:
    options = parse_args()
    file_path = Path(options.file)

    if not file_path.exists():
        print(f"File not found: {file_path}", file=sys.stderr)
        return 1

    try:
        version = get_version_from_file(file_path, options.key)
    except (LookupError, KeyError, ValueError, TypeError) as exc:
        print(f"Failed to locate version value: {exc}", file=sys.stderr)
        return 1

    print(version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
