#!/usr/bin/env python3
"""Validate and normalize the BOOX 4.2.1 home-screen AppDatabase."""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import time
import uuid
from pathlib import Path


TABLE = "AppItemModel"
EXPECTED_COLUMNS = ["id", "time", "x", "y", "data", "page", "type", "source", "position"]
PLAY_STORE = "com.android.vending"
MAGISK = "com.topjohnwu.magisk"
STORAGE_ACTION = "com.onyx.action.STORAGE"
SETTINGS_ACTION = "com.onyx.action.SETTING"
WIDGET_PROVIDERS = {
    "com.onyx.common.applications.appwidget.widget.LibraryRecentlyReadProvider",
    "com.onyx.common.applications.appwidget.widget.NoteListWidgetProvider",
}


class LayoutError(RuntimeError):
    pass


def connect(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    return connection


def validate_database(connection: sqlite3.Connection) -> None:
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise LayoutError(f"SQLite integrity check failed: {integrity}")
    table = connection.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (TABLE,)
    ).fetchone()
    if table is None:
        raise LayoutError(f"Required launcher table is missing: {TABLE}")
    columns = [row[1] for row in connection.execute(f'PRAGMA table_info("{TABLE}")')]
    if columns != EXPECTED_COLUMNS:
        raise LayoutError(f"Unknown launcher schema: {columns}")


def decode(row: sqlite3.Row) -> dict:
    try:
        value = json.loads(row["data"])
    except (TypeError, json.JSONDecodeError) as exc:
        raise LayoutError(f"Invalid JSON in launcher row {row['id']}: {exc}") from exc
    if not isinstance(value, dict):
        raise LayoutError(f"Launcher row {row['id']} is not a JSON object")
    return value


def package_name(item: dict) -> str:
    package = item.get("packageName")
    if isinstance(package, str):
        return package
    component = item.get("componentName")
    if isinstance(component, dict) and isinstance(component.get("packageName"), str):
        return component["packageName"]
    return ""


def is_boox_item(item: dict) -> bool:
    package = package_name(item)
    action = item.get("action", "")
    return package == "com.onyx" or package.startswith("com.onyx.") or (
        isinstance(action, str) and action.startswith("com.onyx.")
    )


def item_key(item: dict) -> tuple[str, str, str, str]:
    return (
        str(item.get("launchName", "")),
        str(item.get("activityClassName", "")),
        str(item.get("action", "")),
        package_name(item),
    )


def updated_item(item: dict, x: int, y: int, page: int = 0) -> dict:
    result = dict(item)
    result.update({"x": x, "y": y, "page": page})
    return result


def make_row(item: dict, item_type: str, position: str, x: int, y: int, now: int) -> tuple:
    item = updated_item(item, x, y)
    return (
        now,
        x,
        y,
        json.dumps(item, ensure_ascii=False, separators=(",", ":")),
        0,
        item_type,
        str(item.get("source", "NONE")),
        position,
    )


def collect(connection: sqlite3.Connection) -> tuple[list[sqlite3.Row], list[dict]]:
    rows = list(connection.execute(f'SELECT * FROM "{TABLE}" ORDER BY id'))
    decoded = [decode(row) for row in rows]
    return rows, decoded


