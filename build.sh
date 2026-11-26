#!/usr/bin/env bash
# Dot Buddy build and install — runs with only this folder (uses no other file in the repo). Needs: Xcode command line tools (xcode-select --install).
#   ./build.sh               build for this Mac's chip and install to ~/Applications/Dot Buddy.app
#   ./build.sh --universal   an app that runs on both Apple silicon and Intel Macs (for handing out)
#   APP=<path> ./build.sh     build the app somewhere else · with FORCE=1, rebuild even if the sources are unchanged
# Fonts (Galmuri and Neo Dunggeunmo, OFL) are downloaded and checked against a checksum — if they cannot be downloaded, the system font is used.
# The default character packs are made only if python3 is available — otherwise the small built-in drawings are used.
# Exit codes: 0 done, 1 missing tool, 2 bad usage. A running app is not restarted.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# m "English" "<Korean>" — prints the Korean text when LANG starts with ko, else English
m() { case "${LANG:-}" in ko*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
UNIVERSAL=0
for a in "$@"; do case "$a" in --universal) UNIVERSAL=1 ;; *) echo "$(m "Unknown option: $a (--universal)" "모르는 옵션: $a (--universal)")" >&2; exit 2 ;; esac; done
ti_warn() { echo; echo "[$(m warning 주의)] $*"; }
for t in swiftc iconutil codesign lipo; do command -v "$t" >/dev/null 2>&1 || { echo "[$(m blocked 막힘)] $(m "$t not found — run: xcode-select --install" "$t 가 없다 — xcode-select --install")" >&2; exit 1; }; done
MINOS=13.0   # SMAppService (login item) needs macOS 13 or later
VERSION="${DOTBUDDY_VERSION:-$(tr -d ' \n' < VERSION 2>/dev/null || echo 0.0.0)}"
BUILD_KIND="${BUILD_KIND:-source}"   # "release" only for the zips CI publishes: those may replace themselves with a newer release   # the version number comes from the single VERSION file

