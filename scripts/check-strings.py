"""Checks Configuration/Localizable.xcstrings before it goes into the app: every string is translated into every
language Outbound speaks, each translation keeps the placeholders of the English, and none uses an em dash.
Prints what is wrong and exits 1, or says how many strings it checked."""

import json
import re
import sys
from pathlib import Path

LANGUAGES = ["es", "fr", "de", "it", "pt-BR", "nl", "ru", "tr", "pl", "ja", "ko", "zh-Hans", "zh-Hant", "hi", "ar"]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f)")

catalog = json.loads(Path(__file__).resolve().parent.parent.joinpath("Configuration/Localizable.xcstrings").read_text())
problems = []


def units(localization):
    """Every string a localization holds: one, or one per plural form."""
    if "stringUnit" in localization:
        yield "", localization["stringUnit"]
    for kind, cases in localization.get("variations", {}).items():
        for case, entry in cases.items():
            yield f" ({kind} {case})", entry["stringUnit"]


checked = 0
for key, entry in catalog["strings"].items():
    if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
        continue
    checked += 1
    wanted = sorted(PLACEHOLDER.findall(key))
    for language in LANGUAGES:
        localization = entry.get("localizations", {}).get(language)
        if not localization:
            problems.append(f"{language}: untranslated: {key!r}")
            continue
        found = list(units(localization))
        if not found:
            problems.append(f"{language}: empty: {key!r}")
        for form, unit in found:
            value = unit.get("value", "")
            if unit.get("state") not in ("translated", "reviewed") or not value.strip():
                problems.append(f"{language}{form}: not translated yet: {key!r}")
            elif "\u2014" in value:
                problems.append(f"{language}{form}: em dash in {value!r}")
            elif not form and sorted(PLACEHOLDER.findall(value)) != wanted:
                problems.append(f"{language}: placeholders {PLACEHOLDER.findall(value)} for {key!r}, want {wanted}")
            elif form and wanted and not PLACEHOLDER.findall(value) and form.split()[-1].rstrip(")") not in ("zero", "one", "two"):
                # Zero, one and two can be words of their own, as Arabic's dual is; every other form needs the number.
                problems.append(f"{language}{form}: lost the number in {value!r}")

if problems:
    print("\n".join(problems[:60]))
    if len(problems) > 60:
        print(f"... and {len(problems) - 60} more")
    sys.exit(1)
print(f"Localizable.xcstrings: {checked} strings in {len(LANGUAGES)} languages, all translated")
