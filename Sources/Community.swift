// Community characters: packs people share in github.com/dot-buddy/characters, listed in packs/index.json there.
//
// Nothing here runs until you open "More Characters…" (or use --community-list / --community-install). Then the app reads
// the index from raw.githubusercontent.com, shows each pack with its preview, and on Install downloads only the files the
// index lists for that pack (chara.json and motion PNGs), checks every file's size and SHA-256 against the index, and puts
// the pack in the characters folder. A pack is plain data: the same loader and size limits as any pack you add by hand.
import AppKit
import CryptoKit

let COMMUNITY_REPO = "dot-buddy/characters"
let COMMUNITY_SITE = "https://dot-buddy.github.io/characters/"
let COMMUNITY_BASE: String = {
  let e = ProcessInfo.processInfo.environment["DOTBUDDY_COMMUNITY_BASE"] ?? ""   // tests point this at a local folder (file://…/community/)
  let b = e.isEmpty ? "https://raw.githubusercontent.com/\(COMMUNITY_REPO)/main/packs/" : e   // (before 0.3.17: community/ in this repo, since removed)
  return b.hasSuffix("/") ? b : b + "/"
}()
/// Limits for a downloaded pack. Real packs are a few KB per file
let COMMUNITY_MAX_FILE = 256 << 10, COMMUNITY_MAX_PACK = 2 << 20, COMMUNITY_MAX_FILES = 48, COMMUNITY_MAX_INDEX = 4 << 20
/// Marker written into a pack installed from the community list (lets the window say Installed / Update, and lets an update replace it)
let COMMUNITY_MARKER = ".community.json"

