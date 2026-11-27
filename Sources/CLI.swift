// Command-line helpers for other agents' hooks:
//   dotbuddy-hook TOOL ID_KEY ACTION [REPLY]   (the same binary under another name, or `DotBuddy --hook …`)
//   DotBuddy --install-cli [dir]               link `dotbuddy` and `dotbuddy-hook` into ~/.local/bin (or dir)
import AppKit

/// Pull a value out of hook JSON by a dotted path: "session_id", "workspace_roots.0"
func jsonPath(_ j: Any?, _ path: String) -> String? {
  var cur = j
  for k in path.split(separator: ".") {
    if let d = cur as? [String: Any] { cur = d[String(k)] }
    else if let a = cur as? [Any], let i = Int(k), i >= 0, i < a.count { cur = a[i] }
    else { return nil }
  }
  switch cur {
  case let s as String: return s.isEmpty ? nil : s
  case let n as NSNumber: return n.stringValue
  default: return nil
  }
}

/// The hook helper. Reads the agent's hook JSON on stdin, reports the session (or sends a gesture), prints REPLY if given,
/// and always exits 0 so it can never block or confuse the agent. DOTBUDDY_PID ties the session to a process
func runHook(_ args: [String]) -> Never {
  guard args.count >= 3 else {
    FileHandle.standardError.write("usage: dotbuddy-hook TOOL ID_KEY ACTION [REPLY]   (ACTION: busy|idle|ask|end|event:NAME)\n".data(using: .utf8)!)
    exit(0)
  }
  let tool = args[0], key = args[1], action = args[2], reply = args.count >= 4 ? args[3] : ""
  let input = FileHandle.standardInput.readDataToEndOfFile()
  let j = try? JSONSerialization.jsonObject(with: input, options: [.fragmentsAllowed])
  let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path   // argv[0] is a bare name when run from PATH
  func call(_ a: [String]) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: me); p.arguments = a
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
  }
  if action.hasPrefix("event:") {
    call(["--signal", "event", String(action.dropFirst(6)), "--from", tool])
  } else if ["busy", "idle", "ask", "end"].contains(action), let id = jsonPath(j, key) {
    var a = ["--report", tool, id, action]
    if let dir = jsonPath(j, "cwd") ?? jsonPath(j, "workspace_roots.0"), case let folder = (dir as NSString).lastPathComponent, folder != "/" { a += ["--name", "\(tool) · \(folder)"] }   // "/x/proj/" → proj; "/" → no name
    if let pid = ProcessInfo.processInfo.environment["DOTBUDDY_PID"], Int32(pid) ?? 0 > 0 { a += ["--pid", pid] }
    call(a)
  }
  if !reply.isEmpty { print(reply) }
  exit(0)
}

/// Link `dotbuddy` and `dotbuddy-hook` to this binary. Inside the app the links survive self-updates (same path)
func installCLI(_ dir: String = NSHomeDirectory() + "/.local/bin") -> Result<[String], Error> {
  let fm = FileManager.default, me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
  do {
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var made: [String] = []
    for name in ["dotbuddy", "dotbuddy-hook"] {
      let link = (dir as NSString).appendingPathComponent(name)
      if let attrs = try? fm.attributesOfItem(atPath: link) {
        guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { throw NSError(domain: "DotBuddy", code: 1, userInfo: [NSLocalizedDescriptionKey: T("\(link) 는 링크가 아니라 그대로 둬요", "\(link) exists and isn't a link; leaving it alone")]) }
        try fm.removeItem(atPath: link)
      }
      try fm.createSymbolicLink(atPath: link, withDestinationPath: me)
      made.append(link)
    }
    return .success(made)
  } catch { return .failure(error) }
}
/// Is dir on PATH (as the app sees it — login shells may differ)?
func onPath(_ dir: String) -> Bool { (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == dir } }
