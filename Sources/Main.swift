// Dot Buddy — a pixel pet that lives on your desktop and reacts to coding-agent sessions (Claude Code by default; other agents via "session sources").
//
// Claude session state is read only from ~/.claude/sessions/<pid>.json (status busy·shell·idle, statusUpdatedAt, name).
// It does not touch hooks, MCP, settings.json or CLAUDE.md, and never uses the conversation context. Only "waiting for a question" reads the last 64KB of the session jsonl.
// One pet represents everything: question(?) > waiting for you (✓ + count) > working (laptop) > all idle (asleep).
// Where it lives: the desktop layer (plays on widgets and window tops, hides behind windows); it comes to the front when it needs to call you.
// Clicking a notification opens that session's terminal (cmux·Terminal·iTerm2·Ghostty down to the tab, others just the app — changeable via "open" in tools.json). Right-click for settings. You can drag and throw it.
// A few ideas come from OpenPets (MIT): transparent pixels click through, fast ticks only while moving, throw speed from the last 0.1 s of samples.
//
//   DotBuddy                 the app (build and install: build.sh)
//   DotBuddy --version       version number (VERSION file -> Info.plist)
//   DotBuddy --state         print the current session verdict as JSON and exit (for self-tests; DOTBUDDY_CLAUDE_DIR and DOTBUDDY_SESSIONS change the folders)
//   DotBuddy --report <tool> <id> <busy|idle|ask|end> [--name NAME] [--label DISPLAY_NAME] [--pid N]
//                            another agent (Codex etc.) reports its own session state — call it from that tool's start/end hooks (see "session sources" below)
//   DotBuddy --run [--tool NAME] [--name NAME] [--label DISPLAY_NAME] -- <command ...>
//                            wrap any CLI as a session — working while it runs, done when it ends (for CLIs with no hooks)
//   DotBuddy --signal event <read|edit|test|commit|shell|web|skill|error|bg-start|bg-done|agent-start[:name]|agent-done>
//                            call it from that agent's tool hooks and the pet gestures and mutters like it does for Claude
//                            (--signal also takes say|done|ask|work|cheer|poke [text] [--from NAME])
//   DotBuddy --preview a.png character x pose sample sheet
//   DotBuddy --demo-gif a.gif [hero|characters|chara:<id>]   README demo animation / one character's preview, drawn offscreen
//   DotBuddy --community-list · --community-install <id> · --community-preview a.png   community characters (DOTBUDDY_COMMUNITY_BASE changes the source)
//   DotBuddy --install-chara <zip|folder|png>   put a character someone sent you into the characters folder (same as dropping it on the pet)
//   DotBuddy --install-cli [dir]  link dotbuddy and dotbuddy-hook into ~/.local/bin · --hook TOOL ID_KEY ACTION [REPLY] (= dotbuddy-hook, reads hook JSON on stdin)
//   DotBuddy --check-update  latest GitHub release vs this build (JSON) · --verify-update <zip> <sig> · --install-update <app path>
import AppKit
import CoreText
import ServiceManagement

// ---------- Start ----------
final class AppDelegate: NSObject, NSApplicationDelegate {
  let pet = Pet()
  func applicationDidFinishLaunching(_ n: Notification) { migrateDefaults(); registerFont(); pet.start(); pet.onboard() }
}

