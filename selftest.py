#!/usr/bin/env python3
"""dot-buddy self-test — checks `DotBuddy --state` verdicts against fake session files in a temp folder (does not launch the app)."""
import json
import shutil
import os
import subprocess
import sys
import tempfile
import time

os.environ["DOTBUDDY_LANG"] = "ko"   # the phrase checks below assume Korean (English is checked separately at the very end)
HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.join(HERE, "bin", "DotBuddy")
fails = []


def check(name, got, want):
    if got != want:
        fails.append(f"{name}: {got!r} != {want!r}")


def state(root, full=False):
    env = {**os.environ, "DOTBUDDY_CLAUDE_DIR": root, "DOTBUDDY_SESSIONS": os.path.join(root, "reports")}
    out = subprocess.run([BIN, "--state"], env=env, capture_output=True, text=True, check=True).stdout
    d = json.loads(out)
    if full:
        return d
    return d["mood"], {s["name"]: s["mood"] for s in d["sessions"]}


def report(root, *args):
    env = {**os.environ, "DOTBUDDY_SESSIONS": os.path.join(root, "reports")}
    return subprocess.run([BIN, "--report", *args], env=env, capture_output=True, text=True).returncode


if not os.access(BIN, os.X_OK):
    print("FAIL — bin/DotBuddy 없음(install.sh 먼저)")
    sys.exit(1)

sleeper = subprocess.Popen(["sleep", "60"])
try:
    with tempfile.TemporaryDirectory() as root:
        sd = os.path.join(root, "sessions"); os.makedirs(sd)
        proj = os.path.join(root, "projects", "-x"); os.makedirs(proj)
        now = time.time() * 1000

        def sess(pid, sid, name, status, ago_min, kind="interactive", started=None, file=None):
            with open(os.path.join(sd, f"{file or pid}.json"), "w") as f:
                json.dump({"pid": pid, "sessionId": sid, "name": name, "status": status, "kind": kind,
                           "statusUpdatedAt": now - ago_min * 60000, **({"startedAt": started} if started else {})}, f)

        sess(os.getpid(), "a", "일함", "busy", 1)
        sess(os.getppid(), "b", "막 끝남", "idle", 3)
        sess(1, "c", "오래 쉼", "idle", 45)                   # pid 1 is someone else's process — alive even with EPERM
        sess(999999, "d", "죽음", "idle", 1)                  # a nonexistent process is dropped
        sess(sleeper.pid, "e", "질문", "busy", 1)
        with open(os.path.join(proj, "e.jsonl"), "w") as f:
            f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "q1", "name": "AskUserQuestion", "input": {}}]}}) + "\n")
        mood, m = state(root)
        check("대표 기분 = 질문", mood, "ask")
        check("세션별", m, {"일함": "work", "막 끝남": "wait", "오래 쉼": "sleep", "질문": "ask"})

        # working again once the question is answered
        with open(os.path.join(proj, "e.jsonl"), "a") as f:
            f.write(json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "q1"}]}}) + "\n")
        mood, m = state(root)
        check("답한 뒤", (mood, m["질문"]), ("wait", "work"))

        # shell counts as working too; sessions that are not interactive are left out
        sess(sleeper.pid, "e", "질문", "shell", 1)
        sess(os.getppid(), "b", "막 끝남", "idle", 3, kind="sdk")
        mood, m = state(root)
        check("shell·sdk", (mood, "막 끝남" in m, m["질문"]), ("work", False, "work"))

        # other agents: sessions reported with --report are picked up too (tool, displayed name, whether the pid is alive)
        check("report — 잘못된 상태는 거절", report(root, "codex", "x1", "napping"), 2)
        report(root, "codex", "x1", "ask", "--name", "코덱스 질문", "--label", "코덱스", "--pid", str(sleeper.pid))
        report(root, "codex", "x2", "busy", "--name", "코덱스 죽음", "--pid", "999999")
        report(root, "aider", "y1", "busy", "--name", "pid 없이")
        d = state(root, full=True)
        got = {s["name"]: (s["mood"], s["tool"], s["label"]) for s in d["sessions"] if s["tool"] != "claude"}
        check("report — 세션", got, {"코덱스 질문": ("ask", "codex", "코덱스"), "pid 없이": ("work", "aider", "aider")})
        check("report — 대표 기분", d["mood"], "ask")
        report(root, "codex", "x1", "end")
        check("report — end 면 빠짐", any(s["name"] == "코덱스 질문" for s in state(root, full=True)["sessions"]), False)
        report(root, "a-b", "c", "busy", "--name", "ab+c"); report(root, "a", "b-c", "busy", "--name", "a+bc")
        report(root, "a", "b-c", "end")
        check("report — 도구·id 의 '-' 가 겹치지 않음", [s["name"] for s in state(root, full=True)["sessions"] if s["tool"] in ("a", "a-b")], ["ab+c"])

        # odd session files: pid 0 and -1 do not count as alive, another process that inherited the pid is dropped, a far-future time does not get stuck on 'done'
        for f in os.listdir(sd): os.remove(os.path.join(sd, f))
        sess(0, "z0", "pid0", "busy", 1, file="z0"); sess(-1, "z1", "pid-1", "idle", 1, file="z1")
        sess(sleeper.pid, "r1", "물려받음", "busy", 1, started=now - 3600_000)
        sess(os.getpid(), "f1", "미래", "idle", -90)
        sess(os.getppid(), "s1", "제때 시작", "busy", 1, started=now)
        mood, m = state(root)
        check("이상한 세션 파일", {k: v for k, v in m.items() if k in ("pid0", "pid-1", "물려받음", "미래", "제때 시작")}, {"미래": "sleep", "제때 시작": "work"})
