# Contributing to Dot Buddy

Thanks for helping. Bug reports, new agent integrations, terminal support and characters you drew yourself are all welcome.

## What Dot Buddy is for

Dot Buddy is a desktop pet you look at. It lives on your screen and tells you, with as little of your attention as possible, whether your agents are working, done or waiting on you. It is not a way to talk to your agents or drive them. Please read this before you start on a feature; a pull request outside it will be closed however well it is made.

Welcome:

- Bug fixes, especially movement, floors, windows and multiple monitors
- Clearer ways to show what agents are doing (reactions, bubbles, badges)
- Integrations for more agents, and more terminals for click-to-jump
- Characters, poses, lines and effects
- Performance, accessibility and translations

Out of scope:

- Chatting with the pet, or with an agent through it, and any calls to an LLM or AI API
- Sending anything to an agent: answering its questions, approving tool use, starting or stopping sessions
- Network features beyond the update check: accounts, sync, analytics, telemetry, remote services
- Tools unrelated to watching agents: to-do lists, timers, reminders, notes, clipboard, music
- Reading more of your data than showing session status needs

Not sure whether an idea fits? Open an issue and ask before writing code.

## Build and run

You need macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). `python3` is optional; it draws the high-res built-in characters.

```bash
./build.sh                          # build bin/DotBuddy and install ~/Applications/Dot Buddy.app
APP=/tmp/Dot.app FORCE=1 ./build.sh # build a throwaway copy elsewhere, forcing a rebuild
./build.sh --universal              # arm64 + x86_64
```

The build skips compiling when no file in `Sources/` changed, and never relaunches a running app. Quit the pet (right-click → Quit) and open the app again to see your change.

`bin/DotBuddy` is the same binary as the app's. Its CLI is handy while developing:

```bash
bin/DotBuddy --state                     # current session verdict as JSON
bin/DotBuddy --preview /tmp/poses.png    # every character × a set of poses
bin/DotBuddy --charas                    # characters that loaded, with frame counts
bin/DotBuddy --lines idle on=window high=300   # 200 sample idle lines for a situation
DOTBUDDY_LANG=en bin/DotBuddy --lines done high=3000
```

## Self-test

```bash
python3 selftest.py
```

It builds fake session files in a temp folder and checks the session verdicts, `--report`, `--run`, click targets, `tools.json`, speech lines, character packs and Codex pets. It doesn't launch the app. It needs a built `bin/DotBuddy`. CI runs the same build and test on every push and pull request.

Please add a check to `selftest.py` when you fix a bug or add behavior that can be tested from the CLI.

## Code layout

Everything is plain Swift and AppKit compiled with `swiftc`. There is no Xcode project and no package manager.

