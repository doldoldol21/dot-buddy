// Speech bubble drawing (dot font) and the settings store
import AppKit
import CoreText
import ServiceManagement

// ---------- Notification speech bubble (dot font Galmuri11, OFL) ----------
func registerFont() {
  let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
  for name in ["Galmuri7", "Galmuri9", "Galmuri11", "neodgm"] {
    let cands = [Bundle.main.url(forResource: name, withExtension: "ttf"), exe.appendingPathComponent("fonts/\(name).ttf")]
    if let u = cands.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
      CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
    }
  }
}
func cg(_ hex: String) -> CGColor {
  var v: UInt64 = 0; Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
  return CGColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
/// 1x dot image: a bordered box with clipped corners + text lines + a tail below. Font anti-aliasing is off so cells are even
/// Notification text size steps -> (font, pixel size). Dots come out even at these sizes (2026-11-13 sample comparison)
/// (font, pixel size, dot size = how many times the pet dot). Extra small and small are half the pet dot: whole pixels on Retina, so they stay crisp
// Lowered one step (2026-11-13): extra small = 3/8 of the pet dot, small = half (Galmuri7), normal = half (Galmuri9), large = same as the pet dot
// Font families: (shown name, small font, large font): each font is drawn only at its own base size (px) where dots come out even (2026-11-13 sample comparison)
struct FontFamily { let id: String, label: String, small: (String, CGFloat), large: (String, CGFloat); var smooth = false }
var FONT_FAMILIES: [FontFamily] = [
  FontFamily(id: "galmuri", label: T("갈무리", "Galmuri"), small: ("Galmuri7", 8), large: ("Galmuri9", 10)),
  FontFamily(id: "neodgm", label: T("Neo둥근모", "NeoDunggeunmo"), small: ("NeoDunggeunmo-Regular", 16), large: ("NeoDunggeunmo-Regular", 16)),
]
/// Terminal font (font-family from the cmux/Ghostty config): drawn smooth (anti-aliased), not as dots
func terminalFamily() -> FontFamily? {
  let home = NSHomeDirectory()
  let files = [home + "/Library/Application Support/com.cmuxterm.app/config.ghostty", home + "/.config/ghostty/config", home + "/Library/Application Support/com.mitchellh.ghostty/config"]
  for f in files {
    guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
    for line in text.split(separator: "\n") {
      let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard kv.count == 2, kv[0] == "font-family", !kv[1].isEmpty else { continue }
      let fam = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      let ps = (NSFontManager.shared.availableMembers(ofFontFamily: fam)?.first { ($0[1] as? String) == "Regular" } ?? NSFontManager.shared.availableMembers(ofFontFamily: fam)?.first)?[0] as? String
      guard let name = ps else { continue }
      return FontFamily(id: "terminal", label: T("터미널 글꼴 (\(fam))", "Terminal font (\(fam))"), small: (name, 12), large: (name, 12), smooth: true)
    }
  }
  return nil
}
var FONT_FAMILY = 0
var RENDER_M = 1                                    // How many pixels one dot is drawn as when the font is smooth
/// Text height per step (pet dot units): extra small 3, small 4, normal 5, large 8. The dot size is set so every font ends up the same height
let TEXT_HEIGHTS: [CGFloat] = [3, 4, 5, 8]
var TEXT_SIZES: [(String, CGFloat, CGFloat)] {
  let f = FONT_FAMILIES[FONT_FAMILY]
  return TEXT_HEIGHTS.enumerated().map { i, hgt in let (n, px) = i == 2 ? f.large : f.small; return (n, px, hgt / px) }
}
var CANVAS_BUBBLE = true
var TEXT_SIZE = 1
func textFont() -> CTFont { CTFontCreateWithName(TEXT_SIZES[TEXT_SIZE].0 as CFString, TEXT_SIZES[TEXT_SIZE].1, nil) }
/// reveal: draw only this many characters from the start (typing). Size is always based on the full text, so the bubble does not jiggle
func noticeImage(_ lines: [(String, CGColor)], fill: CGColor, edge: CGColor, side: Int = 0, check: Bool = false, reveal: Int = .max, tail tdx: Int = 0) -> CGImage? {
  let font = textFont(), px = Int(TEXT_SIZES[TEXT_SIZE].1)
  let cts = lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0.0, attributes: [.font: font, .foregroundColor: $0.1]) as CFAttributedString) }
  let mark = px <= 8 ? ["....g", "...g.", "g.g..", ".g..."] : [".....g", "....g.", "g..g..", ".gg...", ".g...."]   // The check mark is not in the font, so it is drawn with dots
  let cs = px >= 14 ? 2 : 1, iw = check ? (mark[0].count + 1) * cs : 0             // Icon cell (before the first line)
  let tw = (cts.enumerated().map { Int(ceil(CTLineGetTypographicBounds($0.element, nil, nil, nil))) + ($0.offset == 0 ? iw : 0) }.max() ?? 0)
  let lh = px + 3, padX = 4, padY = 2, tail = 4
  let bw = tw + padX * 2 + 2, bodyH = lh * lines.count + padY * 2 + 2
  let W = side == 0 ? bw : bw + tail, H = side == 0 ? bodyH + tail : bodyH
  let bx = side < 0 ? tail : 0, by = side == 0 ? tail : 0                   // Body position (leave the tail side empty)
  guard let c = CGContext(data: nil, width: W * RENDER_M, height: H * RENDER_M, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
  c.scaleBy(x: CGFloat(RENDER_M), y: CGFloat(RENDER_M)); let sm = FONT_FAMILIES[FONT_FAMILY].smooth; c.setShouldAntialias(sm); c.setAllowsAntialiasing(sm); c.setShouldSmoothFonts(false)
  c.setFillColor(edge); c.fill(CGRect(x: bx + 1, y: by, width: bw - 2, height: bodyH)); c.fill(CGRect(x: bx, y: by + 1, width: bw, height: bodyH - 2))
  c.setFillColor(fill); c.fill(CGRect(x: bx + 1, y: by + 1, width: bw - 2, height: bodyH - 2))
  if side == 0 {                                                             // Tail: a 6-4-2 cell staircase going down
    let cx = min(max(W / 2 + tdx, 5), W - 5)                                 // tdx: when the bubble is pushed into the screen, move the tail toward the pet
    c.setFillColor(edge)
    c.fill(CGRect(x: cx - 3, y: 3, width: 6, height: 1)); c.fill(CGRect(x: cx - 2, y: 2, width: 4, height: 1)); c.fill(CGRect(x: cx - 1, y: 1, width: 2, height: 1))
    c.setFillColor(fill)
    c.fill(CGRect(x: cx - 2, y: 3, width: 4, height: 2)); c.fill(CGRect(x: cx - 1, y: 2, width: 2, height: 1))
  } else {                                                                   // Tail: a 6-4-2 cell staircase going sideways (toward the pet), at the lower third of the body height
    let cy = max(4, bodyH / 3), d = side < 0 ? 1 : -1, ex = side < 0 ? tail : W - tail - 1   // ex: body border column
    c.setFillColor(edge)
    for (k, hgt) in [(1, 6), (2, 4), (3, 2)] { c.fill(CGRect(x: ex - d * k, y: cy - hgt / 2, width: 1, height: hgt)) }
    c.setFillColor(fill)
    c.fill(CGRect(x: ex, y: cy - 2, width: 1, height: 4)); c.fill(CGRect(x: ex - d, y: cy - 1, width: 1, height: 2))
  }
  var left = reveal
  for (i, full) in cts.enumerated() {
    let text = lines[i].0, n = min(text.count, max(0, left)); left -= text.count
    let l = n >= text.count ? full : CTLineCreateWithAttributedString(NSAttributedString(string: String(text.prefix(n)), attributes: [.font: font, .foregroundColor: lines[i].1]) as CFAttributedString)
    let ly = by + bodyH - 1 - padY - lh * (i + 1)                                    // Bottom of this line
    if i == 0 && check {
      c.setFillColor(lines[0].1)
      let top = ly + (lh - mark.count * cs) / 2 + mark.count * cs
      for (j, row) in mark.enumerated() { for (k, ch) in row.enumerated() where ch == "g" { c.fill(CGRect(x: bx + padX + 1 + k * cs, y: top - (j + 1) * cs, width: cs, height: cs)) } }
    }
    c.textPosition = CGPoint(x: bx + padX + 1 + (i == 0 ? iw : 0), y: ly + px / 5 + 2)
    CTLineDraw(l, c)
  }
  return c.makeImage()
}
struct BubbleSpec { var lines: [(String, CGColor)], fill: CGColor, edge: CGColor, side = 0, check = false, reveal = Int.max, tail = 0 }   // Text and colors used to redraw the bubble
struct Notice { let pid: Int32, id: String, title: String, ask: Bool; var worked: Double? = nil; var others = 0; var tool = ""   // tool: which agent the notice is from (for decoration)
  var ids: [String] = [], openTool: String? = nil, tty: String? = nil, app: String? = nil; var permission = false   // permission: the question is a tool waiting for your OK. Merged bubble: every session in it, and the tool to open the first with; tty/app as seen when the notice was made (used if the agent has quit by the time it is clicked)
  var members: [String] { ids.isEmpty ? [id] : ids }
}
/// Last line of a notice, chosen to fit the intent: for a question, a phrase saying it waits for an answer; when done, a phrase matching the elapsed time, time of day and backlog count
/// The next notice to show and what stays queued. Three or more "done" notices at once become one bubble ("4 done: a, b, c…")
/// instead of a 10-second queue each; questions are never merged. Clicking the merged bubble goes to the first session
func mergeNotices(_ first: Notice, _ rest: [Notice]) -> (Notice, [Notice]) {
  let session = { (n: Notice) in !n.ask && !n.id.hasPrefix("signal:") }               // outside signals stay on their own (clicking them does nothing)
  guard session(first), rest.filter(session).count >= 2 else { return (first, rest) }
  let dones = [first] + rest.filter(session)
  let names = dones.map(\.title), shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : "")
  let merged = Notice(pid: first.pid, id: first.id, title: T("\(names.count)곳 끝남: ", "\(names.count) done: ") + shown, ask: false, worked: nil, others: 0,
                      tool: Set(dones.map(\.tool)).count == 1 ? first.tool : "", ids: dones.flatMap(\.members), openTool: first.openTool ?? first.tool, tty: first.tty, app: first.app)
  return (merged, rest.filter { !session($0) })
}
func doneLine(_ n: Notice, hour h: Int = Calendar.current.component(.hour, from: Date())) -> String {
  func any(_ a: [String]) -> String {
    let pick = a.filter { !LAST_LINES.contains($0) }.randomElement() ?? a.randomElement()!
    LAST_LINES = Array((LAST_LINES + [pick]).suffix(5)); return pick
  }
  let st = toolStyle(n.tool)
  if n.ask, n.permission, st.ask.isEmpty { return any(T(["허락을 기다려요", "실행해도 될까요?", "승인해 주세요", "허락이 필요해요"], ["Needs your OK", "OK to run this?", "Waiting for approval", "Asking permission"])) }
  if n.ask { return any(st.ask.isEmpty ? T(["질문 있어요", "물어볼 게 있대요", "골라 주세요!", "확인이 필요해요", "대답 기다려요"], ["I have a question", "Needs your input", "Please pick one!", "Needs a check", "Waiting for your answer"]) : st.ask) }
  if !st.done.isEmpty { let base = any(st.done); return n.others > 0 ? base + " (+\(n.others))" : base }
  var a: [String]
  switch n.worked ?? 120 {
  case ..<45: a = T(["금방 끝났어요!", "벌써 했어요!", "후딱 끝!"], ["That was quick!", "Already done!", "Done in a flash!"])
  case ..<(15 * 60): a = T(["끝났어요!", "다 했어요~", "완료!", "확인해 주세요~", "보러 와요!"], ["Done!", "All finished~", "Complete!", "Please take a look~", "Come check it out!"])
  default: a = T(["드디어 끝났어요!", "긴 작업 끝!", "오래 걸렸지만 완료!", "해냈어요!"], ["Finally done!", "Long task finished!", "Took a while, but done!", "Made it!"])
  }
  if h >= 23 || h < 5 { a += T(["늦게까지 수고했어요", "끝! 이제 쉬어요"], ["Thanks for staying up late", "Done! Time to rest"]) }
  let base = any(a)
  return n.others > 0 ? base + " (+\(n.others))" : base                         // Also waiting on other items
}
/// Measures the title in dot font width and splits it into at most two lines (by word; if it overflows, an ellipsis at the end of the last line). maxW in 1x pixels
func wrapTitle(_ text: String, maxW: CGFloat = 0) -> [String] {
  let font = textFont(), maxW = maxW > 0 ? maxW : TEXT_SIZES[TEXT_SIZE].1 * 16   // About sixteen Hangul characters per line
  func w(_ s: String) -> CGFloat { CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]) as CFAttributedString), nil, nil, nil)) }
  var lines: [String] = [], cur = ""
  for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
    let cand = cur.isEmpty ? word : cur + " " + word
    if w(cand) <= maxW { cur = cand; continue }
    if !cur.isEmpty { lines.append(cur) }
    cur = word
    while w(cur) > maxW { var head = cur; while w(head) > maxW { head.removeLast() }; lines.append(head); cur = String(cur.dropFirst(head.count)) }   // A long word with no spaces
  }
  if !cur.isEmpty { lines.append(cur) }
  if lines.count > 2 {
    var last = lines[1]
    while w(last + "…") > maxW { last.removeLast() }
    lines = [lines[0], last + "…"]
  }
  return lines
}
/// Hands the dot image straight to the layer contents: scaling and compositing happen on the GPU (nearest neighbor, dots kept as is). Drawing with draw(_:) made the CPU scale and convert colors on every change
class DotLayerView: NSView {
  var image: CGImage? { didSet { if image !== oldValue { needsDisplay = true } } }
  override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }
  required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    guard let l = layer else { return }
    l.magnificationFilter = .nearest; l.minificationFilter = .nearest; l.contentsGravity = .resize
    l.contents = image
  }
}
final class NoticeView: DotLayerView {
  var onClick: (() -> Void)?
  override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
  override func mouseUp(with e: NSEvent) { onClick?() }
}