struct CommunityFile { let name: String, sha256: String, size: Int }
struct CommunityPack {
  let id: String, name: String, names: [String: String], author: String, license: String, description: String
  let files: [CommunityFile], preview: String?
  var basedOn = ""                                                                // Fan art: the original character and series (the original belongs to its owner)
  var added = ""                                                                  // YYYY-MM-DD the pack first appeared in the list
  var likes = 0, discussion = ""                                                  // People who liked it (❤️/👍 on its GitHub discussion, counted daily by CI) and that discussion
  var descriptions: [String: String] = [:]                                        // The description in other languages ("ko": …)
  /// Added in the last two weeks
  var isNew: Bool {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
    guard let d = f.date(from: added) else { return false }
    return Date().timeIntervalSince(d) < 14 * 86400
  }
  var shownName: String { names[LANG.rawValue] ?? names["en"] ?? name }
  var shownDescription: String { descriptions[LANG.rawValue] ?? description }
  /// One value for "which version of this pack": changes whenever any file changes
  var digest: String { SHA256.hash(data: Data(files.map { "\($0.name):\($0.sha256)" }.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined() }
}
enum CommunityError: Error { case network(String), bad(String), exists(String), notFromList(String), write(String) }
func describe(_ e: CommunityError) -> String {
  switch e {
  case .network(let s): return T("인터넷 문제(\(s))", "network problem (\(s))")
  case .bad(let s): return T("받은 캐릭터 파일이 이상해요(\(s))", "the pack looks wrong (\(s))")
  case .exists(let s): return T("캐릭터 폴더에 이미 \(s) 가 있어요(직접 넣은 것 같아요)", "your characters folder already has \(s) (one you added yourself)")
  case .notFromList(let s): return T("\(s) 는 목록에서 받은 캐릭터가 아니에요(직접 넣은 건 캐릭터 폴더에서 지워 주세요)", "\(s) didn't come from the list (remove your own characters from the characters folder)")
  case .write(let s): return T("지우지 못했어요(\(s))", "couldn't remove it (\(s))")
  }
}

let COMMUNITY_ID = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]{1,31}$")
func validCommunityID(_ s: String) -> Bool { COMMUNITY_ID.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
/// Only chara.json and <motion>.png may be downloaded (no paths, no other file types)
func validCommunityFile(_ s: String) -> Bool {
  if s == "chara.json" { return true }
  guard s.hasSuffix(".png") else { return false }
  return MOTIONS.contains { $0.0 + ".png" == s }
}

/// GET a URL (call off the main thread). https:// or, for tests, file://
func communityGet(_ url: URL, max: Int, timeout: Double = 30) -> Result<Data, CommunityError> {
  var req = URLRequest(url: url, timeoutInterval: timeout)
  req.setValue("DotBuddy/\(APP_VERSION)", forHTTPHeaderField: "User-Agent")
  var out: Result<Data, CommunityError> = .failure(.network("no response"))
  let done = DispatchSemaphore(value: 0)
  URLSession(configuration: .ephemeral).dataTask(with: req) { d, r, e in
    if let e { out = .failure(.network(e.localizedDescription)) }
    else if let h = r as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { out = .failure(.network("HTTP \(h.statusCode)")) }
    else if let d, d.count <= max { out = .success(d) }
    else { out = .failure(.bad("too big")) }
    done.signal()
  }.resume()
  done.wait()
  return out
}

/// The community list (call off the main thread). Packs with a bad id, file name or size are left out
func communityIndex() -> Result<[CommunityPack], CommunityError> {
  guard let u = URL(string: COMMUNITY_BASE + "index.json") else { return .failure(.network("bad URL")) }
  switch communityGet(u, max: COMMUNITY_MAX_INDEX) {
  case .failure(let e): return .failure(e)
  case .success(let d):
    guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let packs = j["packs"] as? [[String: Any]] else { return .failure(.bad("index.json")) }
    var out: [CommunityPack] = []
    for p in packs {
      guard let id = p["id"] as? String, validCommunityID(id), let fl = p["files"] as? [[String: Any]] else { continue }
      var files: [CommunityFile] = []
      for f in fl {
        guard let n = f["name"] as? String, validCommunityFile(n), let h = f["sha256"] as? String, h.count == 64, let s = f["size"] as? Int, s > 0, s <= COMMUNITY_MAX_FILE else { files = []; break }
        files.append(CommunityFile(name: n, sha256: h.lowercased(), size: s))
      }
      guard files.contains(where: { $0.name == "idle.png" }), files.count <= COMMUNITY_MAX_FILES, files.map(\.size).reduce(0, +) <= COMMUNITY_MAX_PACK,
            Set(files.map(\.name)).count == files.count else { continue }
      let str = { (k: String) in (p[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
      let preview = (p["preview"] as? String).flatMap { $0 == "preview.gif" ? $0 : nil }
      out.append(CommunityPack(id: id, name: str("name").isEmpty ? id : String(str("name").prefix(40)), names: (p["names"] as? [String: String] ?? [:]).mapValues { String($0.prefix(40)) },
                               author: String(str("author").prefix(39)), license: String(str("license").prefix(20)), description: String(str("description").prefix(140)), files: files, preview: preview,
                               basedOn: String(str("based_on").prefix(60)), added: str("added").count == 10 ? str("added") : "",
                               likes: max(0, min(p["likes"] as? Int ?? 0, 999_999)),
                               discussion: str("discussion").hasPrefix("https://github.com/\(COMMUNITY_REPO)/discussions/") ? str("discussion") : "",
                               descriptions: (p["descriptions"] as? [String: String] ?? [:]).mapValues { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140)) }.filter { !$0.value.isEmpty }))
    }
    return .success(out.enumerated().sorted { ($0.element.added, -$0.offset) > ($1.element.added, -$1.offset) }.map(\.element))   // newest first, like the gallery
  }
}

enum CommunityState { case notInstalled, installed, updatable, mine }
/// Is this pack in the characters folder, and is it the version the list has?
func communityState(_ p: CommunityPack, dir: URL = CHARAS_DIR) -> CommunityState {
  let d = dir.appendingPathComponent(p.id)
  guard FileManager.default.fileExists(atPath: d.path) else { return .notInstalled }
  guard let m = try? Data(contentsOf: d.appendingPathComponent(COMMUNITY_MARKER)), let j = try? JSONSerialization.jsonObject(with: m) as? [String: Any] else { return .mine }
  return j["digest"] as? String == p.digest ? .installed : .updatable
}

/// Remove a pack that came from the community list: it goes to the Trash (or is deleted if there is no Trash). A folder the
/// user made themselves (no marker) is never touched. Returns the character id ("pack:<id>")
func removeCommunityPack(_ id: String, dir: URL = CHARAS_DIR) -> Result<String, CommunityError> {
  let fm = FileManager.default, d = dir.appendingPathComponent(id)
  guard validCommunityID(id) else { return .failure(.bad("id")) }
  var isDir: ObjCBool = false
  guard fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue, fm.fileExists(atPath: d.appendingPathComponent(COMMUNITY_MARKER).path) else { return .failure(.notFromList(id)) }
  do { try fm.trashItem(at: d, resultingItemURL: nil) } catch {
    do { try fm.removeItem(at: d) } catch { return .failure(.write(error.localizedDescription)) }
  }
  return .success("pack:" + id)
}

/// Download one pack into the characters folder (call off the main thread). Returns the character id ("pack:<id>")
func installCommunityPack(_ p: CommunityPack, dir: URL = CHARAS_DIR) -> Result<String, CommunityError> {
  let fm = FileManager.default
  guard validCommunityID(p.id) else { return .failure(.bad("id")) }
  if communityState(p, dir: dir) == .mine { return .failure(.exists(p.id)) }
  var got: [(String, Data)] = []
  for f in p.files {
    guard validCommunityFile(f.name), let u = URL(string: COMMUNITY_BASE + p.id + "/" + f.name) else { return .failure(.bad(f.name)) }
    switch communityGet(u, max: COMMUNITY_MAX_FILE) {
    case .failure(let e): return .failure(e)
    case .success(let d):
      let h = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
      guard d.count == f.size, h == f.sha256 else { return .failure(.bad("\(f.name) doesn't match the list")) }
      got.append((f.name, d))
    }
  }
  try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
  let tmp = dir.appendingPathComponent(".incoming-\(UUID().uuidString)"), dst = dir.appendingPathComponent(p.id)
  defer { try? fm.removeItem(at: tmp) }
  do {
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    for (n, d) in got { try d.write(to: tmp.appendingPathComponent(n)) }
    let marker: [String: Any] = ["id": p.id, "digest": p.digest, "author": p.author, "license": p.license, "source": COMMUNITY_BASE + p.id + "/"]
    try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]).write(to: tmp.appendingPathComponent(COMMUNITY_MARKER))
    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }         // only a pack we installed before (checked above)
    try fm.moveItem(at: tmp, to: dst)
  } catch { return .failure(.bad(error.localizedDescription)) }
  // The pack must load like any other; if it doesn't, take it out again
  guard loadCharas(in: dir).contains(where: { $0.id == "pack:" + p.id }) else { try? fm.removeItem(at: dst); return .failure(.bad("it doesn't load")) }
  return .success("pack:" + p.id)
}

