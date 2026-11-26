#!/usr/bin/env python3
"""The plain rules of scripts/precheck.py on small made-up diffs (the model part runs only in CI)"""
import importlib.util, os, sys
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("precheck", os.path.join(HERE, "scripts", "precheck.py"))
pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)
fails = []
def check(name, got, want):
    print(("ok   " if got == want else "FAIL ") + name)
    if got != want: fails.append(f"{name}: {got!r} != {want!r}")
def diff(*files):
    out = []
    for path, lines in files:
        out += [f"diff --git a/{path} b/{path}", f"--- a/{path}", f"+++ b/{path}", "@@ -1,1 +1,2 @@", " context"] + ["+" + l for l in lines]
    return "\n".join(out)
def titles(d, body=""):
    return [t for t, _ in pc.rules(pc.parse_diff(d), body)]

check("a clean change with a self-test has nothing to flag",
      titles(diff(("Sources/Draw.swift", ['let x = 1']), ("selftest.py", ["check('x', 1, 1)"]))), [])
check("network code outside the update check",
      "Network access outside the update check" in titles(diff(("Sources/Pet.swift", ['let t = URLSession.shared.dataTask(with: u)']), ("selftest.py", ["x"]))), True)
check("network code in the updater is fine",
      titles(diff(("Sources/Update.swift", ['let t = URLSession.shared.dataTask(with: u)']), ("selftest.py", ["x"]))), [])
check("an AI API call",
      "Calls to an LLM or AI API" in titles(diff(("Sources/Chatter.swift", ['let u = "https://api.openai.com/v1/chat/completions"']), ("selftest.py", ["x"])), "privacy"), True)
check("text without T() is flagged, with T() it isn't",
      ("Text without `T()`" in titles(diff(("Sources/Pet.swift", ['say("All done!", now)']), ("selftest.py", ["x"]))),
       "Text without `T()`" in titles(diff(("Sources/Pet.swift", ['say(T("다 했어!", "All done!"), now)']), ("selftest.py", ["x"])))), (True, False))
check("a source change without a self-test change",
      titles(diff(("Sources/Draw.swift", ['let x = 1']))), ["No self-test change"])
check("a comment-only change needs no self-test", titles(diff(("Sources/Scene.swift", ['// Finding the floor: screen bottom first']))), [])
check("reading transcripts needs a privacy note, and the note clears it",
      ("Privacy or security note" in titles(diff(("Sources/Sessions.swift", ['let x = 1']), ("selftest.py", ["x"]))),
       "Privacy or security note" in titles(diff(("Sources/Sessions.swift", ['let x = 1']), ("selftest.py", ["x"])), "Privacy: reads nothing new"),
       "Privacy or security note" in titles(diff(("Sources/Chatter.swift", ['let lines = T(["메리 크리스마스"], ["Merry Christmas"])']), ("selftest.py", ["x"])))), (True, False, False))
check("a new CLI flag without docs",
      titles(diff(("Sources/Main.swift", ['if a[1] == "--shout" { exit(0) }']), ("selftest.py", ["x"]))), ["CLI docs"])
check("a character pack in the app repo",
      titles(diff(("packs/kitty/chara.json", ['{}']))), ["Character packs go to dot-buddy/characters"])
check("model words are cleaned before they reach the comment",
      pc.clean("See https://evil.example @everyone <img src=x> **bold**\nnext"), "See everyone img srcx bold next")
c = pc.comment([], ("no", "adds a chat window"))
check("an out-of-scope answer leads the comment", ("**Scope.**" in c, c.startswith(pc.MARK)), (True, True))
check("a clean pull request gets a short thank-you", "Nothing to flag" in pc.comment([], ("yes", "")), True)
if fails:
    print("FAIL\n  " + "\n  ".join(fails)); sys.exit(1)
print("ok — precheck rules")