finally:
    sleeper.kill()

# mutterings fit the circumstances: on the floor there are no "so high" lines, up high they show up. "bored" lines only when there is no work
def lines(*args):
    return set(subprocess.run([BIN, "--lines", *args], capture_output=True, text=True, timeout=10).stdout.split("\n")) - {""}
low, hi = lines("carried", "high=20"), lines("carried", "high=600")
check("바닥에서 들림 — 높다 없음", any("높" in l or "무서" in l for l in low), False)
check("높이서 들림 — 높다 있음", any("높" in l for l in hi), True)
check("바닥 혼잣말 — 높다·아찔 없음", any("높" in l or "아찔" in l for l in lines("idle", "high=10", "on=base")), False)
check("바쁠 때 — 심심 없음", any("심심" in l for l in lines("idle", "mood=work", "working=2")), False)
check("창 위 — 창 얘기", any("창" in l or "전망" in l for l in lines("idle", "on=window", "high=300")), True)
check("알림 — 금방 끝남", all(any(k in l for k in ["금방", "벌써", "후딱"]) for l in lines("done", "high=10")), True)
check("알림 — 오래 걸림", all(any(k in l for k in ["드디어", "긴 작업", "오래", "해냈"]) for l in lines("done", "high=3000")), True)
check("알림 — 질문은 끝났다고 안 함", any("끝" in l for l in lines("done", "mood=ask")), False)
check("알림 — 밀린 수", all(l.endswith("(+2)") for l in lines("done", "high=200", "waiting=2")), True)
check("칭찬 — 세션 수", all("4" in l for l in lines("praise", "working=4")), True)
check("칭찬 — 친구 수", all("5명" in l for l in lines("praise", "agents=5")), True)
check("칭찬 — 다른 에이전트 이름", all("코덱스" in l for l in lines("praise", "working=3", "label=코덱스") if "군데" not in l and "굴리" not in l), True)
check("칭찬 — 오늘 기록", all("기록" in l for l in lines("praise", "working=6", "record=1")), True)
# per-agent styling (tools.json): overrides the last line, praise and name; unknown tools get the defaults
with tempfile.TemporaryDirectory() as td:
    tf = os.path.join(td, "tools.json")
    with open(tf, "w") as f:
        json.dump({"codex": {"label": "코덱스", "done": ["코덱스 끝!"], "ask": ["코덱스 질문!"], "praise": ["코덱스 {n}개 출동!"], "fill": "nope"}}, f)
    def tlines(*args):
        r = subprocess.run([BIN, "--lines", *args], capture_output=True, text=True, timeout=10, env={**os.environ, "DOTBUDDY_TOOLS": tf})
        return set(r.stdout.split("\n")) - {""}
    check("꾸미기 — 끝줄", tlines("done", "tool=codex"), {"코덱스 끝!"})
    check("꾸미기 — 끝줄 밀린 수", tlines("done", "tool=codex", "waiting=2"), {"코덱스 끝! (+2)"})
    check("꾸미기 — 질문", tlines("done", "tool=codex", "mood=ask"), {"코덱스 질문!"})
    check("꾸미기 — 칭찬 {n}", tlines("praise", "working=4", "tool=codex"), {"코덱스 4개 출동!"})
    check("꾸미기 — 없는 도구는 기본", any("끝났" in l or "완료" in l or "다 했" in l for l in tlines("done", "tool=other", "high=200")), True)
    check("꾸미기 — 클로드 이름 기본", all("클로드" in l for l in tlines("praise", "working=4", "tool=claude") if "군데" not in l and "굴리" not in l), True)
