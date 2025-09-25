#!/usr/bin/env python3
"""Generate matrices and metadata for the build-and-deploy workflow."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


def load_apps(app_matrix_raw: str | None, raw_names: str | None) -> list[dict[str, Any]]:
    if app_matrix_raw:
        return json.loads(app_matrix_raw)
    names = json.loads(raw_names or "[]")
    return [{"name": name} for name in names]


def load_init_pods(init_raw: str | None) -> list[str]:
    if not init_raw:
        return []
    try:
        value = json.loads(init_raw)
    except json.JSONDecodeError:
        value = init_raw
    if isinstance(value, list):
        return value
    return [str(value)]


def add_extract_version_path(workspace: Path) -> None:
    sys.path.insert(0, str(workspace / ".github" / "actions" / "extract-version"))


def get_version_for_app(
    workspace: Path,
    app: dict[str, Any],
    default_file: str,
    default_key: str | None,
) -> str:
    from extract_version import get_version_from_file  # type: ignore

    version_file = str(app.get("version_file") or default_file)
    version_key = app.get("version_key") or default_key

    resolved = (workspace / version_file).resolve()
    if not resolved.exists():
        raise SystemExit(f"Version file '{version_file}' not found for app '{app['name']}'.")

    return get_version_from_file(resolved, version_key)


def main() -> int:
    workspace = Path(os.environ.get("GITHUB_WORKSPACE", "."))
    add_extract_version_path(workspace)

    apps = load_apps(
        os.environ.get("APP_MATRIX"),
        os.environ.get("RAW_APP_NAMES"),
    )

    if not apps:
        raise SystemExit("At least one app must be defined in app_names.")

    init_list = load_init_pods(os.environ.get("INIT_PODS"))

    default_version_file = (os.environ.get("DEFAULT_VERSION_FILE") or "./package.json").strip()
    default_version_key = (os.environ.get("DEFAULT_VERSION_KEY") or "").strip() or None

    versions: dict[str, str] = {}

    for app in apps:
        if "name" not in app:
            raise SystemExit("Each app entry must include a 'name' field.")
        app["name"] = str(app["name"])

        version = get_version_for_app(
            workspace,
            app,
            default_version_file,
            default_version_key,
        )

        dockerfile = str(app.get("dockerfile") or app["name"])
        context = str(app.get("context") or app.get("build_context") or ".")
        etcd_name = str(app.get("etcd_app_name") or app.get("etcd_name") or app["name"])
        manifest_name = str(app.get("manifest_name") or app["name"])
        version_file = str(app.get("version_file") or default_version_file)
        effective_version_key = app.get("version_key") or default_version_key

        app.update(
            {
                "version_file": version_file,
                "dockerfile": dockerfile,
                "context": context,
                "etcd_name": etcd_name,
                "manifest_name": manifest_name,
                "version": version,
            }
        )
        if effective_version_key:
            app["version_key"] = str(effective_version_key)
        else:
            app.pop("version_key", None)

        versions[app["name"]] = version

    unique_versions = sorted(set(versions.values()))
    primary_version = apps[0]["version"] if apps else ""
    should_tag = "true" if len(unique_versions) == 1 else "false"

    if not init_list:
        init_list = ["__no_init__"]

    output_values = {
        "matrix_apps": json.dumps(apps),
        "matrix_init": json.dumps(init_list),
        "app_versions": json.dumps(versions),
        "unique_versions": json.dumps(unique_versions),
        "primary_version": primary_version,
        "should_tag": should_tag,
    }

    output_path = Path(os.environ["GITHUB_OUTPUT"])
    with output_path.open("a", encoding="utf-8") as out:
        for key, value in output_values.items():
            out.write(f"{key}={value}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
