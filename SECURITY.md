# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability** (<https://github.com/doldoldol21/dot-buddy/security/advisories/new>). Don't open a public issue for a security problem.

Include the Dot Buddy version (`DotBuddy --version`), your macOS version, and steps to reproduce. This is a volunteer project; we aim to reply within a week. Fixes go into the next release, and the advisory is published once a fixed build is available.

Only the latest release is supported.

## What Dot Buddy can do on your Mac

Dot Buddy runs as your user, without elevated privileges, and makes no network connections except the opt-in update check and the community character list (only while you have **More Characters…** open). These are the parts worth knowing about when you judge a report.

**It runs local commands in two places, both of which you set up yourself:**

- **`tools.json` `open` commands.** When you click a bubble, the `open` command for that agent in `~/Library/Application Support/DotBuddy/tools.json` runs as you. It runs through `/usr/bin/env` without a shell. Placeholders such as `{name}` and `{id}` are filled with session data, which can come from outside (for example a session name), so the values are substituted once and never re-expanded. Still, treat `tools.json` like a shell script: anyone who can write to it can run commands as you when you click a bubble. Bubbles raised by `DotBuddy --signal` never run `open` commands.
- **`DotBuddy --run -- <command>`** runs the command you give it, unchanged, and reports it as a session.

**It accepts input from any local process:**

- `--signal` posts a macOS distributed notification that the running app listens to. Any process running as you can make the pet speak (text is truncated) or show a notice.
- `--report` writes small JSON files to `~/Library/Application Support/DotBuddy/sessions/`. Any process running as you can add sessions there.

Neither path runs commands. Local processes running as you are already trusted at that level, so these are not vulnerabilities by themselves. A way to turn them into command execution, file writes outside Dot Buddy's folder, or a crash is.

**It reads files:**

- Claude Code session files under `~/.claude/sessions/` and the tail of a working session's transcript (read-only).
- Images and `chara.json` in the character folder, and Codex pets in `~/.codex/pets/`. Image dimensions are checked before decoding, and a Codex pet's `spritesheetPath` may not point outside its own folder.

**Automation permission.** To focus a tab in Terminal or iTerm2, Dot Buddy sends AppleScript to that app, and macOS asks you for permission the first time.

**Community characters.** **More Characters…** reads `packs/index.json` from [dot-buddy/characters](https://github.com/dot-buddy/characters) on raw.githubusercontent.com (versions before 0.3.17 read a folder in this repo that has since been removed; update to get the list back). Installing a pack downloads only the files the index lists for it, each limited to `chara.json` or a `<motion>.png` name and 256 KB, checks every file's size and SHA-256 against the index, writes them to a new folder inside the character folder, and keeps the pack only if the normal loader reads it. A pack never replaces a folder you created yourself. Packs are reviewed before they're merged, but they are not signed: the trust is "whatever is on `main`". A way to make an install write outside the character folder, or to get code to run from a pack, is a vulnerability.

## Release builds

Release zips are built by GitHub Actions from a tagged commit, ad-hoc signed, and not notarized. If you'd rather not trust a downloaded binary, build from source with `./build.sh`; the build downloads only the two fonts and verifies their checksums.

## Updates

Release zips are signed in CI with an Ed25519 key that only exists as the repository secret `UPDATE_SIGNING_KEY` (and an offline backup held by the maintainer). The app embeds the public key (`UPDATE_PUBLIC_KEY` in `Sources/Update.swift`) and refuses any download whose signature, bundle identifier, version or code signature doesn't match. If you find a way around these checks, please report it privately.
