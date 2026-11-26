#!/usr/bin/env python3
"""scripts/release-notes.py on a small made-up history (no network: GitHub lookups are skipped)"""
import importlib.util, os, subprocess, sys, tempfile, shutil
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("release_notes", os.path.join(HERE, "scripts", "release-notes.py"))
rn = importlib.util.module_from_spec(spec); spec.loader.exec_module(rn)
rn.gh = lambda *a: ""
fails = []
def check(name, got, want):
    print(("ok   " if got == want else "FAIL ") + name)
    if got != want: fails.append(f"{name}: {got!r} != {want!r}")

tmp = tempfile.mkdtemp()
cwd = os.getcwd()
try:
    os.chdir(tmp)
    def run(*a): subprocess.run(a, check=True, capture_output=True)
    def commit(path, subject, author="Someone"):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        open(path, "a").write(subject + "\n")
        run("git", "add", "-A")
        run("git", "-c", f"user.name={author}", "-c", "user.email=a@b.c", "commit", "-q", "-m", subject)
    run("git", "init", "-q")
    commit("VERSION", "Dot Buddy 0.1.0"); run("git", "tag", "v0.1.0")
    commit("Sources/Pet.swift", "The pet waves")
    commit(".github/workflows/ci.yml", "Faster CI")
    commit("Sources/Draw.swift", "Fix the hat (#7)")
    commit("README.md", "Update the contributors list", "github-actions[bot]")
    commit("VERSION", "Dot Buddy 0.2.0"); run("git", "tag", "v0.2.0")
    n = rn.notes("v0.2.0")
    check("the previous tag is found", rn.previous("v0.2.0"), "v0.1.0")
    check("app changes come first", n.index("The pet waves") < n.index("Behind the scenes") < n.index("Faster CI"), True)
    check("a pull request is linked", "- Fix the hat in #7" in n, True)
    check("version bumps and bot commits are left out", ("Dot Buddy 0.2.0" in n, "contributors list" in n), (False, False))
    check("the changelog link compares the two tags", n.rstrip().endswith("compare/v0.1.0...v0.2.0"), True)
    check("the first tag lists everything up to it", "Maintenance release." in rn.notes("v0.1.0"), True)
finally:
    os.chdir(cwd); shutil.rmtree(tmp)
if fails:
    print("\n".join(fails)); sys.exit(1)
