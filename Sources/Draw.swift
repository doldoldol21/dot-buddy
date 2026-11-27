// Dot drawing: time-of-day props, character effects, the canvas, poses
import AppKit
import CoreText
import ServiceManagement

// ---------- Time-of-day props ----------
/// Nightcap (on the head, a striped cone drooping backward with a white pom-pom), a Santa hat in December (the same shape in red,
/// worn all day instead of the nightcap) and a morning mug (beside the front paw, steam rising). Characters with a flame or
/// leaf on top of the head do not wear a cap
func drawProps(_ cv: inout Canvas, _ ch: Chara, _ p: Pose, _ cx0: Int) {
  let id = ch.id.replacingOccurrences(of: "pack:", with: ""), d = p.look < 0 ? -1 : 1, cx = cx0 + p.shake
  let capOK = !["candle", "sprout"].contains(id) && ch.kind != .candle && ch.kind != .sprout
  // The head: the first row with 4 solid dots in a row near the middle, so steam, a stem or a wisp doesn't hold the cap up in the air
  func headRow(_ cv: Canvas) -> Int {
    func solid(_ y: Int) -> Bool { var run = 0; for x in max(0, cx - 8)...min(CW - 1, cx + 8) { if cv.alpha(x, y) >= 0xf0 { run += 1; if run >= 4 { return true } } else { run = 0 } }; return false }
    return ch.sprite != nil ? ((cv.top..<GY).first(where: solid) ?? cv.top) : cv.top
  }
  if p.nightcap || p.santa, capOK {
    let hy = headRow(cv) + 1, b = -d                                                         // The cone droops away from the facing direction
    let band = rgba("#f4f1ea"), pom = rgba("#ffffff")
    let (c1, c2, line) = p.santa ? (rgba("#d8383b"), rgba("#ee5a50"), rgba("#7a1d24")) : (rgba("#5b7fd6"), rgba("#8fb0f0"), rgba("#34407a"))
    for x in -5...5 { cv.set(cx + x, hy, band); cv.set(cx + x, hy + 1, band) }                  // White band (two rows)
    let rows: [(Int, ClosedRange<Int>)] = [(1, -4...4), (2, -3...4), (3, -1...5), (4, 1...6), (5, 4...7)]
    for (j, r) in rows { for x in r { cv.set(cx + x * b, hy - j, x == r.lowerBound || j == 5 ? line : ((x + j) % 3 == 0 ? c2 : c1)) } }   // The striped cone droops backward
    for (x, y) in [(8, 4), (9, 4), (8, 3), (9, 3), (8, 5), (9, 5)] { cv.set(cx + x * b, hy - y + 1, pom) }   // White pom-pom
    cv.top = min(cv.top, hy - 5)
  } else if p.party, capOK {
    // Party hat: an upright striped cone with a pom-pom, the tip leaning a little toward where it looks
    let hy = headRow(cv) + 1
    let (line, c1, c2, dot, pom) = (rgba("#2f3a78"), rgba("#4f8fe6"), rgba("#ffd84a"), rgba("#ff6fa8"), rgba("#ffffff"))
    let rows: [ClosedRange<Int>] = [-4...4, -3...3, -3...3, -2...2, -2...2, -1...1, -1...1, 0...0]   // row 0 is the rim, on the top of the head
    for (j, r) in rows.enumerated() {
      let sx = j >= 5 ? d : 0
      for x in r {
        let c = x == r.lowerBound || x == r.upperBound || j == 0 && abs(x) == 4 ? line : (x - j + 30) % 4 == 0 ? c2 : (x + j + 30) % 5 == 0 ? dot : c1
        cv.set(cx + x + sx, hy - j, c)
      }
    }
    for (x, y) in [(0, 8), (1, 8), (0, 9), (1, 9)] { cv.set(cx + d + (d < 0 ? x - 1 : x), hy - y, pom) }
    cv.top = min(cv.top, hy - 9)
  }
  if p.mug >= 0 {
    let mx = cx + 9 * d - (d < 0 ? 4 : 0), y0 = GY - 4
    let m = rgba("#e9e4da"), o = rgba("#6a5a4c"), cof = rgba("#6b4226"), steam = rgba("#ffffff", 0.75)
    for x in 0..<4 { cv.set(mx + x, y0, o); cv.set(mx + x, y0 + 3, o) }
    for x in 1..<3 { cv.set(mx + x, y0, cof) }
    for y in 1..<3 { cv.set(mx, y0 + y, o); cv.set(mx + 3, y0 + y, o); cv.set(mx + 1, y0 + y, m); cv.set(mx + 2, y0 + y, m) }
    let hx = d > 0 ? mx + 4 : mx - 1; cv.set(hx, y0 + 1, o); cv.set(hx, y0 + 2, o)            // The handle is on the side away from the pet
    cv.set(mx + 1 + p.mug, y0 - 2, steam); cv.set(mx + 2 - p.mug, y0 - 3, steam)
  }
}

