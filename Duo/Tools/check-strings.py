#!/usr/bin/env python3
"""Checks Duo/Resources/Localizable.xcstrings against the strings the compiler extracted.

Every key used in code (`String(localized:)`, `LocalizedStringKey`, `LocalizedStringResource`) must
be in the catalog with an English translation; catalog keys no longer used are reported as stale.
Xcode's IDE does this sync automatically; command-line builds do not, hence this script.

Usage: Duo/Tools/check-strings.py <DerivedData>/Build/Intermediates.noindex/Duo.build/Debug/Duo.build
Exit status 1 when a key is missing or untranslated.
"""
import glob
import json
import pathlib
import sys

build_dir = pathlib.Path(sys.argv[1])
catalog_path = pathlib.Path(__file__).resolve().parent.parent / "Resources" / "Localizable.xcstrings"

used = set()
for path in glob.glob(str(build_dir / "**" / "*.stringsdata"), recursive=True):
    for entries in json.load(open(path)).get("tables", {}).values():
        used.update(entry["key"] for entry in entries)

strings = json.load(open(catalog_path))["strings"]


def translated(entry):
    en = entry.get("localizations", {}).get("en", {})
    if "stringUnit" in en:
        return en["stringUnit"].get("state") == "translated"
    other = en.get("variations", {}).get("plural", {}).get("other", {})
    return other.get("stringUnit", {}).get("state") == "translated"


missing = sorted(k for k in used if k not in strings)
untranslated = sorted(k for k in used if k in strings and not translated(strings[k]))
stale = sorted(k for k in strings if k not in used)
print(f"{len(used)} keys in code, {len(strings)} in the catalog")
for title, keys in (("missing", missing), ("untranslated", untranslated), ("stale", stale)):
    for key in keys:
        print(f"{title}: {key!r}")
sys.exit(1 if missing or untranslated else 0)
