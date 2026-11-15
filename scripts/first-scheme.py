#!/usr/bin/env python3
"""Print the first scheme from `xcodebuild -list -json` read on stdin.

Some Xcode versions print package resolution progress before the JSON document,
so parsing starts at the first brace instead of assuming clean output.
"""
import json
import sys

raw = sys.stdin.read()
start = raw.find("{")
try:
    if start < 0:
        raise ValueError("no JSON object in xcodebuild output")
    listing, _ = json.JSONDecoder().raw_decode(raw[start:])
    container = listing.get("workspace") or listing["project"]
    print(container["schemes"][0])
except (ValueError, KeyError, IndexError) as error:
    sys.stderr.write(f"first-scheme: {error}\nxcodebuild output was:\n{raw}\n")
    sys.exit(1)