// ---------- Settings ----------
enum Layer: String, CaseIterable { case desktop, top
  var label: String { self == .desktop ? T("바탕화면", "Desktop") : T("항상 위", "Always on top") }
}
let UD = UserDefaults.standard
/// Accessories for special days (the party hat, the Santa hat, snow and lines for those days). On unless turned off in the menu
var SEASONAL: Bool { UD.object(forKey: "seasonal") == nil || UD.bool(forKey: "seasonal") }
/// December 1-26: the pet wears a Santa hat
func christmasSeason(month: Int, day: Int) -> Bool { month == 12 && day <= 26 }
/// Launch party: a party hat from the open-source launch for three months, except while the Santa hat is on (December 1-26)
/// Season dates are Gregorian even when the Mac is set to another calendar (Japanese, Buddhist, Hebrew…), in the current time zone
func gregorian() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
let PARTY_FROM = 20261126, PARTY_UNTIL = 20270225
func partySeason(year: Int, month: Int, day: Int) -> Bool {
  let n = year * 10000 + month * 100 + day
  return n >= PARTY_FROM && n <= PARTY_UNTIL && !christmasSeason(month: month, day: day)
}
/// December: a light snow around the pet for one minute in every five (not all the time, so it stays a small surprise)
func snowTime(month: Int, minute: Int) -> Bool { month == 12 && minute % 5 == 0 }
let BUNDLE_ID = "io.github.doldoldol21.dot-buddy", OLD_BUNDLE_IDS = ["dev.personal.dot-buddy"]
/// First launch after the bundle id changed: copy settings from the old id (character, size, days together, login item…)
func migrateDefaults() {
  guard UD.object(forKey: "migratedFrom") == nil else { return }
  for old in OLD_BUNDLE_IDS {
    guard let d = UD.persistentDomain(forName: old), !d.isEmpty else { continue }
    for (k, v) in d where UD.object(forKey: k) == nil { UD.set(v, forKey: k) }
    UD.set(old, forKey: "migratedFrom")
    if d["loginItem"] as? Bool == true { try? SMAppService.mainApp.register() }   // login items are tied to the bundle id
    return
  }
  UD.set("", forKey: "migratedFrom")
}
