#!/usr/bin/env python3
"""Adds a release to altstore/source.json, newest first.

Usage: update-altstore-source.py VERSION BUILD IPA_PATH DOWNLOAD_URL [NOTES]
"""
import datetime
import json
import os
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "altstore" / "source.json"


def main() -> None:
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    version, build, ipa, url = sys.argv[1:5]
    notes = sys.argv[5] if len(sys.argv) > 5 else f"PagePocket {version}"

    source = json.loads(SOURCE.read_text())
    app = source["apps"][0]
    entry = {
        "version": version,
        "buildVersion": build,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": notes,
        "downloadURL": url,
        "size": os.path.getsize(ipa),
        "minOSVersion": "17.0",
    }
    # Re-running a release replaces its entry instead of duplicating it.
    app["versions"] = [entry] + [v for v in app["versions"] if v["version"] != version]

    SOURCE.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
    print(f"source.json: {version} ({build}) -> {url}")


if __name__ == "__main__":
    main()
