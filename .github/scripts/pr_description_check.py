"""Check that a pull request description is filled in properly.

Usage: PR_BODY="..." python3 pr_description_check.py [EXPECTED_TICKET] [--no-checklist]
Prints one ✓/✗ line per check (✗ lines also as ::error:: annotations for
GitHub). Exits 1 if anything is missing.

A reviewer reads the description before the code. It should say which
ticket this is, what changed and how you know it works.
"""

import os
import re
import sys

MIN_WORDS = 8  # "What changed" and "How I tested it" need real sentences
SECTIONS = {
    "ticket": "Ticket",
    "changed": "What changed",
    "tested": "How I tested it",
    "checklist": "Checklist",
}

fails = 0


def ok(msg: str) -> None:
    print(f"✓ {msg}")


def bad(msg: str) -> None:
    global fails
    fails += 1
    print(f"::error::{msg}")
    print(f"✗ {msg}")


def sections(body: str) -> dict[str, str]:
    """Split the description on '## Heading' lines, with HTML comments
    (the template's hints) removed."""
    body = re.sub(r"<!--[\s\S]*?-->", "", body.replace("\r\n", "\n"))
    out: dict[str, str] = {}
    current = None
    for line in body.split("\n"):
        m = re.match(r"^\s*#{1,6}\s+(.+?)\s*#*\s*$", line)
        if m:
            current = m.group(1).strip().lower()
            out[current] = ""
        elif current is not None:
            out[current] += line + "\n"
    return out


def find(secs: dict[str, str], heading: str) -> str | None:
    heading = heading.lower()
    for name, text in secs.items():
        if name.startswith(heading):
            return text.strip()
    return None


def main() -> int:
    body = os.environ.get("PR_BODY", "") or ""
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    expected = (args[0] if args else "").upper()
    want_checklist = "--no-checklist" not in sys.argv

    if not body.strip():
        bad("The pull request description is empty. Fill in the template "
            "(Ticket, What changed, How I tested it, Checklist).")
        return 1

    secs = sections(body)

    # Ticket: a full ID like BUK-14, not the template's bare "BUK-".
    ticket = find(secs, SECTIONS["ticket"])
    if ticket is None:
        bad("The description has no '## Ticket' section. Use the pull request template.")
    else:
        ids = sorted(set(re.findall(r"\bBUK-(\d+)\b", ticket, re.I)))
        if not ids:
            bad("The Ticket section has no ticket number (it says "
                f"'{ticket.splitlines()[0] if ticket else ''}'). Write the full ID, e.g. BUK-14.")
        elif len(ids) > 1:
            bad(f"The Ticket section names more than one ticket ({', '.join('BUK-' + i for i in ids)}). "
                "One pull request, one ticket.")
        elif expected and f"BUK-{ids[0]}" != expected:
            bad(f"The Ticket section says BUK-{ids[0]}, but this pull request is for {expected}.")
        else:
            ok(f"Ticket section names BUK-{ids[0]}")

    # What changed / How I tested it: real sentences, not left blank.
    for key, hint in (("changed", "what you did and why"),
                      ("tested", "the commands you ran and what you saw")):
        heading = SECTIONS[key]
        text = find(secs, heading)
        words = len(re.findall(r"[A-Za-z0-9]+", text or ""))
        if text is None:
            bad(f"The description has no '## {heading}' section. Use the pull request template.")
        elif words < MIN_WORDS:
            bad(f"'{heading}' is {'empty' if words == 0 else 'too short'}. Write {hint}.")
        else:
            ok(f"'{heading}' is filled in")

    # Checklist: every box ticked.
    checklist = find(secs, SECTIONS["checklist"])
    if not want_checklist:
        pass
    elif checklist is None:
        bad("The description has no '## Checklist' section. Use the pull request template.")
    else:
        unticked = re.findall(r"^\s*[-*]\s*\[ \]\s*(.+)$", checklist, re.M)
        ticked = re.findall(r"^\s*[-*]\s*\[[xX]\]", checklist, re.M)
        if unticked:
            for item in unticked:
                bad(f"Checklist item not ticked: {item.strip()}")
        elif not ticked:
            bad("The Checklist is empty. Keep the template's checklist and tick each item.")
        else:
            ok("Every checklist item is ticked")

    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
