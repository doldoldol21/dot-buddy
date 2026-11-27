#!/usr/bin/env python3
"""Launch the built app for real and check that a session finishing reaches the screen.

  python3 -I tests/smoke.py "$RUNNER_TEMP/Dot.app" [screenshot.png]

selftest.py checks verdicts without launching the app; this one starts the app in a GUI session with its own session
folders (no real Claude Code sessions), reports a fake session through the CLI and reads the app's test log
(DOTBUDDY_PROF): the pet is placed, a "done" bubble shows with the session's name, the sound plays when it's turned on,
today's count goes up, a question and a signal get through, a question followed straight by done still counts, and the app is still running at the end. Made for the macOS
runner in CI. On a managed work Mac, leave it to CI.
"""
import os, re, subprocess, sys, tempfile, time

APP = sys.argv[1] if len(sys.argv) > 1 else sys.exit(__doc__)
SHOT = sys.argv[2] if len(sys.argv) > 2 else ""
BIN = os.path.join(APP, "Contents", "MacOS", "DotBuddy")
NAME = "smoke-test"

work = tempfile.mkdtemp(prefix="dotbuddy-smoke-")
env = dict(os.environ, DOTBUDDY_PROF="1", DOTBUDDY_PRESENT="1", DOTBUDDY_CLAUDE_DIR=os.path.join(work, "claude"),
           DOTBUDDY_SESSIONS=os.path.join(work, "sessions"))
for d in ("claude", "sessions"):
    os.makedirs(os.path.join(work, d))
log_path = os.path.join(work, "app.log")
# The argument domain overrides saved settings for this run only: no first-run bubbles and login question, sound on,
# English, no update checks
args = ["-onboarded", "YES", "-sound", "YES", "-lang", "en", "-autoUpdate", "NO"]
app = subprocess.Popen([BIN, *args], env=env, stdout=subprocess.DEVNULL, stderr=open(log_path, "w"))
sleeper = subprocess.Popen(["sleep", "300"])                                    # the fake session's process
failed = []


def log():
    return open(log_path, encoding="utf-8", errors="replace").read()


def wait_for(what, text, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        if app.poll() is not None:
            break
        if text in log():
            print(f"ok   {what}")
            return True
        time.sleep(0.5)
    failed.append(what)
    print(f"FAIL {what} (no '{text}' in the log{'; the app exited with ' + str(app.returncode) if app.poll() is not None else ''})")
    return False


def report(state):
    subprocess.run([BIN, "--report", "claude", "smoke-1", state, "--name", NAME, "--pid", str(sleeper.pid)],
                   env=env, check=True, timeout=10)


try:
    if wait_for("pet is placed", "  pos t=", 40):
        time.sleep(3)                                                           # let it read the empty session folder once
        report("busy")
        time.sleep(4)
        report("idle")
        wait_for("done bubble shows the session", f"bubble notice t=", 20) and wait_for("bubble has its name", NAME, 5)
        wait_for("sound plays when turned on", "  sound done", 10)
        wait_for("today's count goes up", "  done-today 1", 10)
        time.sleep(3)                                                           # the sound plays at most every 2 seconds
        report("busy")
        time.sleep(4)
        report("ask")
        wait_for("a question gets through", "  sound ask", 15)
        time.sleep(3)
        report("idle")                                                          # answered and finished with no "busy" seen in between
        wait_for("done straight after a question counts", "  done-today 2", 10)
        subprocess.run([BIN, "--signal", "done", "smoke signal"], env=env, timeout=10)
        wait_for("a signal counts as done", "  done-today 3", 10)
        subprocess.run([BIN, "--signal", "menu", "3"], env=env, timeout=10)      # the pet's menu (test-only signal), closed by itself after 3 seconds
        if wait_for("menu opens", "  menu open", 10) and wait_for("menu closes", "  menu closed", 10):
            seg = log().split("  menu open", 1)[1].split("  menu closed", 1)[0]
            spots = set(re.findall(r"(?:^ |pos t=\d+ )x=(-?\d+) y=(-?\d+)", seg, re.M))   # where it was as the menu opened, then every second
            if len(spots) == 1:
                print("ok   stands still while the menu is open")
            else:
                failed.append("stands still while the menu is open")
                print(f"FAIL stands still while the menu is open (moved: {sorted(spots)})")
        if SHOT:
            time.sleep(1)
            subprocess.run(["screencapture", "-x", SHOT], timeout=20)         # for a look in the run's artifacts; not checked
        time.sleep(2)
        if app.poll() is None:
            print("ok   still running")
        else:
            failed.append("still running")
            print(f"FAIL still running (exited with {app.returncode})")
    health = [l.strip() for l in log().splitlines() if l.startswith("  HEALTH")]
    if health:                                                                  # odd-looking moments the app noticed itself: shown, not failed
        print(f"note {len(health)} HEALTH line(s):", *health[:10], sep="\n  ")
finally:
    try:
        report("end")
    except Exception:
        pass
    app.terminate()
    sleeper.kill()
    try:
        app.wait(10)
    except subprocess.TimeoutExpired:
        app.kill()

if failed:
    print("\n--- app log (last 60 lines) ---")
    print("\n".join(log().splitlines()[-60:]))
    sys.exit(f"smoke test failed: {', '.join(failed)}")
print("ok — dot-buddy smoke test")