def normalized_rows(connection: sqlite3.Connection) -> tuple[list[tuple], dict]:
    rows, decoded = collect(connection)
    storage = None
    settings = None
    play = None
    magisk = None
    widgets: dict[str, dict] = {}
    existing_group = None
    tools: list[dict] = []
    seen: set[tuple[str, str, str, str]] = set()

    def add_tool(item: dict) -> None:
        nonlocal storage, settings
        if item.get("action") == STORAGE_ACTION:
            storage = item
            return
        if item.get("action") == SETTINGS_ACTION:
            settings = item
            return
        if not is_boox_item(item):
            return
        key = item_key(item)
        if key not in seen:
            seen.add(key)
            tools.append(item)

    for row, item in zip(rows, decoded):
        kind = str(row["type"])
        if kind == "GROUP":
            children = item.get("appInfoList", [])
            if isinstance(children, list):
                for child in children:
                    if isinstance(child, dict):
                        add_tool(child)
            if existing_group is None:
                existing_group = item
        elif kind == "WIDGET":
            provider = item.get("providerClsName")
            if provider in WIDGET_PROVIDERS:
                widgets[provider] = item
        elif kind == "APP":
            package = package_name(item)
            if package == PLAY_STORE:
                play = item
            elif package == MAGISK:
                magisk = item
            else:
                add_tool(item)

    missing = []
    if storage is None:
        missing.append("Storage")
    if settings is None:
        missing.append("Settings")
    if play is None:
        missing.append("Play Store")
    if magisk is None:
        missing.append("Magisk")
    missing_widgets = WIDGET_PROVIDERS.difference(widgets)
    if missing_widgets:
        missing.extend(sorted(missing_widgets))
    if missing:
        raise LayoutError("Required reference items are missing: " + ", ".join(missing))
    if len(tools) < 12:
        raise LayoutError(f"Refusing an incomplete Tools folder containing only {len(tools)} BOOX items")

    now = int(time.time() * 1000)
    group = dict(existing_group or {})
    identifier = str(group.get("idString") or uuid.uuid4().hex)
    group.update(
        {
            "appInfoList": tools,
            "colSpan": 1,
            "idString": identifier,
            "launchName": identifier,
            "name": "Tool",
            "page": 0,
            "rowSpan": 1,
            "source": "NONE",
            "spanSize": 1,
            "time": now,
            "type": "GROUP",
            "x": 0,
            "y": 2,
        }
    )

    library_provider = "com.onyx.common.applications.appwidget.widget.LibraryRecentlyReadProvider"
    notes_provider = "com.onyx.common.applications.appwidget.widget.NoteListWidgetProvider"
    result = [
        make_row(storage, "APP", "Dock", 2, 0, now),
        make_row(settings, "APP", "Dock", 3, 0, now + 1),
        make_row(widgets[library_provider], "WIDGET", "Desktop", 0, 0, now + 2),
        make_row(widgets[notes_provider], "WIDGET", "Desktop", 3, 0, now + 3),
        make_row(group, "GROUP", "Desktop", 0, 2, now + 4),
        make_row(play, "APP", "Desktop", 1, 2, now + 5),
        make_row(magisk, "APP", "Desktop", 2, 2, now + 6),
    ]
    summary = {"topLevelItems": 7, "toolsItems": len(tools), "desktopApps": [PLAY_STORE, MAGISK]}
    return result, summary


def apply_layout(connection: sqlite3.Connection) -> dict:
    validate_database(connection)
    rows, summary = normalized_rows(connection)
    with connection:
        connection.execute(f'DELETE FROM "{TABLE}"')
        connection.executemany(
            f'INSERT INTO "{TABLE}" (time,x,y,data,page,type,source,position) VALUES (?,?,?,?,?,?,?,?)',
            rows,
        )
    validate_database(connection)
    verify_layout(connection)
    return summary


def verify_layout(connection: sqlite3.Connection) -> dict:
    validate_database(connection)
    rows, decoded = collect(connection)
    if len(rows) != 7:
        raise LayoutError(f"Expected 7 top-level launcher items, found {len(rows)}")
    dock = [item for row, item in zip(rows, decoded) if row["position"] == "Dock"]
    if {item.get("action") for item in dock} != {STORAGE_ACTION, SETTINGS_ACTION}:
        raise LayoutError("Dock is not limited to Storage and Settings")
    desktop_apps = {
        package_name(item)
        for row, item in zip(rows, decoded)
        if row["position"] == "Desktop" and row["type"] == "APP"
    }
    if desktop_apps != {PLAY_STORE, MAGISK}:
        raise LayoutError(f"Unexpected desktop app set: {sorted(desktop_apps)}")
    groups = [item for row, item in zip(rows, decoded) if row["type"] == "GROUP"]
    if len(groups) != 1 or len(groups[0].get("appInfoList", [])) < 12:
        raise LayoutError("The single Tools folder is missing or incomplete")
    providers = {
        item.get("providerClsName")
        for row, item in zip(rows, decoded)
        if row["type"] == "WIDGET"
    }
    if providers != WIDGET_PROVIDERS:
        raise LayoutError("Library/Notes widget set did not verify")
    return {
        "topLevelItems": len(rows),
        "toolsItems": len(groups[0]["appInfoList"]),
        "desktopApps": sorted(desktop_apps),
        "dockActions": sorted(str(item.get("action")) for item in dock),
        "widgets": sorted(str(value) for value in providers),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("inspect", "apply", "verify"))
    parser.add_argument("database", type=Path)
    args = parser.parse_args()
    if not args.database.is_file():
        raise LayoutError(f"Database does not exist: {args.database}")
    connection = connect(args.database)
    try:
        if args.command == "apply":
            result = apply_layout(connection)
        elif args.command == "verify":
            result = verify_layout(connection)
        else:
            validate_database(connection)
            rows, _ = collect(connection)
            result = {"topLevelItems": len(rows), "schema": EXPECTED_COLUMNS, "integrity": "ok"}
    finally:
        connection.close()
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LayoutError as exc:
        print(f"home-layout error: {exc}", file=sys.stderr)
        raise SystemExit(2)