func writePNG(_ img: CGImage, _ path: String) {
  let rep = NSBitmapImageRep(cgImage: img)
  try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
/// The default character's automatic motions as frames per motion name — cropped to one same size (width, height) that holds all frames
func packFrames(_ ch: Chara) -> (Int, Int, [String: [[UInt32]]]) {
  func P(_ f: (inout Pose) -> Void) -> Pose { var p = Pose(); f(&p); return p }
  let set: [(String, [Pose])] = [
    ("idle", [P { _ in }, P { $0.squash = 1 }]), ("blink", [P { $0.eyes = .closed }]),
    ("walk", [P { $0.feet = 1; $0.look = 1 }, P { $0.feet = 2; $0.look = 1 }]),
    ("work", [P { $0.laptop = 0 }, P { $0.laptop = 1 }]), ("sleep", [P { $0.eyes = .closed; $0.squash = 1 }, P { $0.eyes = .closed; $0.squash = 2 }]),
    ("cheer", [P { $0.eyes = .happy }, P { $0.eyes = .happy; $0.squash = 1 }]), ("ask", [P { $0.eyes = .wide }]), ("happy", [P { $0.eyes = .happy }]),
    ("jump", [P { $0.eyes = .wide; $0.feet = 3; $0.squash = -1 }]), ("drag", [P { $0.eyes = .happy; $0.feet = 3; $0.squash = -1 }]),
    ("climb", [P { $0.feet = 1; $0.hands = true }, P { $0.feet = 2; $0.hands = true }]), ("hang", [P { $0.hands = true; $0.feet = 3; $0.squash = -1 }]),
    ("sit", [P { $0.feet = 3; $0.eyes = .happy }]), ("talk", [P { $0.talk = true }, P { _ in }]), ("startle", [P { $0.eyes = .wide; $0.feet = 3 }]),
    ("pout", [P { $0.eyes = .closed; $0.blush = true; $0.squash = 1; $0.angry = true }]), ("party", [P { $0.eyes = .happy; $0.hands = true }]),
    ("dizzy", [P { $0.eyes = .dizzy }]), ("wave", [P { $0.eyes = .happy; $0.wave = 0 }, P { $0.eyes = .happy; $0.wave = 1 }]),
    ("shy", [P { $0.eyes = .closed; $0.blush = true; $0.cover = true }]),
  ]
  let all = set.map { ($0.0, $0.1.map { draw(ch, $0) }) }
  var x0 = CW, x1 = 0, y0 = CH                                     // box that holds all frames (the bottom row is fixed at GY)
  for (_, cs) in all { for c in cs { for y in 0..<CH { for x in 0..<CW where c.px[y * CW + x] != 0 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y) } } } }
  let w = min(MAX_W, x1 - x0 + 1), h = min(MAX_H, GY - y0 + 1), ox = x0, oy = GY - h + 1
  var out: [String: [[UInt32]]] = [:]
  for (name, cs) in all { out[name] = cs.map { c in (0..<h).flatMap { y in (0..<w).map { x in c.px[(oy + y) * CW + ox + x] } } } }
  if let sp = ch.sprite { for (n, m) in sp.motions where m.w == w && m.h == h { out[n] = m.frames } }   // a motion the pack drew itself uses that drawing
  return (w, h, out)
}
/// Make a pack sample: the default character's automatic motions as one PNG per motion name (frames joined horizontally) + chara.json — a starting point for redrawing
func exportPack(_ ch: Chara, to dir: URL) -> [String] {
  let (w, h, frames) = packFrames(ch)
  let all = frames.sorted { $0.key < $1.key }
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  var wrote: [String] = []
  for (name, cs) in all {
    let W = w * cs.count
    var px = [UInt32](repeating: 0, count: W * h)
    for (k, c) in cs.enumerated() { for y in 0..<h { for x in 0..<w { px[y * W + k * w + x] = c[y * w + x] } } }
    let data = px.map { $0.bigEndian }.withUnsafeBufferPointer { Data(buffer: $0) }
    guard let prov = CGDataProvider(data: data as CFData), let img = CGImage(width: W, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: RGB_SPACE,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { continue }
    writePNG(img, dir.appendingPathComponent(name + ".png").path); wrote.append(name)
  }
  let meta: [String: Any] = ["name": ch.name + T(" 견본", " sample"), "frame": [w, h], "fps": ["default": 3, "walk": 6, "work": 5, "talk": 6, "wave": 5]]
  if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: dir.appendingPathComponent("chara.json")) }
  return wrote
}