// ---------- Character effects ----------
/// Overlays a different effect per character on error (fx 1) and done (fx 2). X, Y: drawing cell coords -> canvas coords (accounts for horizontal flip)
func charaFX(_ cv: inout Canvas, _ id: String, _ p: Pose, _ w: Int, _ X: (Int) -> Int, _ Y: (Int) -> Int) {
  let k = p.fxK, fade = k < 0.75 ? 1.0 : (1 - k) / 0.25
  func px(_ i: Int, _ j: Int, _ hex: String) { cv.set(X(i), Y(j), rgba(hex, fade)) }
  switch (id, p.fx) {
  case ("cloud", 1):                                                    // Rain drips
    for (n, i) in [4, 9, 14, 19].enumerated() { let j = 21 + (Int(k * 30) + n * 3) % 6; px(i, j, "#7fb2ea"); px(i, j + 1, "#7fb2ea") }
  case ("cloud", 2):                                                    // A small rainbow
    for (r, c) in [(9.5, "#f06b6b"), (8.5, "#f6dc6a"), (7.5, "#6fc27a"), (6.5, "#4f9ad0")] {
      for a in stride(from: 0.0, through: Double.pi, by: 0.08) where a / .pi <= k * 2 { px(12 + Int((cos(a) * r).rounded()), 9 - Int((sin(a) * r * 0.7).rounded()), c) }
    }
  case ("candle", 1):                                                   // The flame shrinks and a wisp of smoke rises
    for n in 0..<3 { let j = -1 - Int(k * 8) - n * 2; px(12 + (n % 2), j, "#b8b8c8") }
  case ("candle", 2):                                                   // The flame bursts up
    let h = Int(4 + sin(min(1, k * 3) * .pi / 2) * 4)
    for j in 0..<h { let half = j < h / 3 ? 0 : (j < h * 2 / 3 ? 1 : 2); for i in (12 - half)...(12 + half) { px(i, -h + j, j > h * 2 / 3 && i == 12 ? "#fff6c8" : (half == 2 && i != 12 ? "#ff8a2a" : "#ffcf3f")) } }
  case ("sprout", 1):                                                   // A single leaf flutters down
    let j = 4 + Int(k * 20), i = 19 + Int(sin(k * 12) * 2); px(i, j, "#79c25a"); px(i + 1, j, "#b8e690")
  case ("sprout", 2):                                                   // A flower blooms
    if k > 0.15 { px(12, 1, "#ffcf3f"); for (i, j) in [(11, 1), (13, 1), (12, 0), (12, 2)] { px(i, j, "#f59ab8") } }
    else { px(12, 2, "#b8e690") }
  case ("mandu", 2), ("mandu", 1):                                      // Puffs of steam on done, a sigh of steam on error
    for c in 0..<(p.fx == 2 ? 3 : 1) {
      let i = [12, 8, 16][c], j0 = 9 - Int(k * 10) - c * 2
      for d in 0..<3 { px(i + ((j0 + d) % 2 == 0 ? 0 : 1), j0 + d, "#d8e4f0") }
    }
  case ("acorn", 2):                                                    // A maple leaf flutters
    for (n, c) in ["#e8823a", "#d9533a", "#f2b84a"].enumerated() { let j = -6 + Int(k * 26) + n * 4, i = [4, 13, 21][n] + Int(sin(k * 10 + Double(n)) * 2); px(i, j, c); px(i + 1, j, c); px(i, j + 1, c) }
  case ("pebble", 2):                                                   // More flowers bloom on the moss
    for (n, i) in [6, 10].enumerated() where k > 0.15 + Double(n) * 0.2 { px(i, 8, "#ffcf3f"); for (a, b) in [(i - 1, 8), (i + 1, 8), (i, 7), (i, 9)] { px(a, b, "#ffffff") } }
  default: break
  }
}

