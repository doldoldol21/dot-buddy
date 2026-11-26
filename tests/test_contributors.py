#!/usr/bin/env python3
"""scripts/contributors.py writes the lists between the README markers without the network (the API calls run only in CI)"""
import importlib.util, os, shutil, sys, tempfile
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("contributors", os.path.join(HERE, "scripts", "contributors.py"))
cb = importlib.util.module_from_spec(spec); spec.loader.exec_module(cb)
fails = []
def check(name, got, want):
    print(("ok   " if got == want else "FAIL ") + name)
    if got != want: fails.append(f"{name}: {got!r} != {want!r}")

tmp = tempfile.mkdtemp()
try:
    for f in ("README.md", "README.ko.md"):
        shutil.copy(os.path.join(HERE, f), tmp)
    cb.HERE = tmp
    people = [f"user{i}" for i in range(9)]
    check("both READMEs change the first time", cb.write(people, ["artist"]), True)
    check("writing the same lists again changes nothing", cb.write(people, ["artist"]), False)
    en = open(os.path.join(tmp, "README.md"), encoding="utf-8").read()
    ko = open(os.path.join(tmp, "README.ko.md"), encoding="utf-8").read()
    part = en[en.index(cb.START):en.index(cb.END)]
    check("seven people to a row", part.count("<tr>"), 2 + 1)
    check("each person links to their profile", part.count('href="https://github.com/user'), 9)
    check("the Korean README gets Korean headings", "<b>캐릭터</b>" in ko and "<b>Characters</b>" in en, True)
    check("text outside the markers is kept", en.split(cb.START)[0] == open(os.path.join(HERE, "README.md"), encoding="utf-8").read().split(cb.START)[0], True)
    check("someone on the list is listed", cb.listed("user3"), True)
    check("someone new isn't", cb.listed("newcomer"), False)
    check("no characters, no Characters heading", "Characters" in cb.block("en", ["a"], []), False)
finally:
    shutil.rmtree(tmp)
if fails:
    print("\n".join(fails)); sys.exit(1)
