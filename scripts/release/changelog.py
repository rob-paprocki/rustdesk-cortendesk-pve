#!/usr/bin/python3 -I
"""CHANGELOG.md helper (Keep a Changelog 1.1.0 + SemVer).

  changelog.py plan [--bump auto|patch|minor|major] [--first X.Y.Z]
      -> prints JSON {"version", "previous", "notes"} for the [Unreleased] section
  changelog.py finalize VERSION DATE
      -> turns [Unreleased] into "## [VERSION] - DATE", adds a fresh [Unreleased],
  changelog.py notes VERSION
      -> prints that version's section (for the release page)
  changelog.py autoline TEXT
      -> adds "- TEXT" under "### Changed" in [Unreleased] for an automatic patch
         release; refuses when [Unreleased] holds anything written by hand

Rules:
  * every release section must start with an "**Upgrading:**" line;
  * "auto" bump: **Breaking** anywhere or a "### Removed" heading -> major;
    any Added/Changed/Deprecated -> minor; only Fixed/Security -> patch.
"""
import json
import re
import sys

PATH = "CHANGELOG.md"
AUTO_PREFIX = "The rdgen patches now apply to upstream rdgen commit "
HEAD = re.compile(r"^## \[([^\]]+)\](?:\s*-\s*(\S+))?\s*$", re.M)


class ChangelogError(Exception):
    pass


def sections(text):
    """[(name, date, body, start, end)] in file order."""
    found = list(HEAD.finditer(text))
    out = []
    for i, m in enumerate(found):
        end = found[i + 1].start() if i + 1 < len(found) else len(text)
        out.append((m.group(1), m.group(2), text[m.end():end].strip("\n"), m.start(), end))
    return out


def parse_version(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", v)
    if not m:
        raise ChangelogError("not a version: %r" % v)
    return tuple(int(x) for x in m.groups())


def unreleased(text):
    for name, _date, body, *_ in sections(text):
        if name.lower() == "unreleased":
            return body
    raise ChangelogError("CHANGELOG.md has no [Unreleased] section")


def previous_version(text):
    for name, *_ in sections(text):
        if re.fullmatch(r"\d+\.\d+\.\d+", name):
            return name
    return None


def check_body(body):
    lines = [l for l in body.splitlines() if l.strip()]
    if not lines or not lines[0].startswith("**Upgrading:**"):
        raise ChangelogError("the release notes must start with an '**Upgrading:**' line "
                             "(for example '**Upgrading:** nothing to do.')")
    if not re.search(r"^### ", body, re.M):
        raise ChangelogError("[Unreleased] has no ### Added/Changed/Fixed/... entries")


def bump_kind(body):
    if "**Breaking**" in body or re.search(r"^### Removed\b", body, re.M):
        return "major"
    if re.search(r"^### (Added|Changed|Deprecated)\b", body, re.M):
        return "minor"
    if re.search(r"^### (Fixed|Security)\b", body, re.M):
        return "patch"
    raise ChangelogError("can't tell the version bump from the headings in [Unreleased]")


def plan(text, bump="auto", first="0.1.0"):
    body = unreleased(text)
    check_body(body)
    prev = previous_version(text)
    if prev is None:
        version = first
        parse_version(version)
    else:
        kind = bump_kind(body) if bump == "auto" else bump
        major, minor, patch = parse_version(prev)
        version = {"major": "%d.0.0" % (major + 1), "minor": "%d.%d.0" % (major, minor + 1),
                   "patch": "%d.%d.%d" % (major, minor, patch + 1)}[kind]
    return {"version": version, "previous": prev, "notes": body}


def autoline(text, line):
    """Add an automatic release line to [Unreleased], or refuse if a person wrote something there.

    [Unreleased] may hold only the Upgrading line, a "### Changed" heading and lines that
    start with "- " plus AUTO_PREFIX (the ones this function wrote).
    """
    body = unreleased(text)
    if not line.startswith(AUTO_PREFIX) or "\n" in line:
        raise ChangelogError("an automatic line must start with %r" % AUTO_PREFIX)
    for l in body.splitlines():
        if not l.strip() or l.startswith("**Upgrading:**") or l.strip() == "### Changed":
            continue
        if l.startswith("- " + AUTO_PREFIX):
            continue
        raise ChangelogError("[Unreleased] has entries written by hand; release it by hand")
    if "- " + line in body.splitlines():
        return text
    new_body = body if body.strip() else "**Upgrading:** nothing to do."
    if not new_body.startswith("**Upgrading:**"):
        new_body = "**Upgrading:** nothing to do.\n\n" + new_body
    if "### Changed" not in new_body:
        new_body = new_body.rstrip("\n") + "\n\n### Changed\n"
    new_body = new_body.rstrip("\n") + "\n- " + line + "\n"
    start, end = [(s[3], s[4]) for s in sections(text) if s[0].lower() == "unreleased"][0]
    head = re.match(r"^## \[Unreleased\][^\n]*\n", text[start:], re.I).group(0)
    rest = text[end:]
    return text[:start] + head + "\n" + new_body + ("\n" if rest.strip() else "") + rest.lstrip("\n")


def finalize(text, version, date):
    parse_version(version)
    body = unreleased(text)
    check_body(body)
    if any(name == version for name, *_ in sections(text)):
        raise ChangelogError("CHANGELOG.md already has a [%s] section" % version)
    m = re.search(r"^## \[Unreleased\]\s*$", text, re.M | re.I)
    return text[:m.start()] + "## [Unreleased]\n\n## [%s] - %s" % (version, date) + text[m.end():]


def notes(text, version):
    for name, _date, body, *_ in sections(text):
        if name == version:
            return body
    raise ChangelogError("no [%s] section" % version)


def main(argv):
    text = open(PATH).read()
    try:
        if argv[1] == "plan":
            bump = argv[argv.index("--bump") + 1] if "--bump" in argv else "auto"
            first = argv[argv.index("--first") + 1] if "--first" in argv else "0.1.0"
            print(json.dumps(plan(text, bump, first)))
        elif argv[1] == "finalize":
            new = finalize(text, argv[2], argv[3])
            open(PATH, "w").write(new)
            print("CHANGELOG.md: [Unreleased] -> [%s] - %s" % (argv[2], argv[3]))
        elif argv[1] == "autoline":
            open(PATH, "w").write(autoline(text, argv[2]))
            print("CHANGELOG.md: added the automatic line")
        elif argv[1] == "notes":
            print(notes(text, argv[2]))
        else:
            raise ChangelogError("unknown command")
    except (ChangelogError, IndexError) as e:
        print("changelog: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
