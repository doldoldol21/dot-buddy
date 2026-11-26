// Demo GIFs for the README, drawn offscreen with the app's own sprite and bubble renderers (no screen recording, nothing private on screen).
//   DotBuddy --demo-gif <out.gif> [hero|characters|chara:<id>]   (chara:<id> = a short loop of one character, used for community previews)
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One pet dot = P pixels, one bubble dot = B pixels (Galmuri small at 2x: the same ratio the app uses on a Retina screen)
private let P = 4, B = 3, FPS = 12.0

private struct Stage {
  let W: Int, H: Int, floorY: Int
  let ctx: CGContext
  init(_ w: Int, _ h: Int, floorY: Int) {
    W = w; H = h; self.floorY = floorY
    ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: RGB_SPACE, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
  }
  /// A calm desktop: soft gradient, one app window on the right, the Dock edge as the floor
  func backdrop(window: CGRect? = nil) {
    let top = CGColor(red: 0.80, green: 0.87, blue: 0.95, alpha: 1), bottom = CGColor(red: 0.95, green: 0.90, blue: 0.84, alpha: 1)
    let g = CGGradient(colorsSpace: RGB_SPACE, colors: [bottom, top] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: H), options: [])
    if let r = window {
      ctx.setFillColor(CGColor(gray: 0, alpha: 0.10)); ctx.addPath(CGPath(roundedRect: r.offsetBy(dx: 0, dy: -4), cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
      ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
      ctx.setFillColor(CGColor(gray: 0.93, alpha: 1)); ctx.fill(CGRect(x: r.minX, y: r.maxY - 30, width: r.width, height: 18))
      ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX, y: r.maxY - 30, width: r.width, height: 30), cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
      for (i, c) in [(0.99, 0.37, 0.34), (0.99, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1)); ctx.fillEllipse(in: CGRect(x: r.minX + 14 + CGFloat(i) * 20, y: r.maxY - 21, width: 12, height: 12))
      }
      ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))                         // a few lines of "terminal output"
      for (i, w) in [0.7, 0.5, 0.82, 0.38, 0.6].enumerated() where r.maxY - 52 - CGFloat(i) * 20 > r.minY + 10 {
        ctx.fill(CGRect(x: r.minX + 18, y: r.maxY - 52 - CGFloat(i) * 20, width: (r.width - 36) * w, height: 8))
      }
    }
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.55)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: floorY))
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.08)); ctx.fill(CGRect(x: 0, y: floorY, width: W, height: 1))
  }
  /// The pet canvas (32×40 dots, feet on row GY) with its feet at (x, footY) in pixels. Returns the y of the top of its head
  @discardableResult func pet(_ ch: Chara, _ p: Pose, x: Int, footY: Int) -> Int {
    let cv = draw(ch, p)
    guard let img = cv.image() else { return footY }
    ctx.draw(img, in: CGRect(x: x - 16 * P, y: footY - (CH - 1 - GY) * P, width: CW * P, height: CH * P))
    return footY + (GY - cv.top) * P
  }
  /// A bubble centered above (cx, bottomY)
  func bubble(_ img: CGImage?, cx: Int, bottomY: Int) {
    guard let img else { return }
    ctx.draw(img, in: CGRect(x: cx - img.width * B / 2, y: bottomY, width: img.width * B, height: img.height * B))
  }
  /// A bubble whose left edge is at x
  func bubble(_ img: CGImage?, left x: Int, bottomY: Int) {
    guard let img else { return }
    ctx.draw(img, in: CGRect(x: x, y: bottomY, width: img.width * B, height: img.height * B))
  }
  func frame() -> CGImage { ctx.makeImage()! }
}

private func writeGIF(_ frames: [CGImage], to path: String) -> Bool {
  guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return false }
  CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
  for f in frames { CGImageDestinationAddImage(dst, f, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / FPS]] as CFDictionary) }
  return CGImageDestinationFinalize(dst)
}

/// Pose for a pack motion at time t (frame from the pack's own fps)
private func packPose(_ ch: Chara, _ motion: String, _ t: Double, look: Int = 1) -> Pose {
  var p = Pose(); p.motion = motion; p.look = look
  if let m = ch.sprite?.motions[motion] { p.frame = Int(t * m.fps) }
  return p
}

