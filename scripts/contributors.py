#!/usr/bin/env python3
"""Keep the contributors list in README.md and README.ko.md up to date, and thank the author of a merged pull request.

  python3 -I scripts/contributors.py                     write the lists (people with a commit here, people who drew a character)
  python3 -I scripts/contributors.py --thank             also comment on the merged pull request in $PR (author $AUTHOR, repo $REPO)

Code contributors come from GitHub's contributors API for this repo, minus people whose commits only added character packs; character artists from the `author` of every pack in
dot-buddy/characters (packs/index.json), in the order their first pack was added. Bots are left out. Needs `gh` with a token.
"""
import base64, json, os, subprocess, sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.environ.get("REPO", "doldoldol21/dot-buddy")
CHARACTERS = "dot-buddy/characters"
START, END = "<!-- contributors:start -->", "<!-- contributors:end -->"
PER_ROW = 7
HEAD = {"en": ("Code", "Characters"), "ko": ("코드", "캐릭터")}


def gh(*a):
    return subprocess.run(["gh", "api", *a], capture_output=True, text=True, check=True).stdout


ART_ONLY = ("community/", "charas/")                                         # character packs: those people are on the Characters row


def coders():
    out = json.loads(gh(f"repos/{REPO}/contributors?per_page=100"))
    return [c["login"] for c in out if c.get("type") != "Bot" and not c["login"].endswith("[bot]") and not only_art(c["login"])]


def only_art(login):
    """True when every commit of theirs here only added character pictures (a pack merged before dot-buddy/characters existed)"""
    shas = json.loads(gh(f"repos/{REPO}/commits?author={login}&per_page=100", "--jq", "[.[].sha]"))
    for sha in shas:
        files = json.loads(gh(f"repos/{REPO}/commits/{sha}", "--jq", "[.files[].filename]"))
        if not files or any(not f.startswith(ART_ONLY) for f in files):
            return False
    return bool(shas)


def artists():
    raw = json.loads(gh(f"repos/{CHARACTERS}/contents/packs/index.json"))
    packs = json.loads(base64.b64decode(raw["content"]).decode("utf-8")).get("packs", [])
    seen = []
    for p in sorted(packs, key=lambda p: (p.get("added", ""), p["id"])):
        a = str(p.get("author", "")).strip()
        if a and a.lower() not in [s.lower() for s in seen]:
            seen.append(a)
    return seen


def cell(login):
    return (f'<td align="center"><a href="https://github.com/{login}"><img src="https://github.com/{login}.png?size=96" '
            f'width="48" height="48" alt="{login}"><br><sub>{login}</sub></a></td>')


def table(title, logins):
    rows = [logins[i:i + PER_ROW] for i in range(0, len(logins), PER_ROW)]
    body = "".join("<tr>" + "".join(cell(x) for x in r) + "</tr>" for r in rows)
    return f"<p><b>{title}</b></p>\n<table>{body}</table>"


def block(lang, code, art):
    c, a = HEAD[lang]
    parts = [table(c, code)] if code else []
    if art:
        parts.append(table(a, art))
    return "\n\n".join(parts)


def write(code, art):
    """Rewrite the lists between the markers; returns True when a file changed"""
    changed = False
    for name, lang in (("README.md", "en"), ("README.ko.md", "ko")):
        path = os.path.join(HERE, name)
        s = open(path, encoding="utf-8").read()
        if START not in s or END not in s:
            continue
        new = s[:s.index(START) + len(START)] + "\n" + block(lang, code, art) + "\n" + s[s.index(END):]
        if new != s:
            open(path, "w", encoding="utf-8").write(new)
            changed = True
    return changed


def listed(login):
    s = open(os.path.join(HERE, "README.md"), encoding="utf-8").read()
    return f'alt="{login}"' in s[s.index(START):s.index(END)] if START in s and END in s else False


def thank(pr, author, first):
    text = f"Merged. Thank you for the contribution, @{author}!"
    if first:
        text += " You're now on the contributors list in the [README](https://github.com/" + REPO + "#contributing)."
    text += " It goes out with the next release."
    gh("-X", "POST", f"repos/{REPO}/issues/{pr}/comments", "-f", f"body={text}")


def main():
    author = os.environ.get("AUTHOR", "")
    first = bool(author) and not listed(author)
    code, art = coders(), artists()
    if author and author.lower() not in [c.lower() for c in code]:
        code.append(author)                                                  # the API can lag a few minutes behind the merge
    print("code:", ", ".join(code))
    print("characters:", ", ".join(art))
    print("README changed" if write(code, art) else "README unchanged")
    if "--thank" in sys.argv[1:] and author:
        try:
            thank(os.environ["PR"], author, first)
        except subprocess.CalledProcessError as e:                         # a missed thank-you shouldn't keep the list from updating
            print("comment failed:", e.stderr, file=sys.stderr)


if __name__ == "__main__":
    main()