| File | What it holds |
|---|---|
| `Sources/Main.swift` | Entry point and the CLI (`--report`, `--signal`, `--run`, `--state`, previews and exports). The header comment documents the CLI |
| `Sources/Pet.swift` | The pet window and the pet itself: movement, physics, reactions, notices, the right-click menu |
| `Sources/Scene.swift` | Finding floors: screen bottom, widgets, window top edges, the Dock |
| `Sources/Sessions.swift` | Session sources (Claude Code session files, the `--report` folder), `tools.json`, the file watcher |
| `Sources/Terminal.swift` | Click-to-jump: finding the terminal app and tab for a session |
| `Sources/Chatter.swift` | Following a working session's transcript, and everything the pet says |
| `Sources/Bubble.swift` | Drawing speech bubbles with the pixel fonts; saved settings |
| `Sources/Draw.swift` | Pixel drawing: poses, props, character effects |
| `Sources/Charas.swift` | Built-in characters, the character pack loader, Codex pet import and export |
| `Sources/Lang.swift` | Language selection and the `T()` helpers |
| `Sources/Update.swift` | The self-updater: latest release lookup, Ed25519 signature check, swapping the app |
| `Sources/Demo.swift` | The README demo GIFs (`--demo-gif`), drawn offscreen, and community previews (`chara:<id>`) |
| `Sources/Community.swift` | Community characters: the list, downloading and checking a pack, the More Characters window |
| `scripts/sign-update.swift` | Signs a release zip in CI |
| `scripts/precheck.py`, `tests/test_precheck.py` | The pull request pre-check comment and its rule tests |
| `scripts/contributors.py`, `tests/test_contributors.py` | The contributors list in the READMEs, updated after every merge and once a day |
| `scripts/release-notes.py`, `tests/test_release_notes.py` | Release notes from the commits since the last tag |
| `tests/fixtures/community/` | One pack and its index entry, for the self-test of downloading community characters. The packs themselves and their checks live in [dot-buddy/characters](https://github.com/dot-buddy/characters) |
| `charas/chars.py`, `charas/pix.py` | Generator for the six built-in high-res character packs |
| `build.sh` | Build, font download, app bundle, ad-hoc signing. It installs to `~/Applications` unless you pass `APP=…`, so use `APP=/tmp/Dot.app ./build.sh` while you have a release build installed |
| `install.sh` | The one-line installer (latest signed release, no Gatekeeper prompt) |
| `selftest.py` | The self-test |

Adding an agent usually needs no Swift at all: its hooks call `--report` and `--signal` (see [docs/agents.md](docs/agents.md)). A built-in source is a class conforming to `SessionSource` in `Sessions.swift`, added to `makeSources()`. A new terminal for click-to-jump is one entry in `TAB_PICKERS` in `Terminal.swift`.

## Every user-facing string comes in two languages

Menus, bubbles, speech lines and CLI messages are shown in Korean or English. There are no string files; write both languages side by side with `T()`, Korean first:

```swift
say(T("다 했어!", "All done!"), now)
let lines = T(["안녕", "반가워"], ["hi", "hey there"])   // the two lists can differ in length
```

- Check both with `DOTBUDDY_LANG=ko` and `DOTBUDDY_LANG=en`.
- If you don't write Korean, put your English in both slots and say so in the pull request. Someone will translate it.
- Keep lines short; bubbles are small. The pet never repeats file paths, commands or question text.

## Characters and copyright

Do not submit characters you don't own the rights to: no characters from games, anime, films, brands or other people's art. Keep those in your own character folder (`~/Library/Application Support/DotBuddy/charas/`); the app only reads that folder and never sends it anywhere.

Original characters are welcome. The easiest way to share one is a pack in [dot-buddy/characters](https://github.com/dot-buddy/characters): add `packs/<name>/` as described in [its README](https://github.com/dot-buddy/characters#share-your-character). It shows up in everyone's **More Characters…** list after the merge. The built-in ones are drawn in code by `charas/chars.py`, so a new built-in character is a new class there. See [CHARACTERS.md](CHARACTERS.md).

## Pull requests

- Keep each pull request to one change, and describe what a user will notice.
- Run `python3 selftest.py` before you push.
- Changes to what the app reads or runs (session files, transcripts, `tools.json` commands) need a note on the privacy or security impact.
- A bot comment points out anything that looks off against this guide (network access, AI calls, text without `T()`, a missing self-test or privacy note, and whether the change fits the scope). It's a hint, not a blocker; the scope part is a small model and can be wrong.
- Once it's merged you're added to the contributors list in the [README](README.md#contributing) automatically.
- By contributing you agree that your work is released under the [MIT License](LICENSE).

## Releasing (maintainers)

1. Bump `VERSION` (SemVer) and commit.
2. Tag and push: `git tag -a v$(cat VERSION) -m "Dot Buddy $(cat VERSION)" && git push origin v$(cat VERSION)`.
3. CI checks that the tag matches `VERSION`, builds a universal app with `BUILD_KIND=release`, signs the zip with the `UPDATE_SIGNING_KEY` secret (`scripts/sign-update.swift`) and publishes the release with `Dot-Buddy-<version>.zip` and its `.sig`. The notes list the commit subjects since the last tag (`scripts/release-notes.py`), so write subjects a user can read. Installed release builds pick it up through the in-app updater.

Never rotate the signing key casually: apps already out there only trust the public key they were built with.