// ---------- Dot canvas ----------
let CW = 32, CH = 40, GY = 38               // Canvas size, the row the feet touch
let RGB_SPACE = CGColorSpaceCreateDeviceRGB()
let KIND_SIZE: [Kind: (Int, Int)] = [.mandu: (16, 12), .acorn: (13, 12), .sprout: (14, 12), .cloud: (17, 11), .candle: (12, 14), .pebble: (16, 10)]   // Body width and height
let KIND_TOP: [Kind: Int] = [.mandu: 1, .acorn: 3, .sprout: 5, .candle: 7, .pebble: 4]                                                              // Rows above the body (room for the speech bubble and badge)
struct Canvas {
  var px = [UInt32](repeating: 0, count: CW * CH)
  var top = GY - 14                                  // Top row of the body (ears included); the speech bubble and badge sit above this
  mutating func set(_ x: Int, _ y: Int, _ c: UInt32) { if x >= 0, y >= 0, x < CW, y < CH, c != 0 { px[y * CW + x] = c } }
  mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: UInt32) { for j in 0..<max(0, h) { for i in 0..<max(0, w) { set(x + i, y + j, c) } } }
  mutating func sprite(_ rows: [String], _ x: Int, _ y: Int, _ pal: [Character: UInt32], flip: Bool = false) {
    for (j, row) in rows.enumerated() {
      let cs = Array(row)
      for (i, ch) in cs.enumerated() { if let c = pal[ch] { set(x + (flip ? cs.count - 1 - i : i), y + j, c) } }
    }
  }
  func alpha(_ x: Int, _ y: Int) -> UInt32 { (x >= 0 && y >= 0 && x < CW && y < CH) ? px[y * CW + x] & 0xff : 0 }
  func image() -> CGImage? {
    let data = px.map { $0.bigEndian }.withUnsafeBufferPointer { Data(buffer: $0) }
    guard let prov = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(width: CW, height: CH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: CW * 4, space: RGB_SPACE,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                   provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}

enum Eyes: Hashable { case open, closed, happy, wide, dizzy }
enum Bubble { case none, check, ask, dots, bang }
struct Pose: Hashable {
  var squash = 0, lift = 0, look = 0, feet = 0      // feet: 0 both down, 1 left foot up, 2 right foot up, 3 dangling
  var eyes = Eyes.open
  var laptop = -1                                    // Typing beat (0 or 1); -1 means no laptop
  var bubble = Bubble.none, count = 0
  var z = -1.0                                       // Sleep: rising z, 0 to 1
  var sparkle = -1.0                                 // Joy: sparkle, 0 to 1
  var shake = 0
  var hearts = -1.0                                  // Hearts: floating up, 0 to 1
  var wave = -1                                      // Hand wave beat (0 or 1)
  var blush = false
  var notes = -1.0                                   // Music notes: 0 to 1 cycle (joy, humming)
  var rot = 0                                        // Rolling: rotation in 90-degree steps
  var down = false                                   // Looking down
  var hands = false                                  // Hanging: both hands raised above the head
  var talk = false                                   // Chattering: mouth open
  var dust = -1.0                                    // Landing dust: spreading, 0 to 1
  var sweat = -1.0                                   // Sweat drop when busy: 0 to 1 running down
  var confetti = -1.0                                // Celebration confetti: 0 to 1 falling
  var snot = -1.0                                    // Snot bubble while sleeping: 0 to 1 inflating then popping
  var up = false                                     // Looking up (eyes one cell higher)
  var cover = false                                  // Covering the eyes with both hands (embarrassed)
  var tail = 0                                       // Cat tail swish (0 or 1)
  var angry = false                                  // Sulking mark (red anger vein)
  var motion = "", frame = 0                         // Pack character: the motion sprite to use and its frame index
  var sink = 0                                       // Rows sunk below the floor (nothing is drawn below the floor)
  var nightcap = false, mug = -1                     // Time-of-day props: nightcap (night / sleeping) and mug (morning, steam beat 0 or 1)
  var santa = false                                  // Seasonal: Santa hat (December, see christmasSeason)
  var party = false                                  // Launch party hat (see partySeason); the nightcap wins at night
  var snow = -1.0                                    // Seasonal: snowflakes drifting down, 0 to 1 cycle (December, see snowTime)
  var fx = 0, fxK = 0.0                              // Character effect: 1 error, 2 done; fxK is progress 0 to 1
  var icon = 0, iconBob = 0                          // Icon above the head: 1 light bulb (flash of insight), 2 question mark (head tilt)
}

let DIGITS: [[String]] = [
  ["kkk", "k.k", "k.k", "k.k", "kkk"], [".k.", "kk.", ".k.", ".k.", "kkk"], ["kkk", "..k", "kkk", "k..", "kkk"], ["kkk", "..k", "kkk", "..k", "kkk"],
  ["k.k", "k.k", "kkk", "..k", "..k"], ["kkk", "k..", "kkk", "..k", "kkk"], ["kkk", "k..", "kkk", "k.k", "kkk"], ["kkk", "..k", ".k.", ".k.", ".k."],
  ["kkk", "k.k", "kkk", "k.k", "kkk"], ["kkk", "k.k", "kkk", "..k", "kkk"],
]

func draw(_ ch: Chara, _ p: Pose) -> Canvas {
  var cv = Canvas()
  let pal: [Character: UInt32] = ["o": ch.line, "b": ch.body, "p": ch.accent, "l": ch.light, "s": ch.shade]
  let feet = !(ch.kind == .mandu || ch.kind == .cloud || ch.kind == .custom)
  let (bw0, bh0) = KIND_SIZE[ch.kind] ?? (14, 12)
  var w = bw0 + p.squash, h = bh0 - p.squash
  let cx = 16 + p.shake
  var bottom = GY - (feet ? 1 : 0) - p.lift, top = bottom - h + 1, left = cx - w / 2
  if p.lift >= 2 && p.rot == 0 { let sw = p.lift > 5 ? 6 : 9; cv.rect(16 - sw / 2, GY, sw, 1, rgba("#000000", 0.16)) }   // A shadow under the feet when lifted
  if let base = ch.sprite {
    // If a motion sprite (pack) exists, use that frame as is: only flip and lift. Otherwise squash, stretch and lift legs on the base sprite
    let mo = p.motion.isEmpty ? nil : base.motions[p.motion]
    let fi = mo.map { ($0.frames.count + p.frame % $0.frames.count) % $0.frames.count } ?? 0
    let shifted: [(Int, Int, Int, Int)] = {                                          // Eye positions in the motion frame (if found): blink, smile and dizzy eyes are overlaid on them
      guard let m = mo, fi < m.eyeAt.count, let (dx, dy) = m.eyeAt[fi] else { return mo == nil ? base.eyes : [] }
      return base.eyes.map { ($0.0 + dx, $0.1 + dy, $0.2, $0.3) }
    }()
    let sp = mo.map { Sprite(w: $0.w, h: $0.h, px: $0.frames[fi], eyes: shifted) } ?? base
    let procedural = mo == nil || p.motion == "idle"
    var rows = Array(0..<sp.h)
    if !procedural {} else if p.squash > 0 { for _ in 0..<min(p.squash, 3) where rows.count > 2 { rows.remove(at: rows.count / 2) } } else if p.squash < 0 { rows.insert(rows[rows.count / 2], at: rows.count / 2) }
    w = sp.w; h = rows.count; bottom = GY - p.lift; top = bottom - h + 1; left = cx - w / 2
    let flip = p.look < 0, legTop = sp.h - 4
    var face = sp.px
    for (ex, ey, ew, eh) in sp.eyes {                                    // Eyes: for closed and smiling eyes, cover the cell with the body color and draw one line
      guard p.eyes == .closed || p.eyes == .happy || p.eyes == .dizzy else { continue }
      for yy in ey..<(ey + eh) { for xx in ex..<(ex + ew) where xx < sp.w && yy < sp.h { face[yy * sp.w + xx] = ch.body } }
      let ly = p.eyes == .happy ? ey : ey + eh - 1
      for xx in ex..<(ex + ew) where xx < sp.w && ly < sp.h { face[ly * sp.w + xx] = ch.line }
      if p.eyes == .dizzy { for k in 0..<min(ew, eh) { face[(ey + k) * sp.w + ex + k] = ch.line; face[(ey + k) * sp.w + ex + ew - 1 - k] = ch.line } }
    }
    for (j, srcY) in rows.enumerated() {
      for i in 0..<sp.w {
        let c = face[srcY * sp.w + i]; guard c != 0 else { continue }
        let x = left + (flip ? sp.w - 1 - i : i)
        var y = top + j
        if procedural && srcY >= legTop && ((p.feet == 1 && i < sp.w / 2) || (p.feet == 2 && i >= sp.w / 2)) { y -= 1 }   // Leg lift
        cv.set(x, y, c)
      }
    }
    if p.fx > 0 { charaFX(&cv, ch.id.replacingOccurrences(of: "pack:", with: ""), p, sp.w, { left + (flip ? sp.w - 1 - $0 : $0) }, { top + $0 }) }
  } else {

  // Things drawn behind the body (the body covers the seam): sprout stem and leaves
  if ch.kind == .sprout {
    let leaf: [Character: UInt32] = ["o": rgba("#3f7a3a"), "g": ch.accent, "G": rgba("#b6e49c")]
    let sway = p.tail
    cv.sprite([".ooo.ooo.", "oGggoggGo", ".ooo.ooo.", "....o....", "....o...."], cx - 4 + sway, top - 5, leaf)
    cv.set(cx, top - 1, rgba("#3f7a3a"))
  }

  // Body: mask -> outline, highlight, shade
  var inside = [[Bool]](repeating: [Bool](repeating: false, count: w + 2), count: h + 2)
  for r in 0..<h {
    for c in 0..<w {
      let x = Double(c) + 0.5, y = Double(r) + 0.5
      var ok: Bool
      switch ch.kind {
      case .mandu:                                                         // Round dome with a flat bottom
        let dx = (x - Double(w) / 2) / (Double(w) / 2), dy = (y - Double(h)) / Double(h)
        ok = pow(abs(dx), 2.0) + pow(abs(dy), 1.7) <= 1
      case .acorn:                                                         // An egg that narrows toward the bottom
        let dx = (x - Double(w) / 2) / (Double(w) / 2), dy = (y - Double(h) * 0.45) / (Double(h) * (y < Double(h) * 0.45 ? 0.45 : 0.55))
        ok = pow(abs(dx), 2.4) + pow(abs(dy), 2.0) <= 1
      case .sprout:                                                        // Pot: the top 3 rows are the rim band, narrowing below
        ok = r < 3 ? !(r == 0 && (c == 0 || c == w - 1)) : abs(x - Double(w) / 2) <= Double(w) / 2 - 1 - Double(r - 3) * 0.3
      case .cloud:                                                         // Puffy: three round lumps
        func inC(_ cx0: Double, _ cy0: Double, _ rr: Double) -> Bool { hypot(x - cx0, (y - cy0) * 1.1) <= rr }
        let base = pow(abs((x - Double(w) / 2) / (Double(w) / 2)), 2.6) + pow(abs((y - Double(h) * 0.7) / (Double(h) * 0.3)), 2.0) <= 1
        ok = base || inC(Double(w) * 0.32, Double(h) * 0.52, Double(h) * 0.3) || inC(Double(w) * 0.63, Double(h) * 0.42, Double(h) * 0.4)
      case .candle:                                                        // A column with only the top corners clipped
        ok = !(r == 0 && (c == 0 || c == w - 1))
      case .pebble:
        let dx = (x - Double(w) / 2) / (Double(w) / 2), dy = (y - Double(h) * 0.55) / (Double(h) * (y < Double(h) * 0.55 ? 0.55 : 0.45))
        ok = pow(abs(dx), 2.2) + pow(abs(dy), 2.0) <= 1
      default:
        let dx = (x - Double(w) / 2) / (Double(w) / 2), dy = (y - Double(h) / 2) / (Double(h) / 2)
        ok = pow(abs(dx), 3.2) + pow(abs(dy), 3.2) <= 1
      }
      inside[r + 1][c + 1] = ok
    }
  }
  for r in 0..<h {
    for c in 0..<w where inside[r + 1][c + 1] {
      let edge = !inside[r][c + 1] || !inside[r + 2][c + 1] || !inside[r + 1][c] || !inside[r + 1][c + 2]
      var col = ch.body
      if edge { col = ch.line }
      else if ch.kind == .sprout && r == 2 { col = ch.shade }                 // Bottom line of the pot rim band
      else if ch.kind == .candle && r == 1 { col = ch.light }                 // Top surface of the melted wax
      else if ch.kind == .pebble && [(3, 5), (w - 4, 4), (w - 6, h - 3)].contains(where: { $0.0 == c && $0.1 == r }) { col = ch.shade }   // Stone pattern
      else if r >= 1 && r <= 2 && c >= 2 && c <= 3 { col = ch.light }
      else if r == h - 2 || (c == w - 2 && r > h / 3) { col = ch.shade }
      cv.set(left + c, top + r, col)
    }
  }

  // Things placed on top of the body: dumpling pleats, acorn cap, candle wick and flame, moss
  switch ch.kind {
  case .mandu:
    cv.sprite([".oo.", "obbo"], cx - 2, top - 1, pal)
    for (dx, dy) in [(-3, 1), (-4, 2), (-5, 3), (2, 1), (3, 2), (4, 3), (-1, 1), (0, 1)] { cv.set(cx + dx, top + dy, rgba("#c9b596")) }   // Pleats
  case .acorn:
    let capC = ch.accent, capS = rgba("#6b4127")
    for r in 0..<4 {
      let x0 = left - (r == 3 ? 1 : 0) + (r == 0 ? 2 : 0), x1 = left + w - 1 + (r == 3 ? 1 : 0) - (r == 0 ? 2 : 0)
      for x in x0...x1 {
        let edge = r == 0 || r == 3 || x == x0 || x == x1
        cv.set(x, top - 1 + r, edge ? ch.line : ((x + r) % 3 == 0 ? capS : capC))
      }
    }
    cv.rect(cx, top - 3, 1, 2, ch.line); cv.set(cx + 1, top - 3, ch.line)
  case .candle:
    cv.set(left + 2, top + 2, ch.light); cv.set(left + 2, top + 3, ch.light); cv.set(left + w - 3, top + 2, ch.light)   // Dripping wax
    cv.rect(cx, top - 2, 1, 2, ch.line)
    let fl: [Character: UInt32] = ["f": ch.accent, "F": rgba("#ffd04a"), "W": rgba("#fff6c8")]
    cv.sprite(p.tail == 0 ? [".f.", "fFf", "fFf", "FWF", ".F."] : ["..f", ".fF", "fFf", "FWF", ".F."], cx - 1, top - 7, fl)
  case .pebble:
    let moss: [Character: UInt32] = ["o": rgba("#4f7f3a"), "g": ch.accent, "G": rgba("#b8de8a")]
    cv.sprite(["..o.oo...", ".oGgggo..", "oggggggo.", ".ooggoo.."], cx - 5, top - 2, moss)
    cv.sprite([".w.", "wyw", ".w."], cx + 2, top - 4, ["w": WHITE, "y": rgba("#ffd34d")])
  default: break
  }

  // Feet
  if feet {
    let fc = ch.line
    if p.feet == 3 { cv.rect(cx - 5, GY - p.lift + 1, 2, 1, fc); cv.rect(cx + 3, GY - p.lift + 1, 2, 1, fc) }
    else {
      if p.feet != 1 { cv.rect(cx - 5, GY - p.lift, 3, 1, fc) }
      if p.feet != 2 { cv.rect(cx + 2, GY - p.lift, 3, 1, fc) }
    }
  }

  // Face
  let ey = top + Int(Double(h) * 0.42) + (p.down ? 2 : 0) - (p.up ? 1 : 0), e1 = cx - 3 + p.look * (p.down ? 2 : 1), e2 = cx + 2 + p.look * (p.down ? 2 : 1)
  for e in [e1, e2] {
    switch p.eyes {
    case .open: cv.set(e, ey, INK); cv.set(e, ey + 1, INK)
    case .closed: cv.set(e - (e == e1 ? 1 : 0), ey + 1, INK); cv.set(e + (e == e1 ? 0 : 1), ey + 1, INK)
    case .happy: cv.set(e - 1, ey + 1, INK); cv.set(e, ey, INK); cv.set(e + 1, ey + 1, INK)
    case .wide: cv.rect(e, ey, 2, 2, INK); cv.set(e, ey, WHITE)
    case .dizzy: cv.set(e - 1, ey - 1, INK); cv.set(e + 1, ey - 1, INK); cv.set(e, ey, INK); cv.set(e - 1, ey + 1, INK); cv.set(e + 1, ey + 1, INK)
    }
  }
  let ck = ch.kind == .mandu ? ch.accent : CHEEK
  cv.rect(e1 - (p.blush ? 3 : 2), ey + 2, p.blush ? 3 : 2, p.blush ? 2 : 1, ck)
  cv.rect(e2 + 2, ey + 2, p.blush ? 3 : 2, p.blush ? 2 : 1, ck)
  let mx = (e1 + e2) / 2
  if p.talk { cv.rect(mx, ey + 3, 2, 2, rgba("#7a3040")); cv.set(mx, ey + 4, rgba("#e0708e")) }
  else if p.eyes == .wide { cv.set(mx, ey + 3, INK); cv.set(mx + 1, ey + 3, INK) }
  else if p.eyes == .happy { cv.rect(mx, ey + 3, 2, 1, rgba("#c2475a")) }
  else { cv.set(mx, ey + 3, INK); cv.set(mx + 1, ey + 3, INK) }

  }
  cv.top = ch.sprite != nil ? ((0..<CH).first { y in (0..<CW).contains { cv.px[y * CW + $0] != 0 } } ?? top) : top - (KIND_TOP[ch.kind] ?? 0)
  drawProps(&cv, ch, p, cx)
  // Laptop (the back of the lid seen from the front) + typing hands
  if p.laptop >= 0 {
    let gr = rgba("#9aa0aa"), gd = rgba("#6a6f78"), lx = cx - 5
    cv.rect(lx, GY - 5, 11, 5, gd); cv.rect(lx + 1, GY - 4, 9, 3, gr); cv.set(cx, GY - 3, rgba("#e8f6fb"))
    cv.rect(lx - 1, GY, 13, 1, gd)
    if p.motion != "work" {                          // If the pack has a work sprite, that sprite draws the hands (avoids overlap)
      let a = p.laptop == 0 ? 0 : 1
      cv.rect(cx - 6, GY - 6 + a, 2, 2, ch.body); cv.set(cx - 6, GY - 6 + a, ch.line)
      cv.rect(cx + 5, GY - 7 + (1 - a), 2, 2, ch.body); cv.set(cx + 6, GY - 7 + (1 - a), ch.line)
    }
  }

  // Speech bubble (for the preview image; the app draws it with noticeImage, in the same shape and dot size as the bubble)
  if p.bubble != .none && CANVAS_BUBBLE {
    let edge = rgba("#5a4334")
    let digits = p.count > 1 ? String(min(p.count, 99)) : ""
    let bw = 11 + digits.count * 4, bx = cx - bw / 2, by = max(0, top - 13 - max(0, (KIND_TOP[ch.kind] ?? 0) - 2))
    let fill = p.bubble == .ask ? rgba("#fbf0d2") : p.bubble == .check ? rgba("#e9f6df") : rgba("#fffaf0")
    cv.rect(bx + 1, by, bw - 2, 9, edge); cv.rect(bx, by + 1, bw, 7, edge); cv.rect(bx + 1, by + 1, bw - 2, 7, fill)
    cv.rect(cx - 1, by + 9, 2, 1, edge); cv.set(cx - 1, by + 8, fill); cv.set(cx, by + 8, fill)
    switch p.bubble {
    case .check: cv.sprite(["....g", "...g.", "g.g..", ".g..."], bx + 3, by + 3, ["g": rgba("#3f8a4a")])
    case .ask: cv.sprite(["kkk", "..k", ".k.", "...", ".k."], bx + 4, by + 2, ["k": rgba("#9a7414")])
    case .dots: for k in 0..<3 { cv.set(bx + 3 + k * 2, by + 5, edge) }
    case .bang: cv.rect(bx + 5, by + 2, 1, 3, rgba("#c9504a")); cv.set(bx + 5, by + 6, rgba("#c9504a"))
    case .none: break
    }
    for (i, d) in digits.enumerated() { cv.sprite(DIGITS[Int(String(d))!], bx + 9 + i * 4, by + 2, ["k": INK]) }
  }
  if p.z >= 0 {
    let c = rgba("#6a6fa8", p.z < 0.75 ? 1 : (1 - p.z) * 4)
    cv.sprite(["zzz", "..z", ".z.", "zzz"], cx + 5 + Int(sin(p.z * 6) * 1.5), top - 4 - Int(p.z * 8), ["z": c])
  }
  if p.hands {                                       // Two hands raised above the head (hands gripping an edge)
    for hx in [cx - 5, cx + 3] { cv.rect(hx, top - 3, 2, 3, ch.body); cv.set(hx, top - 3, ch.line); cv.set(hx + 1, top - 3, ch.line) }
  }
  if p.wave >= 0 {                                   // Waving the right arm (2x3 arm, outlined)
    let hy = top + 1 - p.wave * 2
    cv.sprite([".oo.", "obbo", "obbo", ".oo."], left + w - 1, hy, pal); cv.set(left + w - 1, hy + 4, ch.line)   // A round raised hand
  }
  if p.cover && ch.sprite == nil {                   // Covering the eyes with both hands
    let ey2 = top + Int(Double(h) * 0.42)
    for hx in [cx - 5, cx + 1] { cv.rect(hx, ey2 - 1, 4, 3, ch.light); cv.rect(hx + 1, ey2 - 2, 2, 1, ch.line); cv.set(hx, ey2 - 1, ch.line); cv.set(hx + 3, ey2 - 1, ch.line) }   // Two round hands
  }
  if p.icon > 0 {                                    // Light bulb or question mark above the head (small dots)
    let ix = cx + 5, iy = max(0, cv.top - 9 - p.iconBob)
    if p.icon == 1 {
      cv.sprite([".yyy.", "yywyy", "yyyyy", "yyyyy", ".yyy.", ".ggg.", "..g.."], ix, iy, ["y": rgba("#ffd84a"), "w": rgba("#fff6c2"), "g": rgba("#8a8f99")])
      if p.iconBob == 0 { for (dx, dy) in [(-2, 1), (6, 1), (2, -2)] { cv.set(ix + dx, iy + dy, rgba("#ffe58a")) } }   // Sparkle rays
    } else {
      cv.sprite([".qqq.", "qq.qq", "...qq", "..qq.", "..q..", ".....", "..q.."], ix, iy, ["q": rgba("#4f7ad0")])
    }
  }
  if p.angry {                                       // Red anger vein beside the head
    cv.sprite(["rr.rr", "r...r", ".....", "r...r", "rr.rr"], cx + 4, max(0, (cv.top) - 3), ["r": rgba("#e0505a")])
  }
  if p.snot >= 0 {                                   // Snot bubble (inflates with breathing, pops now and then)
    let r = 1 + p.snot * 2.2, bx = Double(cx + 3) + r, by = Double(top + h / 2 + 1)
    for yy in Int(by - r - 1)...Int(by + r + 1) { for xx in Int(bx - r - 1)...Int(bx + r + 1) {
      let d = hypot(Double(xx) + 0.5 - bx, Double(yy) + 0.5 - by)
      if d <= r + 0.5 { cv.set(xx, yy, d > r - 0.6 ? rgba("#9fc6ea") : rgba("#e8f4ff", 0.75)) }
    } }
    cv.set(Int(bx - r * 0.4), Int(by - r * 0.4), WHITE)
  }
  if p.confetti >= 0 {                               // Six pieces of celebration confetti flutter down
    for k in 0..<6 {
      let q = p.confetti, x0 = cx - 11 + k * 4 + (k % 2 == 0 ? 0 : 1)
      let yy = top - 12 + Int(q * 14) + (k * 5) % 4, sway = Int(sin(q * 9 + Double(k)) * 1.4)
      let c = rgba(["#f06b8a", "#f6dc6a", "#4f9ad0"][k % 3], q < 0.7 ? 1 : (1 - q) / 0.3)
      cv.set(x0 + sway, yy, c); if k % 2 == 0 { cv.set(x0 + sway + 1, yy, c) }
    }
  }
  if p.snow >= 0 {                                   // Six snowflakes drift down past the pet; two of them are little crosses
    let cols = [2, 8, 13, 19, 24, 29], flake = rgba("#ffffff"), arm = rgba("#cfe0f4")
    for (k, x0) in cols.enumerated() {
      let q = (p.snow + Double(k) * 0.37).truncatingRemainder(dividingBy: 1)
      let x = x0 + Int((sin(q * 7 + Double(k) * 1.3) * 1.3).rounded()), y = Int(q * Double(GY + 3)) - 3
      guard y >= 0, y < GY else { continue }
      if k % 3 == 1 { for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { cv.set(x + dx, y + dy, arm) } }
      cv.set(x, y, flake)
    }
  }
  if p.hearts >= 0 {
    for k in 0..<2 {
      let q = p.hearts - Double(k) * 0.3
      guard q >= 0 && q <= 1 else { continue }
      let c = rgba("#f06b8a", q < 0.7 ? 1 : (1 - q) / 0.3)
      cv.sprite([".h.h.", "hhhhh", ".hhh.", "..h.."], cx - 2 + (k == 0 ? -5 : 4) + Int(sin(q * 7) * 1.5), top - 3 - Int(q * 12), ["h": c])
    }
  }
  if p.notes >= 0 {                                  // Two music notes rise alternately
    let cols = [rgba("#7a6ad8"), rgba("#e0708e"), rgba("#4f9ad0")]
    for k in 0..<2 {
      let q = (p.notes + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
      let c = cols[(Int(p.notes * 3) + k) % 3] & 0xffffff00 | UInt32(255 * (q < 0.7 ? 1 : (1 - q) / 0.3))
      let a = c & 0xff, pre = (((c >> 24) & 0xff) * a / 255) << 24 | (((c >> 16) & 0xff) * a / 255) << 16 | (((c >> 8) & 0xff) * a / 255) << 8 | a
      let rows = k == 0 ? ["..nn", "..n.", "..n.", "nnn.", "nn.."] : [".nnnn", ".n..n", ".n..n", "nn.nn", "nn.nn"]
      cv.sprite(rows, cx + (k == 0 ? 6 : -11) + Int(sin(q * 6 + Double(k)) * 2), top - 2 - Int(q * 11), ["n": pre])
    }
  }
  if p.sparkle >= 0 {
    let c = rgba("#f6dc6a", 1 - p.sparkle)
    for k in 0..<4 {
      let a = Double(k) * .pi / 2 + p.sparkle * 2, r = 8 + p.sparkle * 6
      cv.set(cx + Int(cos(a) * r), top + 3 - Int(sin(a) * r * 0.7), c)
    }
  }
  if p.dust >= 0 {                                   // Landing dust: spreads to both sides and fades
    let c = rgba("#a3968a", 1 - p.dust * 0.8), d = Int(p.dust * 5)
    for sd in [-1, 1] {
      cv.set(cx + sd * (6 + d), GY, c); cv.set(cx + sd * (7 + d), GY - 1 - Int(p.dust * 2), c)
      if p.dust < 0.5 { cv.set(cx + sd * (5 + d), GY - 1, c) }
    }
  }
  if p.sweat >= 0 {                                  // Sweat drop (running down beside the head)
    let a = p.sweat < 0.7 ? 1 : (1 - p.sweat) / 0.3
    cv.sprite([".d.", "dld", "ddd", ".d."], left + w - 1, top + Int(p.sweat * 4), ["d": rgba("#4f9ad0", a), "l": rgba("#d6f0ff", a)])
  }
  if p.sink > 0 {                                    // Sinking into the floor: pushes down; nothing is drawn below the floor (GY)
    var out = Canvas()
    for y in 0..<CH { for x in 0..<CW { let c = cv.px[y * CW + x]; if c != 0, y + p.sink <= GY { out.set(x, y + p.sink, c) } } }
    out.top = cv.top + p.sink
    return out
  }
  if p.rot % 4 != 0 {                                // Rolling: 90 degrees at a time around the center of the body
    var out = Canvas()
    let ox = 16, oy = GY - 6
    for y in 0..<CH { for x in 0..<CW {
      let c = cv.px[y * CW + x]; guard c != 0 else { continue }
      let dx = x - ox, dy = y - oy
      let (nx, ny): (Int, Int) = { switch (p.rot % 4 + 4) % 4 { case 1: return (ox - dy, oy + dx); case 2: return (ox - dx, oy - dy); default: return (ox + dy, oy - dx) } }()
      out.set(nx, ny, c)
    } }
    out.top = cv.top
    return out
  }
  return cv
}
