#!/usr/bin/env python3
"""Turn RELEASE_NOTES.md into the text shown in Sparkle's update dialog.

Supports both layouts the project has used:
  * legacy:  "- **Title** — description" bullets before the first "---"
  * bilingual: "### 中文" / "### English" sections of plain "- item" bullets
Only the newest release section (up to the next "## ClashFX" heading) is read.
Output is HTML-escaped and safe inside a CDATA block.
"""
import html
import re
import sys

LEGACY = re.compile(r"^- \*\*(.+?)\*\* — (.+)$", re.MULTILINE)
SECTION_TITLES = {"中文": "中文", "english": "English"}


def latest_section(content: str) -> str:
    parts = re.split(r"(?m)^## ClashFX\b", content)
    # parts[0] is any preamble; the first release body is parts[1] when headed.
    return parts[1] if len(parts) > 1 else content


def plain(text: str) -> str:
    return re.sub(r"[*][*](.+?)[*][*]", r"\1", text)


def bullets(text: str):
    return [m.group(1).strip() for m in re.finditer(r"(?m)^- (.+)$", text)]


def bilingual_sections(section: str):
    """Return [(title, [bullets])] for "### 中文" / "### English" sections."""
    result = []
    pieces = re.split(r"(?m)^### (.+)$", section)
    for i in range(1, len(pieces), 2):
        key = pieces[i].strip().lower()
        title = SECTION_TITLES.get(key) or SECTION_TITLES.get(pieces[i].strip())
        if title is None:
            continue
        body = re.split(r"(?m)^---\s*$", pieces[i + 1])[0]
        items = bullets(body)
        if items:
            result.append((title, items))
    return result


def render_html(tag: str, title_suffix: str, content: str) -> str:
    out = f"<h2>ClashFX v{html.escape(tag)}{html.escape(title_suffix)}</h2>"
    section = latest_section(content)
    legacy = LEGACY.findall(section.split("\n---")[0])
    sections = [] if legacy and not bilingual_sections(section.split("\n---")[0]) else bilingual_sections(section)
    if sections:
        for title, items in sections:
            out += f"<h3>{html.escape(title)}</h3><ul>"
            out += "".join("<li>" + html.escape(plain(item), quote=False) + "</li>" for item in items)
            out += "</ul>"
    else:
        if legacy:
            out += "<ul>" + "".join(
                f"<li><strong>{html.escape(t, quote=False)}</strong> — {html.escape(d)}</li>" for t, d in legacy
            ) + "</ul>"
        else:
            out += "<p>See release notes on GitHub.</p>"
    return out.replace("]]>", "]]&gt;")


def first_summary(content: str, language: str) -> str:
    """First bullet of one language, for the website notification payload."""
    section = latest_section(content)
    legacy = LEGACY.findall(section.split("\n---")[0])
    if legacy and not bilingual_sections(section.split("\n---")[0]):
        return legacy[0][1] if language == "en" else ""
    wanted = "English" if language == "en" else "中文"
    for title, items in bilingual_sections(section):
        if title == wanted:
            return re.sub(r"\*\*(.+?)\*\*", r"\1", items[0])
    return ""


def main(argv):
    path = "RELEASE_NOTES.md"
    try:
        content = open(path, encoding="utf-8").read()
    except OSError:
        content = ""
    if len(argv) >= 3 and argv[1] == "html":
        print(render_html(argv[2], argv[3] if len(argv) > 3 else "", content))
    elif len(argv) == 3 and argv[1] == "summary":
        print(first_summary(content, argv[2]))
    else:
        print("usage: appcast_release_notes.py html TAG [SUFFIX] | summary en|zh", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
