#!/usr/bin/env python3
"""Write the release notes for a tag from the commits since the previous tag.

  python3 -I scripts/release-notes.py v0.3.26 > notes.md

GitHub's generated notes list merged pull requests only, and most changes here are committed to main directly, so those
notes came out empty. This lists every commit subject instead (they're written for users), app changes first and the
project's own changes (CI, docs, tests) after. A commit from a pull request credits its author, and GitHub's
"New Contributors" section is kept. Version-bump commits and bot commits are left out. Needs git history and tags
(fetch-depth: 0); `gh` is used for pull request authors and New Contributors, and the notes still come out without it.
"""
import json, os, re, subprocess, sys

REPO = os.environ.get("REPO", "doldoldol21/dot-buddy")
APP = ("Sources/", "charas/", "build.sh", "install.sh", "VERSION")      # what ends up in the app or its install
BUMP = re.compile(r"^Dot Buddy \d+\.\d+\.\d+$")
PR = re.compile(r"\s*\(#(\d+)\)$")


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout


def gh(*a):
    try:
        return subprocess.run(["gh", "api", *a], capture_output=True, text=True, check=True, timeout=60).stdout
    except Exception:
        return ""


def previous(tag):
    tags = [t for t in git("tag", "--list", "v*", "--sort=-v:refname", "--merged", tag).split() if t != tag]
    return tags[0] if tags else None


def commits(prev, tag):
    out = git("log", f"{prev}..{tag}" if prev else tag, "--no-merges", "--format=%H%x09%an%x09%s")
    for line in out.splitlines():
        sha, author, subject = line.split("\t", 2)
        if BUMP.match(subject) or author.endswith("[bot]"):
            continue
        files = git("show", "--name-only", "--format=", sha).split()
        yield sha, subject, any(f.startswith(APP) for f in files)


def line(sha, subject):
    m = PR.search(subject)
    if not m:
        return f"- {subject}"
    who = gh(f"repos/{REPO}/pulls/{m.group(1)}", "--jq", ".user.login").strip()
    credit = f" by @{who}" if who and who != REPO.split("/")[0] else ""
    return f"- {PR.sub('', subject)}{credit} in #{m.group(1)}"


def new_contributors(prev, tag):
    if not prev:
        return ""
    body = gh(f"repos/{REPO}/releases/generate-notes", "-X", "POST", "-f", f"tag_name={tag}", "-f", f"previous_tag_name={prev}", "--jq", ".body")
    m = re.search(r"## New Contributors\n(.*?)(?:\n\n|\Z)", body, re.S)
    return "## New Contributors\n" + m.group(1).strip() if m else ""


def notes(tag):
    prev = previous(tag)
    app, project = [], []
    for sha, subject, in_app in commits(prev, tag):
        (app if in_app else project).append(line(sha, subject))
    parts = []
    if app:
        parts.append("## What's new\n" + "\n".join(app))
    if project:
        parts.append("## Behind the scenes\n" + "\n".join(project))
    if not parts:
        parts.append("Maintenance release.")
    extra = new_contributors(prev, tag)
    if extra:
        parts.append(extra)
    if prev:
        parts.append(f"**Full changelog**: https://github.com/{REPO}/compare/{prev}...{tag}")
    return "\n\n".join(parts) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.stdout.write(notes(sys.argv[1]))