# executable — only when the sources are newer than the binary or a wanted chip is missing. Built into a temp file, then mv (does not overwrite the running app's executable)
mkdir -p bin
ARCHS="$(uname -m)"; [ "$UNIVERSAL" = 1 ] && ARCHS="arm64 x86_64"
have="$( [ -x bin/DotBuddy ] && lipo -archs bin/DotBuddy 2>/dev/null || true)"
need=0; [ "${FORCE:-0}" = 1 ] || [ ! -x bin/DotBuddy ] && need=1
for f in Sources/*.swift; do [ "$f" -nt bin/DotBuddy ] && need=1; done
for a in $ARCHS; do case " $have " in *" $a "*) ;; *) need=1 ;; esac; done
if [ "$need" = 1 ]; then
  parts=()
  for a in $ARCHS; do
    swiftc -O -parse-as-library -target "$a-apple-macos$MINOS" Sources/*.swift -o "bin/DotBuddy.$a"
    parts+=("bin/DotBuddy.$a")
  done
  lipo -create "${parts[@]}" -output bin/DotBuddy.new && rm -f "${parts[@]}"
  mv -f bin/DotBuddy.new bin/DotBuddy
  echo "built: bin/DotBuddy ($(lipo -archs bin/DotBuddy))"
else
  echo "up to date: bin/DotBuddy ($have)"
fi

# Galmuri 7·9·11 pixel fonts for the bubbles (OFL 1.1, 14MB together) — not kept in the repo; downloaded from an npm package into bin/fonts (gitignored)
FONT_TGZ_SHA=8eaa5ee9761d19030807254c5cf357a08958c05e   # galmuri@2.40.3 dist.shasum
if [ ! -f bin/fonts/Galmuri7.ttf ] || [ ! -f bin/fonts/Galmuri9.ttf ] || [ ! -f bin/fonts/Galmuri11.ttf ]; then
  tmp="$(mktemp -d)"
  if curl -fsSL https://registry.npmjs.org/galmuri/-/galmuri-2.40.3.tgz -o "$tmp/g.tgz" && [ "$(shasum "$tmp/g.tgz" | cut -d' ' -f1)" = "$FONT_TGZ_SHA" ]; then
    tar xzf "$tmp/g.tgz" -C "$tmp" package/dist/Galmuri7.ttf package/dist/Galmuri9.ttf package/dist/Galmuri11.ttf package/dist/LICENSE.txt
    mkdir -p bin/fonts && mv "$tmp"/package/dist/Galmuri*.ttf bin/fonts/ && mv "$tmp/package/dist/LICENSE.txt" bin/fonts/Galmuri-LICENSE.txt
  else
    ti_warn "$(m "Could not download the Galmuri font — bubbles will use the system font" "Galmuri 글꼴을 못 받았다 — 말풍선이 시스템 글꼴로 나온다")"
  fi
  rm -rf "$tmp"
fi

# Six high-resolution default character packs (original, drawn by charas/chars.py) — drawn into bin/charas and put inside the app (Resources/charas).
# Not written to the user folder (~/Library/Application Support/DotBuddy/charas) (only identical copies that an old build put there are removed below)
if command -v python3 >/dev/null 2>&1; then
  if [ ! -f bin/charas/.built ] || [ charas/chars.py -nt bin/charas/.built ] || [ charas/pix.py -nt bin/charas/.built ]; then
    rm -rf bin/charas.new && python3 -I charas/chars.py bin/charas.new && touch bin/charas.new/.built && rm -rf bin/charas && mv bin/charas.new bin/charas \
      || { rm -rf bin/charas.new; ti_warn "$(m "Could not build the default character packs — falling back to the small built-in drawings" "기본 캐릭터 꾸러미를 못 만들었다 — 코드로 그린 작은 그림으로 나온다")"; }
  fi
else
  ti_warn "$(m "python3 not found, skipping the default character packs — falling back to the small built-in drawings" "python3 가 없어 기본 캐릭터 꾸러미를 건너뛴다 — 코드로 그린 작은 그림으로 나온다")"
fi


DEFAULT_APP="$HOME/Applications/Dot Buddy.app"
APP="${APP:-$DEFAULT_APP}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Files the running app holds open (executable, fonts) are not overwritten; only changed ones are swapped in as new files — installing while it is running
# used to delete the fonts the app had loaded, and every bubble character showed as a box (?) (2026-11-19)
put() { cmp -s "$1" "$2" && return 0; cp -f "$1" "$2.new" && mv -f "$2.new" "$2"; }
put bin/DotBuddy "$APP/Contents/MacOS/DotBuddy"
if [ -d bin/charas ] && ! diff -rq bin/charas "$APP/Contents/Resources/charas" >/dev/null 2>&1; then
  R="$APP/Contents/Resources"; rm -rf "$R/charas.new" "$R/charas.old"; cp -R bin/charas "$R/charas.new"
  [ -d "$R/charas" ] && mv "$R/charas" "$R/charas.old"; mv "$R/charas.new" "$R/charas"; rm -rf "$R/charas.old"
fi
# Neo Dunggeunmo (OFL, GitHub release) — checks the sha256 of the downloaded file
fetch() {  # fetch <url> <sha256> <save path>
  [ -f "$3" ] && return 0
  local tmp; tmp="$(mktemp)"
  if curl -fsSL "$1" -o "$tmp" && [ "$(shasum -a 256 "$tmp" | cut -d' ' -f1)" = "$2" ]; then mv "$tmp" "$3"; else rm -f "$tmp"; ti_warn "$(m "Could not download font: $1" "글꼴을 못 받았다: $1")"; return 1; fi
}
fetch https://github.com/neodgm/neodgm/releases/download/v1.601/neodgm.ttf 77305267996073aae07bad9313dad2e306a4128e55bfafbed4c41558fee57b4d bin/fonts/neodgm.ttf || true
fetch https://raw.githubusercontent.com/neodgm/neodgm/v1.601/LICENSE.txt c1997f54b659ff8bbe2addf4e7f03fb823db7d1b81b043fb2633183b1fc0c2f0 bin/fonts/neodgm-LICENSE.txt || true
for f in Galmuri7.ttf Galmuri9.ttf Galmuri11.ttf Galmuri-LICENSE.txt neodgm.ttf neodgm-LICENSE.txt; do
  [ -f "bin/fonts/$f" ] && put "bin/fonts/$f" "$APP/Contents/Resources/$f"
done
ICONSET="$(mktemp -d)/AppIcon.iconset"
bin/DotBuddy --make-icon "$ICONSET" && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.doldoldol21.dot-buddy</string>
  <key>CFBundleName</key><string>Dot Buddy</string>
  <key>CFBundleDisplayName</key><string>Dot Buddy</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>CFBundleExecutable</key><string>DotBuddy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>DotBuddyBuild</key><string>$BUILD_KIND</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Used to jump to the terminal tab (Terminal, iTerm2, Ghostty) running a session when you click its notification.</string>
</dict></plist>
PLIST
# Korean localization (Finder and the system show the Korean name and permission text on Korean systems)
mkdir -p "$APP/Contents/Resources/ko.lproj"
cat > "$APP/Contents/Resources/ko.lproj/InfoPlist.strings" <<'STRINGS'
CFBundleDisplayName = "도트 친구";
NSAppleEventsUsageDescription = "알림을 누르면 그 세션이 도는 터미널 탭(Terminal·iTerm2·Ghostty)으로 가려고 씁니다.";
STRINGS
# Remove the default packs an old build put in the user folder that are identical to the current ones (left there, they keep hiding the app's new drawings). Only when installing to the default location
UC="$HOME/Library/Application Support/DotBuddy/charas"
if [ "$APP" = "$DEFAULT_APP" ] && [ -d "$APP/Contents/Resources/charas" ] && [ -d "$UC" ]; then
  for p in "$APP"/Contents/Resources/charas/*/; do p="$(basename "$p")"; [ -d "$UC/$p" ] && diff -rq "$APP/Contents/Resources/charas/$p" "$UC/$p" >/dev/null 2>&1 && rm -rf "${UC:?}/$p" && echo "$(m "removed: default pack $p from the user folder (the app bundles an identical one)" "치움: 사용자 폴더의 기본 꾸러미 $p(앱 안에 같은 것이 있다)")"; done
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || ti_warn "$(m "Ad-hoc signing failed — on first launch, right-click → Open" "임시 서명 실패 — 처음 열 때 우클릭 → 열기")"
echo "$(m app 앱): $APP"
