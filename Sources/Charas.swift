// Character definitions and pack loading (single sprites, motion packs, Codex pets)
import AppKit
import CoreText
import ServiceManagement

// ---------- Colors ----------
func rgba(_ hex: String, _ a: Double = 1) -> UInt32 {
  var v: UInt64 = 0; Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
  let al = UInt32(max(0, min(255, a * 255)))
  let r = UInt32((v >> 16) & 0xff) * al / 255, g = UInt32((v >> 8) & 0xff) * al / 255, b = UInt32(v & 0xff) * al / 255
  return (r << 24) | (g << 16) | (b << 8) | al            // Premultiplied RGBA
}
let INK = rgba("#2b2222"), CHEEK = rgba("#f08f9a"), WHITE = rgba("#ffffff")

// ---------- Characters ----------
enum Kind { case mandu, acorn, sprout, cloud, candle, pebble, custom }
/// A loaded dot sprite (assumed to face right). eyes = the eye cells that blink (x, y, w, h)
struct Sprite { let w: Int, h: Int, px: [UInt32], eyes: [(Int, Int, Int, Int)]; var motions: [String: Motion] = [:]; var bodyH = 0; var hat: Hat = .auto }   // bodyH: key used when matching sizes (body height without the margin for raised arms)
/// Where a special-day hat goes (chara.json "hat"): found on the head, none (`false`, for a flame, leaf or steam on top), or the dot in idle.png where the hat's brim sits (`[x, y]`)
enum Hat: Equatable { case auto, none, at(Int, Int) }
/// One set of motion sprites: a PNG of equal-size frames laid out horizontally (frame = idle.png size). fps comes from "fps" in chara.json
struct Motion { let w: Int, h: Int, frames: [[UInt32]], fps: Double; var eyeAt: [(Int, Int)?] = [] }   // eyeAt: per frame, where the base eye moved to (dx, dy); nil for frames that redraw the eyes
/// Motion names a character pack can use. Add a file named <name>.png and that sprite is used in that situation. If missing, it falls back to the name after the arrow (the last fallback is idle)
let MOTIONS: [(String, String)] = [
  ("idle", T("가만히 서 있기(필수 — 칸 크기 기준)", "standing still (required — sets the frame size)")), ("blink", T("눈 깜빡임", "blinking")), ("walk", T("걷기", "walking")), ("sneak", T("창 뒤에서 살금살금 걸어 나오기 → walk", "sneaking out from behind a window → walk")), ("roll", T("구르기 → walk", "rolling → walk")),
  ("work", T("노트북 두드리기(일하는 중)", "typing on a laptop (working)")), ("sleep", T("자기", "sleeping")), ("yawn", T("하품 → sleep", "yawning → sleep")), ("stretch", T("기지개 → happy", "stretching → happy")),
  ("cheer", T("끝났어요(✓ 배지와 함께) → happy", "done (with the ✓ badge) → happy")), ("ask", T("질문 기다림", "waiting for an answer")), ("hum", T("콧노래 → happy", "humming → happy")), ("happy", T("기쁨(여러 동작의 대체)", "joy (fallback for many motions)")),
  ("crouch", T("점프 준비(웅크림) — 없으면 기본 그림을 눌러 웅크린다", "crouching before a jump — if missing, the base sprite is squashed")), ("jump", T("점프", "jumping")), ("land", T("착지 순간 → crouch", "landing → crouch")), ("fall", T("떨어지기 → jump", "falling → jump")), ("drag", T("들려 있기 → fall", "being held up → fall")), ("pounce", T("커서 덮치기 → jump", "pouncing on the cursor → jump")), ("stalk", T("덮치기 전 노리기", "stalking before a pounce")), ("dive", T("바닥 속으로 쏙 들어가기(높은 곳·다른 모니터로 갈 때) → jump", "diving into the floor (when going up high or to another monitor) → jump")),
  ("climb", T("옆면 오르기", "climbing a side")), ("descend", T("기어 내려가기 → climb", "climbing down → climb")), ("hang", T("매달리기 → climb", "hanging → climb")), ("sit", T("가장자리에 걸터앉기", "sitting on an edge")), ("peek", T("내려다보기", "looking down")),
  ("talk", T("말할 때", "talking")), ("petted", T("쓰다듬어질 때 → happy", "being petted → happy")), ("startle", T("깜짝", "startled")), ("pout", T("삐짐", "pouting")), ("party", T("완료 만세 → cheer", "cheering at completion → cheer")),
  ("hop", T("폴짝 → happy", "hopping → happy")), ("spin", T("빙글", "spinning")), ("heart", T("하트 → happy", "heart → happy")), ("squish", T("꾹 눌림", "being squished")), ("dizzy", T("어질", "dizzy")), ("wave", T("손 흔들기", "waving")),
  ("shy", T("부끄", "shy")), ("star", T("반짝 → happy", "sparkle → happy")), ("flinch", T("움찔 → startle", "flinching → startle")),
]
let MOTION_FALLBACK: [String: [String]] = [
  "roll": ["walk"], "yawn": ["sleep"], "stretch": ["happy"], "cheer": ["happy"], "hum": ["happy"], "fall": ["jump"], "drag": ["fall", "jump"],
  "pounce": ["jump"], "land": ["crouch"], "dive": ["jump"], "descend": ["climb"], "hang": ["climb"], "petted": ["happy"], "party": ["cheer", "happy"], "hop": ["happy"],
  "heart": ["happy"], "star": ["happy"], "flinch": ["startle"], "sneak": ["walk"],
]
struct Chara {
  let id: String, name: String, kind: Kind
  let body: UInt32, light: UInt32, shade: UInt32, line: UInt32, accent: UInt32
  var sprite: Sprite? = nil
}
/// One image (PNG, WebP or anything ImageIO reads) -> (width, height, RGBA bytes, premultiplied alpha)
/// This is an image from a downloaded pack, so check the size before decoding: blocks images where a small file decodes to several GB (16000^2 PNG, 1MB -> 3GB)
let MAX_IMAGE_PX = 4096 * 4096, MAX_IMAGE_BYTES = 32 << 20
func loadRGBA(_ f: URL) -> (Int, Int, [UInt8])? {
  let f = f.resolvingSymlinksInPath()                                         // For a link, look at the size and type of the file it points to (FIFOs and device files are rejected)
  guard let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true, (v.fileSize ?? 0) <= MAX_IMAGE_BYTES,
        let src = CGImageSourceCreateWithURL(f as CFURL, nil),
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
        let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int,
        pw > 0, ph > 0, pw <= 16384, ph <= 16384, pw * ph <= MAX_IMAGE_PX,
        let cgi = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
  let w = cgi.width, h = cgi.height
  var raw = [UInt8](repeating: 0, count: w * h * 4)
  guard let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: RGB_SPACE, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
  ctx.draw(cgi, in: CGRect(x: 0, y: 0, width: w, height: h))
  return (w, h, raw)
}
/// One PNG -> (width, height, pixels). Semi-transparent pixels are cut at 0.5 (dot art)
func loadPNG(_ f: URL) -> (Int, Int, [UInt32])? {
  guard let (w, h, raw) = loadRGBA(f) else { return nil }
  var px = [UInt32](repeating: 0, count: w * h)
  for i in 0..<(w * h) {
    let v = UInt32(raw[i * 4]) << 24 | UInt32(raw[i * 4 + 1]) << 16 | UInt32(raw[i * 4 + 2]) << 8 | UInt32(raw[i * 4 + 3])
    px[i] = v & 0xff < 128 ? 0 : v
  }
  return (w, h, px)
}

