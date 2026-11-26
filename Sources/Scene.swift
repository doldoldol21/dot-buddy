// Finding the floor: screen bottom first, then widgets and window tops
import AppKit
import CoreText
import ServiceManagement

// ---------- Floor: screen bottom (above the Dock) + widget tops + app window tops: only the spans not covered by other windows ----------
// The window list reads only position and size, without permission (CGWindowList; names are not read). Front windows come first.
enum FloorKind { case base, widget, window }
struct Floor {
  let id: String, owner: String, kind: FloorKind
  let y: CGFloat, x0: CGFloat, x1: CGFloat
  var bottom: CGFloat = 0                 // Bottom edge of the widget or window (for climbing the side and sliding down)
  var edgeL = false, edgeR = false        // Whether the span ends are real corners (otherwise a wall blocked by a front window)
  var rect = CGRect.zero                  // The whole widget or window (spans are only the visible part, so corner checks use this)
  var widget: Bool { kind != .base }
  var mid: CGFloat { (x0 + x1) / 2 }
}
struct Scene { var floors: [Floor] = []; var walls: [CGRect] = []; var order: [Int] = []; var widgetLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 3 }
typealias Scr = (frame: CGRect, visible: CGRect)
func screensNow() -> [Scr] { NSScreen.screens.map { ($0.frame, $0.visibleFrame) } }   // Measured on the main thread and passed in
/// Rough estimate of the Dock bar position: the Dock window covers the whole screen, so the bar size cannot be known (exactly would need Accessibility permission).
/// On a screen where the bottom Dock has taken its space, centered at: slot count (Finder + pinned apps + running apps + right-side slots + Trash) x (icon + 4) + 32
/// The set of regular apps that show an icon in the Dock. NSRunningApplication properties cost an XPC round trip on every read (tens of ms per Dock estimate),
/// so scan once at first and afterwards update only from the notifications sent when apps launch and quit
var regularSet: Set<String>?
let regularLock = NSLock()
func regularApps() -> Set<String> {
  regularLock.lock(); defer { regularLock.unlock() }
  if let s = regularSet { return s }
  let s = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
  regularSet = s
  let nc = NSWorkspace.shared.notificationCenter
  nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { n in
    guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.activationPolicy == .regular, let id = a.bundleIdentifier else { return }
    regularLock.lock(); regularSet?.insert(id); regularLock.unlock()
  }
  nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { n in
    guard let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
    regularLock.lock(); regularSet?.remove(id); regularLock.unlock()
  }
  return s
}
/// The Dock bar's frame as the Dock itself reports it (private CoreDock call in the system frameworks; no permission). The slot estimate below missed
/// minimized windows and separators, so the bar's ends were 50 to 110 points wider than it thought and the pet stood behind them (2026-11-23).
/// nil if the call is missing or fails; then the estimate is used.
private typealias DockRectFn = @convention(c) (UnsafeMutablePointer<CGRect>) -> Void   // Its return value is not a status (it read 0 or junk), so the rect itself is checked
private let coreDockGetRect: DockRectFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockGetRect").map { unsafeBitCast($0, to: DockRectFn.self) }
func dockRectNow() -> CGRect? {
  guard let f = coreDockGetRect else { return nil }
  var r = CGRect.zero
  f(&r)
  return r.width.isFinite && r.height.isFinite && r.width > 20 && r.height > 20 ? r : nil
}
func dockEstimate(_ scrs: [Scr]) -> CGRect? {
  guard let d = UserDefaults(suiteName: "com.apple.dock") else { return nil }
  let o = d.string(forKey: "orientation") ?? "bottom"
  let side = o == "left" || o == "right"
  guard let s = scrs.first(where: { side ? (o == "left" ? $0.visible.minX > $0.frame.minX + 8 : $0.visible.maxX < $0.frame.maxX - 8) : $0.visible.minY > $0.frame.minY + 8 }) else { return nil }
  if let r = dockRectNow() {                           // The Dock's own frame (top-left origin) when it answers
    let H = scrs[0].frame.height, b = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
    if s.frame.intersects(b) { return side ? b.insetBy(dx: 4, dy: 0) : CGRect(x: b.minX, y: b.minY + 4, width: b.width, height: b.height - 8) }
  }
  let pinned = Set((d.array(forKey: "persistent-apps") as? [[String: Any]] ?? []).compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String })
  let running = regularApps()
  let apps = 1 + pinned.subtracting(["com.apple.finder"]).count + running.subtracting(pinned).subtracting(["com.apple.finder"]).count
  let right = (d.array(forKey: "persistent-others") ?? []).count + 1 + ((d.object(forKey: "show-recents") as? Bool ?? true) ? 1 : 0)
  let tile = CGFloat(d.double(forKey: "tilesize") > 0 ? d.double(forKey: "tilesize") : 48)
  let len = CGFloat(apps + right) * (tile + 4) + 32
  if side {                                                                         // Vertical bar: centered vertically beside the screen edge; the top is a small platform, the side is a wall
    let th = o == "left" ? s.visible.minX - s.frame.minX : s.frame.maxX - s.visible.maxX, L = min(s.visible.height - 20, len)
    return CGRect(x: o == "left" ? s.frame.minX + 4 : s.frame.maxX - th + 4, y: s.visible.midY - L / 2, width: th - 8, height: L)
  }
  let w = min(s.frame.width - 20, len), h = s.visible.minY - s.frame.minY
  return CGRect(x: s.frame.midX - w / 2, y: s.frame.minY + 4, width: w, height: h - 8)
}
func scanScene(petH: CGFloat, halfW: CGFloat, scrs: [Scr] = screensNow(), dock: CGRect? = nil) -> Scene {
  var sc = Scene()
  guard let primary = scrs.first else { return sc }
  let H = primary.frame.height, me = ProcessInfo.processInfo.processIdentifier
  let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
  var wins: [(Int, CGRect)] = [], widgets: [(Int, CGRect)] = [], wlv: [Int] = []
  for w in list {
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], (w[kCGWindowOwnerPID as String] as? Int32) != me else { continue }
    let r = CGRect(x: b["X"] ?? 0, y: H - (b["Y"] ?? 0) - (b["Height"] ?? 0), width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    let layer = w[kCGWindowLayer as String] as? Int ?? 0, owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let num = w[kCGWindowNumber as String] as? Int ?? 0, alpha = w[kCGWindowAlpha as String] as? Double ?? 1
    if owner == "Notification Center" && layer < 0 {
      wlv.append(layer)
      if r.width > 40 && r.width < 1200 && r.height > 40 && r.height < 1200 { widgets.append((num, r)) }
    } else if layer == 0 && alpha > 0.05 && r.width >= 120 && r.height >= 60 { wins.append((num, r)) }
  }
  if let m = wlv.max() { sc.widgetLevel = m + 1 }
  sc.walls = wins.map(\.1); sc.order = wins.map(\.0)                          // Front-to-back order (changes when a window is clicked to bring it forward)                                                   // The window side the pet hits when thrown
  // From the horizontal span [x0,x1], subtract the x ranges of covering windows. Only windows overlapping the strip the pet body fits in (y to y+petH) cover it
  func visible(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat, _ blockers: ArraySlice<(Int, CGRect)>) -> [(CGFloat, CGFloat, Bool, Bool)] {
    var segs: [(CGFloat, CGFloat, Bool, Bool)] = [(x0, x1, true, true)]
    for (_, b) in blockers where b.maxY > y - 2 && b.minY < y + petH {
      var next: [(CGFloat, CGFloat, Bool, Bool)] = []
      for s in segs {
        if b.maxX <= s.0 || b.minX >= s.1 { next.append(s); continue }
        if b.minX > s.0 { next.append((s.0, b.minX, s.2, false)) }
        if b.maxX < s.1 { next.append((b.maxX, s.1, false, s.3)) }
      }
      segs = next
    }
    return segs.filter { $0.1 - $0.0 >= halfW * 2 + 8 }
  }
  let all = wins[...]
  // The floor is the very bottom of the screen (goes down to the Dock). Where a Dock bar exists, the top of the bar becomes its own floor
  let blockers = dock.map { all + [(0, $0)] } ?? Array(all)
  for (i, s) in scrs.enumerated() {
    let y = s.frame.minY
    let segs = visible(y, s.visible.minX, s.visible.maxX, blockers[...])
    for (k, v) in segs.enumerated() {
      sc.floors.append(Floor(id: "s\(i):\(k)", owner: "s\(i)", kind: .base, y: y, x0: v.0, x1: v.1))
    }
    // Even if the whole screen bottom is covered (maximized, full screen), leave one place to stand; without it the pet falls forever
    if segs.isEmpty { sc.floors.append(Floor(id: "s\(i):x", owner: "s\(i)", kind: .base, y: s.visible.minY, x0: s.visible.minX, x1: s.visible.maxX)) }
  }
  if let d = dock {                                                          // Top of the Dock bar: the pet climbs up and walks and sits on it like a widget.
    sc.walls.append(d)                                                       // The whole top counts: the Dock is in front of every window and so is a pet on it
    for (k, v) in visible(d.maxY, d.minX, d.maxX, all[all.endIndex...]).enumerated() {
      sc.floors.append(Floor(id: "dock:\(k)", owner: "dock", kind: .widget, y: d.maxY, x0: v.0, x1: v.1, bottom: d.minY - 4, edgeL: v.2, edgeR: v.3, rect: d))
    }
  }
  /// Clip widget and window tops to that screen (so the pet does not walk off screen or stand below the Dock)
  func clip(_ r: CGRect) -> (Scr, CGFloat, CGFloat)? {
    let over = { (f: CGRect) -> CGFloat in (f.minY <= r.maxY && r.maxY <= f.maxY) ? min(r.maxX, f.maxX) - max(r.minX, f.minX) : -1 }
    guard let scr = scrs.max(by: { over($0.frame) < over($1.frame) }), over(scr.frame) > 0 else { return nil }
    let v = scr.visible
    guard r.maxY + petH < v.maxY, r.maxY > v.minY + 8 else { return nil }      // Below the menu bar (maximized windows) or below the Dock height is no place to stand
    let x0 = max(r.minX, v.minX), x1 = min(r.maxX, v.maxX)
    return x1 - x0 >= halfW * 2 + 8 ? (scr, x0, x1) : nil
  }
  for (num, r) in widgets {
    guard let (cs, cx0, cx1) = clip(r) else { continue }
    let roomL = r.minX - halfW * 2 >= cs.frame.minX, roomR = r.maxX + halfW * 2 <= cs.frame.maxX   // Room for the body outside the corner (does not hang from the corner of a widget flush with the screen edge)
    for (k, v) in visible(r.maxY, cx0, cx1, all).enumerated() {
      sc.floors.append(Floor(id: "g\(num):\(k)", owner: "g\(num)", kind: .widget, y: r.maxY, x0: v.0, x1: v.1, bottom: r.minY, edgeL: v.2 && v.0 == r.minX && roomL, edgeR: v.3 && v.1 == r.maxX && roomR, rect: r))
    }
  }
  for (i, (num, r)) in wins.enumerated() {
    guard let (cs, cx0, cx1) = clip(r) else { continue }
    let roomL = r.minX - halfW * 2 >= cs.frame.minX, roomR = r.maxX + halfW * 2 <= cs.frame.maxX
    for (k, v) in visible(r.maxY, cx0, cx1, all[..<i]).enumerated() {   // Standing on a window puts the pet on the layer just above that window: only windows in front of that window cover it
      sc.floors.append(Floor(id: "w\(num):\(k)", owner: "w\(num)", kind: .window, y: r.maxY, x0: v.0, x1: v.1, bottom: r.minY, edgeL: v.2 && v.0 == r.minX && roomL, edgeR: v.3 && v.1 == r.maxX && roomR, rect: r))
    }
  }
  return sc
}