@main
struct Main {
  static func main() {
    let a = CommandLine.arguments
    if (a[0] as NSString).lastPathComponent == "dotbuddy-hook" { runHook(Array(a.dropFirst())) }   // the same binary linked as dotbuddy-hook
    if a.count >= 2 && a[1] == "--hook" { runHook(Array(a.dropFirst(2))) }
    if a.count >= 2 && a[1] == "--install-cli" {
      switch installCLI(a.count >= 3 ? a[2] : NSHomeDirectory() + "/.local/bin") {
      case .success(let l): print(l.joined(separator: "\n")); exit(0)
      case .failure(let e): print(e.localizedDescription); exit(1)
      }
    }
    if a.count == 2 && (a[1] == "--version" || a[1] == "-v") { print(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"); exit(0) }   // run bin/DotBuddy directly and it prints dev
    if a.count >= 3 && a[1] == "--lines" {
      // sample mutterings by circumstance (for tests): --lines <kind> [high=pt] [on=base|widget|window] [spot=…] [mood=work|wait|ask|sleep] [working=N] [fast=1]
      var x = Ctx()
      for kv in a.dropFirst(3) {
        let p = kv.split(separator: "=", maxSplits: 1).map(String.init); guard p.count == 2 else { continue }
        switch p[0] {
        case "high": x.high = CGFloat(Double(p[1]) ?? 0)
        case "on": x.on = p[1]
        case "spot": x.spot = p[1]
        case "chara": x.chara = p[1]
        case "working": x.working = Int(p[1]) ?? 0
        case "waiting": x.waiting = Int(p[1]) ?? 0
        case "fast": x.fast = p[1] == "1"
        case "hour": x.hour = Int(p[1]) ?? x.hour; x.minute = 0
        case "weekday": x.weekday = Int(p[1]) ?? x.weekday
        case "date": let md = p[1].split(separator: "-").compactMap { Int($0) }; if md.count == 2 { x.month = md[0]; x.day = md[1] } else if md.count == 3 { x.year = md[0]; x.month = md[1]; x.day = md[2] }   // date=12-25 or 2026-12-25
        case "seasonal": x.seasonal = p[1] == "1"
        case "mood": x.mood = ["work": .work, "wait": .wait, "ask": .ask][p[1]] ?? .sleep
        default: break
        }
      }
      if a[2] == "done" {                                                            // last line of the notification: high=seconds worked, waiting=number of other waiting sessions, mood=ask
        let tl = a.first { $0.hasPrefix("tool=") }.map { String($0.dropFirst(5)) } ?? ""
        for _ in 0..<200 { print(doneLine(Notice(pid: 0, id: "x", title: "", ask: x.mood == .ask, worked: Double(x.high), others: x.waiting, tool: tl), hour: 14)) }
        return
      }
      if a[2] == "praise" {                                                          // praise: working=number of sessions, agents=number of friends, record=1
        let ag = a.compactMap { $0.hasPrefix("agents=") ? Int($0.dropFirst(7)) : nil }.first ?? 0, rec = a.contains("record=1")
        let lb = a.first { $0.hasPrefix("label=") }.map { String($0.dropFirst(6)) } ?? T("클로드", "Claude")
        let tl = a.first { $0.hasPrefix("tool=") }.map { String($0.dropFirst(5)) }
        let st = tl.map(toolStyle), label = st?.label ?? lb
        for _ in 0..<200 { print(praiseLine(sessions: x.working, agents: ag, record: rec, label: label, custom: st?.praise ?? [])) }
        return
      }
      let kinds: [String: Chat] = ["idle": .idle, "carried": .carried, "startle": .startle, "petted": .petted, "welcome": .welcome, "sleepy": .sleepy]
      guard let k = kinds[a[2]] else { return }
      for _ in 0..<200 { print(line(k, x)) }
      return
    }
    if a.count >= 2 && a[1] == "--report" {
      // another agent reports its own session state: --report <tool> <id> <busy|idle|ask|end> [--name NAME] [--label DISPLAY_NAME] [--pid N]
      func opt(_ k: String) -> String { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } ?? "" }
      guard a.count >= 5, ["busy", "idle", "ask", "end"].contains(a[4]) else { print(T("쓰는 법: --report <도구> <id> <busy|idle|ask|end> [--name 이름] [--label 보일 이름] [--pid N]", "Usage: --report <tool> <id> <busy|idle|ask|end> [--name NAME] [--label DISPLAY_NAME] [--pid N]")); exit(2) }
      do { try ReportSource.write(tool: a[2], id: a[3], status: a[4], name: opt("--name"), label: opt("--label"), pid: Int32(opt("--pid")) ?? 0) }
      catch { print(T("못 썼어요: \(error.localizedDescription)", "Could not write: \(error.localizedDescription)")); exit(1) }
      return
    }
    if a.count >= 2 && a[1] == "--run" {
      // wrap any CLI as a session: --run [--tool NAME] [--name NAME] [--label DISPLAY_NAME] -- <command …>
      //   working while it runs; when it ends it becomes done and is tied to that shell's pid (dropped when the shell closes; clicking goes to that tab).
      //   The command's input, output and exit code pass through unchanged. If nonzero, an 'error' gesture is sent too (not sent with DOTBUDDY_QUIET — for tests)
      guard let sep = a.firstIndex(of: "--"), sep + 1 < a.count else { print(T("쓰는 법: --run [--tool 이름] [--name 이름] [--label 보일 이름] -- <명령 …>", "Usage: --run [--tool NAME] [--name NAME] [--label DISPLAY_NAME] -- <command ...>")); exit(2) }
      let head = Array(a[..<sep]), cmd = Array(a[(sep + 1)...])
      func opt(_ k: String) -> String { head.firstIndex(of: k).flatMap { $0 + 1 < head.count ? head[$0 + 1] : nil } ?? "" }
      let base = (cmd[0] as NSString).lastPathComponent, tool = opt("--tool").isEmpty ? base : opt("--tool")
      let sid = "\(base)-\(getppid())", name = opt("--name").isEmpty ? "\(base) · \((FileManager.default.currentDirectoryPath as NSString).lastPathComponent)" : opt("--name")
      try? ReportSource.write(tool: tool, id: sid, status: "busy", name: name, label: opt("--label"), pid: getpid())
      signal(SIGINT, { _ in }); signal(SIGQUIT, { _ in })                          // ^C goes to the command (exec restores the default behavior) and the wrapper leaves its end state
      var child: pid_t = 0
      let argv = cmd.map { strdup($0) } + [nil]
      defer { argv.forEach { free($0) } }
      let rc = posix_spawnp(&child, cmd[0], nil, nil, argv, environ)
      var code: Int32 = 127
      if rc == 0 {
        var st: Int32 = 0
        while waitpid(child, &st, 0) == -1 && errno == EINTR {}
        code = (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)            // if killed by a signal, 128 + signal, like a shell
      } else { FileHandle.standardError.write("\(cmd[0]): \(String(cString: strerror(rc)))\n".data(using: .utf8)!) }
      try? ReportSource.write(tool: tool, id: sid, status: "idle", name: name, label: opt("--label"), pid: getppid())
      if code != 0, ProcessInfo.processInfo.environment["DOTBUDDY_QUIET"] == nil { DistributedNotificationCenter.default().postNotificationName(SIGNAL_NAME, object: String(decoding: try! JSONSerialization.data(withJSONObject: ["kind": "event", "text": "error", "from": tool]), as: UTF8.self), userInfo: nil, deliverImmediately: true) }
      exit(code)
    }
    if a.count >= 3 && a[1] == "--signal" {
      // from another program to the pet: --signal <say|done|ask|work|cheer|poke|event> [text] [--from NAME]
      //   the text of event is a gesture name (EVENT_NAMES): read·edit·test·commit·shell·web·skill·error·bg-start·bg-done·agent-start[:name]·agent-done
      var text = a.count >= 4 ? a[3] : "", from = ""
      if let i = a.firstIndex(of: "--from"), i + 1 < a.count { from = a[i + 1]; if a.count >= 4 && a[3] == "--from" { text = "" } }
      guard ["say", "done", "ask", "work", "cheer", "poke", "event", "goto", "drop", "fling"].contains(a[2]) else { print(T("알 수 없는 신호: \(a[2]) (say·done·ask·work·cheer·poke·event)", "Unknown signal: \(a[2]) (say·done·ask·work·cheer·poke·event)")); exit(2) }
      if a[2] == "event", chatEvent(text) == nil { print(T("알 수 없는 몸짓: \(text) (\(EVENT_NAMES.joined(separator: "·")))", "Unknown gesture: \(text) (\(EVENT_NAMES.joined(separator: "·")))")); exit(2) }
      let j = ["kind": a[2], "text": text, "from": from]
      let s = String(decoding: try! JSONSerialization.data(withJSONObject: j), as: UTF8.self)
      DistributedNotificationCenter.default().postNotificationName(SIGNAL_NAME, object: s, userInfo: nil, deliverImmediately: true)
      return
    }
    if a.count >= 3 && a[1] == "--where" {
      // where clicking that pid's session would go (does not move): --where <pid> [tool]
      let pid = Int32(a[2]) ?? 0, p = openPlan(pid: pid, id: "", tool: a.count >= 4 ? a[3] : "claude", name: "")
      let j: [String: Any] = ["via": p.via, "app": p.app?.bundleIdentifier ?? "", "tty": p.tty ?? "", "open": p.custom ?? []]
      print(String(decoding: try! JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]), as: UTF8.self))
      return
    }
    if a.count >= 3 && a[1] == "--open" {
      // actually go to that session (same as clicking the notification): --open <pid> [tool] [id]
      openSession(pid: Int32(a[2]) ?? 0, id: a.count >= 5 ? a[4] : "", tool: a.count >= 4 ? a[3] : "claude", name: "")
      return
    }
    if a.count >= 2 && a[1] == "--state" {
      let l = readAll(makeSources())
      let j: [String: Any] = ["mood": "\(l.first?.mood ?? .sleep)", "sessions": l.map { ["name": $0.name, "mood": "\($0.mood)", "pid": Int($0.pid), "tool": $0.tool, "label": $0.label] }]
      print(String(decoding: try! JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]), as: UTF8.self))
      return
    }
    if a.count >= 2 && a[1] == "--floors" {                                     // the floors currently visible (kind, height, span) — for checking
      let sc = scanScene(petH: 45, halfW: 24, dock: dockEstimate(screensNow()))
      for f in sc.floors { print(f.kind, Int(f.y), Int(f.x0), Int(f.x1), f.edgeL ? "L" : "-", f.edgeR ? "R" : "-") }
      if let d = dockEstimate(screensNow()) { print("dock-bar", Int(d.minX), Int(d.maxX), "top", Int(d.maxY), sc.floors.contains { $0.owner == "dock" } ? T("(설 수 있음)", "(can stand)") : T("(앞 창에 가려 지금은 못 섬)", "(hidden behind a window, cannot stand now)")) }
      return
    }
    if a.count >= 2 && a[1] == "--check-update" {                                  // latest release vs this build, as JSON (talks to GitHub)
      var j: [String: Any] = ["current": APP_VERSION, "build": BUILD_KIND]
      switch latestRelease() {
      case .success(let u): j["latest"] = u.version; j["newer"] = versionNewer(u.version, than: APP_VERSION); j["zip"] = u.zip.absoluteString
      case .failure(let e): j["error"] = describe(e)
      }
      print(String(decoding: (try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
      exit(j["error"] == nil ? 0 : 1)
    }
    if a.count >= 3 && a[1] == "--install-update" {                                // download, verify and swap in the latest release at <app path> (testing; the app does this from its menu)
      guard case .success(let u) = latestRelease() else { print("no release"); exit(1) }
      switch installUpdate(u, appPath: a[2]) {
      case .success(let p): print("installed \(u.version) at \(p)"); exit(0)
      case .failure(let e): print(describe(e)); exit(1)
      }
    }
    if a.count >= 4 && a[1] == "--verify-update" {                                 // --verify-update <zip> <sig file> [public key]: exit 0 if the signature is valid
      guard let d = FileManager.default.contents(atPath: a[2]), let s = FileManager.default.contents(atPath: a[3]) else { exit(2) }
      exit(verifyUpdate(d, sig: String(decoding: s, as: UTF8.self), key: a.count >= 5 ? a[4] : UPDATE_PUBLIC_KEY) ? 0 : 1)
    }
    if a.count >= 3 && a[1] == "--merge-notices" {                                 // test hook: --merge-notices "a,b?,c" (? = question) → what the next bubble says, then what stays queued
      let ns = a[2].split(separator: ",").map { s in Notice(pid: 0, id: String(s), title: String(s.replacingOccurrences(of: "?", with: "")), ask: s.hasSuffix("?")) }
      guard let f = ns.first else { exit(2) }
      let (n, rest) = mergeNotices(f, Array(ns.dropFirst()))
      print(n.title); print(rest.map(\.title).joined(separator: ",")); exit(0)
    }
    if a.count == 5 && a[1] == "--party-season", let y = Int(a[2]), let m = Int(a[3]), let d = Int(a[4]) { exit(partySeason(year: y, month: m, day: d) ? 0 : 1) }   // test hook: --party-season <year> <month> <day>
    if a.count == 4 && a[1] == "--snow-time", let m = Int(a[2]), let mi = Int(a[3]) { exit(snowTime(month: m, minute: mi) ? 0 : 1) }   // test hook: --snow-time <month> <minute>
    if a.count == 4 && a[1] == "--version-newer" { exit(versionNewer(a[2], than: a[3]) ? 0 : 1) }
    if a.count >= 3 && a[1] == "--demo-gif" {                                      // README demo animation: --demo-gif <out.gif> [hero|characters|chara:<id>]
      exit(demoGIF(a[2], scene: a.count >= 4 ? a[3] : "hero") ? 0 : 1)
    }
    if a.count >= 3 && a[1] == "--notice-preview" {
      // the pet (✓ bubble) + bubbles at each font size step, placed side by side at 1x then enlarged 3x — to check the dot size is the same. Third argument = font id
      registerFont()
      if a.count >= 4, let fi = FONT_FAMILIES.firstIndex(where: { $0.id == a[3] }) { FONT_FAMILY = fi }
      var imgs: [CGImage] = []
      for k in 0..<TEXT_SIZES.count {
        TEXT_SIZE = k
        let lines: [(String, CGColor)] = wrapTitle(T("api 서버 세션 네 개를 합친 통합 세션이에요", "A merged session combining four api-server sessions")).map { ($0, cg("#3a2a24")) } + [(T("끝났어요!", "Done!"), cg("#3f8a4a"))]
        if let img = noticeImage(lines, fill: cg("#fffaf0"), edge: cg("#5a4334")) { imgs.append(img) }
        if let b = noticeImage([("3", cg("#3f8a4a"))], fill: cg("#e9f6df"), edge: cg("#5a4334"), check: true) { imgs.append(b) }
        if let b = noticeImage([("?", cg("#9a7414"))], fill: cg("#fbf0d2"), edge: cg("#5a4334")) { imgs.append(b) }
      }
      var pp = Pose(); pp.eyes = .happy; pp.bubble = .check; pp.count = 2
      guard let pet = draw(CHARAS[1], pp).image() else { return }
      let S = 3, W = (CW + 8 + imgs.map(\.width).reduce(0) { $0 + $1 + 8 }), H = max(CH, imgs.map(\.height).max() ?? 0) + 4
      guard let ctx = CGContext(data: nil, width: W * S, height: H * S, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
      ctx.setFillColor(CGColor(red: 0.62, green: 0.74, blue: 0.55, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W * S, height: H * S))
      ctx.interpolationQuality = .none
      ctx.draw(pet, in: CGRect(x: 0, y: 0, width: CW * S, height: CH * S))
      var x = CW + 8
      for img in imgs { ctx.draw(img, in: CGRect(x: x * S, y: 2 * S, width: img.width * S, height: img.height * S)); x += img.width + 8 }
      if let out = ctx.makeImage() { writePNG(out, a[2]) }
      return
    }
    if a.count >= 3 && a[1] == "--make-icon" {
      // app icon: a slime on a grass-green rounded square
      try? FileManager.default.createDirectory(atPath: a[2], withIntermediateDirectories: true)
      for base in [16, 32, 128, 256, 512] {
        for k in [1, 2] {
          let S = base * k
          guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
          let r = CGRect(x: 0, y: 0, width: S, height: S).insetBy(dx: CGFloat(S) * 0.08, dy: CGFloat(S) * 0.08)
          ctx.addPath(CGPath(roundedRect: r, cornerWidth: CGFloat(S) * 0.2, cornerHeight: CGFloat(S) * 0.2, transform: nil))
          ctx.setFillColor(CGColor(red: 0.69, green: 0.81, blue: 0.61, alpha: 1)); ctx.fillPath()
          ctx.interpolationQuality = .none
          var p = Pose(); p.eyes = .happy
          if let img = draw(CHARAS[0], p).image() {
            let cell = CGFloat(S) * 0.84 / 22
            ctx.draw(img, in: CGRect(x: CGFloat(S) / 2 - cell * 16, y: CGFloat(S) * 0.2 - cell * 1.5, width: cell * CGFloat(CW), height: cell * CGFloat(CH)))
          }
          if let img = ctx.makeImage() { writePNG(img, "\(a[2])/icon_\(base)x\(base)\(k == 2 ? "@2x" : "").png") }
        }
      }
      return
    }
    if a.count >= 4 && a[1] == "--export-pack" {
      // pack sample: --export-pack <folder> <character id (mandu·acorn·…)>
      guard let ch = (CHARAS + loadCustomCharas()).first(where: { $0.id == a[3] }) else { print(T("캐릭터 없음: \(a[3]) — ", "No such character: \(a[3]) — ") + (CHARAS + loadCustomCharas()).map(\.id).joined(separator: ", ")); exit(1) }
      print(exportPack(ch, to: URL(fileURLWithPath: a[2])).joined(separator: " ")); return
    }
    if a.count >= 3 && a[1] == "--fx-sheet" {
      // character effect preview: --fx-sheet <png> — packs (rows) × [error 0.2·0.5 · done 0.3·0.6] (frames), 6x
      let charas = loadCustomCharas(), ks: [(Int, Double)] = [(1, 0.2), (1, 0.5), (2, 0.3), (2, 0.6), (-1, 0), (-3, 0), (-4, 0), (-5, 0.3), (-6, 0), (-7, 0)], S = 6   // -1 eyes closed · -3 Santa hat · -4 Santa hat facing left · -5 snow · -6 party hat · -7 party hat facing left
      guard !charas.isEmpty, let ctx = CGContext(data: nil, width: CW * S * ks.count, height: CH * S * charas.count, bitsPerComponent: 8, bytesPerRow: 0, space: RGB_SPACE, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
      ctx.setFillColor(CGColor(red: 0.62, green: 0.74, blue: 0.55, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: CW * S * ks.count, height: CH * S * charas.count)); ctx.interpolationQuality = .none
      for (r, ch) in charas.enumerated() { for (c, (f, k)) in ks.enumerated() {
        var p = Pose(); if f > 0 { p.fx = f; p.fxK = k } else if f == -1 { p.eyes = .closed } else if f == -5 { p.santa = true; p.snow = k } else if f <= -6 { p.party = true; p.look = f == -7 ? -1 : 0 } else if f <= -3 { p.santa = true; p.look = f == -4 ? -1 : 0 }
        if let img = draw(ch, p).image() { ctx.draw(img, in: CGRect(x: c * CW * S, y: (charas.count - 1 - r) * CH * S, width: CW * S, height: CH * S)) }
      } }
      if let img = ctx.makeImage() { writePNG(img, a[2]) }
      print(charas.map(\.id).joined(separator: " ")); return
    }
    if a.count >= 4 && a[1] == "--motion-sheet" {
      // pack preview: --motion-sheet <png> <character id> — one motion per row, frames at 6x (exactly as the pet draws them)
      guard let ch = loadCustomCharas().first(where: { $0.id == a[3] }), let sp = ch.sprite else { print(T("꾸러미 없음: \(a[3])", "No such pack: \(a[3])")); exit(1) }
      let rows = MOTIONS.map(\.0).filter { sp.motions[$0] != nil }, cols = rows.map { sp.motions[$0]!.frames.count }.max() ?? 1, S = 6
      guard !rows.isEmpty, let ctx = CGContext(data: nil, width: CW * S * cols, height: CH * S * rows.count, bitsPerComponent: 8, bytesPerRow: 0, space: RGB_SPACE, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
      ctx.setFillColor(CGColor(red: 0.62, green: 0.74, blue: 0.55, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: CW * S * cols, height: CH * S * rows.count))
      ctx.interpolationQuality = .none
      for (r, name) in rows.enumerated() { for k in 0..<sp.motions[name]!.frames.count {
        var p = Pose(); p.motion = name; p.frame = k
        if name == "work" { p.laptop = k % 2 }                                      // put on a laptop like the app does
        if let img = draw(ch, p).image() { ctx.draw(img, in: CGRect(x: k * CW * S, y: (rows.count - 1 - r) * CH * S, width: CW * S, height: CH * S)) }
      } }
      if let img = ctx.makeImage() { writePNG(img, a[2]) }
      print(rows.joined(separator: " ")); return
    }
    if a.count >= 2 && a[1] == "--motions" {                                        // motion name table (for docs)
      let fb = { (n: String) in (MOTION_FALLBACK[n] ?? []).joined(separator: " → ") }
      for (n, d) in MOTIONS { print("| `\(n)` | \(d.components(separatedBy: " → ")[0]) | \(fb(n).isEmpty ? (n == "idle" ? "—" : "idle") : fb(n) + " → idle") |") }
      return
    }
    if a.count >= 3 && a[1] == "--bubble-preview" {                                // bubble tail in three directions (down, left, right) at 4x
      registerFont(); FONT_FAMILY = 1; TEXT_SIZE = 1
      let imgs = [0, -1, 1].compactMap { noticeImage([(T("말풍선 꼬리 \($0)", "Bubble tail \($0)"), cg("#3a2a24"))], fill: cg("#ffffff"), edge: cg("#8a7a68"), side: $0) }
        + [-99, 12].compactMap { noticeImage([(T("밀린 꼬리 \($0)", "Shifted tail \($0)"), cg("#3a2a24"))], fill: cg("#ffffff"), edge: cg("#8a7a68"), tail: $0) }   // top bubble shifted away from the screen edge
      let W = imgs.map(\.width).reduce(0, +) + 10 * (imgs.count + 1), H = (imgs.map(\.height).max() ?? 10) + 20, S = 4
      guard let ctx = CGContext(data: nil, width: W * S, height: H * S, bitsPerComponent: 8, bytesPerRow: 0, space: RGB_SPACE, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
      ctx.setFillColor(CGColor(red: 0.62, green: 0.74, blue: 0.55, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W * S, height: H * S)); ctx.interpolationQuality = .none
      var x = 10; for im in imgs { ctx.draw(im, in: CGRect(x: x * S, y: 10 * S, width: im.width * S, height: im.height * S)); x += im.width + 10 }
      if let img = ctx.makeImage() { writePNG(img, a[2]) }; return
    }
    if a.count >= 3 && a[1] == "--typing-preview" {                                // typing indicator "..." (1·2·3 dots) → typing one character at a time, top to bottom at 3x (checks that the bubble size stays the same)
      registerFont(); FONT_FAMILY = 1; TEXT_SIZE = 1
      let msg = T("타이핑 시험이에요, 잘 보여요?", "This is a typing test, can you see it?")
      let imgs = [1, 2, 3].compactMap { noticeImage([("...", cg("#3a2a24"))], fill: cg("#ffffff"), edge: cg("#8a7a68"), reveal: $0) }
        + [1, 4, 9, msg.count].compactMap { noticeImage([(msg, cg("#3a2a24"))], fill: cg("#ffffff"), edge: cg("#8a7a68"), reveal: $0) }
      let W = (imgs.map(\.width).max() ?? 10) + 20, H = imgs.map(\.height).reduce(0, +) + 10 * (imgs.count + 1), S = 3
      guard let ctx = CGContext(data: nil, width: W * S, height: H * S, bitsPerComponent: 8, bytesPerRow: 0, space: RGB_SPACE, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
      ctx.setFillColor(CGColor(red: 0.62, green: 0.74, blue: 0.55, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W * S, height: H * S)); ctx.interpolationQuality = .none
      var y = H - 10; for im in imgs { y -= im.height; ctx.draw(im, in: CGRect(x: 10 * S, y: y * S, width: im.width * S, height: im.height * S)); y -= 10 }
      if let img = ctx.makeImage() { writePNG(img, a[2]) }; return
    }
    if a.count >= 4 && a[1] == "--export-codex-pet" {
      // our character → Codex pet pack (pet.json + spritesheet.png): --export-codex-pet <folder> <character id>
      ALL_CHARAS = mergeCharas(loadCustomCharas())
      guard exportCodexPet(findChara(a[3]), to: URL(fileURLWithPath: a[2])) else { print(T("못 만들었어요", "Could not create it")); exit(1) }
      print(a[2]); return
    }
    if a.count >= 2 && a[1] == "--community-list" {                               // the community character list, as JSON (talks to GitHub, or DOTBUDDY_COMMUNITY_BASE)
      switch communityIndex() {
      case .failure(let e): print(describe(e)); exit(1)
      case .success(let ps):
        let list = ps.map { p -> [String: Any] in ["id": p.id, "name": p.shownName, "description": p.shownDescription, "author": p.author, "license": p.license, "files": p.files.count, "state": "\(communityState(p))", "added": p.added, "new": p.isNew, "likes": p.likes, "discussion": p.discussion] }
        if let d = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]) { print(String(decoding: d, as: UTF8.self)) }
        return
      }
    }
    if a.count >= 3 && a[1] == "--community-preview" {                            // the More Characters window drawn offscreen at 2x: --community-preview <out.png>
      _ = NSApplication.shared
      let w = CommunityWindow { _, _ in }; w.window.appearance = NSAppearance(named: .aqua); w.show()
      let end = Date().addingTimeInterval(4); while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }   // list and previews arrive asynchronously
      guard let v = w.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
      v.cacheDisplay(in: v.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[2])); exit(0)
    }
    if a.count >= 3 && a[1] == "--community-install" {                            // --community-install <id>: download one community pack into the characters folder
      guard case .success(let ps) = communityIndex(), let p = ps.first(where: { $0.id == a[2] }) else { print(T("목록에 \(a[2]) 가 없어요", "\(a[2]) isn't in the list")); exit(1) }
      switch installCommunityPack(p) {
      case .success(let id): print(id); return
      case .failure(let e): print(describe(e)); exit(1)
      }
    }
    if a.count >= 3 && a[1] == "--community-remove" {                             // --community-remove <id>: what Remove in More Characters does (to the Trash)
      switch removeCommunityPack(a[2]) {
      case .success(let id): print(id); return
      case .failure(let e): print(describe(e)); exit(1)
      }
    }
    if a.count >= 3 && a[1] == "--install-chara" {                                // --install-chara <zip|folder|png>: what dropping it on the pet does
      switch installDroppedChara(URL(fileURLWithPath: a[2])) {
      case .success(let (id, _)): print(id); return
      case .failure(let e): print(describe(e)); exit(1)
      }
    }
    if a.count >= 2 && a[1] == "--charas" {
      // loaded characters and motions (frame counts) — for checking packs
      let list = loadCustomCharas().map { c -> [String: Any] in ["id": c.id, "name": c.name, "size": [c.sprite?.w ?? 0, c.sprite?.h ?? 0], "motions": (c.sprite?.motions ?? [:]).mapValues(\.frames.count)] }
      if let d = try? JSONSerialization.data(withJSONObject: ["dir": CHARAS_DIR.path, "charas": list, "motionNames": MOTIONS.map(\.0)], options: [.sortedKeys]) { print(String(decoding: d, as: UTF8.self)) }
      return
    }
    if a.count >= 3 && a[1] == "--preview" {
      // character (rows) × pose (frames) sample sheet. Each frame is 32×40 dots at 6x
      var poses: [Pose] = []
      var p = Pose(); poses.append(p)
      p = Pose(); p.feet = 1; p.lift = 1; p.look = 1; poses.append(p)
      p = Pose(); p.laptop = 1; poses.append(p)
      p = Pose(); p.eyes = .happy; p.bubble = .check; p.count = 3; p.lift = 3; poses.append(p)
      p = Pose(); p.eyes = .wide; p.bubble = .ask; poses.append(p)
      p = Pose(); p.eyes = .closed; p.squash = 1; p.z = 0.3; poses.append(p)
      p = Pose(); p.eyes = .wide; p.feet = 3; p.squash = -1; poses.append(p)
      p = Pose(); p.eyes = .happy; p.hearts = 0.35; p.blush = true; poses.append(p)          // click reactions
      p = Pose(); p.eyes = .dizzy; p.shake = 1; p.sparkle = 0.4; poses.append(p)
      p = Pose(); p.eyes = .happy; p.wave = 1; poses.append(p)
      p = Pose(); p.eyes = .closed; p.blush = true; p.look = -1; poses.append(p)
      p = Pose(); p.eyes = .closed; p.squash = 3; poses.append(p)
      p = Pose(); p.eyes = .wide; p.bubble = .bang; p.lift = 2; poses.append(p)
      p = Pose(); p.eyes = .happy; p.notes = 0.3; poses.append(p)                               // humming
      p = Pose(); p.eyes = .happy; p.rot = 1; p.feet = 3; poses.append(p)                       // rolling
      p = Pose(); p.look = 1; p.down = true; poses.append(p)                                    // looking down
      p = Pose(); p.feet = 3; p.lift = -1; p.notes = 0.6; poses.append(p)                       // sitting on an edge
      p = Pose(); p.squash = 1; p.dust = 0.4; poses.append(p)                                   // landing dust
      p = Pose(); p.laptop = 0; p.sweat = 0.3; poses.append(p)                                  // sweat when busy
      p = Pose(); p.eyes = .wide; p.hands = true; p.feet = 3; p.lift = 6; poses.append(p)       // grabbing the cursor (shadow)
      p = Pose(); p.eyes = .happy; p.wave = 0; p.bubble = .ask; poses.append(p)                 // waving while waiting on a question
      p = Pose(); p.eyes = .closed; p.feet = 2; p.squash = -1; p.shake = 1; poses.append(p)     // struggling while lifted
      p = Pose(); p.eyes = .happy; p.hands = true; p.lift = 5; p.feet = 3; p.confetti = 0.45; poses.append(p)   // cheering when done
      p = Pose(); p.eyes = .closed; p.squash = 1; p.snot = 0.9; poses.append(p)                 // snot bubble
      p = Pose(); p.eyes = .closed; p.blush = true; p.cover = true; poses.append(p)             // shy (covering eyes)
      p = Pose(); p.eyes = .closed; p.blush = true; p.squash = 1; p.look = -1; p.angry = true; poses.append(p)  // sulking
      p = Pose(); p.up = true; p.tail = 1; p.wave = 0; p.talk = true; poses.append(p)           // looking up, waving and talking
      p = Pose(); p.squash = -1; p.eyes = .closed; p.hands = true; p.sink = 8; poses.append(p)  // sinking into the floor
      p = Pose(); p.eyes = .wide; p.icon = 1; poses.append(p)                                   // light bulb
      p = Pose(); p.shake = 1; p.icon = 2; poses.append(p)                                      // question mark
      p = Pose(); p.party = true; poses.append(p)                                               // launch party hat
      p = Pose(); p.party = true; p.look = -1; p.laptop = 1; poses.append(p)                    // party hat, facing left, working
      let charas = CHARAS + loadCustomCharas()
      let S = 6, W = CW * S * poses.count, H = CH * S * charas.count
      guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
      ctx.setFillColor(CGColor(red: 0.62, green: 0.74, blue: 0.55, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
      ctx.interpolationQuality = .none
      for (r, c) in charas.enumerated() {
        for (k, ps) in poses.enumerated() {
          if let img = draw(c, ps).image() { ctx.draw(img, in: CGRect(x: k * CW * S, y: H - (r + 1) * CH * S, width: CW * S, height: CH * S)) }
        }
      }
      if let img = ctx.makeImage() { writePNG(img, a[2]) }
      return
    }
    let app = PetApp.shared
    let d = AppDelegate()
    app.delegate = d
    app.setActivationPolicy(.accessory)     // no Dock, ⌘Tab or menu bar — just the pet
    app.run()
  }
}