// ---------- Codex pets ----------
// Reads the Codex app's pet pack (pet.json + spritesheet.webp) as is. The sheet is 8 columns x 9 rows (192x208 per cell), one motion per row, and
// the empty cells at the end are transparent. Based on the community doc (hatch-pet animation-rows.md); the official OpenAI spec has not been found yet (2026-11-19).
// Shrinks the large image to 24 dots tall for the dot engine (one dot = one pixel, cell max 30x32). Each cell has its feet aligned to the floor (the app moves the jump height).
/// Row -> (Codex name, our motion names, frames per second: average of the doc's frame times)
let CODEX_ROWS: [(String, [String], Double)] = [
  ("idle", ["idle"], 5.5), ("running-right", ["walk"], 7.5), ("running-left", [], 7.5), ("waving", ["wave", "happy"], 5.7),
  ("jumping", ["jump", "cheer"], 6), ("failed", ["pout", "dizzy"], 6.6), ("waiting", ["ask"], 5.9), ("running", ["sneak"], 7.5), ("review", ["work"], 5.8),
]
let CODEX_CELL = (192, 208)
var CODEX_PETS: URL {                                                    // Where Codex keeps pets: ${CODEX_HOME:-~/.codex}/pets
  let e = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.codex")
  return URL(fileURLWithPath: e).appendingPathComponent("pets")
}
private var codexCache: [String: (Date, Chara)] = [:]
/// One Codex pet folder -> a character (nil if the sheet is unreadable or the format differs). The same file is not shrunk again
func loadCodexPet(_ dir: URL) -> Chara? {
  guard let d = try? Data(contentsOf: dir.appendingPathComponent("pet.json")), let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
  let rel = (m["spritesheetPath"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("/") || $0.contains("..") ? nil : $0 } ?? "spritesheet.webp"   // Never read outside the folder
  let sheetURL = dir.appendingPathComponent(rel)
  guard sheetURL.resolvingSymlinksInPath().path.hasPrefix(dir.resolvingSymlinksInPath().path + "/") else { return nil }   // Do not read if a link points outside the pack
  let mt = (try? sheetURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
  if let c = codexCache[sheetURL.path], c.0 == mt { return c.1 }
  guard let (W, H, raw) = loadRGBA(sheetURL), W % 8 == 0 else { return nil }
  let cw = W / 8, ch = cw * CODEX_CELL.1 / CODEX_CELL.0                       // Cell ratio 192:208; a resized sheet is read if it has the same ratio
  guard ch > 0, H % ch == 0, H / ch >= CODEX_ROWS.count else { return nil }
  func a(_ x: Int, _ y: Int) -> Int { Int(raw[(y * W + x) * 4 + 3]) }
  // Per cell, the box that contains the drawing (pixels with alpha above half)
  struct Cell { let x0: Int, x1: Int, y0: Int, y1: Int }
  func box(_ r: Int, _ c: Int) -> Cell? {
    var x0 = cw, x1 = -1, y0 = ch, y1 = -1
    for y in 0..<ch { for x in 0..<cw where a(c * cw + x, r * ch + y) >= 128 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
    return x1 < 0 ? nil : Cell(x0: x0, x1: x1, y0: y0, y1: y1)
  }
  var rows: [[Cell]] = []
  for r in 0..<CODEX_ROWS.count {
    var cells = (0..<8).map { box(r, $0) }
    while let l = cells.last, l == nil { cells.removeLast() }               // Empty cells at the end are unused cells
    rows.append(cells.map { $0 ?? Cell(x0: 0, x1: -1, y0: 0, y1: -1) })
  }
  guard let idle = rows.first, !idle.isEmpty, idle.allSatisfy({ $0.x1 >= 0 }) else { return nil }
  let used = rows.enumerated().filter { !CODEX_ROWS[$0.offset].1.isEmpty }.flatMap(\.element).filter { $0.x1 >= 0 }
  let ux0 = used.map(\.x0).min()!, ux1 = used.map(\.x1).max()!
  let winW = ux1 - ux0 + 1, winH = used.map { $0.y1 - $0.y0 + 1 }.max()!
  let idleH = Double(idle.map { $0.y1 - $0.y0 + 1 }.sorted()[idle.count / 2])
  let sc = min(24 / idleH, Double(MAX_H) / Double(winH), Double(MAX_W) / Double(winW))   // Source pixel -> dot
  let ow = max(1, Int((Double(winW) * sc).rounded(.up))), oh = max(1, Int((Double(winH) * sc).rounded(.up)))
  /// Shrinks one cell: one dot = the average of the source box (that color if alpha is above half, else transparent). The cell's feet (y1) are aligned to the floor row.
  /// Edge dots (transparent neighbor) use the darkest color in the box instead of the average, because the outline of a smooth large image got lost in the average and looked blurry
  func shrink(_ r: Int, _ c: Int, _ b: Cell) -> [UInt32] {
    var out = [UInt32](repeating: 0, count: ow * oh), dark = out
    guard b.x1 >= 0 else { return out }
    func pack(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> UInt32 { func un(_ v: Int) -> UInt32 { UInt32(min(255, v * 255 / a)) }; return un(r) << 24 | un(g) << 16 | un(b) << 8 | 0xff }   // Un-premultiply alpha back to the original color
    for oy in 0..<oh { for ox in 0..<ow {
      let sx0 = ux0 + Int(Double(ox) / sc), sx1 = max(sx0 + 1, ux0 + Int(Double(ox + 1) / sc))
      let sy1 = b.y1 + 1 - Int(Double(oh - 1 - oy) / sc), sy0 = min(sy1 - 1, b.y1 + 1 - Int(Double(oh - oy) / sc))
      var R = 0, G = 0, B = 0, A = 0, n = 0, dl = Int.max, dc: UInt32 = 0
      for y in max(0, sy0)..<min(ch, max(sy1, 0)) { for x in max(0, sx0)..<min(cw, sx1) {
        let i = ((r * ch + y) * W + c * cw + x) * 4, al = Int(raw[i + 3])
        R += Int(raw[i]); G += Int(raw[i + 1]); B += Int(raw[i + 2]); A += al; n += 1
        if al >= 192, case let l = (Int(raw[i]) + Int(raw[i + 1]) + Int(raw[i + 2])) * 255 / al, l < dl { dl = l; dc = pack(Int(raw[i]), Int(raw[i + 1]), Int(raw[i + 2]), al) }
      } }
      guard n > 0, A * 2 >= n * 255 else { continue }
      out[oy * ow + ox] = pack(R, G, B, A); dark[oy * ow + ox] = dc
    } }
    var res = out
    for oy in 0..<oh { for ox in 0..<ow where out[oy * ow + ox] != 0 && dark[oy * ow + ox] != 0 {
      let edge = [(-1, 0), (1, 0), (0, -1), (0, 1)].contains { (dx, dy) in let x = ox + dx, y = oy + dy; return x < 0 || y < 0 || x >= ow || y >= oh || out[y * ow + x] == 0 }
      if edge { res[oy * ow + ox] = dark[oy * ow + ox] }
    } }
    return res
  }
  var motions: [String: Motion] = [:]
  for (r, (_, names, fps)) in CODEX_ROWS.enumerated() where !names.isEmpty && !rows[r].isEmpty {
    let frames = rows[r].enumerated().map { shrink(r, $0.offset, $0.element) }
    for n in names { motions[n] = Motion(w: ow, h: oh, frames: frames, fps: fps) }
  }
  guard let first = motions["idle"]?.frames.first else { return nil }
  var freq: [UInt32: Int] = [:]; for c in first where c != 0 { freq[c, default: 0] += 1 }
  let lum = { (c: UInt32) -> Int in Int(c >> 24) + Int((c >> 16) & 0xff) + Int((c >> 8) & 0xff) }
  let body = freq.max { $0.value < $1.value }?.key ?? rgba("#8fd3a8"), line = freq.keys.min { lum($0) < lum($1) } ?? INK
  let name = (m["displayName"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(30)) } ?? dir.lastPathComponent
  let c = Chara(id: "codex:" + dir.lastPathComponent, name: name, kind: .custom, body: body, light: body, shade: body, line: line, accent: rgba("#f08f9a"),
                sprite: Sprite(w: ow, h: oh, px: first, eyes: [], motions: motions, bodyH: Int((idleH * sc).rounded())))
  codexCache[sheetURL.path] = (mt, c)
  return c
}
/// Our character as a Codex pet pack (8x9 sheet, 192x208 cells, dots scaled by an integer factor), for trying it in Codex or testing import
func exportCodexPet(_ ch: Chara, to dir: URL) -> Bool {
  let (w, h, set) = packFrames(ch)
  let k = max(1, min(CODEX_CELL.0 / w, CODEX_CELL.1 / h)), W = CODEX_CELL.0 * 8, H = CODEX_CELL.1 * CODEX_ROWS.count
  var px = [UInt32](repeating: 0, count: W * H)
  func put(_ row: Int, _ col: Int, _ f: [UInt32], flip: Bool) {
    let ox = col * CODEX_CELL.0 + (CODEX_CELL.0 - w * k) / 2, oy = row * CODEX_CELL.1 + CODEX_CELL.1 - h * k   // Centered horizontally, on the bottom
    for y in 0..<(h * k) { for x in 0..<(w * k) { let sx = x / k; px[(oy + y) * W + ox + x] = f[(y / k) * w + (flip ? w - 1 - sx : sx)] } }
  }
  let src: [(String, Bool)] = [("idle", false), ("walk", false), ("walk", true), ("wave", false), ("jump", false), ("pout", false), ("ask", false), ("walk", false), ("work", false)]
  for (r, (mn, flip)) in src.enumerated() { for (c, f) in (set[mn] ?? set["idle"]!).prefix(8).enumerated() { put(r, c, f, flip: flip) } }
  let data = px.map { $0.bigEndian }.withUnsafeBufferPointer { Data(buffer: $0) }
  guard let prov = CGDataProvider(data: data as CFData), let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: RGB_SPACE,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return false }
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  writePNG(img, dir.appendingPathComponent("spritesheet.png").path)                // The system cannot write WebP, so leave it as PNG and point to it from pet.json
  let id = ch.id.replacingOccurrences(of: "pack:", with: "")
  let meta: [String: Any] = ["id": id, "displayName": ch.name, "description": "Dot Buddy character \(ch.name)", "spritesheetPath": "spritesheet.png"]
  guard let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return false }
  return (try? d.write(to: dir.appendingPathComponent("pet.json"))) != nil
}
let SIGNAL_NAME = Notification.Name(BUNDLE_ID + ".signal")   // Name of the external signal (distributed notification)
let MAX_W = CW - 2, MAX_H = CH - 8                                   // Max size of one cell (30x32 dots)
var CHARAS_DIR: URL {                                                // Can be changed with DOTBUDDY_CHARAS (for testing and making packs)
  if let e = ProcessInfo.processInfo.environment["DOTBUDDY_CHARAS"], !e.isEmpty { return URL(fileURLWithPath: e) }
  return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DotBuddy/charas")
}
/// The default character packs bundled in the app (build.sh draws them with charas/chars.py into Resources/charas; when run directly as bin/DotBuddy, bin/charas).
/// If the user folder (CHARAS_DIR) has the same name, it wins. If DOTBUDDY_CHARAS is set (testing, making packs), only that folder is read
var BUNDLE_CHARAS: URL? {
  guard (ProcessInfo.processInfo.environment["DOTBUDDY_CHARAS"] ?? "").isEmpty, let u = Bundle.main.resourceURL?.appendingPathComponent("charas"),
        FileManager.default.fileExists(atPath: u.path) else { return nil }
  return u
}
/// Load characters (the app's default packs -> user folder -> Codex pets). Put other people's characters or your own drawings in the user folder
func loadCustomCharas() -> [Chara] {
  var out: [Chara] = []
  for dir in [BUNDLE_CHARAS, CHARAS_DIR].compactMap({ $0 }) {
    for c in loadCharas(in: dir) { out.removeAll { $0.id == c.id }; out.append(c) }
  }
  for f in ((try? FileManager.default.contentsOfDirectory(at: CODEX_PETS, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) where !out.contains(where: { $0.id == "codex:" + f.lastPathComponent }) {
    if let c = loadCodexPet(f) { out.append(c) }                                 // Pets placed in Codex can also be picked as is
  }
  return out
}
/// Read one character folder. Two forms:
/// charas/<name>.png (+ <name>.json)        a single sprite. The other motions are made by stretching and flipping it
/// charas/<name>/idle.png, walk.png, ...     a pack. Only motions named in MOTIONS use their own sprite; the rest use fallbacks or automatic motions
/// json: {"name": "shown name", "names": {"en": "Shown name"}, "eyes": [[x,y,w,h], ...], "fps": {"default": 6, "walk": 8}}   names holds per-language names (name if absent)
/// chara.json "hat": false → no hat, [x, y] inside the frame → the brim's middle dot; anything else → found on the head
func hatSpot(_ v: Any?, w: Int, h: Int) -> Hat {
  if let b = v as? Bool, !b { return .none }
  if let a = v as? [Int], a.count == 2, (0..<w).contains(a[0]), (0..<h).contains(a[1]) { return .at(a[0], a[1]) }
  return .auto
}
func loadCharas(in dir: URL) -> [Chara] {
  let fm = FileManager.default
  var out: [Chara] = []
  func meta(_ u: URL) -> [String: Any] { (try? Data(contentsOf: u)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
  func make(id: String, fallbackName: String, idle: (Int, Int, [UInt32]), meta m: [String: Any], motions: [String: Motion]) -> Chara {
    let (w, h, px) = idle
    var freq: [UInt32: Int] = [:]; for c in px where c != 0 { freq[c, default: 0] += 1 }
    let eyes = (m["eyes"] as? [[Int]] ?? []).filter { $0.count == 4 && $0[0] >= 0 && $0[1] >= 0 && $0[2] > 0 && $0[3] > 0 && $0[0] + $0[2] <= w && $0[1] + $0[3] <= h }.map { ($0[0], $0[1], $0[2], $0[3]) }   // Eye coordinates outside the image are dropped
    let lum = { (c: UInt32) -> Int in Int(c >> 24) + Int((c >> 16) & 0xff) + Int((c >> 8) & 0xff) }
    let body = freq.max { $0.value < $1.value }?.key ?? rgba("#8fd3a8")
    let line = freq.keys.min { lum($0) < lum($1) } ?? INK
    return Chara(id: id, name: (m["names"] as? [String: String])?[LANG.rawValue] ?? m["name"] as? String ?? fallbackName, kind: .custom, body: body, light: body, shade: body, line: line,
                 accent: rgba("#f08f9a"), sprite: Sprite(w: w, h: h, px: px, eyes: eyes, motions: motions, bodyH: m["height"] as? Int ?? h, hat: hatSpot(m["hat"], w: w, h: h)))
  }
  let items = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).sorted { $0.path < $1.path }   // hidden: a community pack still downloading (.incoming-…)
  for f in items {
    let name = f.deletingPathExtension().lastPathComponent
    if (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      if fm.fileExists(atPath: f.appendingPathComponent("pet.json").path) { if let c = loadCodexPet(f) { out.append(c) }; continue }   // Codex pet pack
      let m = meta(f.appendingPathComponent("chara.json")), fps = m["fps"] as? [String: Double] ?? [:]
      guard let sheet = loadPNG(f.appendingPathComponent("idle.png")) else { continue }
      let fr = m["frame"] as? [Int] ?? []                                         // Frame size [width, height]. If absent, the single idle.png is one frame
      let fw = fr.count == 2 ? fr[0] : sheet.0, fh = sheet.1
      guard fw > 0, fw <= MAX_W, fh <= MAX_H, sheet.0 % fw == 0 else { continue }
      var idlePx: [UInt32] = []; idlePx.reserveCapacity(fw * fh)
      for y in 0..<fh { idlePx.append(contentsOf: sheet.2[(y * sheet.0)..<(y * sheet.0 + fw)]) }
      let idle = (fw, fh, idlePx)
      var motions: [String: Motion] = [:]
      for (mn, _) in MOTIONS {
        guard let (w, h, px) = loadPNG(f.appendingPathComponent(mn + ".png")), h == fh, w % fw == 0 else { continue }   // Frame sizes must match
        let n = w / fw
        let frames: [[UInt32]] = (0..<n).map { (k: Int) -> [UInt32] in
          var out: [UInt32] = []; out.reserveCapacity(fw * h)
          for y in 0..<h { let s = y * w + k * fw; out.append(contentsOf: px[s..<(s + fw)]) }
          return out
        }
        let f = fps[mn] ?? fps["default"] ?? 6
        var mo = Motion(w: fw, h: h, frames: frames, fps: f.isFinite ? min(60, max(0.5, f)) : 6)   // A negative or infinite fps would break the frame index
        let eyeRects = (m["eyes"] as? [[Int]] ?? []).filter { $0.count == 4 && $0[0] >= 0 && $0[1] >= 0 && $0[2] > 0 && $0[3] > 0 && $0[0] + $0[2] <= fw && $0[1] + $0[3] <= fh }   // Eyes outside the image are dropped (same filtering as make)
        mo.eyeAt = frames.map { (fp: [UInt32]) -> (Int, Int)? in                                               // Find where the pixels identical to the base sprite's eye are
          guard !eyeRects.isEmpty else { return nil }
          for dy in -4...4 { for dx in -3...3 {
            let ok = eyeRects.allSatisfy { e in (e[1]..<(e[1] + e[3])).allSatisfy { y in (e[0]..<(e[0] + e[2])).allSatisfy { x in
              let sx = x + dx, sy = y + dy
              return sx >= 0 && sy >= 0 && sx < fw && sy < h && fp[sy * fw + sx] == idle.2[y * fw + x] && fp[sy * fw + sx] != 0 } } }
            if ok { return (dx, dy) }
          } }
          return nil
        }
        motions[mn] = mo
      }
      out.append(make(id: "pack:" + name, fallbackName: name, idle: idle, meta: m, motions: motions))
    } else if f.pathExtension.lowercased() == "png", let img = loadPNG(f), img.0 <= MAX_W, img.1 <= MAX_H {
      out.append(make(id: "custom:" + name, fallbackName: name, idle: img, meta: meta(f.deletingPathExtension().appendingPathExtension("json")), motions: [:]))
    }
  }
  return out
}
var ALL_CHARAS: [Chara] = CHARAS
/// If a pack with the same name (charas/<id>/) exists, use it instead of the default character drawn in code (build.sh bundles six high-quality ones in the app)
/// Find a character by saved id: a pack and the default character with the same name stand in for each other (the chosen character carries over if the pack is removed or added)
func findChara(_ id: String) -> Chara {
  let bare = { (s: String) in s.replacingOccurrences(of: "pack:", with: "").replacingOccurrences(of: "custom:", with: "") }
  return ALL_CHARAS.first { $0.id == id } ?? ALL_CHARAS.first { bare($0.id) == bare(id) } ?? ALL_CHARAS.first ?? CHARAS[0]
}
func mergeCharas(_ packs: [Chara]) -> [Chara] {
  let ids = Set(packs.map { $0.id.replacingOccurrences(of: "pack:", with: "").replacingOccurrences(of: "custom:", with: "") })
  let packFirst = CHARAS.compactMap { c in packs.first { $0.id == "pack:" + c.id } }          // Keep the default characters' order
  return packFirst + CHARAS.filter { !ids.contains($0.id) } + packs.filter { p in !packFirst.contains { $0.id == p.id } }
}
let CHARAS: [Chara] = [
  Chara(id: "mandu", name: T("만두", "Dumpling"), kind: .mandu, body: rgba("#f8f1e4"), light: rgba("#ffffff"), shade: rgba("#e2d2b6"), line: rgba("#9a8468"), accent: rgba("#f2a6a0")),
  Chara(id: "acorn", name: T("도토리", "Acorn"), kind: .acorn, body: rgba("#e3ad72"), light: rgba("#f5d3a4"), shade: rgba("#c88b50"), line: rgba("#6e4527"), accent: rgba("#8d5a35")),
  Chara(id: "sprout", name: T("새싹 화분", "Sprout"), kind: .sprout, body: rgba("#e0855a"), light: rgba("#f2ab86"), shade: rgba("#c26a44"), line: rgba("#7a3e26"), accent: rgba("#7cc46a")),
  Chara(id: "cloud", name: T("구름", "Cloud"), kind: .cloud, body: rgba("#f4f8ff", 0.95), light: rgba("#ffffff", 0.97), shade: rgba("#d3dff3", 0.95), line: rgba("#7a8fb8"), accent: rgba("#ffd56a")),
  Chara(id: "candle", name: T("촛불", "Candle"), kind: .candle, body: rgba("#fbefd9"), light: rgba("#fffaf0"), shade: rgba("#ead2ab"), line: rgba("#a07850"), accent: rgba("#ff9a3c")),
  Chara(id: "pebble", name: T("이끼돌", "Pebble"), kind: .pebble, body: rgba("#bcc5ce"), light: rgba("#e1e7ec"), shade: rgba("#9aa4af"), line: rgba("#5d6873"), accent: rgba("#8cbf5a")),
]
