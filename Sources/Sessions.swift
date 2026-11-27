// Reading sessions: Claude session files, the shared --report folder, per-agent styling, and file watching
import AppKit
import CoreText
import ServiceManagement

// ---------- Sessions ----------
enum Mood: Int, Comparable { case sleep = 0, free, work, wait, ask          // free: just playing, when agent extensions are off or there is nothing to do
  static func < (a: Mood, b: Mood) -> Bool { a.rawValue < b.rawValue }
  var label: String { T(["쉬는 중", "노는 중", "일하는 중", "다 했어요", "질문 있어요"], ["Resting", "Playing", "Working", "Done", "Has a question"])[rawValue] }
}
struct Sess { let pid: Int32, id: String, name: String, mood: Mood, since: Double, derived: Bool; var tool = "claude", label = T("클로드", "Claude"); var why = "" }   // why: what a waiting session waits for ("permission" = a tool needs your OK)   // tool: which source (agent) the session comes from; label: the name used when it speaks

// ---------- Session sources ----------
// Each agent has one place to read its sessions from. A new agent can either (1) add a source that follows this protocol to SOURCES, or
// (2) without changing any code, call `DotBuddy --report …` from that agent's hooks to leave a status file in the shared folder (ReportSource).
// (3) For a CLI with no hooks, wrap it with `DotBuddy --run -- <command>` (counts as working while it runs, done when it exits).
// Live gestures (reading, editing, testing…) are not the job of a source; signals (`DotBuddy --signal`) or following the Claude transcript (Tail) handle them.
protocol SessionSource: AnyObject {
  var tool: String { get }                       // short English id (claude, codex…) — Sess.tool
  func read(now: Double) -> [Sess]
  func jsonl(_ sid: String) -> URL?              // if there is a Claude-style transcript file (for live gestures); nil if not
  var watchDir: String? { get }                  // folder to re-read right away when it changes (its *.json files are watched too); nil means periodic reads only
}
extension SessionSource { func jsonl(_ sid: String) -> URL? { nil }; var watchDir: String? { nil } }
/// Shared status folder: one <tool>-<id>.json per session. {"tool","label","id","name","status": busy|idle|ask,"updatedAt": seconds,"pid"?}
/// With a pid, the session is dropped when that process dies. Without one, it is dropped 30 minutes after the last report (2 hours if it was working)
var REPORT_DIR: URL {
  if let e = ProcessInfo.processInfo.environment["DOTBUDDY_SESSIONS"], !e.isEmpty { return URL(fileURLWithPath: e) }
  return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DotBuddy/sessions")
}
final class ReportSource: SessionSource {
  let tool = "report"
  var watchDir: String? { REPORT_DIR.path }
  func read(now: Double) -> [Sess] {
    guard let files = try? FileManager.default.contentsOfDirectory(at: REPORT_DIR, includingPropertiesForKeys: nil) else { return [] }
    return files.filter { $0.pathExtension == "json" }.compactMap { f -> Sess? in
      guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let tool = j["tool"] as? String, let id = j["id"] as? String else { return nil }
      let raw = (j["updatedAt"] as? NSNumber)?.doubleValue ?? 0
      let status = j["status"] as? String ?? "idle", at = raw > now + 60 ? 0 : min(now, raw)   // more than 1 minute in the future (clock set back, or written in milliseconds) counts as long ago
      let pid = (j["pid"] as? NSNumber)?.int32Value ?? 0
      let gone = pid != 0 ? !alive(pid, before: at) : now - at > (status == "idle" ? 30 * 60 : 2 * 3600)
      if gone { try? FileManager.default.removeItem(at: f); return nil }         // delete the file of a finished session (so they do not pile up)
      let idle = now - at
      let mood: Mood = status == "ask" ? .ask : status == "idle" ? (idle < 5 * 60 ? .wait : idle < 20 * 60 ? .free : .sleep) : .work
      let label = (j["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tool
      return Sess(pid: pid, id: "\(tool):\(id)", name: (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id, mood: mood, since: at, derived: false, tool: tool, label: label)
    }
  }
  /// --report: write a status file (delete it for end)
  static func write(tool: String, id: String, status: String, name: String, label: String, pid: Int32) throws {
    let safe = { (x: String, dash: Bool) in String(x.map { $0.isLetter || $0.isNumber || (dash && $0 == "-") || $0 == "_" ? $0 : "_" }.prefix(80)) }
    let f = REPORT_DIR.appendingPathComponent("\(safe(tool, false))-\(safe(id, true)).json")   // tool names never contain '-', so the first '-' is always the separator (keeps a-b+c and a+b-c from colliding)
    if status == "end" { try? FileManager.default.removeItem(at: f); return }
    try FileManager.default.createDirectory(at: REPORT_DIR, withIntermediateDirectories: true)
    var j: [String: Any] = ["tool": tool, "id": id, "status": status, "updatedAt": Date().timeIntervalSince1970]
    if !name.isEmpty { j["name"] = name }; if !label.isEmpty { j["label"] = label }; if pid > 0 { j["pid"] = Int(pid) }
    try JSONSerialization.data(withJSONObject: j).write(to: f, options: .atomic)
  }
}
/// Per-agent (source tool) bubble styling — overridden from tools.json in the app support folder (change the path with DOTBUDDY_TOOLS). Edits apply on the next read
///   {"codex": {"label": "Codex", "fill": "#eef4ff", "askFill": "#fff0d8", "edge": "#3a4a6a", "titleColor": "#24304a",
///              "done": ["Codex is done!"], "ask": ["Codex has a question"], "praise": ["Codex x{n} on the job!"], "showLabel": true}}
///   Missing fields use the defaults. done and ask are the last line of the done and question notifications, praise is the praise when several run at once ({n} = count), showLabel puts "Codex · " before the notification title
struct ToolStyle {
  var label: String? = nil, fill: String? = nil, askFill: String? = nil, edge: String? = nil, titleColor: String? = nil
  var done: [String] = [], ask: [String] = [], praise: [String] = [], showLabel = false
  var open: [String]? = nil   // command to run when the notification is clicked (argument array; {pid}, {tty}, {id}, {tool}, {name} and {app} are substituted)
}
var TOOLS_FILE: URL {
  if let e = ProcessInfo.processInfo.environment["DOTBUDDY_TOOLS"], !e.isEmpty { return URL(fileURLWithPath: e) }
  return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DotBuddy/tools.json")
}
let BUILTIN_STYLES: [String: ToolStyle] = ["claude": ToolStyle(label: T("클로드", "Claude"))]
private var toolStyles: [String: ToolStyle] = BUILTIN_STYLES, toolStylesAt: Date? = .distantPast
private let toolStylesLock = NSLock()
/// Styling for that tool (re-read if the file changed — locked because both the source-reading thread and the main thread call it)
func toolStyle(_ tool: String) -> ToolStyle {
  toolStylesLock.lock(); defer { toolStylesLock.unlock() }
  let mt = (try? TOOLS_FILE.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
  if mt != toolStylesAt {
    toolStylesAt = mt; toolStyles = BUILTIN_STYLES
    if mt != nil, let d = try? Data(contentsOf: TOOLS_FILE), let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] {
      func hex(_ v: Any?) -> String? { (v as? String).flatMap { $0.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil ? $0 : nil } }
      for (k, v) in j {
        var st = toolStyles[k] ?? ToolStyle()
        if let x = v["label"] as? String, !x.isEmpty { st.label = x }
        st.fill = hex(v["fill"]) ?? st.fill; st.askFill = hex(v["askFill"]) ?? st.askFill; st.edge = hex(v["edge"]) ?? st.edge; st.titleColor = hex(v["titleColor"]) ?? st.titleColor
        st.done = (v["done"] as? [String] ?? st.done).filter { !$0.isEmpty }; st.ask = (v["ask"] as? [String] ?? st.ask).filter { !$0.isEmpty }
        st.praise = (v["praise"] as? [String] ?? st.praise).filter { !$0.isEmpty }; st.showLabel = v["showLabel"] as? Bool ?? st.showLabel
        if let o = v["open"] as? [String] { st.open = o.filter { !$0.isEmpty } } else if let o = v["open"] as? String, !o.isEmpty { st.open = [o] }
        toolStyles[k] = st
      }
    }
  }
  return toolStyles[tool] ?? ToolStyle()
}
/// Enabled sources — add a new agent source here
func makeSources() -> [SessionSource] { [Sessions(), ReportSource()] }
func readAll(_ srcs: [SessionSource], now: Double = Date().timeIntervalSince1970) -> [Sess] {
  srcs.flatMap { $0.read(now: now) }.map { s in var s = s; if let l = toolStyle(s.tool).label { s.label = l }; return s }.sorted { ($0.mood.rawValue, $0.since) > ($1.mood.rawValue, $1.since) }
}

final class Sessions: SessionSource {   // Claude Code
  let tool = "claude"
  var watchDir: String? { root.appendingPathComponent("sessions").path }
  let root: URL
  private var jsonlCache: [String: URL] = [:]
  init() {
    let e = ProcessInfo.processInfo.environment, env = [e["DOTBUDDY_CLAUDE_DIR"], e["CLAUDE_CONFIG_DIR"]].compactMap { $0 }.first { !$0.isEmpty }   // if the Claude config folder was moved, use that
    root = URL(fileURLWithPath: env ?? (NSHomeDirectory() + "/.claude"))
  }
  /// Result of reading one session file — not re-read while the modification time is unchanged
  private struct Rec { let mtime: Date, pid: Int32, sid: String, name: String, status: String, at: Double, started: Double, derived: Bool, interactive: Bool; var waitingFor = "" }
  private var recs: [String: Rec] = [:]
  private var askCache: [String: (UInt64, Bool)] = [:]
  private var jsonlMiss: [String: Double] = [:]                               // when the transcript file was not found — do not scan again for 30 seconds
  private var lastMood: [String: Mood] = [:]                                  // if read while the file is being written, keep the previous verdict (so a flapping verdict does not fire two notifications)
  func read(now: Double) -> [Sess] {
    let dir = root.appendingPathComponent("sessions")
    guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
    var out: [Sess] = [], seen = Set<String>()
    for f in files where f.pathExtension == "json" {
      let key = f.lastPathComponent; seen.insert(key)
      let mt = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      var r = recs[key]
      if r == nil || r!.mtime != mt {
        guard let data = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (j["pid"] as? NSNumber)?.int32Value, let sid = j["sessionId"] as? String else {
          if r == nil { continue }                                                  // if it is mid-write, use the previous value — so a session that vanishes briefly and reappears does not fire two notifications
          guard let x = r, x.interactive, alive(x.pid, before: x.started), let m = lastMood[key] else { continue }
          out.append(Sess(pid: x.pid, id: x.sid, name: x.name, mood: m, since: x.at, derived: x.derived))
          continue
        }
        var name = (j["name"] as? String) ?? ""
        if name.isEmpty { name = ((j["cwd"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? sid }   // if cwd is /, use the session id
        let raw = ((j["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000
        let at = raw > now + 60 ? 0 : min(now, raw)                               // more than 1 minute in the future (clock set back) counts as long ago — so idle sessions do not all fire a "done" notification at once
        r = Rec(mtime: mt, pid: pid, sid: sid, name: name, status: j["status"] as? String ?? "idle",
                at: at, started: ((j["startedAt"] as? NSNumber)?.doubleValue).map { $0 / 1000 } ?? 0, derived: (j["nameSource"] as? String) == "derived",
                interactive: (j["kind"] as? String).map { $0 == "interactive" } ?? true, waitingFor: j["waitingFor"] as? String ?? "")
        recs[key] = r
      }
      guard let x = r, x.interactive, alive(x.pid, before: x.started) else { continue }   // dropped if the pid has been reused by another process
      let idle = now - x.at                                                       // after finishing, wait 5 minutes for the user to check, then just play until 20 minutes (so it does not keep nagging)
      let untouched = x.status == "idle" && x.started > 0 && x.at - x.started < 3          // Claude writes "idle" as it starts: a session nobody has used yet is not a "done"
      var mood: Mood = x.status == "idle" ? (idle < 5 * 60 && !untouched ? .wait : idle < 20 * 60 ? .free : .sleep) : x.status == "waiting" ? .ask : .work
      if mood == .work && pendingAsk(x.sid) { mood = .ask }                     // older Claude Code without "waiting": an unanswered AskUserQuestion in the transcript
      lastMood[key] = mood
      // Claude Code writes status "waiting" with waitingFor "permission prompt" (a tool needs your OK), "input needed" (a question) or "dialog open"
      out.append(Sess(pid: x.pid, id: x.sid, name: x.name, mood: mood, since: x.at, derived: x.derived, why: mood == .ask && x.waitingFor.hasPrefix("permission") ? "permission" : ""))
    }
    recs = recs.filter { seen.contains($0.key) }; lastMood = lastMood.filter { seen.contains($0.key) }
    let sids = Set(recs.values.map(\.sid))                                      // discard the cache of vanished sessions (so it does not grow when left running for a long time)
    askCache = askCache.filter { sids.contains($0.key) }; jsonlCache = jsonlCache.filter { sids.contains($0.key) }; jsonlMiss = jsonlMiss.filter { sids.contains($0.key) }
    return out.sorted { ($0.mood.rawValue, $0.since) > ($1.mood.rawValue, $1.since) }
  }
  func jsonl(_ sid: String) -> URL? {
    if let u = jsonlCache[sid] { return u }
    let now = Date().timeIntervalSince1970
    if let t = jsonlMiss[sid], now - t < 30 { return nil }
    let p = root.appendingPathComponent("projects")
    for d in (try? FileManager.default.contentsOfDirectory(at: p, includingPropertiesForKeys: nil)) ?? [] {
      let u = d.appendingPathComponent(sid + ".jsonl")
      if FileManager.default.fileExists(atPath: u.path) { jsonlCache[sid] = u; jsonlMiss[sid] = nil; return u }
    }
    jsonlMiss[sid] = now
    return nil
  }
  /// Is an unanswered AskUserQuestion left at the end of the transcript
  func pendingAsk(_ sid: String) -> Bool {
    guard let u = jsonl(sid), let h = try? FileHandle(forReadingFrom: u) else { return false }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    if let c = askCache[sid], c.0 == size { return c.1 }                       // if the transcript did not grow, return the same result
    let ans = scanAsk(h, size)
    askCache[sid] = (size, ans)
    return ans
  }
  private func scanAsk(_ h: FileHandle, _ size: UInt64) -> Bool {
    try? h.seek(toOffset: size > 65536 ? size - 65536 : 0)
    guard let data = try? h.readToEnd(), data.range(of: Data("AskUserQuestion".utf8)) != nil else { return false }   // filter by bytes first (dozens of times faster than converting to a string and searching)
    let text = String(decoding: data, as: UTF8.self)
    var pending: [String: String] = [:]
    for line in text.split(separator: "\n") {
      guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let m = j["message"] as? [String: Any], let content = m["content"] as? [[String: Any]] else { continue }
      for b in content {
        if b["type"] as? String == "tool_use", let id = b["id"] as? String { pending[id] = b["name"] as? String ?? "" }
        if b["type"] as? String == "tool_result", let id = b["tool_use_id"] as? String { pending[id] = nil }
      }
    }
    return pending.values.contains("AskUserQuestion")
  }
}

// ---------- File watching (kqueue): session files are overwritten in place, so watch the folder (add/delete) and each file (write) separately ----------
final class Watcher {
  private var sources: [String: DispatchSourceFileSystemObject] = [:]
  private var scheduled = false
  private let onChange: () -> Void
  init(onChange: @escaping () -> Void) { self.onChange = onChange }
  private func add(_ path: String, _ mask: DispatchSource.FileSystemEvent) {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
    src.setEventHandler { [weak self, weak src] in
      if let ev = src?.data, !ev.intersection([.delete, .rename]).isEmpty { src?.cancel(); self?.sources[path] = nil }
      self?.fire()
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    sources[path] = src
  }
  /// Sync the folders + the *.json files inside them to the current list (start watching new files, stop for vanished ones). A missing folder is checked again next time
  func sync(dirs: [String]) {
    var keep = Set(dirs)
    for dir in dirs {
      if sources[dir] == nil { add(dir, [.write, .delete, .rename]) }
      let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.map { dir + "/" + $0 })
      keep.formUnion(names)
      for p in names where sources[p] == nil { add(p, [.write, .extend, .delete, .rename]) }
    }
    for (p, src) in sources where !keep.contains(p) { src.cancel(); sources[p] = nil }
  }
  /// Events that arrive together are collected for 0.15 s and handled once
  private func fire() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.scheduled = false; self?.onChange() }
  }
}