# wrapping any CLI (--run): working while it runs (wrapper pid), done when it ends (calling shell pid), exit code passes through
with tempfile.TemporaryDirectory() as td:
    env = {**os.environ, "DOTBUDDY_SESSIONS": td, "DOTBUDDY_QUIET": "1"}
    r = subprocess.run([BIN, "--run", "--tool", "aider", "--name", "고치기", "--", "/bin/sh", "-c", 'cat "$DOTBUDDY_SESSIONS"/*.json'], capture_output=True, text=True, timeout=10, env=env)
    during = json.loads(r.stdout or "{}")
    after = json.loads(open(os.path.join(td, f"aider-sh-{os.getpid()}.json")).read()) if os.path.exists(os.path.join(td, f"aider-sh-{os.getpid()}.json")) else {}
    check("감싸기 — 도는 동안", (during.get("status"), during.get("tool"), during.get("name")), ("busy", "aider", "고치기"))
    check("감싸기 — 끝나면 셸에 묶임", (after.get("status"), after.get("pid")), ("idle", os.getpid()))
    check("감싸기 — 종료 코드", subprocess.run([BIN, "--run", "--", "/bin/sh", "-c", "exit 3"], capture_output=True, timeout=10, env=env).returncode, 3)
    check("감싸기 — 없는 명령", subprocess.run([BIN, "--run", "--", "no-such-cmd-xyz"], capture_output=True, timeout=10, env=env).returncode, 127)
    check("감싸기 — 명령 없음", subprocess.run([BIN, "--run"], capture_output=True, timeout=10, env=env).returncode, 2)
# where a notification click goes: a pid that is not a terminal goes nowhere; if tools.json has "open", that command (with placeholders substituted) comes first
def where(pid, tool="claude", tf=None):
    env = {**os.environ, "DOTBUDDY_TOOLS": tf} if tf else os.environ
    return json.loads(subprocess.run([BIN, "--where", str(pid), tool], capture_output=True, text=True, timeout=10, env=env).stdout)
check("가는 곳 — pid 0", where(0)["via"], "none")
check("가는 곳 — launchd", where(1)["via"], "none")
with tempfile.TemporaryDirectory() as td:
    tf, mark = os.path.join(td, "tools.json"), os.path.join(td, "opened")
    with open(tf, "w") as f:
        json.dump({"*": {"open": ["/bin/sh", "-c", 'echo "$0 $1" > ' + mark, "{tool}", "{id}"]}, "codex": {"open": ["/usr/bin/true", "{pid}"]}}, f)
    check("가는 곳 — 도구별 open", where(0, "codex", tf)["open"], ["/usr/bin/true", ""])
    check("가는 곳 — 기본 open(*)", (where(0, "other", tf)["via"], where(0, "other", tf)["open"][3]), ("open", "other"))
    subprocess.run([BIN, "--open", "0", "gemini", "s1"], capture_output=True, timeout=10, env={**os.environ, "DOTBUDDY_TOOLS": tf})
    check("가는 곳 — open 명령 실행", open(mark).read().strip() if os.path.exists(mark) else None, "gemini s1")
    os.remove(mark)
    subprocess.run([BIN, "--open", "0", "gemini", "x{tool}{pid}"], capture_output=True, timeout=10, env={**os.environ, "DOTBUDDY_TOOLS": tf})
    check("가는 곳 — 넣은 값 안의 {…} 는 다시 안 바꿈", open(mark).read().strip() if os.path.exists(mark) else None, "gemini x{tool}{pid}")
    os.remove(mark)
    subprocess.run([BIN, "--open", "0", "", "signal:1"], capture_output=True, timeout=10, env={**os.environ, "DOTBUDDY_TOOLS": tf})
    check("가는 곳 — 바깥 신호 알림은 명령을 안 돌림", os.path.exists(mark), False)
