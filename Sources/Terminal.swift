// When a notification is clicked, go to that session's terminal (tab)
import AppKit
import CoreText
import ServiceManagement

// ---------- Going to the session's terminal ----------
// Clicking a notification goes to the terminal the session is running in. Order:
//   (1) the "open" command in tools.json (per tool, or "*" for all) — the user can attach any terminal
//   (2) find the app that launched the session process (walking up the parents; if that fails, the 'responsible app' macOS knows) and pick its tab
//       — cmux and WezTerm (CLI), Terminal, iTerm2 and Ghostty (AppleScript, found by tty). An app with no way to pick a tab is only brought to the front
//       — inside tmux, the pane is picked with tmux first, then the terminal tab that shows that tmux session
// Reads the tty and parents with libproc, without any external program (does not spawn ps).
/// Run one external command — killed after timeout seconds if it hangs (so a stuck cmux or osascript cannot stop the notification from ever showing)
func run(_ exe: String, _ args: [String], timeout: Double = 4) -> Data? {
  let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
  let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
  guard (try? p.run()) != nil else { return nil }
  let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
  DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: stop)
  let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); stop.cancel()
  return p.terminationReason == .exit && p.terminationStatus == 0 ? d : nil
}
func procInfo(_ pid: Int32) -> proc_bsdinfo? {
  guard pid > 0 else { return nil }
  var i = proc_bsdinfo(); let n = MemoryLayout<proc_bsdinfo>.size
  return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &i, Int32(n)) == Int32(n) ? i : nil
}
/// Is that pid alive — if the time t (when the session started or reported) is known, a process that started after it is a stranger that inherited the pid, so false
func alive(_ pid: Int32, before t: Double? = nil) -> Bool {
  guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }   // kill(0) and kill(-1) 'succeed', so reject anything <= 0 first
  guard let t, t > 0, let i = procInfo(pid) else { return true }
  return Double(i.pbi_start_tvsec) <= t + 5
}
/// The outermost ancestor of pid on the same terminal: the tab's shell (or its login), which lives as long as the tab.
/// A `--run` from a script, make or `sh -c` has a short-lived parent; tying the finished report to that parent dropped it at once.
/// 0 when pid has no terminal (cron, an agent's tool call)
func tabShell(_ pid: Int32) -> Int32 {
  guard let me = procInfo(pid), me.e_tdev != UInt32.max else { return 0 }
  var best: Int32 = 0, p = pid
  for _ in 0..<64 where p > 1 {
    guard let i = procInfo(p), i.e_tdev == me.e_tdev else { break }
    best = p; p = Int32(i.pbi_ppid)
  }
  return best
}
/// Controlling terminal "/dev/ttys003" — nil if none
func ttyPath(_ pid: Int32) -> String? {
  guard let i = procInfo(pid), i.e_tdev != UInt32.max, let c = devname(dev_t(bitPattern: i.e_tdev), S_IFCHR) else { return nil }
  let n = String(cString: c); return n.isEmpty || n.hasPrefix("?") ? nil : "/dev/" + n
}
/// pid macOS regards as the process's 'responsible app' (the app shown in the permission dialog). A private function, so used only when it exists
private let responsibleFor: (@convention(c) (Int32) -> Int32)? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: (@convention(c) (Int32) -> Int32).self) }
/// The app that launched the session process (the one shown in the Dock). If an intermediate server such as iTerm2 or tmux has been reparented to launchd, use the responsible app
func ownerApp(_ pid: Int32) -> NSRunningApplication? {
  func app(_ p: Int32) -> NSRunningApplication? { NSRunningApplication(processIdentifier: p).flatMap { $0.activationPolicy == .regular && $0.processIdentifier != getpid() ? $0 : nil } }
  var p = pid
  for _ in 0..<32 where p > 1 {
    if let a = app(p) { return a }
    guard let i = procInfo(p) else { break }
    p = Int32(i.pbi_ppid)
  }
  if let f = responsibleFor, case let r = f(pid), r > 1 { return app(r) }
  return nil
}
/// How to pick a tab inside an app — a new terminal needs just one line here (bundle id → function). true means it picked one
let TAB_PICKERS: [String: (NSRunningApplication, String) -> Bool] = [
  "com.cmuxterm.app": { app, tty in cmuxFocus(cmuxCLI(app), tty: tty) },
  "com.apple.Terminal": { _, tty in osa(["tell application id \"com.apple.Terminal\"", "repeat with w in windows", "repeat with t in tabs of w",
                                          "if tty of t is item 1 of argv then", "set selected of t to true", "set index of w to 1", "return \"ok\"", "end if", "end repeat", "end repeat", "end tell"], tty) },
  "com.googlecode.iterm2": { _, tty in osa(["tell application id \"com.googlecode.iterm2\"", "repeat with w in windows", "repeat with t in tabs of w", "repeat with s in sessions of t",
                                             "if tty of s is item 1 of argv then", "select w", "select t", "select s", "return \"ok\"", "end if", "end repeat", "end repeat", "end repeat", "end tell"], tty) },
  "com.github.wez.wezterm": { app, tty in weztermFocus(app, tty: tty) },
  "com.mitchellh.ghostty": { _, tty in osa(["tell application id \"com.mitchellh.ghostty\"", "repeat with t in terminals",                 // Ghostty 1.4+ (AppleScript); focus selects the tab too
                                             "if tty of t is item 1 of argv then", "focus t", "return \"ok\"", "end if", "end repeat", "end tell"], tty) },
]
/// Same terminal device, whether or not the path starts with /dev/ (an empty one matches nothing)
func sameTTY(_ a: String, _ b: String) -> Bool { !a.isEmpty && !b.isEmpty && (a as NSString).lastPathComponent == (b as NSString).lastPathComponent }
/// WezTerm: its CLI lists every pane with its tty, and activate-pane also switches to that pane's tab and window
func weztermFocus(_ app: NSRunningApplication, tty: String) -> Bool {
  guard let cli = [app.bundleURL?.appendingPathComponent("Contents/MacOS/wezterm").path, "/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm"].compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
        let d = run(cli, ["cli", "list", "--format", "json"]), let panes = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]],
        let id = panes.first(where: { sameTTY($0["tty_name"] as? String ?? "", tty) })?["pane_id"] as? Int else { return false }
  return run(cli, ["cli", "activate-pane", "--pane-id", "\(id)"]) != nil
}
/// A session inside tmux runs on a tmux pane's tty, not on a terminal tab's. Find that pane and the terminal showing it:
/// the client that used that tmux session last, or if none is attached, the client used last (which gets switched over to it)
struct TmuxPane { var exe = "", session = "", window = "", pane = "", client = "", clientPid: Int32 = 0, attached = false }
func tmuxPane(tty: String) -> TmuxPane? {
  guard let exe = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
        let d = run(exe, ["list-panes", "-a", "-F", "#{pane_tty}\t#{session_id}\t#{window_id}\t#{pane_id}"]) else { return nil }   // no tmux server: fails, nil
  func rows(_ d: Data) -> [[String]] { String(decoding: d, as: UTF8.self).split(separator: "\n").map { $0.components(separatedBy: "\t") } }
  guard let r = rows(d).first(where: { $0.count == 4 && sameTTY($0[0], tty) }) else { return nil }
  var t = TmuxPane(exe: exe, session: r[1], window: r[2], pane: r[3])
  let cs = run(exe, ["list-clients", "-F", "#{client_activity}\t#{client_tty}\t#{client_pid}\t#{session_id}"]).map(rows)?.filter { $0.count == 4 } ?? []
  let mine = cs.filter { $0[3] == t.session }
  if let c = (mine.isEmpty ? cs : mine).max(by: { (Int($0[0]) ?? 0) < (Int($1[0]) ?? 0) }) { t.client = c[1]; t.clientPid = Int32(c[2]) ?? 0; t.attached = !mine.isEmpty }
  return t
}
func tmuxFocus(_ t: TmuxPane) {
  if !t.attached, !t.client.isEmpty { _ = run(t.exe, ["switch-client", "-c", t.client, "-t", t.session]) }
  _ = run(t.exe, ["select-window", "-t", t.window]); _ = run(t.exe, ["select-pane", "-t", t.pane])
}
/// Run AppleScript through osascript (system default) — the tty is passed as an argument so it never gets mixed into the script text. The first run shows an 'allow control' dialog
func osa(_ lines: [String], _ arg: String) -> Bool {
  let src = (["on run argv"] + lines + ["return \"\"", "end run"]).flatMap { ["-e", $0] }
  return run("/usr/bin/osascript", src + [arg], timeout: 60).map { String(decoding: $0, as: UTF8.self).hasPrefix("ok") } ?? false
}
func cmuxCLI(_ app: NSRunningApplication?) -> String? {
  ([app?.bundleURL?.appendingPathComponent("Contents/Resources/bin/cmux").path].compactMap { $0 } + ["/Applications/cmux.app/Contents/Resources/bin/cmux", "/opt/homebrew/bin/cmux", "/usr/local/bin/cmux"])
    .first { FileManager.default.isExecutableFile(atPath: $0) }
}
/// Scan cmux windows, workspaces and panes — per pane (workspace, pane, tty, title)
func cmuxSurfaces(_ cmux: String) -> [(ws: [String: Any], s: [String: Any])] {
  guard let d = run(cmux, ["tree", "--all", "--json"]), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
  var out: [(ws: [String: Any], s: [String: Any])] = []
  for w in j["windows"] as? [[String: Any]] ?? [] {
    for ws in w["workspaces"] as? [[String: Any]] ?? [] {
      for p in ws["panes"] as? [[String: Any]] ?? [] { for s in p["surfaces"] as? [[String: Any]] ?? [] { out.append((ws, s)) } }
    }
  }
  return out
}
func cmuxFocus(_ cmux: String?, tty: String) -> Bool {
  guard let cmux else { return false }
  for (ws, s) in cmuxSurfaces(cmux) where (s["tty"] as? String).map({ !$0.isEmpty && !tty.isEmpty && (tty.hasSuffix($0) || $0.hasSuffix(tty)) }) == true {   // an empty tty (a browser pane) would match anything
    guard let wref = ws["ref"] as? String, let sref = s["ref"] as? String else { continue }
    _ = run(cmux, ["select-workspace", "--workspace", wref])
    _ = run(cmux, ["focus-panel", "--panel", sref, "--workspace", wref])
    return true
  }
  return false
}
/// pid → tab title (only for cmux — the automatic name 'foldername-two characters of session ID' is hard to recognize). Otherwise the session name as is
func tabTitles(_ pids: [Int32]) -> [Int32: String] {
  guard !pids.isEmpty, let cmux = cmuxCLI(nil) else { return [:] }
  var byTTY: [String: String] = [:]
  for (ws, s) in cmuxSurfaces(cmux) {
    if let tty = s["tty"] as? String, let title = (s["title"] as? String) ?? (ws["title"] as? String), !title.isEmpty { byTTY[(tty as NSString).lastPathComponent] = title }
  }
  var out: [Int32: String] = [:]
  for pid in pids { if let t = ttyPath(pid), let title = byTTY[(t as NSString).lastPathComponent] { out[pid] = title } }
  return out
}
/// The route to this session — only says what it would do, without actually moving (for --where and tests)
struct OpenPlan { var custom: [String]? = nil, app: NSRunningApplication? = nil, tty: String? = nil, tmux: TmuxPane? = nil
  var via: String { custom != nil ? "open" : app.map { tty != nil && TAB_PICKERS[$0.bundleIdentifier ?? ""] != nil ? "tab" : "app" } ?? "none" }
}
/// tty: the one stored when the notice was made, used when the agent has quit since (its tab, and shell, is usually still there)
func openPlan(pid: Int32, id: String, tool: String, name: String, tty: String? = nil) -> OpenPlan {
  var p = OpenPlan(); p.tty = ttyPath(pid) ?? tty; p.app = pid > 0 ? ownerApp(pid) : nil
  if let cmd = toolStyle(tool).open ?? toolStyle("*").open, !cmd.isEmpty {
    let vals = ["pid": pid > 0 ? "\(pid)" : "", "tty": p.tty ?? "", "id": id, "tool": tool, "name": name, "app": p.app?.bundleIdentifier ?? ""]
    p.custom = cmd.map { fillSlots($0, vals) }
  }
  if p.custom == nil, let t = p.tty, let x = tmuxPane(tty: t) {                  // inside tmux: the tab to pick is the terminal's that shows it, and so is the app
    p.tmux = x
    if !x.client.isEmpty { p.tty = x.client }
    if x.clientPid > 0, let a = ownerApp(x.clientPid) { p.app = a }
  }
  return p
}
/// Scan {name} placeholders once and substitute — a {…} inside an inserted value is not substituted again (the session name is text from outside)
func fillSlots(_ a: String, _ vals: [String: String]) -> String {
  var out = "", rest = Substring(a)
  while let o = rest.firstIndex(of: "{") {
    out += rest[..<o]
    if let c = rest[o...].firstIndex(of: "}"), let v = vals[String(rest[rest.index(after: o)..<c])] { out += v; rest = rest[rest.index(after: c)...] }
    else { out.append("{"); rest = rest[rest.index(after: o)...] }
  }
  return out + rest
}
/// Go to the session of the clicked notification (called from outside the main thread — osascript and cmux can be slow)
func openSession(pid: Int32, id: String, tool: String, name: String, tty: String? = nil, app: String? = nil) {
  guard !id.hasPrefix("signal:") else { return }                              // a notification shown for an outside signal (--signal) can be sent by anyone, so it does not run commands
  var p = openPlan(pid: pid, id: id, tool: tool, name: name, tty: tty)
  if p.app == nil, let b = app { p.app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first }
  if let c = p.custom, run("/usr/bin/env", c, timeout: 15) != nil { return }                 // user command: if it fails, fall back to the default route
  if let t = p.tmux { tmuxFocus(t) }                                             // pick the pane inside tmux first, then the terminal tab showing it
  guard let app = p.app else { return }
  if let tty = p.tty, let pick = TAB_PICKERS[app.bundleIdentifier ?? ""] { _ = pick(app, tty) }
  if let u = app.bundleURL { let c = NSWorkspace.OpenConfiguration(); c.activates = true; NSWorkspace.shared.openApplication(at: u, configuration: c) }   // bring the already running app to the front
  else { app.activate() }
}