// ---------- Installing a character someone handed you ----------
// Drop a .zip, a character folder or a single .png on the pet (or run --install-chara <path>) and it lands in the characters folder.
// Only the files the loader reads are copied (chara.json, <motion>.png, a Codex pet's pet.json and sheet, a single sprite's .png and .json);
// anything else in the folder or zip is left behind. The new character must load before it replaces anything, and a character
// with the same name goes to the Trash rather than being deleted.
let DROP_MAX_ZIP = 32 << 20, DROP_MAX_UNZIPPED = 64 << 20, DROP_MAX_ZIP_FILES = 400

/// Can this be dropped on the pet? (a folder, a .zip or a .png)
func droppableChara(_ u: URL) -> Bool {
  let ext = u.pathExtension.lowercased()
  return ext == "zip" || ext == "png" || (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
}

/// Run a system tool and return its output, or nil if it failed
private func runTool(_ path: String, _ args: [String]) -> String? {
  let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
  let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
  guard (try? p.run()) != nil else { return nil }
  let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
  return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
}

/// Install a character from a .zip, a folder or a .png (call off the main thread). Returns the character id and its shown name
func installDroppedChara(_ src: URL, dir: URL = CHARAS_DIR) -> Result<(String, String), CommunityError> {
  let fm = FileManager.default
  let notFound = CommunityError.bad(T("캐릭터를 못 찾았어요. idle.png 가 든 폴더나 zip, png 한 장을 놓아 주세요", "no character in it; drop a folder or zip with idle.png, or a single .png"))
  var work: URL?
  defer { if let w = work { try? fm.removeItem(at: w) } }
  let isDir = { (u: URL) in (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
  var root = src, name = isDir(src) ? src.lastPathComponent : src.deletingPathExtension().lastPathComponent
  if src.pathExtension.lowercased() == "zip" {
    // Look at the listing first so a zip that unpacks into something huge is refused before anything is written
    guard let sz = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, sz <= DROP_MAX_ZIP else { return .failure(.bad(T("zip 이 너무 커요", "the zip is too big"))) }
    guard let list = runTool("/usr/bin/unzip", ["-l", src.path]) else { return .failure(.bad(T("zip 을 못 열었어요", "can't open the zip"))) }
    let last = list.split(separator: "\n").last.map { $0.split(separator: " ").compactMap { Int($0) } } ?? []
    guard last.count >= 2, last[0] <= DROP_MAX_UNZIPPED, last[1] <= DROP_MAX_ZIP_FILES else { return .failure(.bad(T("zip 이 너무 커요", "the zip is too big"))) }
    guard let names = runTool("/usr/bin/unzip", ["-Z1", src.path]),
          !names.split(separator: "\n").contains(where: { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }) else { return .failure(.bad(T("zip 안 경로가 이상해요", "a path in the zip points outside it"))) }
    let w = fm.temporaryDirectory.appendingPathComponent("dotbuddy-drop-\(UUID().uuidString)"); work = w
    guard runTool("/usr/bin/ditto", ["-x", "-k", src.path, w.path]) != nil else { return .failure(.bad(T("zip 을 못 풀었어요", "can't unpack the zip"))) }
    root = w
  } else if !isDir(src) && src.pathExtension.lowercased() != "png" {
    return .failure(notFound)
  }
  // A folder (or unpacked zip) that holds one character folder, e.g. a zip of ago/: go into it
  let has = { (u: URL, f: String) in fm.fileExists(atPath: u.appendingPathComponent(f).path) }
  if isDir(root), !has(root, "idle.png"), !has(root, "pet.json") {
    let kids = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).filter { $0.lastPathComponent != "__MACOSX" }
    let dirs = kids.filter(isDir), pngs = kids.filter { $0.pathExtension.lowercased() == "png" }
    if dirs.count == 1, pngs.isEmpty { root = dirs[0]; name = root.lastPathComponent }
    else if dirs.isEmpty, pngs.count == 1 { root = pngs[0]; name = root.deletingPathExtension().lastPathComponent }
    else { return .failure(notFound) }
  }
  // The name becomes the folder (or file) name: no slashes, colons or leading dots
  name = String(name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").drop { $0 == "." }.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
  if name.isEmpty || name == "__MACOSX" { name = "chara" }

  // Pick the files to copy
  var files: [(URL, String)] = [], id: String, dstName: String
  if isDir(root) {
    dstName = name
    if has(root, "pet.json") {
      id = "codex:" + name
      guard let d = try? Data(contentsOf: root.appendingPathComponent("pet.json")), let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return .failure(.bad("pet.json")) }
      let sheet = m["spritesheetPath"] as? String ?? "spritesheet.webp"
      guard !sheet.isEmpty, !sheet.contains("/"), !sheet.hasPrefix("."), has(root, sheet) else { return .failure(.bad("spritesheetPath")) }
      files = [(root.appendingPathComponent("pet.json"), "pet.json"), (root.appendingPathComponent(sheet), sheet)]
    } else {
      id = "pack:" + name
      files = (["chara.json"] + MOTIONS.map { $0.0 + ".png" }).filter { has(root, $0) }.map { (root.appendingPathComponent($0), $0) }
    }
  } else {
    dstName = name + ".png"; id = "custom:" + name
    files = [(root, dstName)]
    let js = root.deletingPathExtension().appendingPathExtension("json")
    if fm.fileExists(atPath: js.path) { files.append((js, name + ".json")) }
  }
  for (u, _) in files {
    let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard v?.isRegularFile == true, (v?.fileSize ?? 0) <= MAX_IMAGE_BYTES else { return .failure(.bad(u.lastPathComponent)) }   // no links, nothing huge
  }
  guard !files.isEmpty else { return .failure(notFound) }

  // Already the one in the characters folder (dragged from there): nothing to copy
  let dst = dir.appendingPathComponent(dstName)
  if root.resolvingSymlinksInPath().path == dst.resolvingSymlinksInPath().path {
    return loadCharas(in: dir).first { $0.id == id }.map { .success((id, $0.name)) } ?? .failure(notFound)
  }
  // Put it together next to the characters folder (hidden, so the app doesn't load it half-written), check it loads, then swap it in
  try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
  let stage = dir.appendingPathComponent(".incoming-\(UUID().uuidString)")
  defer { try? fm.removeItem(at: stage) }
  do {
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    if isDir(root) {
      let p = stage.appendingPathComponent(dstName); try fm.createDirectory(at: p, withIntermediateDirectories: true)
      for (u, n) in files { try fm.copyItem(at: u, to: p.appendingPathComponent(n)) }
    } else {
      for (u, n) in files { try fm.copyItem(at: u, to: stage.appendingPathComponent(n)) }
    }
  } catch { return .failure(.bad(error.localizedDescription)) }
  guard let c = loadCharas(in: stage).first(where: { $0.id == id }) else { return .failure(.bad(T("불러올 수 없는 그림이에요(칸 크기를 CHARACTERS.md 와 맞춰 보세요)", "it doesn't load (check the frame size against CHARACTERS.md)"))) }
  do {
    var olds = [dst]
    if !isDir(root) { olds.append(dir.appendingPathComponent(name + ".json")) }
    for o in olds where fm.fileExists(atPath: o.path) { try fm.trashItem(at: o, resultingItemURL: nil) }   // the old one with the same name goes to the Trash
    for (_, n) in (isDir(root) ? [(root, dstName)] : files) { try fm.moveItem(at: stage.appendingPathComponent(n), to: dir.appendingPathComponent(n)) }
  } catch { return .failure(.bad(error.localizedDescription)) }
  return .success((id, c.name))
}

// ---------- The window ----------
final class CommunityWindow: NSObject, NSWindowDelegate {
  let window: NSWindow
  private let stack = NSStackView(), status = NSTextField(labelWithString: ""), sort = NSPopUpButton()
  private var packs: [CommunityPack] = []
  private var busy = false
  private let onInstalled: (String, String) -> Void                          // (character id, shown name)
  var onClose: (() -> Void)?
  var onRemoved: ((String, String) -> Void)?                                  // (character id, shown name)

  init(onInstalled: @escaping (String, String) -> Void) {
    self.onInstalled = onInstalled
    window = ClosableWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.title = T("다른 캐릭터 받기", "More Characters")
    window.isReleasedWhenClosed = false; window.delegate = self; window.minSize = NSSize(width: 400, height: 300)
    let head = NSTextField(wrappingLabelWithString: T("사람들이 그려서 올린 캐릭터예요. 받으면 캐릭터 메뉴에 바로 생겨요. 내 캐릭터를 올리는 방법은 아래 링크에 있어요.",
                                                     "Characters people drew and shared. Install one and it shows up in the Character menu right away. To share yours, see the link below."))
    head.font = .systemFont(ofSize: 12); head.textColor = .secondaryLabelColor
    let linkButton = { (title: String, action: Selector) -> NSButton in
      let b = NSButton(title: "", target: self, action: action); b.isBordered = false
      b.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 12)]); return b
    }
    sort.addItems(withTitles: [T("최신순", "Newest"), T("인기순", "Most liked")]); sort.controlSize = .small; sort.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    sort.selectItem(at: UD.integer(forKey: "communitySort") == 1 ? 1 : 0); sort.target = self; sort.action = #selector(resort)
    let gap = NSView(); gap.setContentHuggingPriority(.init(1), for: .horizontal)
    let link = NSStackView(views: [linkButton(T("갤러리에서 보기 →", "Browse the gallery →"), #selector(openGallery)), linkButton(T("내 캐릭터 올리는 법 →", "How to share your character →"), #selector(openGuide)), gap, sort])
    link.orientation = .horizontal; link.spacing = 16
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
    let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false; doc.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = doc; scroll.translatesAutoresizingMaskIntoConstraints = false
    status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 12)
    let root = NSView(); [head, link, scroll, status].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
    NSLayoutConstraint.activate([
      head.topAnchor.constraint(equalTo: root.topAnchor, constant: 14), head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      link.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 4), link.leadingAnchor.constraint(equalTo: head.leadingAnchor), link.trailingAnchor.constraint(equalTo: head.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: link.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8), status.leadingAnchor.constraint(equalTo: head.leadingAnchor), status.trailingAnchor.constraint(equalTo: head.trailingAnchor),
      status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
      doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8),
    ])
    window.contentView = root
    window.center()
  }
  func show() {
    NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    load()
  }
  func windowWillClose(_ n: Notification) { onClose?() }
  @objc func openGuide() { NSWorkspace.shared.open(URL(string: "https://github.com/\(COMMUNITY_REPO)/blob/main/" + T("README.ko.md", "README.md"))!) }
  @objc func openGallery() { NSWorkspace.shared.open(URL(string: COMMUNITY_SITE + T("ko/", ""))!) }

  private func load() {
    status.stringValue = T("목록 받는 중…", "Loading the list…")
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let r = communityIndex()
      DispatchQueue.main.async {
        guard let self else { return }
        switch r {
        case .failure(let e): self.status.stringValue = T("목록을 못 받았어요: ", "Couldn't load the list: ") + describe(e)
        case .success(let p): self.packs = p; self.rebuild(); self.status.stringValue = T("캐릭터 \(p.count)개", p.count == 1 ? "1 character" : "\(p.count) characters")
        }
      }
    }
  }
  @objc func resort() { UD.set(sort.indexOfSelectedItem, forKey: "communitySort"); rebuild() }
  @objc func openLike(_ b: NSButton) {
    guard let id = b.identifier?.rawValue, let p = packs.first(where: { $0.id == id }), let u = URL(string: p.discussion) else { return }
    NSWorkspace.shared.open(u)
  }
  private func rebuild() {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let shown = sort.indexOfSelectedItem == 1 ? packs.enumerated().sorted { ($0.element.likes, -$0.offset) > ($1.element.likes, -$1.offset) }.map(\.element) : packs   // the list comes newest first
    for (i, p) in shown.enumerated() {
      if i > 0 { let sep = NSBox(); sep.boxType = .separator; stack.addArrangedSubview(sep); sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
      let row = self.row(p); stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
  }
  private func row(_ p: CommunityPack) -> NSView {
    let img = NSImageView(); img.imageScaling = .scaleProportionallyUpOrDown; img.animates = true; img.wantsLayer = true
    img.layer?.magnificationFilter = .nearest; img.layer?.cornerRadius = 6; img.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.08).cgColor
    if let pv = p.preview, let u = URL(string: COMMUNITY_BASE + p.id + "/" + pv) {
      DispatchQueue.global(qos: .utility).async {
        if case .success(let d) = communityGet(u, max: 1 << 20), let im = NSImage(data: d) { DispatchQueue.main.async { img.image = im } }
      }
    }
    let title = NSTextField(labelWithString: p.shownName); title.font = .boldSystemFont(ofSize: 13)
    var nameRow: [NSView] = [title]
    if p.isNew {
      let tag = NSTextField(labelWithString: T("새로", "New")); tag.font = .systemFont(ofSize: 10, weight: .semibold); tag.textColor = .controlAccentColor; nameRow.append(tag)
    }
    if !p.discussion.isEmpty {                                                         // ♥ count; clicking it opens the discussion to like it on GitHub
      let like = NSButton(title: "", target: self, action: #selector(openLike(_:))); like.isBordered = false; like.identifier = NSUserInterfaceItemIdentifier(p.id)
      like.attributedTitle = NSAttributedString(string: "♥ \(p.likes)", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)])
      like.toolTip = T("GitHub에서 좋아요 누르기 (❤️ 또는 👍)", "Like it on GitHub (❤️ or 👍)"); nameRow.append(like)
    }
    let n = NSStackView(views: nameRow); n.orientation = .horizontal; n.spacing = 6; n.alignment = .firstBaseline
    let name: NSView = n
    let by = NSTextField(wrappingLabelWithString: [p.author.isEmpty ? "" : T("그린 사람 \(p.author)", "by \(p.author)"), p.license, p.basedOn.isEmpty ? "" : T("팬아트 · 원작 \(p.basedOn)", "Fan art of \(p.basedOn)")].filter { !$0.isEmpty }.joined(separator: " · "))
    by.font = .systemFont(ofSize: 11); by.textColor = .secondaryLabelColor
    let desc = NSTextField(wrappingLabelWithString: p.shownDescription); desc.font = .systemFont(ofSize: 12)
    let state = communityState(p)
    let btn = NSButton(title: "", target: self, action: #selector(install(_:))); btn.bezelStyle = .rounded; btn.identifier = NSUserInterfaceItemIdentifier(p.id)
    switch state {
    case .notInstalled: btn.title = T("받기", "Install")
    case .updatable: btn.title = T("새로 받기", "Update")
    case .installed: btn.title = T("받음", "Installed"); btn.isEnabled = false
    case .mine: btn.title = T("이름 겹침", "Name in use"); btn.isEnabled = false; btn.toolTip = describe(.exists(p.id))
    }
    let text = NSStackView(views: [name, by] + (p.shownDescription.isEmpty ? [] : [desc])); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
    var buttons: [NSView] = [btn]
    if state == .installed || state == .updatable {                                   // Installed from the list: it can be removed again (to the Trash)
      let rm = NSButton(title: T("지우기", "Remove"), target: self, action: #selector(remove(_:))); rm.bezelStyle = .rounded; rm.controlSize = .small
      rm.font = .systemFont(ofSize: NSFont.smallSystemFontSize); rm.identifier = NSUserInterfaceItemIdentifier(p.id); buttons.append(rm)
    }
    let side = NSStackView(views: buttons); side.orientation = .vertical; side.alignment = .centerX; side.spacing = 4
    side.setContentHuggingPriority(.required, for: .horizontal); side.widthAnchor.constraint(equalToConstant: 96).isActive = true   // one column of buttons on every row
    let h = NSStackView(views: [img, text, side]); h.orientation = .horizontal; h.alignment = .centerY; h.distribution = .fill; h.spacing = 12; h.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
    img.widthAnchor.constraint(equalToConstant: 96).isActive = true; img.heightAnchor.constraint(equalToConstant: 64).isActive = true
    text.setContentHuggingPriority(.defaultLow, for: .horizontal); text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    btn.setContentHuggingPriority(.required, for: .horizontal); img.setContentHuggingPriority(.required, for: .horizontal)
    desc.preferredMaxLayoutWidth = 240; by.preferredMaxLayoutWidth = 240                 // (a fan-art line makes it long)
    return h
  }
  @objc func remove(_ b: NSButton) {
    guard !busy, let id = b.identifier?.rawValue, let p = packs.first(where: { $0.id == id }) else { return }
    switch removeCommunityPack(p.id) {
    case .success(let cid): status.stringValue = T("\(p.shownName) 지웠어요(휴지통에 있어요)", "Removed \(p.shownName) (it's in the Trash)"); onRemoved?(cid, p.shownName)
    case .failure(let e): status.stringValue = describe(e)
    }
    rebuild()
  }
  @objc func install(_ b: NSButton) {
    guard !busy, let id = b.identifier?.rawValue, let p = packs.first(where: { $0.id == id }) else { return }
    busy = true; b.isEnabled = false; b.title = T("받는 중…", "Installing…")
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let r = installCommunityPack(p)
      DispatchQueue.main.async {
        guard let self else { return }
        self.busy = false
        switch r {
        case .success(let cid): self.status.stringValue = T("\(p.shownName) 받았어요", "Installed \(p.shownName)"); self.onInstalled(cid, p.shownName)
        case .failure(let e): self.status.stringValue = T("못 받았어요: ", "Couldn't install: ") + describe(e)
        }
        self.rebuild()
      }
    }
  }
}
private final class FlippedView: NSView { override var isFlipped: Bool { true } }
/// The app has no menu bar, so nothing handles ⌘W: the window closes itself on ⌘W and on Esc
final class ClosableWindow: NSWindow {
  override func performKeyEquivalent(with e: NSEvent) -> Bool {
    if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "w" { performClose(nil); return true }
    return super.performKeyEquivalent(with: e)
  }
  override func cancelOperation(_ sender: Any?) { performClose(nil) }
}