# gesture signals from other agents: unknown names are refused (valid names would reach the real app, so they are not sent here)
check("몸짓 신호 — 모르는 이름 거절", subprocess.run([BIN, "--signal", "event", "dance"], capture_output=True, timeout=10).returncode, 2)
check("몸짓 신호 — 빈 이름 거절", subprocess.run([BIN, "--signal", "event"], capture_output=True, timeout=10).returncode, 2)
lunch = [l for l in subprocess.run([BIN, "--lines", "idle", "hour=12", "weekday=3"], capture_output=True, text=True, timeout=10).stdout.split("\n") if l]
check("점심 — 배고파 류가 자주", sum(any(k in l for k in ["배고파", "점심", "꼬르륵", "밥 먹", "배에서"]) for l in lunch) > len(lunch) * 0.3, True)
check("밤 — 점심 말 없음", any("점심" in l for l in lines("idle", "hour=23", "weekday=3")), False)
check("캐릭터 혼잣말 — 촛불", any("꺼질" in l or "촛농" in l or "밝혀" in l or "불 조심" in l for l in lines("idle", "chara=candle", "hour=16", "weekday=3")), True)
check("캐릭터 혼잣말 — 다른 캐릭터엔 안 섞임", any("촛농" in l for l in lines("idle", "chara=mandu", "hour=16", "weekday=3")), False)
check("매달림 — 팔 아파", any("팔" in l or "버텨" in l or "대롱" in l for l in lines("idle", "spot=hang", "on=air")), True)

# character packs: export a sample and read it back, and motions are picked up by frame count and every motion name is in the docs
with tempfile.TemporaryDirectory() as packs:
    subprocess.run([BIN, "--export-pack", os.path.join(packs, "c2"), "acorn"], capture_output=True, timeout=20)
    os.remove(os.path.join(packs, "c2", "sit.png"))                        # a missing motion falls back to a default (reading is unchanged)
    with open(os.path.join(packs, "bad.png"), "wb") as f: f.write(b"not a png")   # a broken file is skipped
    env = dict(os.environ, DOTBUDDY_CHARAS=packs)
    out = json.loads(subprocess.run([BIN, "--charas"], capture_output=True, text=True, timeout=20, env=env).stdout)
    c2 = [c for c in out["charas"] if c["id"] == "pack:c2"]
    check("꾸러미 읽기", (len(out["charas"]), bool(c2) and c2[0]["motions"].get("walk"), bool(c2) and "sit" in c2[0]["motions"]), (1, 2, False))
    r = subprocess.run([BIN, "--motion-sheet", os.path.join(packs, "s.png"), "pack:c2"], capture_output=True, text=True, timeout=20, env=env)
    check("꾸러미 미리보기", (r.returncode, os.path.exists(os.path.join(packs, "s.png"))), (0, True))
    doc = open(os.path.join(HERE, "CHARACTERS.md"), encoding="utf-8").read()
    missing = [n for n in out["motionNames"] if f"| `{n}` |" not in doc]
    check("문서에 동작 이름", missing, [])
with tempfile.TemporaryDirectory() as packs:                                    # badly made packs (eyes outside the picture, negative fps, too-large picture) are skipped without crashing the app
    import struct, zlib
    def png(path, w, h):                                                         # a single gray image (w×h when decompressed) — small file, large picture once decompressed
        raw = zlib.compress(b"".join(b"\0" + b"\0" * w for _ in range(h)), 9)
        chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
        open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)) + chunk(b"IDAT", raw) + chunk(b"IEND", b""))
    png(os.path.join(packs, "huge.png"), 5000, 5000)
    for name, meta in [("eyes", {"eyes": [[2, -1, 2, 2], [20, 15, 1, 1], [0, 0, 1, -1]]}), ("fps", {"fps": {"default": -6, "walk": 1e300}})]:
        subprocess.run([BIN, "--export-pack", os.path.join(packs, name), "acorn"], capture_output=True, timeout=20)
        cj = os.path.join(packs, name, "chara.json")
        with open(cj) as f: m0 = json.load(f)
        with open(cj, "w") as f: json.dump({**m0, **meta}, f)
    r = subprocess.run([BIN, "--charas"], capture_output=True, text=True, timeout=20, env=dict(os.environ, DOTBUDDY_CHARAS=packs))
    ids = sorted(c["id"] for c in json.loads(r.stdout or '{"charas": []}')["charas"])
    check("잘못 만든 꾸러미 — 죽지 않음", (r.returncode, ids), (0, ["pack:eyes", "pack:fps"]))
    r = subprocess.run([BIN, "--motion-sheet", os.path.join(packs, "s.png"), "pack:fps"], capture_output=True, timeout=20, env=dict(os.environ, DOTBUDDY_CHARAS=packs))
    check("잘못 만든 꾸러미 — 음수 fps 로 그려도 안 죽음", r.returncode, 0)
