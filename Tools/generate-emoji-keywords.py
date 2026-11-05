#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

"""Regenerate the words that find emoji in the command bar.

Downloads pinned copies of the Unicode CLDR emoji annotations, the names and
search keywords Unicode publishes for emoji pickers in every language, and of
Slack's shortcodes from iamcal/emoji-data. Writes one table per app language
into the Swift source the app and the tests compile, and the license notices
of both into THIRD-PARTY-NOTICES.md. Change a pin, then run it again.
"""

from pathlib import Path
import base64
import hashlib
import io
import json
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Sources/Vorssaint/Services/CommandBar/CommandBarEmojiKeywords.swift"
NOTICES = ROOT / "THIRD-PARTY-NOTICES.md"

CLDR_VERSION = "49.0.0"
CLDR = (f"https://registry.npmjs.org/cldr-annotations-full/-/cldr-annotations-full-{CLDR_VERSION}.tgz",
        "sha512-AYFll+64o58nWlCq+EEmQE1G+zyw6avVdYlsr4edLEQ3tTb7tVldu2ICD4bbCyx62cchP4j5lUtXLbFqajqgbg==")
SLACK_COMMIT = "e77759c296ed37beb0dbd63908b43d8619509c6d"
SLACK = (f"https://raw.githubusercontent.com/iamcal/emoji-data/{SLACK_COMMIT}/emoji.json",
         "sha256-8736d721991e48c41c57acc46b65e5d32258a45e4bcdebcc6012f420f81e775d")
SLACK_LICENSE = (f"https://raw.githubusercontent.com/iamcal/emoji-data/{SLACK_COMMIT}/LICENSE",
                 "sha256-ee9953a79bf2132b59b1342b217f1c377b3d03d9e7713006f6c3b89eb159f1db")

# Each AppLanguage case and the CLDR locales it reads, parent first. Hong
# Kong only records where it differs from Taiwan's traditional Chinese.
LOCALES = {
    "enUS": ["en"], "ptBR": ["pt"], "tr": ["tr"], "ru": ["ru"], "es": ["es"],
    "sk": ["sk"], "de": ["de"], "fr": ["fr"], "it": ["it"], "ja": ["ja"],
    "ko": ["ko"], "uk": ["uk"], "zhHans": ["zh"], "zhTW": ["zh-Hant"],
    "zhHK": ["zh-Hant", "zh-Hant-HK"],
}


def fetch(url, digest):
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    algorithm, expected = digest.split("-", 1)
    actual = hashlib.new(algorithm, data).digest()
    found = base64.b64encode(actual).decode() if algorithm == "sha512" else actual.hex()
    if found != expected:
        raise SystemExit(f"{url} changed: expected {digest}, found {algorithm}-{found}")
    return data


def canonical(emoji):
    return emoji.replace("\ufe0f", "").replace("\ufe0e", "")


def annotations(archive, locales):
    merged = {}
    for locale in locales:
        member = archive.extractfile(f"package/annotations/{locale}/annotations.json")
        for emoji, fields in json.load(member)["annotations"]["annotations"].items():
            merged.setdefault(canonical(emoji), {}).update(fields)
    return merged


def searchable(name, phrases):
    """Drops each phrase the text already holds. It would add bytes, not a
    match."""
    seen, kept = f" {name.casefold()} ", []
    for phrase in phrases:
        folded = phrase.casefold()
        if f" {folded} " in seen:
            continue
        seen += folded + " "
        kept.append(phrase)
    return " ".join(kept)


def table(entries, emoji_set, slack=None):
    """English also gets Slack's shortcodes, and Slack's Unicode name where
    CLDR has none, so every English line carries a name."""
    lines = []
    for emoji in emoji_set:
        entry = entries.get(emoji, {})
        fallback = slack[emoji]["name"].lower() if slack else ""
        name = (entry.get("tts") or [fallback])[0]
        codes = slack[emoji]["short_names"] if slack else []
        words = searchable(name, entry.get("default", []) + codes)
        if name or words:
            line = f"{emoji}\t{name}\t{words}"
            if "\n" in line or line.count("\t") != 2 or '"""#' in line:
                raise SystemExit(f"{emoji} cannot be stored: {line!r}")
            lines.append(line)
    return "\n".join(lines)


def main():
    archive = tarfile.open(fileobj=io.BytesIO(fetch(*CLDR)))
    slack = json.loads(fetch(*SLACK))
    # Slack's list names every emoji Unicode has, and only emoji, so it also
    # keeps CLDR's annotated punctuation and math symbols out of the tables.
    singles = {}
    for entry in slack:
        emoji = canonical("".join(chr(int(code, 16)) for code in entry["unified"].split("-")))
        if len(emoji) == 1:
            singles[emoji] = entry
    emoji_set = sorted(singles, key=ord)

    cases = []
    for language, locales in LOCALES.items():
        body = table(annotations(archive, locales), emoji_set, singles if language == "enUS" else None)
        cases.append(f'        case .{language}: return #"""\n{body}\n"""#\n')

    cldr_license = archive.extractfile("package/LICENSE").read().decode()
    slack_license = fetch(*SLACK_LICENSE).decode()
    cldr_copyright = next(line for line in cldr_license.splitlines() if line.startswith("Copyright"))
    slack_copyright = next(line for line in slack_license.splitlines() if line.startswith("Copyright"))
    OUTPUT.write_text(
        "// SPDX-License-Identifier: GPL-3.0-or-later AND Unicode-3.0 AND MIT\n"
        "// Generated by Tools/generate-emoji-keywords.py. Do not edit.\n"
        f"// Names and keywords: Unicode CLDR {CLDR_VERSION} annotations, {cldr_copyright}\n"
        f"// Shortcodes: Slack's, from iamcal/emoji-data, {slack_copyright}\n"
        "// Their license notices are in THIRD-PARTY-NOTICES.md.\n\n"
        "extension CommandBarEmoji {\n"
        "    /// One line per emoji, without its presentation selector: the emoji,\n"
        "    /// its name and the other words that find it, split by tabs.\n"
        "    static func keywordTable(_ language: AppLanguage) -> String {\n"
        "        switch language {\n"
        + "".join(cases)
        + "        }\n    }\n}\n")
    NOTICES.write_text(
        "# Third-party notices\n\n"
        "Vorssaint is licensed under the GPL 3.0 or later, see [LICENSE](LICENSE).\n"
        "The emoji names, keywords and shortcodes the command bar searches come from\n"
        "the projects below, under their own licenses.\n"
        "`Tools/generate-emoji-keywords.py` writes this file.\n\n"
        f"## Unicode CLDR {CLDR_VERSION} emoji annotations\n\n"
        f"```text\n{cldr_license.strip()}\n```\n\n"
        "## iamcal/emoji-data, Slack's emoji shortcodes\n\n"
        f"```text\n{slack_license.strip()}\n```\n")


if __name__ == "__main__":
    main()
