#!/usr/bin/env python3
"""Parse cicd input YAML and emit env/output values for the workflow."""

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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Load cicd inputs and write env/output files.")
    parser.add_argument("--inputs-file", required=True, help="Path to the YAML inputs file")
    parser.add_argument("--env", required=True, help="Path to GITHUB_ENV")
    parser.add_argument("--output", required=True, help="Path to GITHUB_OUTPUT")
    return parser.parse_args()


def to_env_value(value: Any) -> str:
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return ""
    return str(value)


def normalize_app_entries(entries: Any) -> tuple[list[str], list[dict[str, Any]]]:
    if isinstance(entries, list):
        iterable = entries
    elif isinstance(entries, str) and entries.strip():
        try:
            parsed = json.loads(entries)
            iterable = parsed if isinstance(parsed, list) else [entries]
        except json.JSONDecodeError:
            iterable = [entries]
    else:
        iterable = []

    app_names: list[str] = []
    app_matrix: list[dict[str, Any]] = []

    for entry in iterable:
        if isinstance(entry, dict):
            if "name" not in entry:
                raise SystemExit("Each app entry must include a 'name' field.")
            normalized = {k: v for k, v in entry.items() if v is not None}
        else:
            normalized = {"name": str(entry)}
        normalized["name"] = str(normalized["name"])
        app_names.append(normalized["name"])
        app_matrix.append(normalized)

    return app_names, app_matrix


def main() -> int:
    args = parse_args()
    inputs_path = Path(args.inputs_file)
    if not inputs_path.is_file():
        print(f"❌ Error: File {inputs_path} not found!", file=sys.stderr)
        return 1

    ensure_module("yaml", "pyyaml")
    import yaml  # type: ignore

    with inputs_path.open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}

    app_names, app_matrix = normalize_app_entries(data.get("app_names", []))

    env_path = Path(args.env)
    with env_path.open("a", encoding="utf-8") as env_file:
        for key, value in data.items():
            env_file.write(f"{key}={to_env_value(value)}\n")
        env_file.write(f"app_names={json.dumps(app_names)}\n")
        env_file.write(f"app_matrix={json.dumps(app_matrix)}\n")

    output_path = Path(args.output)
    with output_path.open("a", encoding="utf-8") as output_file:
        output_file.write(f"app_names={json.dumps(app_names)}\n")
        output_file.write(f"app_matrix={json.dumps(app_matrix)}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