with tempfile.TemporaryDirectory() as packs:                                    # six high-resolution default character packs: the generator draws them and the app reads them all
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "charas", "chars.py"), packs], capture_output=True, timeout=60)
    out = json.loads(subprocess.run([BIN, "--charas"], capture_output=True, text=True, timeout=20, env=dict(os.environ, DOTBUDDY_CHARAS=packs)).stdout)
    got = sorted((c["id"], c["size"] == [26, 26], len(c["motions"]) >= 14) for c in out["charas"])
    check("기본 꾸러미 여섯", got, sorted((f"pack:{k}", True, True) for k in ["acorn", "candle", "cloud", "mandu", "pebble", "sprout"]))
# Codex pet (pet.json + 8×9 sheet): export our character and read it back, and it comes out at the same size and motions. Both the character folder and CODEX_HOME/pets are read
with tempfile.TemporaryDirectory() as td:
    home, charas = os.path.join(td, "codex"), os.path.join(td, "charas")
    os.makedirs(charas)
    r1 = subprocess.run([BIN, "--export-codex-pet", os.path.join(home, "pets", "acorn"), "acorn"], capture_output=True, timeout=20, env=dict(os.environ, DOTBUDDY_CHARAS=charas)).returncode
    r2 = subprocess.run([BIN, "--export-codex-pet", os.path.join(charas, "mandu-cx"), "mandu"], capture_output=True, timeout=20, env=dict(os.environ, DOTBUDDY_CHARAS=charas)).returncode
    os.makedirs(os.path.join(charas, "bad"))                                        # a pet.json pointing outside the sheet is skipped
    with open(os.path.join(charas, "bad", "pet.json"), "w") as f:
        json.dump({"id": "bad", "displayName": "bad", "spritesheetPath": "../codex/pets/acorn/spritesheet.png"}, f)
    out = json.loads(subprocess.run([BIN, "--charas"], capture_output=True, text=True, timeout=20, env=dict(os.environ, DOTBUDDY_CHARAS=charas, CODEX_HOME=home)).stdout)
    got = {c["id"]: (c["name"], sorted(c["motions"])) for c in out["charas"]}
    want = sorted(["idle", "walk", "sneak", "wave", "happy", "jump", "cheer", "pout", "dizzy", "ask", "work"])
    check("Codex 펫 — 내보내기", (r1, r2), (0, 0))
    check("Codex 펫 — CODEX_HOME 에서", got.get("codex:acorn"), ("도토리", want))
    check("Codex 펫 — 캐릭터 폴더에서", got.get("codex:mandu-cx"), ("만두", want))
    check("Codex 펫 — 폴더 밖 시트 거절", "codex:bad" in got, False)
    check("Codex 펫 — 키 24점 안팎", all(22 <= c["size"][1] <= 32 for c in out["charas"] if c["id"].startswith("codex:")), True)
with tempfile.TemporaryDirectory() as packs:
    tp = os.path.join(packs, "typing.png")                                         # typing preview: three dots + typing one character at a time are drawn
    r = subprocess.run([BIN, "--typing-preview", tp], capture_output=True, text=True, timeout=20)
    check("타이핑 말풍선", (r.returncode, os.path.exists(tp) and os.path.getsize(tp) > 500), (0, True))