func demoGIF(_ out: String, scene: String) -> Bool {
  registerFont(); CANVAS_BUBBLE = false
  FONT_FAMILY = FONT_FAMILIES.firstIndex { $0.id == "galmuri" } ?? 0; TEXT_SIZE = 1
  ALL_CHARAS = mergeCharas(loadCustomCharas())
  let paper = cg("#fffaf0"), edge = cg("#5a4334"), ink = cg("#3a2a24"), green = cg("#3f8a4a"), gold = cg("#9a7414")
  var frames: [CGImage] = []
  switch scene {
  case "characters":
    let ids = ["mandu", "acorn", "sprout", "cloud", "candle", "pebble"], st = Stage(720, 200, floorY: 36)
    let acts = ["idle", "wave", "walk", "cheer", "work", "hum"]
    for i in 0..<Int(FPS * 6) {
      let t = Double(i) / FPS
      st.backdrop()
      for (k, id) in ids.enumerated() {
        let ch = findChara(id), m = acts[(k + Int(t / 1.5)) % acts.count]
        var p = packPose(ch, m, t + Double(k) * 0.3)
        if m == "work" { p.laptop = Int(t * 6) % 2 }
        st.pet(ch, p, x: 60 + k * 120, footY: st.floorY)
      }
      frames.append(st.frame())
    }
  case let s where s.hasPrefix("chara:"):                                         // one character: idle → walk → work → cheer → wave, for the community gallery
    let id = String(s.dropFirst(6))
    let bare = { (s: String) in s.replacingOccurrences(of: "pack:", with: "").replacingOccurrences(of: "custom:", with: "") }
    guard ALL_CHARAS.contains(where: { $0.id == id || bare($0.id) == bare(id) }) else { return false }   // a pack can stand in for a built-in of the same name
    let ch = findChara(id), st = Stage(220, 120, floorY: 12)
    let acts = ["idle", "walk", "work", "cheer", "wave"], each = 1.6
    for i in 0..<Int(FPS * each * Double(acts.count)) {
      let t = Double(i) / FPS, k = Int(t / each), m = acts[k], u = t - Double(k) * each
      st.backdrop()
      var p = packPose(ch, m, t)
      if m == "work" { p.laptop = Int(t * 6) % 2 }
      let x = m == "walk" ? 80 + Int(60 * u / each) : (k > 1 ? 140 : 80)
      st.pet(ch, p, x: x, footY: st.floorY)
      frames.append(st.frame())
    }
  default:                                                                       // hero: stroll along a window's top edge → work → done (✓) → question (?)
    let ch = findChara("mandu"), st = Stage(720, 360, floorY: 20)
    let win = CGRect(x: 300, y: 34, width: 380, height: 120), top = Int(win.maxY)
    let walkFrom = 330, walkTo = 470
    let done = noticeImage([("api-server", ink), (T("끝났어요!", "Done!"), green)], fill: paper, edge: edge)
    let badge = noticeImage([("1", green)], fill: cg("#e9f6df"), edge: edge, check: true)
    let ask = noticeImage([("web-app", ink), (T("물어볼 게 있대요", "Has a question for you"), gold)], fill: cg("#fbf0d2"), edge: edge)
    let say = T("테스트 돌리는 중~", "Running the tests~")
    for i in 0..<Int(FPS * 12) {
      let t = Double(i) / FPS
      st.backdrop(window: win)
      switch t {
      case ..<2.5:                                                               // stroll along the window's top edge
        let x = walkFrom + Int(Double(walkTo - walkFrom) * t / 2.5)
        st.pet(ch, packPose(ch, "walk", t), x: x, footY: top)
      case ..<5.5:                                                               // the agent is working: laptop out, a little chatter
        var p = packPose(ch, "work", t); p.laptop = Int(t * 6) % 2
        let head = st.pet(ch, p, x: walkTo, footY: top)
        if t > 3.0 { st.bubble(noticeImage([(say, ink)], fill: cg("#ffffff"), edge: cg("#8a7a68"), reveal: Int((t - 3.0) * 14) + 1), cx: walkTo, bottomY: head + 6) }
      case ..<9:                                                                 // done: a hop, confetti, the notice and the ✓ badge
        var p = packPose(ch, "cheer", t); p.confetti = min(1, (t - 5.5) / 1.6); p.fx = 2; p.fxK = min(1, (t - 5.5) / 2)
        let hop = t - 5.5 < 0.4 ? Int(sin((t - 5.5) / 0.4 * .pi) * 20) : 0
        let head = st.pet(ch, p, x: walkTo, footY: top + hop) - hop
        st.bubble(done, cx: walkTo, bottomY: head + 6)
        st.bubble(badge, left: walkTo + (done?.width ?? 0) * B / 2 + 8, bottomY: head + 6)
      default:                                                                   // another session asks a question: wave and wait
        let head = st.pet(ch, packPose(ch, "wave", t), x: walkTo, footY: top)
        st.bubble(ask, cx: walkTo, bottomY: head + 6)
      }
      frames.append(st.frame())
    }
  }
  return writeGIF(frames, to: out)
}
