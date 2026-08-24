#!/usr/bin/env python3
"""Convert XML or binary plist values into deterministic JSON."""

import base64
import datetime
import json
import plistlib
import sys


def json_value(value):
    if isinstance(value, bytes):
        return base64.b64encode(value).decode("ascii")
    if isinstance(value, datetime.datetime):
        normalized = value.astimezone(datetime.timezone.utc) if value.tzinfo else value.replace(tzinfo=datetime.timezone.utc)
        return normalized.isoformat().replace("+00:00", "Z")
    if isinstance(value, dict):
        return {str(key): json_value(child) for key, child in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_value(child) for child in value]
    if isinstance(value, plistlib.UID):
        return value.data
    return value


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: plist-to-json.py PLIST_PATH")

    with open(sys.argv[1], "rb") as plist_file:
        value = plistlib.load(plist_file)
    json.dump(json_value(value), sys.stdout, ensure_ascii=False, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