# dotbuddy-hook (built in): reads the agent's hook JSON, reports the session, prints the reply, always exits 0
with tempfile.TemporaryDirectory() as td:
    env = {**os.environ, "DOTBUDDY_SESSIONS": td, "DOTBUDDY_PID": str(os.getpid())}
    def hook(payload, *args):
        return subprocess.run([BIN, "--hook", *args], input=payload, capture_output=True, text=True, timeout=10, env=env)
    r = hook('{"session_id":"s1","cwd":"/work/proj/"}', "codex", "session_id", "busy", "{}")
    got = json.load(open(os.path.join(td, "codex-s1.json"))) if os.path.exists(os.path.join(td, "codex-s1.json")) else {}
    check("hook — report", (r.returncode, r.stdout.strip(), got.get("status"), got.get("name"), got.get("pid")), (0, "{}", "busy", "codex · proj", os.getpid()))
    r = hook('{"workspace_roots":["/a/web"],"conversation_id":"c1"}', "cursor", "conversation_id", "idle")
    check("hook — nested path", json.load(open(os.path.join(td, "cursor-c1.json"))).get("name") if os.path.exists(os.path.join(td, "cursor-c1.json")) else None, "cursor · web")
    check("hook — junk input still exits 0", (hook("not json", "x", "session_id", "busy").returncode, hook("", "x").returncode), (0, 0))
    hook('{"session_id":"s1"}', "codex", "session_id", "end")
    check("hook — end removes", os.path.exists(os.path.join(td, "codex-s1.json")), False)

# Notices: three or more "done" at once merge into one bubble; questions stay separate
def merged(spec):
    return subprocess.run([BIN, "--merge-notices", spec], capture_output=True, text=True, timeout=10, env={**os.environ, "DOTBUDDY_LANG": "en"}).stdout.split("\n")[:2]
check("notices — two stay separate", merged("a,b"), ["a", "b"])
check("notices — four merge", merged("a,b,c,d"), ["4 done: a, b, c…", ""])
check("notices — questions not merged", merged("a,q?,b,c"), ["3 done: a, b, c", "q"])
check("notices — a question first is shown alone", merged("q?,a,b"), ["q", "a,b"])

# Updater: version order, and a signature that doesn't match is refused (the real key only lives in CI)
def run_ok(*args):
    return subprocess.run([BIN, *args], capture_output=True, timeout=20).returncode == 0
check("update — version order", [run_ok("--version-newer", a, b) for a, b in [("0.10.0", "0.9.3"), ("0.1.1", "0.1.0"), ("0.1.0", "0.1.0"), ("v1.0", "0.9"), ("0.1", "0.1.0")]], [True, True, False, True, False])
with tempfile.TemporaryDirectory() as td:
    z, s = os.path.join(td, "u.zip"), os.path.join(td, "u.zip.sig")
    open(z, "wb").write(os.urandom(4096)); open(s, "w").write("AAAA" * 22)
    check("update — bad signature refused", subprocess.run([BIN, "--verify-update", z, s], capture_output=True, timeout=20).returncode, 1)

# README demo GIFs are drawn offscreen by the app (no screen recording)
with tempfile.TemporaryDirectory() as td:
    g = os.path.join(td, "c.gif")
    r = subprocess.run([BIN, "--demo-gif", g, "characters"], capture_output=True, timeout=60)
    check("demo GIF", (r.returncode, os.path.exists(g) and open(g, "rb").read(6) in (b"GIF89a", b"GIF87a")), (0, True))
    # "Save This Character as GIF" in the menu runs this for the character on screen; an unknown character makes no file
    g1, g2 = os.path.join(td, "m.gif"), os.path.join(td, "x.gif")
    r1 = subprocess.run([BIN, "--demo-gif", g1, "chara:mandu"], capture_output=True, timeout=60)
    r2 = subprocess.run([BIN, "--demo-gif", g2, "chara:no-such-one"], capture_output=True, timeout=60)
    check("GIF of one character", (r1.returncode, os.path.exists(g1) and open(g1, "rb").read(6) in (b"GIF89a", b"GIF87a"), r2.returncode, os.path.exists(g2)), (0, True, 1, False))

# English: with an English system language, no Hangul gets mixed into the mutterings and notification text
import re
def en_lines(*args):
    r = subprocess.run([BIN, "--lines", *args], capture_output=True, text=True, timeout=10, env={**os.environ, "DOTBUDDY_LANG": "en"})
    return [l for l in r.stdout.split("\n") if l]
hangul = re.compile("[\uac00-\ud7a3]")
cases = [("idle", "hour=12", "weekday=3"), ("idle", "hour=23", "weekday=6"), ("idle", "on=window", "high=300"), ("idle", "spot=hang", "on=air"), ("idle", "chara=candle"),
         ("done", "high=200", "waiting=2"), ("done", "mood=ask"), ("praise", "working=4"), ("praise", "agents=5"), ("carried", "high=600"), ("idle", "mood=wait", "waiting=2")]
leaks = sorted({l for c in cases for l in en_lines(*c) if hangul.search(l)})
check("영어 — 한글 안 섞임", leaks, [])
check("영어 — 문구가 나옴", all(en_lines(*c) for c in cases), True)
xmas = re.compile("Christmas|presents|Cake")
check("계절 — 크리스마스·새해에만, 끄면 안 나옴", (any(xmas.search(l) for l in en_lines("idle", "date=12-25", "hour=15")), any(xmas.search(l) for l in en_lines("idle", "date=12-25", "hour=15", "seasonal=0")),
      any(xmas.search(l) for l in en_lines("idle", "date=7-1", "hour=15")), any("New Year" in l for l in en_lines("idle", "date=1-1", "hour=15"))), (True, False, False, True))

# community characters (the client side; the pack rules are tested in dot-buddy/characters): installing from the list works,
# and a file that doesn't match the list, an id with a path in it, or a folder the user made themselves is refused.
# tests/fixtures/community is one pack and its index entry, copied from that repo.
FIXTURE = os.path.join(HERE, "tests", "fixtures", "community")
def motions():
    src = open(os.path.join(HERE, "Sources", "Charas.swift"), encoding="utf-8").read()
    return re.findall(r'\("([a-z]+)", T\(', src[src.index("let MOTIONS"):src.index("let MOTION_FALLBACK")])
def community(base, charas, *args):
    env = dict(os.environ, DOTBUDDY_COMMUNITY_BASE=base, DOTBUDDY_CHARAS=charas)
    r = subprocess.run([BIN, *args], capture_output=True, text=True, timeout=30, env=env)
    return r.returncode, r.stdout.strip()
base = "file://" + FIXTURE + "/"
ids = [p["id"] for p in json.load(open(os.path.join(FIXTURE, "index.json")))["packs"]]
with tempfile.TemporaryDirectory() as td:
    ch = os.path.join(td, "charas")
    rc, out = community(base, ch, "--community-install", ids[0])
    st = json.loads(community(base, ch, "--community-list")[1])
    loaded = [c["id"] for c in json.loads(community(base, ch, "--charas")[1])["charas"]]
    check("커뮤니티 — 받기", (rc, out, [p["state"] for p in st if p["id"] == ids[0]], "pack:" + ids[0] in loaded), (0, "pack:" + ids[0], ["installed"], True))
    src = os.path.join(td, "src"); shutil.copytree(FIXTURE, src)
    open(os.path.join(src, ids[0], "idle.png"), "ab").write(b"x")                        # changed after the list was made
    idx = json.load(open(os.path.join(src, "index.json")))
    idx["packs"].append(dict(idx["packs"][0], id="../escape"))                             # a path in the id: left out of the list
    json.dump(idx, open(os.path.join(src, "index.json"), "w"))
    rc2, _ = community("file://" + src + "/", os.path.join(td, "c2"), "--community-install", ids[0])
    listed = [p["id"] for p in json.loads(community("file://" + src + "/", os.path.join(td, "c2"), "--community-list")[1])]
    mine = os.path.join(td, "c3"); os.makedirs(os.path.join(mine, ids[0]))
    rc3, _ = community(base, mine, "--community-install", ids[0])
    check("커뮤니티 — 안 맞는 파일·경로 id·내 폴더는 거절", (rc2, os.path.exists(os.path.join(td, "c2", ids[0])), "../escape" in listed, rc3, os.listdir(os.path.join(mine, ids[0]))), (1, False, False, 1, []))
    lk = os.path.join(td, "likes"); shutil.copytree(FIXTURE, lk); li = json.load(open(os.path.join(lk, "index.json")))
    li["packs"][0].update(likes=5, discussion="https://example.com/discussions/1"); li["packs"].append(dict(li["packs"][0], id="liked", likes=2, discussion="https://github.com/dot-buddy/characters/discussions/7"))
    json.dump(li, open(os.path.join(lk, "index.json"), "w"))
    got = {p["id"]: (p["likes"], p["discussion"]) for p in json.loads(community("file://" + lk + "/", os.path.join(td, "c4"), "--community-list")[1])}
    check("커뮤니티 — 좋아요 수와 GitHub 토론 링크만", (got[ids[0]], got["liked"]), ((5, ""), (2, "https://github.com/dot-buddy/characters/discussions/7")))
    li["packs"][-1]["descriptions"] = {"ko": "한국어 소개"}; json.dump(li, open(os.path.join(lk, "index.json"), "w"))
    def described(lang):
        env = dict(os.environ, DOTBUDDY_COMMUNITY_BASE="file://" + lk + "/", DOTBUDDY_CHARAS=os.path.join(td, "c4"), DOTBUDDY_LANG=lang)
        out = subprocess.run([BIN, "--community-list"], capture_output=True, text=True, timeout=30, env=env).stdout
        return {p["id"]: p["description"] for p in json.loads(out)}
    ko, en = described("ko"), described("en")
    check("커뮤니티 — 설명은 보는 사람 언어로(없으면 기본)", (ko["liked"], en["liked"] == li["packs"][0]["description"], ko[ids[0]] == li["packs"][0]["description"]), ("한국어 소개", True, True))
    rr, _ = community(base, mine, "--community-remove", ids[0])                         # Remove: never a folder the user made
    r4, out4 = community(base, ch, "--community-remove", ids[0])
    st4 = [p["state"] for p in json.loads(community(base, ch, "--community-list")[1]) if p["id"] == ids[0]]
    check("커뮤니티 — 지우기(받은 것만)", (rr, os.path.isdir(os.path.join(mine, ids[0])), r4, out4, os.path.exists(os.path.join(ch, ids[0])), st4), (1, True, 0, "pack:" + ids[0], False, ["notInstalled"]))

# a character someone sent you (--install-chara = dropping it on the pet): only the files the loader reads are copied, a folder
# with the same name is replaced, a single png works, and a zip without a character or with a path outside it is refused
import struct, zlib, zipfile
def rgba_png(path, w, h):
    raw = zlib.compress((b"\0" + b"\x40\x80\xc0\xff" * w) * h, 9)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", raw) + chunk(b"IEND", b""))
with tempfile.TemporaryDirectory() as td:
    ch = os.path.join(td, "charas")
    def inst(p):
        r = subprocess.run([BIN, "--install-chara", p], capture_output=True, text=True, timeout=30, env=dict(os.environ, DOTBUDDY_CHARAS=ch))
        return r.returncode, r.stdout.strip()
    pack = os.path.join(td, "src", "buddy"); shutil.copytree(os.path.join(FIXTURE, ids[0]), pack)
    open(os.path.join(pack, "run.sh"), "w").write("echo hi")
    mo = set(motions())
    want = sorted(f for f in os.listdir(pack) if f == "chara.json" or (f.endswith(".png") and f[:-4] in mo))
    z = os.path.join(td, "buddy-share.zip"); subprocess.run(["ditto", "-c", "-k", "--keepParent", pack, z], check=True)
    r1 = inst(z); got1 = sorted(os.listdir(os.path.join(ch, "buddy")))
    os.remove(os.path.join(pack, "walk.png"))
    r2 = inst(pack); got2 = "walk.png" in os.listdir(os.path.join(ch, "buddy"))
    png = os.path.join(td, "blob.png"); rgba_png(png, 12, 10)
    r3 = inst(png)
    os.makedirs(os.path.join(td, "notes")); open(os.path.join(td, "notes", "a.txt"), "w").write("hi")
    nz = os.path.join(td, "notes.zip"); subprocess.run(["ditto", "-c", "-k", "--keepParent", os.path.join(td, "notes"), nz], check=True)
    r4 = inst(nz)
    ez = os.path.join(td, "evil.zip")
    with zipfile.ZipFile(ez, "w") as zf: zf.write(png, "../evil.png")
    r5 = inst(ez)
    loaded = [c["id"] for c in json.loads(community(base, ch, "--charas")[1])["charas"]]
    check("받은 캐릭터 설치 — zip·폴더·png", (r1, got1 == want, r2[0], got2, r3, "pack:buddy" in loaded, "custom:blob" in loaded),
          ((0, "pack:buddy"), True, 0, False, (0, "custom:blob"), True, True))
    check("받은 캐릭터 설치 — 캐릭터 없는 zip·밖을 가리키는 경로는 거절", (r4[0], r5[0], os.path.exists(os.path.join(td, "evil.png")), sorted(os.listdir(ch))),
          (1, 1, False, ["blob.png", "buddy"]))

if fails:
    print("FAIL\n  " + "\n  ".join(fails))
    sys.exit(1)
print("ok — dot-buddy selftest")
