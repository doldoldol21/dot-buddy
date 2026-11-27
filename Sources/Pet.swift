// The pet window and a single pet (movement, reactions, notifications, menu)
import AppKit
import CoreText
import ServiceManagement

// ---------- Pet window ----------
final class PetWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  // Keeps the system from treating this as a draggable window, so dragging to an edge doesn't show the macOS window-tiling (half-snap) overlay. The app moves the position itself
  override var isMovable: Bool { get { false } set {} }
  override var isMovableByWindowBackground: Bool { get { false } set {} }
  // Window managers (Rectangle, Magnet, etc.) use Accessibility (AX) to find draggable windows and snap them to screen edges; the pet window is not exposed to AX
  override func isAccessibilityElement() -> Bool { false }
  override func accessibilityRole() -> NSAccessibility.Role? { .unknown }
  // Window server load (test mode ticks line): moving or reordering a window keeps the window server much busier than redrawing the image (at 24 per second, WindowServer +8~12 points, measured 2026-11-17)
  static var moves = 0, bubbleMoves = 0, orders = 0, inMove = false             // Can call each other internally, so count only once
  var isPet = false
  func countMove() { if isPet { PetWindow.moves += 1 } else { PetWindow.bubbleMoves += 1 } }
  override func setFrameOrigin(_ p: NSPoint) { let o = PetWindow.inMove; if !o { countMove() }; PetWindow.inMove = true; super.setFrameOrigin(p); PetWindow.inMove = o }
  override func setFrame(_ r: NSRect, display: Bool) { let o = PetWindow.inMove; if !o { countMove() }; PetWindow.inMove = true; super.setFrame(r, display: display); PetWindow.inMove = o }
  var orderGen = 0                                                                // Number of times this window's order/level changed; used to see whether the speech bubble must be re-attached
  override var level: NSWindow.Level { didSet { if level != oldValue { orderGen += 1 } } }
  override func order(_ m: NSWindow.OrderingMode, relativeTo n: Int) { PetWindow.orders += 1; orderGen += 1; super.order(m, relativeTo: n) }
  override func orderFrontRegardless() { PetWindow.orders += 1; orderGen += 1; super.orderFrontRegardless() }
  override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
  // AppKit pushes a window whose top would go under the menu bar back down below it. The pet window is taller than the pet (padding above the head),
  // so a pet standing on a window just below the menu bar was drawn about 30pt lower, inside that window (on Slack's title bar, 2026-11-25). The app places these windows itself
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
final class PetApp: NSApplication {
  override func accessibilityWindows() -> [Any]? { [] }
  override func accessibilityChildren() -> [Any]? { [] }
  override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
}
final class PetView: DotLayerView {
  weak var pet: Pet?
  override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
  override func mouseDown(with e: NSEvent) { pet?.grab(e) }
  override func mouseDragged(with e: NSEvent) { pet?.dragTo() }
  override func mouseUp(with e: NSEvent) { pet?.release() }
  override func rightMouseDown(with e: NSEvent) { pet?.showMenu() }
  // Drop a character (.zip, folder or .png) on the pet to install it
  private func dropped(_ s: NSDraggingInfo) -> [URL] {
    (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter(droppableChara)
  }
  override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { dropped(s).isEmpty ? [] : .copy }
  override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { dropped(s).isEmpty ? [] : .copy }
  override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
    guard let u = dropped(s).first else { return false }
    pet?.installChara(u); return true
  }
}

enum React: CaseIterable { case hop, spin, heart, squish, dizzy, wave, shy, star, pout, party, flinch }
let POKE_REACTS: [React] = [.hop, .spin, .heart, .squish, .dizzy, .wave, .shy, .star]   // Picked at random when clicked
enum Act {
  var isAwake: Bool { if case .sleep = self { return false }; if case .yawn = self { return false }; return true }
  case stand, walk(CGFloat), fall, jump(CGPoint, CGPoint, Double, Double), drag, work, sleep, cheer, react(React?, Double, Double)
  case roll(CGFloat), hum                                   // Roll, stand and hum
  case walkTo(CGFloat, String), climb(String, CGFloat)      // Go next to a widget, then climb its side (facing direction)
  case slide(CGFloat), peek(CGFloat), sitEdge(CGFloat)      // Slide down the side, look down from the edge, sit on the edge and swing legs
  case hang(String, CGFloat)                                 // Hang from a window or widget corner (owner, side)
  case yawn, stretch                                         // Yawn before sleeping, stretch on waking
  case descend(CGFloat)                                      // Face the wall and climb down one step at a time
  case sneak(CGFloat, String)                                // When covered by a window, walk out to where it is visible (instead of teleporting)
  case stalk                                                 // Wiggle the rear while eyeing the cursor
  case follow(CGFloat)                                       // Trot after a slowly moving cursor at the same height
  case dive(String)                                          // Dive into the floor, then drop in from above the destination screen
  case walkOff(CGFloat)                                      // Walk to the window's end and hop down (on the way to the next target)
  case stroll(CGFloat)                                       // Stroll to the far side of the current floor (look around on arrival)
}

final class Pet: NSObject, NSMenuDelegate {
  let sources = makeSources()
  var list: [Sess] = []
  var mood: Mood = .sleep
  var chara: Chara = CHARAS[0]
  let layer = Layer.desktop                                                       // Always on the desktop level (the menu's 'show position' option was removed; bring-to-front on notification is separate)
  let frontOnAlert = false                                                       // Does not come to the front on notification (menu option removed)
  var scene = Scene()
  var scale = CGFloat(UD.integer(forKey: "scale") == 0 ? 3 : UD.integer(forKey: "scale"))
  var acked: Set<String> = []
  var window: PetWindow!
  var view: PetView!
  var pos = CGPoint.zero
  var vel = CGVector(dx: 0, dy: 0)
  var act: Act = .fall
  var actUntil = 0.0
  var floorID: String?
  var floors: [Floor] = []
  var lastFloors = 0.0, lastPoll = 0.0
  var timer: Timer?
  var rate = 0.0
  var grabOffset = CGPoint.zero, grabStart = CGPoint.zero, samples: [(Double, CGPoint)] = []
  var cheerUntil = 0.0, prevWaiting: Set<String> = [], polledOnce = false
  var notices: [Notice] = [], showing: Notice?, showUntil = 0.0
  let noticeSecs = 10.0                                                          // Completion notification bubble lasts 10 seconds (menu option removed)
  var noticeWin: PetWindow!, noticeView = NoticeView()
  // Chattiness: (0 off, 1 quiet: important things only, 2 normal, 3 talkative)
  var chatty = UD.object(forKey: "chatty") == nil ? 2 : min(3, max(0, UD.integer(forKey: "chatty")))
  let throwFeel = 1                                                              // Throw feel: fixed at normal (floaty); the 0 and 2 cells in the table are kept for tuning
  var roam = UD.object(forKey: "roam") == nil ? 1 : min(2, max(0, UD.integer(forKey: "roam")))                   // Roaming: 0 relaxed, 1 normal, 2 active (how often it goes off to play on windows)
  var chatWin: PetWindow!, chatView = NoticeView(), chatUntil = 0.0, lastChat = 0.0, nextIdleChat = 0.0
  var tails: [String: Tail] = [:], tailPending: Set<String> = []
  var workStart: [String: Double] = [:]
  var badgeWin: PetWindow!, badgeView = NoticeView(), badgeKey = ""
  var lastKey = ""                                                             // Clearing it makes it redraw on the next tick
  var lastPose = Pose(), lastChara = ""
  var lastCanvas = Canvas()
  var drawCache: [Pose: (Canvas, CGImage)] = [:]
  var screenFrames: [CGRect] = NSScreen.screens.map(\.frame)                 // Re-measure only when the screen changes
  var lastTick = 0.0, hiddenSince = 0.0, bonkUntil = 0.0
  // Lifelike feel (the 12 principles of animation: anticipation, squash, follow-through, randomized intervals): blinking, small gestures, landing squash, edge sway, stumbling
  var blinkUntil = 0.0, blinkNext = 0.0, fidget = -1, lastFidget = -1, fidgetUntil = 0.0, nextFidget = 0.0
  var landUntil = 0.0, wobbleUntil = 0.0, stumbleUntil = 0.0, standLook = 0
  // Play: landing dust, mid-air spin when thrown, window riding, petting, cursor hunting, greeting
  var dustT0 = -9.0, spinning = false, startleUntil = 0.0
  var rideOwner = "", rideRect = CGRect.zero, rideUntil = 0.0, lastRide = 0.0
  var strokes: [Double] = [], strokeX: CGFloat = 0, strokeDir = 0, pettedUntil = 0.0, petStart = 0.0
  var lastMouse = CGPoint.zero, mouseStill = 0.0, mouseNear = false, nextPounce = 0.0, pounceBoost: CGFloat = 0
  var liftSaid = false, liftCtx = Ctx(), dropSaid = false
  var away = false, lastIdleCheck = 0.0, grabT = 0.0, carriedSaid = false, awayDone = 0
  var climbFrom: CGFloat?, climbRestAt = CGFloat.infinity, climbRestUntil = 0.0, nextGoal: String?, nextGoalDive = true
  var nextFollow = 0.0, lastFidgetQ = false, lastHourSaid = -1
  var propHour = -1, propHourAt = -99.0, santaOn = false, snowOn = false, partyOn = false
  var clicks: [Double] = [], poutNext = false, caught = false, touchUntil = 0.0, gest: Chat?, gestT0 = 0.0, errs: [Double] = [], fx = 0, fxT0 = -99.0
  var days: Int {                                                          // Day number since the day we first met (first day = 1)
    let d0 = UD.double(forKey: "firstDay")
    if d0 == 0 { UD.set(Date().timeIntervalSince1970, forKey: "firstDay"); return 1 }
    return (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: d0)), to: Calendar.current.startOfDay(for: Date())).day ?? 0) + 1
  }
  /// The screen the pet is standing on now: among screens whose width matches, those with the pet's feet at or above them (minY <= y), the highest one (monitors stacked vertically)
  func screenIdx(_ p: CGPoint) -> Int? {
    let xs = screenFrames.indices.filter { p.x >= screenFrames[$0].minX && p.x < screenFrames[$0].maxX }
    return xs.filter { screenFrames[$0].minY <= p.y + 1 }.max { screenFrames[$0].minY < screenFrames[$1].minY } ?? xs.min { screenFrames[$0].minY < screenFrames[$1].minY }
  }
  func any(_ a: [String]) -> String { a.randomElement()! }
  /// Agent name of the waiting sessions: the shared name if all are the same (Claude, or the label in tools.json), 'agent' if mixed
  func waitingAgent(ask: Bool) -> String {
    let names = Set(list.filter { ask ? $0.mood == .ask : $0.mood == .wait }.map { $0.tool == "claude" ? "Claude" : $0.label })
    return names.count == 1 ? names.first! : T("에이전트", "Agent")
  }
  var ctx: Ctx {
    var x = Ctx()
    let si = screenIdx(pos), scr = NSScreen.screens
    x.high = pos.y - (si.flatMap { $0 < scr.count ? scr[$0].visibleFrame.minY : nil } ?? 0)
    x.days = days; x.firstToday = !Calendar.current.isDateInToday(Date(timeIntervalSince1970: UD.double(forKey: "lastWelcome")))
    if let f = floor { x.on = f.kind == .base ? "base" : f.kind == .widget ? "widget" : "window" } else { x.on = "air" }
    x.chara = chara.id.replacingOccurrences(of: "pack:", with: "")
    switch act { case .sitEdge: x.spot = "sitEdge"; case .hang: x.spot = "hang"; case .sleep, .yawn: x.spot = "sleep"; default: break }
    x.working = list.filter { $0.mood == .work }.count
    x.waiting = Set(list.filter { $0.mood >= .wait }.map(\.id)).subtracting(acked).count
    x.mood = mood; x.sweaty = sweaty; x.awayDone = awayDone; x.missed = missedBanners; x.who = waitingAgent(ask: mood == .ask)
    if case .drag = act, let a = samples.first, let b = samples.last, b.0 - a.0 > 0.01, now - b.0 < 0.12 { x.fast = abs(b.1.x - a.1.x) / CGFloat(b.0 - a.0) > 1100 }
    return x
  }
  var fastMoving: Bool { switch act { case .drag, .fall, .jump, .slide: return true; default: return false } }
  var uninterruptible: Bool { switch act { case .drag, .jump, .fall, .climb, .slide, .descend, .sneak, .stalk, .walkTo, .hang, .react, .yawn, .stretch, .dive, .walkOff: return true; default: return false } }
  var inTransit: Bool { switch act { case .jump, .fall, .drag, .climb, .slide, .descend, .sneak, .walkTo, .dive: return true; default: return false } }
  func dist(_ f: Floor) -> CGFloat { hypot(min(max(pos.x, f.x0), f.x1) - pos.x, f.y - pos.y) }
  var fontFamily = 0 { didSet { FONT_FAMILY = fontFamily; updateRenderM() } }
  /// The terminal font draws one dot smoothly across several screen pixels
  func updateRenderM() {
    let bs = window?.backingScaleFactor ?? 2
    RENDER_M = FONT_FAMILIES[FONT_FAMILY].smooth ? max(1, Int((textDot * bs).rounded())) : 1
  }
  var noticeScale = min(4, max(1, UD.integer(forKey: "textSize2") == 0 ? 2 : UD.integer(forKey: "textSize2"))) { didSet { TEXT_SIZE = noticeScale - 1 } }
  var textDot: CGFloat {                                                       // Size of one speech-bubble dot, rounded to match actual screen pixels
    let bs = window?.backingScaleFactor ?? 2                                   // (measured against the Medium pet size, so Size doesn't change Bubble Text)
    return max(1 / bs, (3 * TEXT_SIZES[TEXT_SIZE].2 * bs).rounded() / bs)
  }
  var humming = false, fallTop = 0.0 as CGFloat
  var fallOwner: String?                                                         // Owner of the level set while falling (not re-set if the same)
  var dropOwner: String?                                                         // Landing spot when dropping in from above (other windows' top edges along the way are passed over)
  var ballistic = false
  var thrown = false                                                             // Flying after being thrown by hand: reduced gravity and air drag so it floats along
  var handFall = false                                                           // Falling after release (both gentle drop and throw): in front of all windows until it lands
  var passThru = false                                                           // No room to land, so falling through behind windows and the Dock

  var alert: Bool { !Set(list.filter { $0.mood >= .wait }.map(\.id)).subtracting(acked).isEmpty }
  var onTop: Bool { layer == .top || (frontOnAlert && alert) }
  var now: Double { ProcessInfo.processInfo.systemUptime }

  func start() {
    window = PetWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false); window.isPet = true
    window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    view = PetView(); view.pet = self; view.registerForDraggedTypes([.fileURL])
    let holder = NSView(); holder.wantsLayer = true                                  // The pet window is PAD larger than the pet on every side. The pet image moves inside it, and the window is moved only when the pet reaches its edge
    holder.addSubview(view); window.contentView = holder
    noticeWin = PetWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    noticeWin.isOpaque = false; noticeWin.backgroundColor = .clear; noticeWin.hasShadow = false
    noticeWin.collectionBehavior = window.collectionBehavior
    noticeWin.contentView = noticeView
    noticeView.onClick = { [weak self] in self?.openNotice() }
    chatWin = PetWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    chatWin.isOpaque = false; chatWin.backgroundColor = .clear; chatWin.hasShadow = false; chatWin.ignoresMouseEvents = true
    chatWin.collectionBehavior = window.collectionBehavior; chatWin.contentView = chatView
    badgeWin = PetWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    badgeWin.isOpaque = false; badgeWin.backgroundColor = .clear; badgeWin.hasShadow = false; badgeWin.ignoresMouseEvents = true
    badgeWin.collectionBehavior = window.collectionBehavior; badgeWin.contentView = badgeView
    CANVAS_BUBBLE = false
    for w in [window, noticeWin, chatWin, badgeWin] as [NSWindow?] { w?.animationBehavior = .none }   // Turn off the system window animation when the speech bubble appears or disappears (it wakes at every display cycle)
    resize()
    let m = NSEvent.mouseLocation
    let scr = NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main ?? NSScreen.screens.first
    let vf = scr?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)   // With the lid closed there is no screen
    var x = vf.midX                                                               // Drop in from the top, but not onto the Dock: falling there lands behind the bar
    if let f = scr?.frame, let d = dockEstimate(screensNow()), f.contains(CGPoint(x: d.midX, y: d.midY)), d.width > d.height, x > d.minX - 60, x < d.maxX + 60 {   // a bottom Dock under the drop point
      x = d.minX - vf.minX > vf.maxX - d.maxX ? max(vf.minX + 60, d.minX - 90) : min(vf.maxX - 60, d.maxX + 90)
    }
    pos = CGPoint(x: x, y: vf.maxY - 80)
    if let p = UD.array(forKey: "place") as? [Double], p.count == 3, Date().timeIntervalSince1970 - p[2] < 300,       // Relaunched a moment ago (language change, update): stay where it was
       NSScreen.screens.contains(where: { $0.frame.insetBy(dx: 1, dy: 1).contains(CGPoint(x: p[0], y: p[1] + 1)) }) {
      pos = CGPoint(x: p[0], y: p[1])
    }
    UD.removeObject(forKey: "place")
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
      UD.set([Double(self.pos.x), Double(self.pos.y), Date().timeIntervalSince1970], forKey: "place"); UD.synchronize()
    }
    if let tf = terminalFamily() { FONT_FAMILIES.append(tf) }
    fontFamily = FONT_FAMILIES.firstIndex { $0.id == (UD.string(forKey: "fontFamily") ?? "neodgm") } ?? 0   // Default: Neo Dunggeunmo
    TEXT_SIZE = noticeScale - 1; FONT_FAMILY = fontFamily; updateRenderM()
    ALL_CHARAS = mergeCharas(loadCustomCharas())
    let saved = UD.string(forKey: "chara") ?? ""                                // Keep the chosen character even when a single sheet is moved into a pack (custom:x -> pack:x)
    chara = findChara(saved)
    resize()
    watcher = Watcher { [weak self] in self?.poll() }
    DistributedNotificationCenter.default().addObserver(forName: SIGNAL_NAME, object: nil, queue: .main) { [weak self] n in   // DotBuddy --signal …
      guard let self, self.extSignal, let s = n.object as? String, let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return }
      self.onSignal(j)
    }
    NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in   // The moment another app's window is clicked: if standing on a window, wake immediately and follow the drag (normally stays on the slow tick)
      guard let self else { return }
      var onWindow = self.floor?.owner.hasPrefix("w") == true
      if case .hang = self.act { onWindow = true }
      if onWindow { self.lastRide = 0; self.tick() }
    }
    poll(); refreshFloors(force: true); applyLevel()
    startUpdateChecks()
    window.orderFrontRegardless()
    NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in NSTimeZone.resetSystemTimeZone() }   // Even if the time zone changes while running (travel), time-of-day text and on-the-hour notifications follow the new time zone
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }                                                   // Desktop switch: all windows change at once; don't be startled, just land at the new spot
      self.spaceChangedAt = self.now; self.lastFloors = 0; self.sceneActiveUntil = self.now + 3
    }
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in   // Waiting under a cover: switching back to that app shows it again at once (its own occlusion does not change while the window is still in front of it)
      guard let self, self.now < self.graceUntil else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.lastFloors = 0; self.tick() }
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
      guard let self, self.now - self.occlScanAt > 0.3 else { return }                // Covered by a window brought to the front, or its own window came back: re-measure now (the 2 second scan made it show up late)
      self.occlScanAt = self.now; self.lastFloors = 0; self.tick()
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.screenFrames = NSScreen.screens.map(\.frame); self?.refreshFloors(force: true) }
    schedule(1.0 / 30)
  }
  // Window margin (pt). With 120 on every side the window moves less, but twice a big window failed to draw fully under the Dock or a full-screen transparent window, so it was turned off.
  // Only a little left and right (tested 2026-11-17): walking moves only the image inside the window, and the window moves only after PADX; moving the window keeps the window server much busier than redrawing the image
  static let PADX: CGFloat = 40, PADY: CGFloat = 0
  func resize() {
    let w = CGFloat(CW) * ds, h = CGFloat(CH) * ds
    window.setContentSize(NSSize(width: w + Pet.PADX * 2, height: h + Pet.PADY * 2))
    view.frame = NSRect(x: Pet.PADX, y: Pet.PADY, width: w, height: h)
  }
  /// Screen rectangle where the pet image sits (excluding the window margin)
  var petRect: CGRect { CGRect(origin: CGPoint(x: window.frame.minX + view.frame.minX, y: window.frame.minY + view.frame.minY), size: view.frame.size) }
  /// Put the level right above the window being stood on (running or hanging): hidden by windows in front of that window, and shown in front of windows behind it.
  /// On the floor, widgets or the Dock, use the desktop level (behind all windows). Do nothing in always-on-top mode
  var stackedOn: Int? = nil, lastStack = 0.0
  var napToken: NSObjectProtocol?
  func applyStacking(force: Bool = false) {
    guard !onTop else { stackedOn = nil; return }
    var owner: String? = nil
    switch act {
    case .jump:                                                                     // When jumping to a window above, keep the current level until the top edge is cleared (rises hidden behind the front window), then use the level above that window
      guard let tf = targetFloor.flatMap({ id in floors.first { $0.id == id } }) ?? afterFloor.flatMap({ id in floors.first { $0.id == id } }) else { return }
      if pos.y < tf.y - 2 { return }
      owner = tf.owner
    case .hang(let o, _): owner = o
    case .fall:                                                                     // While falling: guess the floor it will land on and use that level, so it doesn't pop in or out when front/back order flips at touchdown
      if handFall && !passThru { return }                                           // While falling after release, keep the held level (in front of all windows). Dropping to the desktop level made it vanish behind windows (released inside a window, it goes straight behind that window). On landing, switch to that floor's level
      let x = pos.x + vel.dx * 0.15
      guard let f = floors.filter({ $0.y <= pos.y + 0.5 && x >= $0.x0 + 4 && x <= $0.x1 - 4 && (dropOwner == nil || $0.owner == dropOwner || $0.kind == .base) }).max(by: { $0.y < $1.y }) else { return }
      let body = CGPoint(x: pos.x, y: pos.y + 7 * scale)                           // Seen now but behind a window at that floor's level: keep this level until it falls clear of that window.
      if wallsInFront(of: f.owner).contains(where: { $0.contains(body) }), !frontWalls().contains(where: { $0.contains(body) }) { return }   // Switching at once made it vanish mid-air behind a window that sat behind the one it jumped from (2026-11-24)
      if f.owner != fallOwner || force { fallOwner = f.owner; stackFor(f.owner) }
      return
    case .drag, .dive, .slide, .descend: return                                     // Other mid-air actions are left unchanged (decided on landing)
    default: owner = floor?.owner ?? afterFloor.flatMap { id in floors.first { $0.id == id } }?.owner
    }
    let num = owner.flatMap { $0.first == "w" ? Int($0.dropFirst()) : nil }
    if let num {
      if stackedOn != num || force || now - lastStack > 3 {                         // When another app comes to the front the order gets shuffled, so re-align occasionally
        lastStack = now; stackedOn = num
        if window.level != .normal { window.level = .normal }
        window.order(.above, relativeTo: num)
        restackBubbles()
      }
    } else if stackedOn != nil || dockLevel != (owner == "dock") || window.level.rawValue != (owner == "dock" || onTop ? NSWindow.Level.floating.rawValue : scene.widgetLevel) {   // Landed on a floor, widget or the Dock (also returns from the top level held while lifted)
      stackedOn = nil; dockLevel = owner == "dock"; applyLevel()
    }
  }
  /// Set the level to match its owner (just in front of the window, otherwise the floor or widget level)
  func stackFor(_ owner: String) {
    guard !onTop else { return }
    if prof { FileHandle.standardError.write("  stack \(owner) act=\(String(describing: act).components(separatedBy: "(")[0]) y=\(Int(pos.y))\n".data(using: .utf8)!) }
    if owner.first == "w", let num = Int(owner.dropFirst()) {
      lastStack = now; stackedOn = num
      if window.level != .normal { window.level = .normal }
      window.order(.above, relativeTo: num); restackBubbles()
    } else if stackedOn != nil || dockLevel != (owner == "dock") || window.level.rawValue != (owner == "dock" || onTop ? NSWindow.Level.floating.rawValue : scene.widgetLevel) { stackedOn = nil; dockLevel = owner == "dock"; applyLevel() }
  }
  /// The bubble, badge and notifications always sit right above the pet window; if the pet is hidden behind a window they are hidden too (so the bubble doesn't float alone)
  /// Skip if already right above the pet and the pet window order hasn't changed since; re-aligning the order on every typed character kept the window server busy
  var stuckGen: [ObjectIdentifier: Int] = [:]
  func stickBubble(_ w: NSWindow) {
    let k = ObjectIdentifier(w)
    if w.isVisible, w.level == window.level, stuckGen[k] == window.orderGen { return }
    if w.level != window.level { w.level = window.level }
    w.order(.above, relativeTo: window.windowNumber); stuckGen[k] = window.orderGen
  }
  func restackBubbles() { for w in [noticeWin, chatWin, badgeWin] where w?.isVisible == true { stickBubble(w!) } }
  /// On the Dock bar (or falling onto it) the pet is in front of all windows, like the Dock itself. At the desktop level, a window whose
  /// bottom edge sat just above the bar covered the pet there, so that part of the bar was no floor and a pet falling onto it went behind the Dock (2026-11-23)
  var dockLevel = false
  var restLevel: Int { onTop || dockLevel ? NSWindow.Level.floating.rawValue : scene.widgetLevel }
  /// Windows in front of the pet: those in front of the window it stands on, none on the top level or the Dock, otherwise all
  /// Windows that would be in front of the pet standing on a floor of this owner
  func wallsInFront(of owner: String) -> [CGRect] {
    if owner == "dock" { return [] }
    if owner.first == "w", let n = Int(owner.dropFirst()), let i = scene.order.firstIndex(of: n) { return Array(scene.walls[..<i]) }
    return scene.walls
  }
  func frontWalls() -> [CGRect] {
    if let n = stackedOn, let i = scene.order.firstIndex(of: n) { return Array(scene.walls[..<i]) }
    return onTop || dockLevel ? [] : scene.walls
  }
  func applyLevel() {
    window.level = onTop || dockLevel ? .floating : NSWindow.Level(rawValue: scene.widgetLevel)
    noticeWin.level = window.level; chatWin.level = window.level; badgeWin.level = window.level
    if window.level != .normal { stackedOn = nil }
    if onTop || dockLevel { window.orderFrontRegardless() }
    restackBubbles()
  }
  func schedule(_ r: Double) {
    guard r != rate else { return }
    rate = r; timer?.invalidate()
    let tm = Timer(timeInterval: r, repeats: true) { [weak self] _ in self?.tick() }
    tm.tolerance = r >= 0.2 ? r * 0.5 : (r < 0.02 ? 0.002 : r * 0.15)           // Slow ticks let the system batch wake-ups; the 60 per second tick keeps its beat
    RunLoop.main.add(tm, forMode: .common)                                     // So it doesn't stop even while dragging (event tracking)
    timer = tm
  }

  // Sessions every 2 seconds
  var watcher: Watcher?
  /// Reading the session files (a few ms) happens on the io queue, and only applying the result on main. If another request comes while reading, run once more after it finishes
  let ioQ = DispatchQueue(label: "dotbuddy.io", qos: .utility)
  var polling = false, pollAgain = false
  func poll() {
    lastPoll = now
    guard extClaude else { if !list.isEmpty || true { applyPoll([]) }; return }     // If the extension is off, session files are neither looked at nor read
    profile("watch") { watcher?.sync(dirs: sources.compactMap(\.watchDir)) }
    if polling { pollAgain = true; return }
    polling = true
    ioQ.async { [weak self] in
      guard let self else { return }
      let l = self.profile("poll") { readAll(self.sources) }
      DispatchQueue.main.async {
        self.polling = false; self.applyPoll(l)
        if self.pollAgain { self.pollAgain = false; self.poll() }
      }
    }
  }
  func applyPoll(_ l: [Sess]) {
    defer { syncTails() }
    let wasTop = onTop                                                           // Measure before reading the new list so changes can be detected
    list = l
    let waiting = Set(list.filter { $0.mood >= .wait }.map(\.id))
    acked.formIntersection(waiting)
    let fresh = list.filter { $0.mood >= .wait && !prevWaiting.contains($0.id) }
    let wall = Date().timeIntervalSince1970                                       // Working time: since this app first saw it as 'working'
    var worked: [String: Double] = [:]
    for s in fresh { if let w0 = workStart[s.id] { worked[s.id] = wall - w0 } }
    for s in list where s.mood == .work && workStart[s.id] == nil { workStart[s.id] = wall }
    let workingIDs = Set(list.filter { $0.mood == .work }.map(\.id)); workStart = workStart.filter { workingIDs.contains($0.key) }
    let busy = list.filter { $0.mood == .work }, tools = Set(busy.map(\.tool))
    praiseSessions(busy.count, tool: tools.count == 1 ? tools.first! : nil, label: tools.count == 1 ? busy[0].label : T("에이전트", "agent"))   // If several agents are mixed, "5 agents"
    if !fresh.isEmpty { cheerUntil = now + 2.5; if away { awayDone += fresh.count } }
    if polledOnce, !fresh.isEmpty, !away { fx = 2; fxT0 = now }
    if polledOnce, !fresh.isEmpty, !away, floor != nil, !uninterruptible { act = .react(.party, now, 1.5); if chatty >= 2, noticeSecs == 0 { say(line(.party, ctx), now) } }   // Moment of finishing: two cheers + confetti                                   // Newly finished session: sparkle
    if polledOnce, !fresh.isEmpty {                                               // Sound (if turned on) and today's count; not for sessions already finished at launch
      chime(ask: fresh.contains { $0.mood == .ask })
      countDone(fresh.filter { $0.mood == .wait }.count)
    }
    if polledOnce && noticeSecs > 0 && !fresh.isEmpty {                           // Don't announce sessions that were already finished when the app started
      let pids = fresh.filter(\.derived).map(\.pid)
      DispatchQueue.global(qos: .utility).async { [weak self] in                   // ps and cmux can be slow, so run them off main
        let titles = tabTitles(pids)
        DispatchQueue.main.async {
          guard let self else { return }
          let still = Set(self.list.filter { $0.mood >= .wait }.map(\.id))
          for s in fresh where still.contains(s.id) {
            let others = still.subtracting(self.acked).subtracting([s.id]).count
            self.notices.append(Notice(pid: s.pid, id: s.id, title: s.derived ? (titles[s.pid] ?? s.name) : s.name, ask: s.mood == .ask, worked: worked[s.id], others: others, tool: s.tool))
          }
        }
      }
    }
    notices.removeAll { !waiting.contains($0.id) && !$0.id.hasPrefix("signal:") }   // No need to announce a session that went back to work (signal notifications are not sessions, so they stay as is)
    if let n = showing, !waiting.contains(n.id), !n.id.hasPrefix("signal:") { hideNotice() }
    polledOnce = true
    prevWaiting = waiting
    applyMood(wasTop: wasTop)
  }
  var lastMoodCheck = 0.0
  var bannerOn = false, lastBannerCheck = 0.0, bannerChecking = false, missedBanners = 0
  func stepBanner(_ t: Double) {
    guard extNotif, !bannerChecking, t - lastBannerCheck > 1.5 else { return }
    lastBannerCheck = t; bannerChecking = true
    sceneQ.async { [weak self] in
      let ws = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
      let on = ws.contains { ($0[kCGWindowOwnerName as String] as? String) == "Notification Center" && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
      DispatchQueue.main.async {
        guard let self else { return }
        self.bannerChecking = false
        if on && !self.bannerOn { self.onBanner() }
        self.bannerOn = on
      }
    }
  }
  /// A notification arrived: look at the top right of the screen and get startled or glad (content is unknown; it is not read)
  func onBanner() {
    let t = now
    if away || screenLocked { missedBanners += 1; return }
    guard floor != nil, !uninterruptible else { return }
    standLook = 1; act = .react(Bool.random() ? .star : nil, t, 1.0); startleUntil = t + 0.5
    if chatty > 0, showing == nil, t - lastChat > 3 { say(any(T(["띵동~ 알림!", "뭔가 왔어요!", "알림 왔다!", "저기 봐요, 알림!", "누가 찾나 봐요"], ["Ding dong! A ping!", "Something came in!", "Ooh, a notification!", "Look, a notification!", "Someone's looking for you"])), t) }
  }
  /// Signal handling: say (speak), done (completion notice), ask (question notice), work (working, 60 seconds or until work off), cheer, poke
  func onSignal(_ j: [String: String]) {
    let t = now, kind = j["kind"] ?? "", text = j["text"] ?? "", from = j["from"] ?? T("신호", "Signal")
    switch kind {
    case "say": if !text.isEmpty { say(String(text.prefix(40)), t) }
    case "done", "ask":
      let n = Notice(pid: 0, id: "signal:\(t)", title: text.isEmpty ? from : String(text.prefix(60)), ask: kind == "ask")
      if noticeSecs > 0 { notices.append(n) }
      chime(ask: kind == "ask"); if kind == "done" { countDone(1) }
      cheerUntil = t + 2.5; if kind == "done" { fx = 2; fxT0 = t }
      if kind == "ask" { signalAskUntil = t + 120 } else { signalWorkUntil = 0; if floor != nil, !uninterruptible { act = .react(.party, t, 1.5) } }
    case "work": if text == "off" { signalWorkUntil = 0 } else { signalWorkUntil = t + min(3600, max(0, Double(text).flatMap { $0.isFinite ? $0 : nil } ?? 60)) }   // At most one hour (so it is never held forever by 1e308)
    case "event":                                                                    // Gestures of other agents (reading, editing, testing...); Claude reads its transcript directly and does the same
      if let c = chatEvent(text) { chat(c) }; return
    case "cheer": cheerUntil = t + 2.5; if floor != nil, !uninterruptible { act = .react(.party, t, 1.5) }
    case "poke": if floor != nil, !uninterruptible { poke() }
    case "drop" where prof:                                                          // For testing: as if released at that spot (drag and drop)
      let v = text.split(separator: ",").compactMap { Double($0) }; if v.count == 2 { pos = CGPoint(x: v[0], y: v[1]); floorID = nil; act = .drag; samples = []; ignoring = false; grabStart = CGPoint(x: -999, y: -999); release() }
    case "fling" where prof:                                                         // For testing: "x,y,vx,vy" - as if thrown from that spot at that velocity; for 4 seconds, records position and occlusion every frame
      let v = text.split(separator: ",").compactMap { Double($0) }
      if v.count == 4 {
        pos = CGPoint(x: v[0], y: v[1]); vel = CGVector(dx: v[2], dy: v[3]); floorID = nil
        if !onTop { stackedOn = nil; window.level = .floating; window.orderFrontRegardless(); restackBubbles() }   // As if it had been held
        let sp = hypot(vel.dx, vel.dy); thrown = sp > 400; handFall = true; spinning = sp > 1200; act = .fall; flingTrace = t + 4; lastTick = t; schedule(1.0 / 60)
      }
    case "goto" where prof:                                                          // For testing (DOTBUDDY_PROF): drop it from above "x,y"
      let v = text.split(separator: ",").compactMap { Double($0) }; if v.count == 2 { pos = CGPoint(x: v[0], y: v[1]); floorID = nil; vel = .init(dx: 0, dy: 0); act = .fall }
    default: return
    }
    applyMood()
  }
  func applyMood(wasTop: Bool? = nil) {
    let wasTop = wasTop ?? onTop
    let m = baseMood()
    if m != mood {
      let old = mood; mood = m; nextGoal = nil
      if !uninterruptible {                                                         // If moving, it decides on its own after finishing
        if m == .sleep, floor != nil { act = .yawn; actUntil = now + 1.6 }
        else if old == .sleep, floor != nil { act = .stretch; actUntil = now + 1.0 }
        else { decide() }
      }
    }
    if wasTop != onTop { applyLevel(); if onTop { goVisible() } }
  }
  /// Re-measure the floor. If the segment it was standing on changed, move to the segment of the same owner (window, widget, screen) that contains the current position; if none (covered, or the window moved), it falls
  /// Re-measure the floor. Reading the window list (a few to ~10 ms) runs in the background, and only applying runs on main (avoids hitches while thrown). force runs immediately (setting change, startup)
  let sceneQ = DispatchQueue(label: "dotbuddy.scene", qos: .utility)
  var scanning = false, dockRect: CGRect?, dockAt = -99.0
  var sceneSig = "", sceneActiveUntil = 0.0, spaceChangedAt = -99.0
  func refreshFloors(force: Bool = false) {
    let scrs = screensNow(), ph = 15 * scale, hw = halfW
    if force { dockAt = now; dockRect = dockEstimate(scrs); applyScene(scanScene(petH: ph, halfW: hw, scrs: scrs, dock: dockRect)); return }
    guard !scanning else { return }
    scanning = true
    let redoDock = now - dockAt > 10, oldDock = dockRect
    if redoDock { dockAt = now }
    sceneQ.async { [weak self] in                                                    // Dock estimation (reading the window list) also runs off main; it ran on main every 10 seconds and delayed ticks
      let dk = redoDock ? dockEstimate(scrs) : oldDock
      let sc = self?.profile("scanScene") { scanScene(petH: ph, halfW: hw, scrs: scrs, dock: dk) } ?? Scene()
      DispatchQueue.main.async { self?.scanning = false; if redoDock { self?.dockRect = dk }; self?.applyScene(sc) }
    }
  }
  func applyScene(_ sc: Scene) {
    if !rideOwner.isEmpty, let num = Int(rideOwner.dropFirst()), let i = sc.order.firstIndex(of: num), i < sc.walls.count { rideRect = sc.walls[i] }
    let sig = sc.walls.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }.joined(separator: ";") + "|" + sc.order.map(String.init).joined(separator: ",")
    if sig != sceneSig { if !sceneSig.isEmpty { sceneActiveUntil = now + 4 }; sceneSig = sig }   // Window layout is changing: re-measure often for 4 seconds
    if let f0 = sc.order.first, f0 != lastFront {                                   // The frontmost window changed (the user clicked another window); shortly after, decide whether to jump down onto that window
      let first = lastFront == 0; lastFront = f0
      if !first, now - spaceChangedAt > 2 { frontJump = (f0, now + .random(in: 0.5...1.4)) }
    }
    let old = floor
    scene = sc; sceneGen &+= 1
    floors = scene.floors
    if let o = old {
      let back = floors.first(where: { $0.owner == o.owner && abs($0.y - pos.y) < 3 && pos.x >= $0.x0 - 3 * scale && pos.x <= $0.x1 + 3 * scale })
      if back != nil, graceUntil > 0 { graceUntil = 0; if prof { FileHandle.standardError.write("  GRACE back\n".data(using: .utf8)!) } }
      if back == nil, coverGrace(o) { floors.append(o) }                            // Covered by a window brought to the front: wait in place a moment (it may come right back)
      else if let n = back {
        floorID = n.id
        switch act {
        case .sitEdge, .peek, .hang, .sneak: break
        default:
          let cx = min(max(pos.x, n.x0 + halfW), n.x1 - halfW)
          if abs(cx - pos.x) > 2 && coveringWindow(on: n) != nil && !coverEscape(from: n) { floorID = nil; act = .sneak(cx, n.id); schedule(1.0 / 24) }   // Slightly overlapped by a front window: climb onto the covering window or hop sideways, otherwise trot
        }
      } else if let n = floors.first(where: { $0.owner == o.owner && abs($0.y - o.y) > 2 && pos.x >= $0.x0 && pos.x <= $0.x1 }),
                NSEvent.pressedMouseButtons & 1 != 0 || abs(n.y - o.y) < 150 || !(n.rect.width < o.rect.width * 0.8 || n.rect.height < o.rect.height * 0.8) {
        floorID = n.id; pos.y = n.y                                              // Moving the window up or down carries the pet along (not while it shrinks into the Dock: then it falls, below)
      } else if let n = floors.filter({ $0.owner == o.owner && abs($0.y - pos.y) < 3 && !$0.id.hasSuffix(":x") }).min(by: { abs($0.mid - pos.x) < abs($1.mid - pos.x) }) {
        if !coverEscape(from: n) { floorID = nil; act = .sneak(min(max(pos.x, n.x0 + halfW), n.x1 - halfW), n.id); schedule(1.0 / 24) }   // A window came to the front and covered it: walk out to where it is visible
      } else if !coverEscape(from: nil) { floorID = nil; vel = .init(dx: 0, dy: 0); act = .fall }   // The whole top edge is covered: go onto the covering window or to a visible spot; if impossible, fall
    }
    let inHand: Bool = { switch act { case .drag, .dive: return true; default: return handFall } }()   // (a dive keeps the level it started with until it drops in)   // While held or falling after release, in front of all windows; don't revert to the desktop level when re-measuring the floor
    if stackedOn == nil, !inHand, window.level.rawValue != restLevel { applyLevel() }
    applyStacking(force: true)
  }
  /// The window it stands on was covered by another window brought to the front (the user clicked a window behind). People often glance at it and come straight back,
  /// so for a few seconds it stays where it is, hidden, and the floor is kept; if its window comes back to the front it shows again at once (rescans are dense meanwhile).
  /// Covered for longer, the usual escape runs: climb onto the covering window, step to a visible spot, or fall. Reacting at once left the window it was on
  /// (it had already jumped elsewhere) and it seemed to show up seconds later (2026-11-23)
  var graceUntil = 0.0, graceID = "", occlScanAt = 0.0, graceScanned = false
  func coverGrace(_ o: Floor) -> Bool {
    guard o.kind == .window, !screenLocked, now - spaceChangedAt > 2, now - landUntil > 1, scene.walls.contains(o.rect) else { graceUntil = 0; return false }   // Just landed on a spot that turns out covered: nothing to wait for, get out now (it stayed hidden 3.6s, 2026-11-26)   // Only if the window itself is still there unmoved (moved, closed or minimized are handled elsewhere)
    switch act { case .stand, .walk, .work, .cheer, .hum, .sleep, .react, .roll, .follow, .yawn, .stretch, .sitEdge, .peek, .stroll: break; default: return false }
    if graceUntil == 0 || graceID != o.id {                                          // A new cover (an expired wait on this same floor stays expired until it is seen again)
      graceUntil = now + Pet.COVER_WAIT; graceID = o.id; graceScanned = false
      if case .sleep = act {} else if case .work = act {} else { act = .stand; actUntil = graceUntil + 0.6 }   // Hold still (walking off a floor it can't see looked odd when it came back)
      if prof { FileHandle.standardError.write("  GRACE start \(o.owner)\n".data(using: .utf8)!) }
    }
    return now < graceUntil
  }
  static let COVER_WAIT = 4.0
  /// Windows currently covering the pet's body (only windows in front of the pet). Standing on a window: windows in front of that window; on the floor or a widget: all windows
  func coveringWindow(on f: Floor?) -> CGRect? {
    if f?.owner == "dock" { return nil }                                            // On the Dock the pet is in front of every window
    let body = CGRect(x: pos.x - halfW * 0.6, y: pos.y + 2 * scale, width: halfW * 1.2, height: 10 * scale)
    var front = scene.walls
    if let f, f.kind == .window, let num = Int(f.owner.dropFirst()), let i = scene.order.firstIndex(of: num) { front = Array(scene.walls[..<i]) }
    return front.first { $0.intersects(body) && $0 != f?.rect }
  }
  /// A window that came to the front covered the pet: move to be visible. If that window's top edge is reachable, climb up (and set the level above that window),
  /// otherwise hop sideways to a visible spot on the same floor. Returns false if neither works (it trots instead)
  func coverEscape(from n: Floor?) -> Bool {
    switch act { case .stand, .walk, .work, .cheer, .hum, .sleep, .react, .roll, .follow, .yawn, .stretch, .sitEdge, .peek, .stroll: break; default: return false }
    let body = CGPoint(x: pos.x, y: pos.y + 7 * scale)
    // A back window was clicked, came forward and covered it: choose a jump mostly by the nearest of up (top edge of the covering window), sideways (visible side of the same floor) and down (visible lower floor)
    var opts: [(Double, () -> Bool)] = []
    if let cover = coveringWindow(on: n ?? floor), cover.contains(body), cover.maxY > pos.y,
       let top = floors.filter({ $0.rect == cover && $0.x1 - $0.x0 >= halfW * 2 + 8 }).min(by: { abs($0.mid - pos.x) < abs($1.mid - pos.x) }),
       top.y > pos.y, top.y - pos.y <= 650 {
      let near = top.y - pos.y <= 260
      opts.append((near ? 0.5 : 0.3, { [unowned self] in
        if self.chatty >= 2, self.showing == nil, self.now - self.lastChat > 4, Bool.random() { self.say(any(T(["영차, 위로!", "이 창 위가 좋겠다", "가렸잖아~"], ["Heave-ho, up we go!", "On top of this one!", "Hey, you covered me~"])), self.now) }
        if near { self.hop(to: top); return true }; return self.leap(to: top) }))   // At the moment of the jump it rises to the level above that window and becomes visible
    }
    if let n {
      let cx = min(max(pos.x, n.x0 + halfW), n.x1 - halfW)
      if abs(cx - pos.x) < 260 {                                                      // Hop sideways (the uncovered side of the same floor)
        opts.append((abs(cx - pos.x) < 120 ? 0.45 : 0.3, { [unowned self] in
          self.edgeHop(to: CGPoint(x: cx, y: n.y), then: .stand, floor: n.id, dur: 0.3 + Double(abs(cx - self.pos.x)) / 1200, peak: 18); self.actUntil = self.now + 0.8; return true }))
      }
    }
    let lows = floors.filter { $0.y < pos.y - 40 && !$0.id.hasSuffix(":x") && $0.x1 - $0.x0 >= halfW * 2 + 12 && abs(min(max(pos.x, $0.x0), $0.x1) - pos.x) < 500 }
    if let g = lows.max(by: { $0.y < $1.y }) {                                           // Down: jump down to the visible spot right below (the highest lower floor)
      opts.append((0.25, { [unowned self] in
        if self.chatty >= 2, self.showing == nil, self.now - self.lastChat > 4, Bool.random() { self.say(any(T(["아래로 피신!", "뛰어내린다!", "여기 말고 저기~"], ["Escape downward!", "Jumping down!", "Not here, over there~"])), self.now) }
        return self.leap(to: g) }))
    }
    var total = opts.reduce(0) { $0 + $1.0 }
    while !opts.isEmpty {                                                              // Pick by weight; if that fails, try the next
      var r = Double.random(in: 0..<total), i = 0
      while i < opts.count - 1 && r >= opts[i].0 { r -= opts[i].0; i += 1 }
      if opts[i].1() { return true }
      total -= opts[i].0; opts.remove(at: i)
    }
    // Hop to a nearby visible floor (another window or widget); at the moment of the jump it rises to that window's level and becomes visible
    if let g = floors.filter({ !$0.id.hasSuffix(":x") && $0.id != floorID && dist($0) < 260 && $0.y - pos.y < 200 }).min(by: { dist($0) < dist($1) }) { hop(to: g); return true }
    return false
  }
  var floor: Floor? { floors.first { $0.id == floorID } }
  var halfW: CGFloat { 8 * scale }
  /// Size of one image dot. The default character uses scale; for loaded images, shrink so the height is 15~16 rows, and match actual screen pixels
  var ds: CGFloat {
    guard let sp = chara.sprite, max(sp.bodyH, 1) > 20 else { return scale }      // If within 20 rows including hand and ear margins, keep the default size
    let bs = window?.backingScaleFactor ?? 2
    return max(1 / bs, (scale * 16 / CGFloat(sp.bodyH) * bs).rounded() / bs)
  }

  // Next action that fits the current mood
  func decide() {
    guard let here = floor else { act = .fall; return }
    let t = now, r = Double.random(in: 0...1)
    if let g = nextGoal { nextGoal = nil; if let f = floors.first(where: { $0.id == g }), goVia(f, dive: nextGoalDive) { return } }   // Next step on the stepping stones
    let widgets = nearMe(floors.filter(\.widget))                             // Visible widget or window top edge, starting with the screen the user is looking at
    humming = false
    // After playing up high for a while, go down (about half up, half down): walk to the nearest real corner and hop down. If it lands on another window, it goes down again next time
    if here.widget, upSince > 0, t - upSince > upLimit, mood != .sleep || r < 0.3 {
      let edges = [(here.x0 + halfW, here.edgeL), (here.x1 - halfW, here.edgeR)].filter(\.1).map(\.0)
      let sorted = edges.sorted { abs($0 - pos.x) < abs($1 - pos.x) }                // Nearer end 65%, farther end 35%, so it doesn't always come down at the same place
      if let e = sorted.count > 1 && Double.random(in: 0...1) < 0.35 ? sorted[1] : sorted.first { act = .walkOff(e); return }
      // No corner to step down from (screen edge or blocked by a front window): long jump to the floor
      if nearMe(floors).filter({ $0.kind == .base && !$0.id.hasSuffix(":x") }).sorted(by: { dist($0) < dist($1) }).contains(where: { leap(to: $0) }) { return }
    }
    switch mood {
    case .sleep:                                                         // Nearby widget or window tops are the bed (half the time it just sleeps on the floor); random among the few nearest
      if !here.widget, r < 0.45, pickTargets(widgets, by: { -self.dist($0) }).contains(where: { goVia($0, dive: false) }) {} else { act = .sleep }
    case .wait, .ask:
      if r < 0.4 { act = .cheer; actUntil = t + .random(in: 4...8) } else { wander(t) }
    case .free:                                                          // Without an agent: mostly strolling, humming and sitting on edges, occasionally going up
      wander(t)
    case .work:
      if !here.widget, r < 0.4, t - downSince > 25, pickTargets(widgets, by: { ($0.x1 - $0.x0) - self.dist($0) * 0.8 }).contains(where: { goVia($0, dive: false) }) {}   // After playing on the floor a while, pick one of a few wide, nearby top edges as a desk
      else if r < 0.5 { act = .work; actUntil = t + .random(in: 10...25) }
      else { wander(t) }
    }
  }
  /// Relaxed play: walking, strolling to the far side, exploring elsewhere (window tops, Dock, floor, anywhere), rolling, humming in place; so it doesn't stay in one spot for long
  func wander(_ t: Double) {
    let r = Double.random(in: 0...1), dir = pickDir()
    let floorTime = floor?.widget == true || t - downSince > 8                        // Just after coming down to the floor, it plays on the floor for 8 seconds
    let onBase = floor?.kind == .base, (pW, pS, pE0) = onBase ? (0.16, 0.32, 0.72) : (0.24, 0.46, 0.74)   // On the floor, walk less and go play on windows more often
    let pE = min(0.95, pS + (pE0 - pS) * [0.5, 1, 1.6][roam])                      // Roaming setting: reduces or increases the share of going off to play
    if r < pW { act = .walk(dir); actUntil = t + (floor?.kind == .base ? .random(in: 3...8) : .random(in: 2...5)); humming = Double.random(in: 0...1) < 0.35 }
    else if r < pS, let x = strollX(dir) { act = .stroll(x); humming = Double.random(in: 0...1) < 0.3 }
    else if r < pE, floorTime, explore() {}
    else if r < 0.86 { act = .roll(dir); actUntil = t + .random(in: 0.8...1.6) }
    else { act = .hum; actUntil = t + .random(in: 3...6) }
  }
  /// Choose left or right: slightly favor the side with more room, and favor the opposite side after going the same way twice (so it doesn't drift to one side)
  var lastDirs: [CGFloat] = []
  func pickDir() -> CGFloat {
    var pR = 0.5
    if let f = floor { let l = max(0, pos.x - f.x0 - halfW), rr = max(0, f.x1 - halfW - pos.x); pR = Double((rr + 60) / (l + rr + 120)) }
    if lastDirs.count >= 2, lastDirs.suffix(2).allSatisfy({ $0 == lastDirs.last! }) { pR = lastDirs.last! > 0 ? min(pR, 0.25) : max(pR, 0.75) }
    let d: CGFloat = Double.random(in: 0...1) < pR ? 1 : -1
    lastDirs = Array((lastDirs + [d]).suffix(3)); return d
  }
  /// Stroll destination: anywhere more than 120pt away in that direction (the opposite side if that side is narrow)
  func strollX(_ dir: CGFloat) -> CGFloat? {
    guard let f = floor else { return nil }
    let lo = f.x0 + halfW, hi = f.x1 - halfW
    for d in [dir, -dir] {
      let a = d > 0 ? pos.x + 120 : lo, b = d > 0 ? hi : pos.x - 120
      if b - a > 10 { return .random(in: a...b) }
    }
    return nil
  }
  /// Explore elsewhere: anywhere among widgets, window top edges, the Dock and floor segments on the screen the user is looking at (recently visited places go last). Only places reachable by walking, jumping or climbing
  func explore() -> Bool {
    guard let here = floor else { return false }
    let wantDown = here.widget && upSince > 0 && now - upSince > upLimit            // Played enough up high: don't go any higher (prevents going down and straight back up)
    let near = { (f: Floor) -> Bool in self.dist(f) < 1400 || (f.y - self.pos.y <= Pet.CLIMB_FAR && abs(min(max(self.pos.x, f.x0), f.x1) - self.pos.x) < 1000) }   // A tall window was left out when measured by straight distance as too far; include it if it is close sideways and the height is climbable
    let cands = nearMe(floors).filter { $0.id != here.id && !$0.id.hasSuffix(":x") && near($0) && ($0.x1 - $0.x0) >= halfW * 2 + 20
      && (!wantDown || $0.y < here.y - 20) && (blocked[$0.owner] ?? 0) < now }.shuffled()
    var order = cands.filter { !recentOwners.contains($0.owner) && $0.owner != here.owner } + cands.filter { recentOwners.contains($0.owner) || $0.owner == here.owner }
    // The window you're working in (front-most) goes first, unless the pet was just there: it likes to be where you are
    let front = scene.order.first.map { "w\($0)" }
    if let i = order.firstIndex(where: { $0.owner == front }), !recentOwners.contains(order[i].owner), order[i].owner != here.owner { order.insert(order.remove(at: i), at: 0) }
    // A window floating high above (its bottom edge far off the floor, too high to climb or leap): now and then dive in and drop onto it from above.
    // Checked first, because walking to a nearer spot almost always succeeds; without this the pet stayed on the floor and the Dock for tens of minutes
    // when every nearby window floated above the Dock (measured 2026-11-20)
    if let f = order.first(where: { $0.kind == .window && $0.y - pos.y > 650 }), Double.random(in: 0...1) < (f.owner == front ? 0.6 : 0.3) { dive(to: f); return true }
    if order.prefix(6).contains(where: { goVia($0, dive: false) }) { return true }
    // Same screen's floor, but cut off by a window that reaches down to the Dock or floor: sneak behind it and come out on the other side
    if here.kind == .base, let f = order.first(where: { $0.kind == .base && $0.owner == here.owner && min(abs($0.x0 - pos.x), abs($0.x1 - pos.x)) < 600 }) {   // Walking hidden behind is limited to about 6 seconds
      let room = max(0, min(300, f.x1 - f.x0 - halfW * 2 - 4))
      let x = f.x0 > here.x1 ? f.x0 + halfW + 2 + .random(in: 0...room) : f.x1 - halfW - 2 - .random(in: 0...room)
      floorID = nil; act = .sneak(x, f.id); schedule(1.0 / 24); return true
    }
    // On a high window that can't be reached by walking: sometimes dive in and drop out from above it
    if order.prefix(6).contains(where: { leap(to: $0) }) { return true }                 // If it can't be reached by walking, long jump sideways or diagonally
    return false
  }
  /// Only the floor of the screen where the mouse is (where the user is looking). All of them if none are on that screen
  func nearMe(_ fs: [Floor]) -> [Floor] {
    let m = NSEvent.mouseLocation
    guard let scr = NSScreen.screens.first(where: { $0.frame.contains(m) }) else { return fs }
    let mine = fs.filter { scr.frame.contains(CGPoint(x: $0.mid, y: $0.y)) }
    return mine.isEmpty ? fs : mine
  }
  /// Go to a widget or window: only when reachable (false if not). So it doesn't fly around, jumps are limited to 220pt wide and 200pt high
  static let HOP_X: CGFloat = 220, HOP_Y: CGFloat = 200, GRAB_Y: CGFloat = 160, CLIMB_H: CGFloat = 220, HOP_UP: CGFloat = 130, CLIMB_FAR: CGFloat = 2000   // Even a window as tall as the screen is climbed along its long side (with 480 and 900, it couldn't get onto tall windows and stayed on the floor); rest about every 500pt
  @discardableResult func go(to f: Floor, climbMax: CGFloat = Pet.CLIMB_H) -> Bool {
    guard let here = floor, f.id != here.id else { return false }
    // 1) Climb the side: walk to the side (if the bottom edge is close, jump slightly and hang on) and climb up
    if f.widget, f.y > pos.y + 20, f.y - here.y <= climbMax, f.bottom - here.y <= Pet.GRAB_Y, !here.widget || here.y < f.bottom {   // Only low walls (about widget height) are climbed
      let R = f.rect == .zero ? CGRect(x: f.x0, y: f.bottom, width: f.x1 - f.x0, height: f.y - f.bottom) : f.rect
      let left = R.minX - halfW - 1, right = R.maxX + halfW + 1
      let front: [CGRect] = { if let n = stackedOn, let i = scene.order.firstIndex(of: n) { return Array(scene.walls[..<i]) }; return scene.walls }()   // Windows in front of the pet (all windows when on the floor)
      let seen = { (x: CGFloat) -> Bool in                                              // If the side to climb is covered by a front window, it is invisible the whole way up; don't climb such walls
        let strip = CGRect(x: x - self.halfW, y: here.y, width: self.halfW * 2, height: f.y - here.y).insetBy(dx: 2, dy: 2)
        return !front.contains { $0 != R && $0.intersects(strip) }
      }
      let sides = [(left, f.edgeL), (right, f.edgeR)].filter { $0.1 && $0.0 > here.x0 + halfW && $0.0 < here.x1 - halfW && seen($0.0) }.map(\.0)
      if let side = sides.min(by: { abs($0 - pos.x) < abs($1 - pos.x) }) {
        walkHop = false; act = .walkTo(side, f.id); return true
      }
    }
    // 2) Short jump: directly if within reach, otherwise walk along the current floor to get close first
    guard f.y - here.y <= Pet.HOP_UP, here.y - f.y <= Pet.HOP_Y else { return false }   // Jump only a little upward (if high, dive in and come out above)
    if f.y > here.y + 20, f.rect != .zero, abs(pos.x - f.rect.midX) < f.rect.width / 2 + halfW + 2 {   // Overlapping below or beside a window: jumping straight would pass behind the window
      let outs = [f.rect.minX - halfW - 3, f.rect.maxX + halfW + 3].filter { $0 > here.x0 + halfW && $0 < here.x1 - halfW }
      guard let lx = outs.min(by: { abs($0 - pos.x) < abs($1 - pos.x) }) else { return false }
      walkHop = true; act = .walkTo(lx, f.id); return true
    }
    let tx = min(max(pos.x, f.x0 + halfW), f.x1 - halfW)
    if abs(tx - pos.x) <= Pet.HOP_X { hop(to: f); return true }
    let wx = min(max(tx, here.x0 + halfW), here.x1 - halfW)
    if abs(tx - wx) <= Pet.HOP_X { walkHop = true; act = .walkTo(wx, f.id); return true }
    return false
  }
  /// Can it get from a to b in one go (same criteria as go(to:): climb the side, or walk and make a short jump)
  func canReach(_ a: Floor, _ b: Floor) -> Bool {
    if b.widget, b.y > a.y + 20, b.y - a.y <= Pet.CLIMB_H, b.bottom - a.y <= Pet.GRAB_Y, !a.widget || a.y < b.bottom {
      for (x, ok) in [(b.x0 - halfW - 1, b.edgeL), (b.x1 + halfW + 1, b.edgeR)] where ok && x > a.x0 + halfW && x < a.x1 - halfW { return true }
    }
    guard b.y - a.y <= Pet.HOP_UP, a.y - b.y <= Pet.HOP_Y else { return false }
    let gap = max(0, max(b.x0, a.x0) - min(b.x1, a.x1))                          // Horizontal gap between the two segments
    return gap + halfW * 2 <= Pet.HOP_X
  }
  /// A high window that can't be reached directly is reached in two steps, using other windows or widgets as footholds
  /// Candidate selection: shuffle the top 4 by score, and put recently visited places (3) last, so it doesn't always go to the same spot. Places too far (over 900pt) are excluded
  var recentOwners: [String] = []
  var hops: [(String, Double)] = [], blocked: [String: Double] = [:]
  func pickTargets(_ fs: [Floor], by score: (Floor) -> CGFloat) -> [Floor] {
    let near = fs.filter { dist($0) < 900 }.sorted { score($0) > score($1) }
    let top = Array(near.prefix(4)).shuffled()
    return top.filter { !recentOwners.contains($0.owner) } + top.filter { recentOwners.contains($0.owner) }
  }
  func goVia(_ f: Floor, dive canDive: Bool = true) -> Bool {
    if go(to: f) { return true }
    guard let here = floor else { return false }
    let sameScreen = screenIdx(CGPoint(x: pos.x, y: pos.y + 1)) == screenIdx(CGPoint(x: f.mid, y: f.y + 1))
    if f.y > here.y {                                                                // Up: foothold, then (same screen) walk to the side and climb the long way
      let steps = floors.filter { $0.widget && $0.id != here.id && $0.id != f.id && $0.y > here.y && $0.y < f.y && canReach(here, $0) && canReach($0, f) }
      if let m = steps.min(by: { dist($0) < dist($1) }), go(to: m) { nextGoal = f.id; nextGoalDive = canDive; return true }
      if sameScreen, go(to: f, climbMax: Pet.CLIMB_FAR) { return true }
    }
    if sameScreen, here.widget {                                                     // On the current window: walk to the end toward the destination, step down, then go again
      let dir: CGFloat = f.mid < pos.x ? -1 : 1
      let edge = dir > 0 ? here.x1 - halfW : here.x0 + halfW
      if (dir > 0 ? here.edgeR : here.edgeL) { nextGoal = f.id; nextGoalDive = canDive; act = .walkOff(edge); return true }
    }
    if sameScreen, leap(to: f) { return true }                                     // On the same screen, long jump instead of diving in
    if canDive, !sameScreen || f.y - pos.y > Pet.CLIMB_FAR { dive(to: f); return true }   // Dive in and drop from above only for another monitor or places too high (not done when the destination was chosen while playing)
    return false
  }
  /// Dive into the floor, then drop and land from the top of the screen above the destination (for high windows or another monitor)
  var diveT0 = 0.0, dropIn = false, migrating = false
  var pocketSince = 0.0, pocketFloor = ""
  var upSince = 0.0, downSince = 0.0, upLimit = 60.0                             // When up on a window or widget / when down on the floor / limit for staying up
  var mouseScr = -1, mouseScrSince = 0.0, lastScrCheck = 0.0, nextMigrate = 0.0
  var screenLocked = false, escapes: [Double] = []
  // ---- Reaction sources: always on as a built-in app feature (they react automatically when connected; the menu 'extensions' option was removed) ----
  let extClaude = true      // Claude Code sessions (work, completion, questions, chatter)
  let extNotif = true         // React when a Mac notification banner appears (content is not read)
  let extSignal = true      // Signals sent by other programs (DotBuddy --signal ...)
  var signalWorkUntil = 0.0, signalAskUntil = 0.0
  /// Current mood: the most urgent state reported by the enabled extensions. If none, playing by day; sleeping at night, when away or when locked
  func baseMood() -> Mood {
    var m: Mood = .sleep
    let live = list.filter { !acked.contains($0.id) }                              // A session viewed by clicking is not nagged about until it goes back to work
    if extClaude, let f = live.first?.mood { m = max(m, f) }
    let t = now
    if extSignal && t < signalAskUntil { m = max(m, .ask) } else if extSignal && t < signalWorkUntil { m = max(m, .work) }
    if m == .sleep && !(extClaude && !live.isEmpty) {                               // With no agent news: awake and playing if a person is present
      let h = Calendar.current.component(.hour, from: Date())
      if !away && !screenLocked && h >= 7 && h < 24 { m = .free }
    }
    return m
  }
  /// If the user works on another monitor for a while (12 seconds), follow to that monitor: dive in and drop out above near the cursor (at most once per 30 seconds)
  /// Onto a window the user just brought to the front: hop if close, jump down onto it from the top of the screen if far (not every time, at most once per 25~50 seconds)
  var lastFront = 0, frontJump: (Int, Double)?, nextFrontJump = 0.0
  func stepFrontJump(_ t: Double) {
    guard let (num, at) = frontJump, t >= at, t >= graceUntil else { return }
    let busy: Bool = { switch act { case .walkOff, .walkTo: return false; default: return uninterruptible } }()   // If walking (going to step down or to climb), stop and go
    if floor == nil || busy { if t > at + 4 { frontJump = nil }; return }   // Go after the current action (jump, stepping down) finishes; wait up to 4 seconds
    frontJump = nil
    guard t > nextFrontJump, mood != .sleep, !screenLocked, Double.random(in: 0...1) < 0.6 else { return }
    let owner = "w\(num)"
    if floor?.owner == owner { return }                                             // Already on that window
    let m = NSEvent.mouseLocation
    guard let f = floors.filter({ $0.owner == owner }).min(by: { abs($0.mid - m.x) < abs($1.mid - m.x) }) else { return }   // If the top edge isn't visible (maximized or covered), don't go
    if let ms = screenFrames.firstIndex(where: { $0.contains(m) }), screenIdx(CGPoint(x: f.mid, y: f.y + 1)) != ms { return }   // If it's a window on a screen without the cursor (cmd-tab), don't go; it would go and immediately come back to the cursor's screen
    nextGoal = nil; walkHop = false
    guard go(to: f) || leap(to: f) else { return }                                  // Only when reachable by walking or jumping (diving in and coming out above looks like teleporting)
    nextFrontJump = t + .random(in: 25...50)
    if chatty >= 2, showing == nil, t - lastChat > 5, Bool.random() { say(any(T(["나도 볼래!", "이 창이구나!", "같이 보자~", "여기 재밌어 보여!", "기다려 나도 갈래!"], ["Let me see too!", "Oh, this window!", "Let's look together~", "This looks fun!", "Wait, I'm coming!"])), t) }
  }
  func followScreen(_ t: Double) {
    guard t - lastScrCheck > 1 else { return }
    lastScrCheck = t
    let m = NSEvent.mouseLocation, ms = screenFrames.firstIndex { $0.contains(m) } ?? -1
    if ms != mouseScr { mouseScr = ms; mouseScrSince = t }
    guard !screenLocked, t >= graceUntil, ms >= 0, screenIdx(pos) != ms, t - mouseScrSince > 12, t > nextMigrate, floor != nil, !uninterruptible, mood != .sleep || act.isAwake else { return }
    nextMigrate = t + 30
    let cands = floors.filter { screenIdx(CGPoint(x: $0.mid, y: $0.y + 1)) == ms && !$0.id.hasSuffix(":x") }
    if let g = cands.min(by: { hypot($0.mid - m.x, ($0.y - m.y) * 0.6) < hypot($1.mid - m.x, ($1.y - m.y) * 0.6) }) { dive(to: g); migrating = true }
  }
  func dive(to f: Floor) {
    if prof { FileHandle.standardError.write("  dive-from hidden=\(!window.occlusionState.contains(.visible)) \(Thread.callStackSymbols.dropFirst().prefix(2).map { $0.components(separatedBy: " ").filter { !$0.isEmpty }.dropFirst(3).first ?? "" })\n".data(using: .utf8)!) }
    diveT0 = now; act = .dive(f.id); schedule(1.0 / 60)
    if chatty >= 2, showing == nil, now - lastChat > 6, Double.random(in: 0...1) < 0.4 { say(any(T(["슝~", "저기로 갈래!", "잠깐 다녀올게"], ["Whoosh~", "Going over there!", "Be right back!"])), now) }
  }
  /// Long jump: cross to a far window or widget on the same screen, sideways or diagonally, in a big arc (easier for the eye to follow than diving in and coming out above)
  /// Only within 1000pt wide and 650pt up. The landing spot is slightly inside, not at the end
  @discardableResult func leap(to f: Floor) -> Bool {
    guard f.x1 - f.x0 >= halfW * 2 + 12, screenIdx(CGPoint(x: pos.x, y: pos.y + 1)) == screenIdx(CGPoint(x: f.mid, y: f.y + 1)) else { return false }
    let lo = f.x0 + halfW + 6, hi = f.x1 - halfW - 6, inset = min(60, (hi - lo) / 2)
    var x = min(max(pos.x, lo), hi)
    if x == lo { x += .random(in: 0...inset) } else if x == hi { x -= .random(in: 0...inset) }
    guard abs(x - pos.x) <= 1000, f.y - pos.y <= 650 else { return false }
    if pos.y - f.y > 250 {                                                          // Far down: hop up slightly and fly with the same gravity as when falling from the desktop
      let g: CGFloat = 2600, vy0: CGFloat = 380
      let tFly = (vy0 + (vy0 * vy0 + 2 * g * (pos.y - f.y)).squareRoot()) / g   // If the name is T, it shadows the text function T(...)
      vel = CGVector(dx: (x - pos.x) / tFly, dy: vy0); floorID = nil; fallTop = pos.y
      act = .fall; passThru = true; dropOwner = f.owner; ballistic = true; nextGoal = nil; walkHop = false
      schedule(1.0 / 60)
      if chatty >= 2, showing == nil, now - lastChat > 8, Double.random(in: 0...1) < 0.35 { say(any(T(["뛰어내린다!", "슝~", "으랏차!"], ["Jumping down!", "Whoosh~", "Hup!"])), now) }
      return true
    }
    let d = hypot(x - pos.x, f.y - pos.y)
    jumpUp = false; jumpPeak = 30 + min(140, d * 0.12)
    act = .jump(pos, CGPoint(x: x, y: f.y), now + (d > 300 ? 0.28 : 0.2), 0.42 + Double(d) / 1500)   // Crouch big, then stretch
    floorID = nil; targetFloor = f.id; nextGoal = nil; walkHop = false
    schedule(1.0 / 60)
    if chatty >= 2, showing == nil, now - lastChat > 8, Double.random(in: 0...1) < 0.35 { say(any(T(["영차!", "점프!", "날아간다~", "으랏차!", "멀리뛰기!"], ["Hup!", "Jump!", "Wheee, I'm flying~", "Heave-ho!", "Long jump!"])), now) }
    return true
  }
  func hop(to f: Floor) {
    let x = min(max(pos.x, f.x0 + halfW + 6), f.x1 - halfW - 6)
    let d = hypot(x - pos.x, f.y - pos.y)
    jumpUp = f.y > pos.y + 20 && f.kind != .base                                    // To a window above: first shoot up, then go over
    act = .jump(pos, CGPoint(x: x, y: f.y), now + (d > 120 ? 0.22 : 0.16), (jumpUp ? 0.45 : 0.35) + Double(d) / 1400)   // Crouch (longer the farther it jumps)
    floorID = nil
    targetFloor = f.id
    schedule(1.0 / 60)                                                           // Even if started outside a tick, from the first frame
  }
  var targetFloor: String?
  var fallCheck = CGPoint.zero, fallCheckT = 0.0
  var walkHop = false, jumpUp = false, jumpPeak: CGFloat = 28, afterJump: Act?, afterFloor: String?
  /// Edge crossing: hop a short way instead of teleporting, then on to the next action
  func edgeHop(to p: CGPoint, then next: Act, floor fid: String? = nil, dur: Double = 0.26, peak: CGFloat = 10) {
    afterJump = next; afterFloor = fid; targetFloor = nil; floorID = nil; jumpUp = false; jumpPeak = peak
    act = .jump(pos, p, now + 0.08, dur)
    schedule(1.0 / 60)
  }
  var slideStop: CGFloat = 0
  var hangOwner = "", hangY: CGFloat = 0
  // When called to the top, to the visible floor (bottom of the screen)
  func goVisible() {
    refreshFloors(force: true)
  }

  // With DOTBUDDY_PROF=1, print tick processing time to standard error every 5 seconds (for performance checks)
  let prof = ProcessInfo.processInfo.environment["DOTBUDDY_PROF"] != nil
  var profT: [Double] = [], profAt = 0.0
  var profLast = 0.0, profPosT = 0.0, flingTrace = 0.0, actLogName = "", profHidden = false
  func tick() {
    if prof {
      let t0 = now, first = profLast == 0, gap = t0 - profLast; profLast = t0       // now is a fresh time on every read, so read it once
      if t0 - profPosT >= 1 { profPosT = t0; FileHandle.standardError.write("  pos t=\(Int(t0)) x=\(Int(pos.x)) y=\(Int(pos.y)) floor=\(floor?.id ?? "-")\n".data(using: .utf8)!) }   // Position every second (for the distribution of where it stays)
      if !first, gap > 0.06, { switch act { case .jump, .fall: return true; default: return false } }() { FileHandle.standardError.write("  GAP \(String(format: "%.2f", gap))s rate=\(rate) occluded=\(!window.occlusionState.contains(.visible))\n".data(using: .utf8)!) }
      let a = DispatchTime.now().uptimeNanoseconds; tickBody()
      let an = String(describing: act).components(separatedBy: "(")[0]
      if an != actLogName { FileHandle.standardError.write("  ACT \(String(format: "%.2f", t0)) \(actLogName) -> \(an) x=\(Int(pos.x)) y=\(Int(pos.y)) floor=\(floorID ?? "-") front=\(frontJump.map { "\($0.0)" } ?? "-")\n".data(using: .utf8)!); actLogName = an }   // Every time the action changes (from what to what)
      if t0 < flingTrace {
        let onScr = screenFrames.contains { $0.contains(CGPoint(x: pos.x, y: pos.y + 6 * scale)) }
        let vis = window.occlusionState.contains(.visible), wf = window.frame, vf = view.frame
        FileHandle.standardError.write("  FT \(String(format: "%.3f", t0)) x=\(Int(pos.x)) y=\(Int(pos.y)) act=\(String(describing: act).components(separatedBy: "(")[0]) stack=\(stackedOn ?? -1) lvl=\(window.level.rawValue) cov=\(coveredPoints()) onScr=\(onScr) occVis=\(vis) win=\(Int(wf.minX)),\(Int(wf.minY)),\(Int(wf.width))x\(Int(wf.height)) view=\(Int(vf.minX)),\(Int(vf.minY)) alpha=\(window.alphaValue) shown=\(window.isVisible)\n".data(using: .utf8)!)
      }
      profT.append(Double(DispatchTime.now().uptimeNanoseconds - a) / 1e6)
      healthCheck(t0)
      if now - profAt > 5 { profAt = now; let s = profT.sorted(); if !s.isEmpty { FileHandle.standardError.write("ticks \(s.count) moves \(PetWindow.moves) bmoves \(PetWindow.bubbleMoves) orders \(PetWindow.orders) avg \(String(format: "%.2f", s.reduce(0, +) / Double(s.count)))ms p95 \(String(format: "%.2f", s[s.count * 95 / 100]))ms max \(String(format: "%.2f", s.last!))ms act \(act)\n".data(using: .utf8)!) }; profT.removeAll(); PetWindow.moves = 0; PetWindow.bubbleMoves = 0; PetWindow.orders = 0 }
    } else { tickBody() }
  }
  // ---- Anomaly detection (DOTBUDDY_PROF): automatically catches situations that would look odd to the user and logs them as "  HEALTH kind ..." ----
  var hInvisibleSince = 0.0, hAirSince = 0.0, hAirPos = CGPoint.zero, hStuckSince = 0.0, hStuckPos = CGPoint.zero
  var hActs: [(Double, String, CGPoint)] = [], hSides: [ObjectIdentifier: [(Double, Int)]] = [:], hReported: [String: Double] = [:]
  func hLog(_ kind: String, _ detail: String, _ t: Double) {
    if let last = hReported[kind], t - last < 10 { return }                          // Same kind only once per 10 seconds
    hReported[kind] = t
    FileHandle.standardError.write("  HEALTH \(kind) \(detail) act=\(String(describing: act).components(separatedBy: "(")[0]) x=\(Int(pos.x)) y=\(Int(pos.y)) floor=\(floorID ?? "-")\n".data(using: .utf8)!)
  }
  func healthCheck(_ t: Double) {
    let name = String(describing: act).components(separatedBy: "(")[0]
    // 1) Invisible: four or more of the five body points are covered by a front window or on no screen, for over 3 seconds
    let hiddenPts = coveredPoints()
    if hiddenPts >= 4 { if hInvisibleSince == 0 { hInvisibleSince = t } else if t - hInvisibleSince > 3 { hLog("invisible", "\(String(format: "%.1f", t - hInvisibleSince))s covered=\(hiddenPts)/5", t) } } else { hInvisibleSince = 0 }
    // 2) Frozen in mid-air: no floor (and not falling, jumping, dragging, etc.) for 1 second, or falling but staying in place for over 1 second
    let airborne = ["fall", "jump", "drag", "dive", "climb", "descend", "hang", "slide", "sneak"].contains(name)
    if floor == nil && (!airborne || hypot(pos.x - hAirPos.x, pos.y - hAirPos.y) < 0.5) {
      if hAirSince == 0 { hAirSince = t; hAirPos = pos } else if t - hAirSince > 1 { hLog("air-stall", "\(String(format: "%.1f", t - hAirSince))s", t) }
    } else { hAirSince = 0; hAirPos = pos }
    // 3) Walking in place: a walking-type action but within 4pt for over 3 seconds
    if ["walk", "walkTo", "walkOff", "stroll", "sneak", "follow"].contains(name) {
      if hStuckSince == 0 || hypot(pos.x - hStuckPos.x, pos.y - hStuckPos.y) > 4 { hStuckSince = t; hStuckPos = pos } else if t - hStuckSince > 3 { hLog("stuck-walk", "\(String(format: "%.1f", t - hStuckSince))s", t) }
    } else { hStuckSince = 0 }
    // 4) Repeating in place: the same action starts more than 6 times at the same spot (40pt) within 30 seconds
    if hActs.last?.1 != name { hActs.append((t, name, pos)); hActs = hActs.filter { t - $0.0 < 30 } }
    if ["jump", "climb", "walkOff", "leap", "dive"].contains(name) {
      let same = hActs.filter { $0.1 == name && hypot($0.2.x - pos.x, $0.2.y - pos.y) < 40 }.count
      if same >= 6 { hLog("loop", "\(name)×\(same) in 30s", t) }
    }
  }
  /// Number of the five body points covered by a front window (all windows if on the floor level, including the Dock bar) or off screen
  func coveredPoints() -> Int {
    let front = frontWalls()
    let body = [CGPoint(x: pos.x, y: pos.y + 6 * scale), CGPoint(x: pos.x - halfW * 0.6, y: pos.y + 3 * scale), CGPoint(x: pos.x + halfW * 0.6, y: pos.y + 3 * scale), CGPoint(x: pos.x, y: pos.y + 11 * scale), CGPoint(x: pos.x, y: pos.y + 1)]
    return body.filter { p in !screenFrames.contains { $0.contains(p) } || front.contains { $0.contains(p) } }.count
  }
  func healthBubbleSide(_ win: NSWindow, _ side: Int) {                              // 5) Bubble flip-flop: one bubble changed position more than 4 times within 3 seconds
    guard prof else { return }
    let t = now, k = ObjectIdentifier(win)
    let a = ((hSides[k] ?? []) + [(t, side)]).filter { t - $0.0 < 3 }; hSides[k] = a
    if a.count > 4 { hLog("bubble-flip", "\(win == chatWin ? "chat" : win == noticeWin ? "notice" : "badge") \(a.map { String($0.1) }.joined(separator: ","))", t) }
  }
  func profile<T>(_ name: String, _ f: () -> T) -> T {
    guard prof else { return f() }
    let a = DispatchTime.now().uptimeNanoseconds; let r = f(); let ms = Double(DispatchTime.now().uptimeNanoseconds - a) / 1e6
    if ms > 2 { FileHandle.standardError.write("  slow \(name) \(String(format: "%.2f", ms))ms\n".data(using: .utf8)!) }
    return r
  }
  var lastActName = "", profPos = CGPoint.zero, profAct = ""
  func tickBody() {
    let t = now
    if t < snoozeUntil {                                                            // Hidden for a while (menu): keep everything out of sight, wake rarely
      for w in [window, noticeWin, chatWin, badgeWin] as [NSWindow?] where w?.isVisible == true { w?.orderOut(nil) }
      schedule(min(5, max(0.5, snoozeUntil - t))); return
    }
    if snoozed { snoozed = false; window.orderFrontRegardless(); applyLevel(); cheerUntil = t + 1.5; say(T("나 왔어!", "I'm back!"), t) }
    if prof {                                                                       // Teleport detection: if moved more than 25pt in one tick, what moved it
      let n0 = String(describing: act).components(separatedBy: "(")[0]
      let jump = hypot(pos.x - profPos.x, pos.y - profPos.y)
      if jump > 25 && profPos != .zero && !["fall", "drag", "dive"].contains(profAct) && !["fall", "drag", "dive"].contains(n0) { FileHandle.standardError.write("  TELEPORT \(Int(jump))pt \(profAct)->\(n0) from=(\(Int(profPos.x)),\(Int(profPos.y))) to=(\(Int(pos.x)),\(Int(pos.y)))\n".data(using: .utf8)!) }
      profPos = pos; profAct = n0
    }
    if prof { let n = String(describing: act).components(separatedBy: "(")[0]; if n != lastActName { lastActName = n; FileHandle.standardError.write("  act \(n) y=\(Int(pos.y)) x=\(Int(pos.x)) floor=\(floorID ?? "-") up=\(upSince > 0 ? Int(t - upSince) : -1)/\(Int(upLimit))\n".data(using: .utf8)!) } }
    // Session changes arrive immediately as file events. This is a backup check for what events can't catch (falling asleep after 20 minutes, process death, waiting on a question)
    if t - lastPoll > (list.contains { $0.mood == .work } ? 5 : 30) { poll() }
    let hidden = !window.occlusionState.contains(.visible) && showing == nil && coveredPoints() >= 4   // Over the Dock (a full-screen transparent window), it is visible even if the system says 'occluded'; only when the body is actually covered
    escapes = escapes.filter { t - $0 < 20 }
    let busyScene = t < sceneActiveUntil || (hidden && hiddenSince > 0 && t - hiddenSince < 8)   // The window is moving or was just covered
    if graceUntil > 0, t >= graceUntil, !graceScanned { graceScanned = true; lastFloors = 0 }   // The wait just ended: rescan now so the usual escape runs from fresh floors (the hidden escape below waits for it)
    if t - lastFloors > (t < graceUntil + 0.5 ? 0.25 : busyScene ? 0.8 : (mood == .sleep || hidden ? 6 : (floor?.kind == .base ? 4 : 2)) * (fastMoving ? 4 : 1)) { lastFloors = t; lastRide = 0; stepRide(t); refreshFloors() }   // Apply the window move first so it isn't moved twice
    let dt = min(0.25, max(0.001, t - lastTick)); lastTick = t                  // Actual elapsed time (keeps its own speed even when waking slowly while covered)
    let mdt = min(dt, 0.05)                                                     // One walking or rolling step is capped at 1/20 second; this used to skip 30pt on the first step after starting to move from a slow rest
    // If covered for over 1.5 seconds, run to a visible floor
    if prof, hidden != profHidden { profHidden = hidden; FileHandle.standardError.write("  HID \(hidden ? 1 : 0) \(String(format: "%.2f", t)) x=\(Int(pos.x)) y=\(Int(pos.y)) act=\(String(describing: act).components(separatedBy: "(")[0]) floor=\(floorID ?? "-")\n".data(using: .utf8)!) }
    if hidden { if hiddenSince == 0 { hiddenSince = t; lastFloors = 0 } } else { hiddenSince = 0 }   // Just covered: re-measure the floor right away
    if hidden, !screenLocked, t >= graceUntil + 0.6, escapes.count < 2, t - hiddenSince > 1.5, !inTransit, floor != nil {   // If the screen is locked, being invisible is expected; don't escape. At most twice per 20 seconds
      hiddenSince = t; escapes.append(t)
      if let f = floor, coverEscape(from: f) {} else
      if let n = floors.filter({ $0.id != floorID && abs($0.y - pos.y) < 3 && !$0.id.hasSuffix(":x") && abs($0.mid - pos.x) < 900 }).min(by: { dist($0) < dist($1) }) {
        floorID = nil; act = .sneak(min(max(pos.x, n.x0 + halfW), n.x1 - halfW), n.id)
      } else if let to = nearMe(floors).filter({ $0.id != floorID && !$0.id.hasSuffix(":x") && dist($0) > 40 }).min(by: { dist($0) < dist($1) }) { if dist(to) <= 160 { hop(to: to) } else if !leap(to: to) { dive(to: to) } }
    }
    // Boxed into a sliver of floor (a window reaching past the screen bottom leaves only a gap at the edge): after 12 seconds there, get out.
    // Seen 2026-11-20: a window covered all of the bottom-left floor but 86pt and the pet stayed in that gap for a long time
    if let f = floor, f.kind == .base, f.x1 - f.x0 < halfW * 2 + 60, !inTransit {
      if pocketSince == 0 || pocketFloor != f.id { pocketSince = t; pocketFloor = f.id }
      else if t - pocketSince > 12 {
        pocketSince = t
        let others = nearMe(floors).filter { $0.id != f.id && !$0.id.hasSuffix(":x") && $0.x1 - $0.x0 >= halfW * 2 + 20 }
        let front = scene.order.first.map { "w\($0)" }
        if let to = others.first(where: { $0.owner == front }) ?? others.filter({ $0.kind == .base }).max(by: { ($0.x1 - $0.x0) < ($1.x1 - $1.x0) }) ?? others.min(by: { dist($0) < dist($1) }) {
          if !leap(to: to) { dive(to: to) }
        }
      }
    } else { pocketSince = 0 }
    profile("ride") { stepRide(t) }
    stepBanner(t)
    if t - lastMoodCheck > 5 { lastMoodCheck = t; applyMood() }                       // Mood that changes with time, being away, or signal expiry
    if let f = floor {                                                             // Time spent up and down
      if f.widget, recentOwners.last != f.owner {                                      // Places recently climbed
        recentOwners = Array((recentOwners + [f.owner]).suffix(3))
        hops = Array((hops + [(f.owner, t)]).suffix(5))
        if hops.count == 5, t - hops[0].1 < 40, Set(hops.map(\.0)).count <= 2 {      // Went back and forth between two places five times within 40 seconds: exclude both from destinations for 1 minute
          for (o, _) in hops { blocked[o] = t + 60 }; hops = []
        }
      }
      if f.widget { if upSince == 0 { upSince = t; upLimit = .random(in: 30...80) } }
      else if upSince != 0 || downSince == 0 { upSince = 0; downSince = t }
    }
    followScreen(t)
    stepFrontJump(t)
    profile("away") { stepAway(t) }
    let swA = DispatchTime.now().uptimeNanoseconds
    switch act {
    case .fall:
      fallTop = max(fallTop, pos.y)
      if hypot(pos.x - fallCheck.x, pos.y - fallCheck.y) > 6 { fallCheck = pos; fallCheckT = t }
      else if t - fallCheckT > 1.0, let to = nearMe(floors).filter({ !$0.id.hasSuffix(":x") }).min(by: { dist($0) < dist($1) }) {   // Stuck somewhere
        fallCheckT = t; vel = .init(dx: 0, dy: 0); dive(to: to); break
      }
      let tg: CGFloat = [550, 1700, 1500][throwFeel], tdrag: CGFloat = [0.9, 0.45, 0.7][throwFeel], tcap: CGFloat = [-800, -1500, -1400][throwFeel]   // Normal: gravity 800 and sideways damping 0.85 were too floaty (far, like drawing a mountain); make it weightier
      vel.dy -= (thrown ? (vel.dy > 0 ? tg * 0.9 : tg) : 2600) * CGFloat(dt); if !ballistic { vel.dx *= pow(thrown ? tdrag : 0.4, CGFloat(dt)) }   // Slightly lighter while rising from a throw; 0.45 and 0.75 times were too light
      if thrown { vel.dy = max(vel.dy, tcap) }                                     // When thrown, the descent speed has a cap (so it lands floating)   // Long jumps shouldn't lose less sideways speed (so they reach the target)
      let ny = pos.y + vel.dy * CGFloat(dt), nx = pos.x + vel.dx * CGFloat(dt)
      if let f = floors.filter({ $0.y <= pos.y + 0.5 && $0.y >= ny && nx >= $0.x0 + 4 && nx <= $0.x1 - 4 && (dropOwner == nil || $0.owner == dropOwner || $0.kind == .base) }).max(by: { $0.y < $1.y }) {
        pos = CGPoint(x: nx, y: f.y); floorID = f.id
        if vel.dy < -1200 { vel.dy = -vel.dy * 0.25; vel.dx *= ballistic ? 0.2 : 0.5; if ballistic { ballistic = false }; act = .fall; floorID = nil; pos.y += 1; if chatty >= 2, showing == nil, t - lastChat > 2, Double.random(in: 0...1) < 0.5 { say(line(.bounce, ctx), t) } }
        else {
          vel = .init(dx: 0, dy: 0)
          let drop = fallTop - pos.y; fallTop = 0
          landUntil = t + 0.14; dustT0 = t
          let spun = spinning; spinning = false
          if dropIn {                                                                 // Dropped in from above
            dropIn = false; act = .react(migrating ? .wave : .hop, t, migrating ? 1.4 : 0.6)
            if migrating, chatty > 0, showing == nil {                                  // Followed to another monitor: one meme line
              say(any(T(["저 불렀어요?", "찾았어요?", "여기 계셨구나!", "나 두고 가지 마~", "따라왔지롱", "짜잔~ 나야!", "어디 갔나 했잖아", "이쪽이 더 재밌어 보여서~", "왔다 갔다 바쁘다 바빠", "들켰다!"], ["You called?", "Looking for me?", "Oh, there you are!", "Don't leave me behind~", "Followed you, hehe", "Ta-da~ it's me!", "Where'd you go?", "This side looked more fun~", "Back and forth, so busy!", "You caught me!"])), t)
            } else if chatty >= 2, showing == nil, t - lastChat > 4, Bool.random() { say(any(T(["짠!", "도착!", "왔다~"], ["Ta-da!", "Made it!", "I'm here~"])), t) }
            migrating = false
          }
          else if spun || thrown && drop > 120 || drop > 250 && Double.random(in: 0...1) < 0.6 { act = .react(.dizzy, t, thrown ? 1.8 : 1.4); if chatty > 0, showing == nil, t - lastChat > 1.5 { say(line(.landHard, ctx), t) } }   // Dizzy after falling from a height or being thrown and falling
          else { if dropSaid, chatty > 0, showing == nil, t - lastChat > 1 { say(line(.dropped, ctx), t) }; decide() }
          dropSaid = false
        }
      } else {
        // Entering a window's side from the side: thud, bounce back out
        let bodyTop = ny + 14 * scale
        if passThru { pos = CGPoint(x: nx, y: ny) }                                  // Passing behind: falls straight down without catching on anything
        else if abs(vel.dx) > 80, let w = scene.walls.enumerated().first(where: { (i, w) in
          let crosses = ny < w.maxY - 4 && bodyTop > w.minY && ((pos.x <= w.minX - halfW * 0.5) != (nx <= w.minX - halfW * 0.5) || (pos.x >= w.maxX + halfW * 0.5) != (nx >= w.maxX + halfW * 0.5))
          guard crosses else { return false }
          if !handFall { return true }
          // Thrown: only a side you can see. The spot where it would hit must not be covered by a window in front (hitting hidden sides sent a throw to the left off to the right, 2026-11-18)
          let hit = CGPoint(x: nx < w.midX ? w.minX + 2 : w.maxX - 2, y: ny + 7 * scale)
          return !scene.walls[..<i].contains { $0.contains(hit) && (nx < w.midX ? $0.maxX - w.minX : w.maxX - $0.minX) > 40 }   // A front window overlapping the side by a sliver doesn't hide it (windows tiled side by side overlap a few points; the throw flew through, 2026-11-23)
        })?.element {
          let fromLeft = pos.x < w.midX
          pos = CGPoint(x: fromLeft ? w.minX - halfW * 0.5 - 1 : w.maxX + halfW * 0.5 + 1, y: ny)
          vel.dx = -vel.dx * (handFall ? 0.25 : 0.45); bonkUntil = t + 0.45           // A thrown pet stops dead against the side and slides down it (only a small bounce back)
          if chatty > 0, showing == nil, t - lastChat > 1.2 { say(line(.bonk, ctx), t) }
        } else if let w = scene.walls.enumerated().first(where: { (i, w) in                // Collisions only with windows whose spot is visible (top edges and sides of windows covered by a front window are passed through; this caused the catching, stuttering look)
          let b = CGPoint(x: nx, y: ny + 7 * scale)
          return wallHit(w, from: pos, to: CGPoint(x: nx, y: ny)) && !scene.walls[..<i].contains { $0.contains(b) }
        })?.element {
          if pos.y + 7 * scale >= w.maxY - 2 {                                       // From above (body center was above the top edge): a top edge it can't stand on (covered, above the screen, narrow gap)
            if handFall && vel.dy > 0 { pos = CGPoint(x: nx, y: ny) }                // Rising from a throw: it doesn't land on a top edge, it just passes (in front of all windows)
            else if let dir = slipDir(on: w) {                                              // If a way to step aside is open, slide down
              pos.y = w.maxY; vel.dy = 0; vel.dx = dir * max(abs(vel.dx), 320)
              if chatty >= 2, showing == nil, t - lastChat > 3 { say(line(.slip, ctx), t) }
            } else if handFall { pos = CGPoint(x: nx, y: ny) }                        // While falling after release, in front of all windows; it doesn't slip behind but passes in front and lands on a visible floor (otherwise it vanished behind a window and reappeared)
            else { passThru = true; pos = CGPoint(x: nx, y: ny); vel.dx *= 0.3 }     // Gap is narrow (windows on both sides): don't squeeze, pass behind and fall; walk out to a visible spot on the floor
          } else if handFall { pos = CGPoint(x: nx, y: ny) }                         // While flying after release, in front of all windows; no chance of hitting its head on a bottom edge
          else { pos.x = nx; vel.dy = -abs(vel.dy) * 0.3; bonkUntil = t + 0.45; if chatty > 0, showing == nil, t - lastChat > 1.2 { say(line(.headBonk, ctx), t) } }   // From below: bonk on the head
        } else { pos = CGPoint(x: nx, y: ny) }
      }
      bounceWalls()
      // If it fell below the Dock, onto that screen's floor; only the floor of the screen the pet is horizontally inside now (so it doesn't catch the adjacent screen's floor and get stuck on the boundary)
      if case .fall = act, let si = screenIdx(pos),
         let base = floors.filter({ $0.owner == "s\(si)" && pos.y < $0.y - 2 }).min(by: { dist($0) < dist($1) }) {
        let fromY = fallTop; fallTop = 0; vel = .init(dx: 0, dy: 0); landUntil = t + 0.14; dustT0 = t; pos.y = base.y   // (on the floor line first: below it, body points off screen counted as covered)
        if pos.x >= base.x0 + halfW && pos.x <= base.x1 - halfW { pos.y = base.y; floorID = base.id; decide() }
        else if handFall ? abs(min(max(pos.x, base.x0 + halfW), base.x1 - halfW) - pos.x) > 120 : coveredPoints() < 3,   // (also when it walked off a window and is still seen: sneaking out from behind the back window hid it, 2026-11-24)
                let g = { (ok: [Floor]) in (ok.contains { $0.y < fromY - 40 } ? ok.filter { $0.y < fromY - 40 } : ok).min(by: { dist($0) < dist($1) }) }(   // A floor lower than where it fell from first (the nearest was often the window it had just jumped off, and it went straight back up)
                  floors.filter({ !$0.id.hasSuffix(":x") && $0.x1 - $0.x0 >= halfW * 2 + 8 && screenIdx(CGPoint(x: $0.mid, y: $0.y + 1)) == si })) {
          pos.y = base.y; dive(to: g)                                                // Fell in front (thrown, or its window closed) onto a spot behind a window, far from any visible floor: hop out in front and drop onto the nearest visible spot.
        }                                                                              // Walking out behind the window kept it unseen for seconds and it popped up at the screen bottom (closing a KakaoTalk window over Safari, 2026-11-23)
        else { pos.y = base.y; act = .sneak(min(max(pos.x, base.x0 + halfW), base.x1 - halfW), base.id) }   // If it fell behind a window, walk out to where it is visible
      } else if pos.y < -3000, let base = floors.first(where: { $0.kind == .base }) {
        fallTop = 0; pos = CGPoint(x: base.mid, y: base.y); floorID = base.id; vel = .init(dx: 0, dy: 0); decide()
      }
    case let .jump(a, b, t0, dur):
      let k = max(0, min(1, (t - t0) / dur)), e = CGFloat(k)
      if jumpUp {                                                                   // Shoot up (barely moving sideways), then go over above the top edge and land; it doesn't pass behind the window
        let top = b.y + 16, rise: CGFloat = 0.62
        if e < rise { let u = e / rise; pos = CGPoint(x: a.x + (b.x - a.x) * 0.04 * u, y: a.y + (top - a.y) * (1 - (1 - u) * (1 - u))) }
        else { let u = (e - rise) / (1 - rise); pos = CGPoint(x: a.x + (b.x - a.x) * (0.04 + 0.96 * u), y: top + (b.y - top) * u * u) }
      } else {
        let peak = max(a.y, b.y) + jumpPeak + abs(b.x - a.x) * 0.06 + pounceBoost              // Low, short arc
        let y = (1 - e) * (1 - e) * a.y + 2 * (1 - e) * e * peak + e * e * b.y
        pos = CGPoint(x: a.x + (b.x - a.x) * e, y: y)
      }
      if pounceBoost > 0, k > 0.35, k < 0.65, !caught { let m = NSEvent.mouseLocation; if abs(m.x - pos.x) < halfW + 6 && abs(m.y - headY) < 26 { caught = true } }
      if k >= 1 {
        jumpUp = false; jumpPeak = 28
        if var nx = afterJump { afterJump = nil; floorID = afterFloor; afterFloor = nil; targetFloor = nil; if case let .react(r, _, d) = nx { nx = .react(r, t, d); landUntil = t + 0.14 }; act = nx; break }
        if let id = targetFloor, id.hasPrefix("climb:") { targetFloor = nil; act = .climb(String(id.dropFirst(6)), pos.x < (floors.first { $0.id == String(id.dropFirst(6)) }?.mid ?? pos.x) ? 1 : -1); break }
        floorID = targetFloor; targetFloor = nil; landUntil = t + 0.14; dustT0 = t
        let pounced = pounceBoost > 0, got = caught; pounceBoost = 0; caught = false
        if floor == nil { act = .fall }
        else if pounced {                                                          // Sometimes it really catches it
          act = .react(got ? .star : (Bool.random() ? .dizzy : .squish), t, got ? 1.2 : 0.9)
          if chatty >= 2, showing == nil, t - lastChat > 4, got || Bool.random() { say(line(got ? .caught : .missed, ctx), t) }
        } else { decide() }
      }
    case let .walk(dir):
      guard let f = floor else { act = .fall; break }
      pos.x += dir * (t < stumbleUntil ? 12 : 38) * CGFloat(mdt)
      if Double.random(in: 0...1) < dt / 40 { stumbleUntil = t + 0.35 }                 // Sometimes a stumble
      else if Double.random(in: 0...1) < dt / 14 { standLook = Int(-dir); act = .stand; actUntil = t + 0.8; break }   // Stop and look back
      if pos.x < f.x0 + halfW || pos.x > f.x1 - halfW {
        pos.x = min(max(pos.x, f.x0 + halfW), f.x1 - halfW)
        let r = Double.random(in: 0...1), realEdge = dir > 0 ? f.edgeR : f.edgeL
        let beyond = CGPoint(x: (dir > 0 ? f.x1 : f.x0) + dir * (halfW + 6), y: f.y + 8 * scale)
        let here = CGPoint(x: (dir > 0 ? f.x1 : f.x0) - dir * 4, y: f.y + 8 * scale)
        if f.kind == .base, let next = screenFrames.firstIndex(where: { $0.contains(beyond) }), next != screenFrames.firstIndex(where: { $0.contains(here) }), r < 0.6 {   // Walk across to the next monitor (falls if the heights differ)
          floorID = nil; vel = CGVector(dx: dir * 90, dy: 60); act = .fall
        }
        else if f.widget, r < 0.4, let g = floors.filter({ g in g.widget && g.owner != f.owner && g.y < f.y + Pet.HOP_UP && g.y > f.y - 160
                   && (dir > 0 ? g.x0 > f.x1 - 20 && g.x0 < f.x1 + Pet.HOP_X : g.x1 < f.x0 + 20 && g.x1 > f.x0 - Pet.HOP_X) }).min(by: { abs($0.mid - pos.x) < abs($1.mid - pos.x) }) {
          jumpPeak = 40; hop(to: g)                                                       // Jump over to the next window
          if chatty >= 2, showing == nil, t - lastChat > 8, Double.random(in: 0...1) < 0.3 { say(any(T(["영차!", "점프!", "건너가자~"], ["Hup!", "Jump!", "Across we go~"])), t) }
        }
        else if !f.widget || !realEdge || r < 0.25 { act = .walk(-dir) }               // Turn around at a wall blocked by the screen edge or a front window
        else if r < 0.42 { wobbleUntil = t + 0.35; hangOwner = f.owner; hangY = f.y; actUntil = t + 0.3 + .random(in: 3...7)
          edgeHop(to: CGPoint(x: dir > 0 ? f.x1 + halfW * 0.45 : f.x0 - halfW * 0.45, y: f.y - CGFloat(GY + 1 - lastCanvas.top) * ds), then: .hang(f.owner, dir), dur: 0.3, peak: 6) }
        else if r < 0.55 { wobbleUntil = t + 0.4; act = .peek(dir); actUntil = t + 1.6 }                       // Look down
        else if r < 0.8 && mood != .work { wobbleUntil = t + 0.35; actUntil = t + 0.3 + .random(in: 5...10); edgeHop(to: CGPoint(x: dir > 0 ? f.x1 - 2 * scale : f.x0 + 2 * scale, y: f.y), then: .sitEdge(dir), floor: f.id, dur: 0.22, peak: 5) }   // Hop sideways to the edge and sit (this used to move 24pt at a time)
        else { slideStop = f.bottom; edgeHop(to: CGPoint(x: dir > 0 ? f.x1 + halfW + 1 : f.x0 - halfW - 1, y: f.y - 4 * scale), then: f.y - f.bottom <= 260 && Bool.random() ? .descend(dir) : .slide(dir), dur: 0.28, peak: 8) }   // Climbing down with hands and feet is only for low walls (slide if high)   // Hop out past the corner, then grab the side
      }
      if case .walk = act, t > actUntil { decide() }
    case let .roll(dir):
      guard let f = floor else { act = .fall; break }
      pos.x += dir * 120 * CGFloat(mdt)
      if pos.x < f.x0 + halfW * 0.3 || pos.x > f.x1 - halfW * 0.3 {
        if f.widget { floorID = nil; vel = CGVector(dx: dir * 120, dy: 0); act = .fall }   // Rolls off the end of the widget
        else { pos.x = min(max(pos.x, f.x0 + halfW), f.x1 - halfW); act = .roll(-dir) }
      } else if t > actUntil { decide() }
    case let .walkOff(x):                                                            // On reaching the end, hop forward and step down
      guard let f = floor else { act = .fall; break }
      let d = x - pos.x
      if abs(d) < 3 {
        let dir: CGFloat = x > f.mid ? 1 : -1
        edgeHop(to: CGPoint(x: (dir > 0 ? f.x1 : f.x0) + dir * (halfW + 4), y: f.y + 6), then: .fall, dur: 0.24, peak: 10)
        vel = CGVector(dx: dir * 40, dy: 0)
      } else { pos.x += (d > 0 ? 1 : -1) * min(abs(d), 40 * CGFloat(mdt)) }
    case let .stroll(x):                                                             // Stroll to the far side: on arrival, briefly look around or do the next thing
      guard let f = floor else { act = .fall; break }
      let d = min(max(x, f.x0 + halfW), f.x1 - halfW) - pos.x
      if abs(d) < 3 { if Bool.random() { standLook = Bool.random() ? 1 : -1; act = .stand; actUntil = t + .random(in: 0.8...2.2) } else { decide() } }
      else { if Double.random(in: 0...1) < dt / 40 { stumbleUntil = t + 0.35 }; pos.x += (d > 0 ? 1 : -1) * min(abs(d), (t < stumbleUntil ? 12 : 42) * CGFloat(mdt)) }
    case let .walkTo(x, id):
      guard floor != nil, let f = floors.first(where: { $0.id == id }) else { if floor == nil { act = .fall } else { decide() }; break }
      let d = x - pos.x
      if abs(d) < 3 {
        let atSide = x < f.x0 || x > f.x1
        if walkHop || !atSide || f.y <= pos.y + 20 { walkHop = false; hop(to: f) }                                   // When close, jump up briefly
        else if pos.y < f.bottom - 4 {                                                    // If the bottom edge is slightly high, jump and hang on
          targetFloor = "climb:" + id; floorID = nil
          act = .jump(pos, CGPoint(x: x, y: f.bottom), t, 0.4 + Double(f.bottom - pos.y) / 1400)
        } else { floorID = nil; act = .climb(id, x < f.mid ? 1 : -1) }
      } else { pos.x += (d > 0 ? 1 : -1) * min(abs(d), 70 * CGFloat(mdt)) }
    case let .climb(id, side):
      guard let f = floors.first(where: { $0.id == id }) else { act = .fall; break }
      if climbFrom == nil { climbFrom = pos.y; climbRestAt = f.y - pos.y > 240 ? pos.y + min(f.y - pos.y, 1000) * .random(in: 0.4...0.6) : .infinity }
      if pos.y >= climbRestAt { climbRestAt = f.y - pos.y > 450 ? pos.y + .random(in: 400...600) : .infinity; climbRestUntil = t + .random(in: 1.0...1.6); if chatty >= 2, Bool.random(), showing == nil, t - lastChat > 4 { say(any(T(["헥헥…", "조금만 쉬고…", "영차…!"], ["Huff, puff...", "Quick breather...", "Nnngh... hup!"])), t) } }
      if t >= climbRestUntil { pos.y += 110 * CGFloat(dt) }                            // On a high wall, hang halfway to catch its breath
      if pos.y >= f.y { pos.y = f.y; edgeHop(to: CGPoint(x: side > 0 ? f.x0 + halfW + 2 : f.x1 - halfW - 2, y: f.y), then: .react(.hop, t, 0.5), floor: f.id, peak: 8) }   // Heave over the top edge   // Hop once it is on top
    case let .hang(owner, dir):                                                 // Dangle, then climb back up or let go
      guard let f = floors.first(where: { $0.owner == owner && abs($0.y - hangY) < 3 }) else { vel = .init(dx: 0, dy: 0); act = .fall; break }
      if t > actUntil {
        if Bool.random() { edgeHop(to: CGPoint(x: dir > 0 ? f.x1 - halfW : f.x0 + halfW, y: f.y), then: .react(.hop, t, 0.5), floor: f.id, dur: 0.32, peak: 14) }
        else { vel = CGVector(dx: -dir * 60, dy: 0); act = .fall }
      }
    case let .sneak(x, id):
      guard let f = floors.first(where: { $0.id == id }) else { act = .fall; break }
      pos.y = f.y
      let d = x - pos.x
      if abs(d) < 3 {                                                              // Come out and look around; the segment number may have changed while walking, so find the segment it is standing on now again
        if let g = floors.first(where: { $0.owner == f.owner && abs($0.y - pos.y) < 2 && pos.x >= $0.x0 + halfW - 3 && pos.x <= $0.x1 - halfW + 3 }) { floorID = g.id; act = .peek(d >= 0 ? 1 : -1); actUntil = t + 0.9 }
        else { act = .fall }
      }
      else { pos.x += (d > 0 ? 1 : -1) * min(abs(d), (coveredPoints() >= 4 ? 300 : 95) * CGFloat(mdt)) }   // Nobody sees it behind a window, so hurry; it was unseen for over 3 seconds behind a wide window
    case let .dive(id):                                                              // Crouch (0.15) -> hop (0.2) -> dive (0.45) -> drop from above
      let k = (t - diveT0) / 0.8
      if k >= 1 {
        guard let f = floors.first(where: { $0.id == id }) else { decide(); break }
        let si = screenIdx(CGPoint(x: f.mid, y: f.y)) ?? 0, s = screenFrames[min(si, screenFrames.count - 1)]
        let m = NSEvent.mouseLocation
        let x = min(max(s.contains(m) && m.x > f.x0 && m.x < f.x1 ? m.x : pos.x, f.x0 + halfW + 6), f.x1 - halfW - 6)   // If the cursor is above it, toward the cursor
        pos = CGPoint(x: x, y: s.maxY - 6); vel = .init(dx: 0, dy: -60); floorID = nil; fallTop = 0; dropIn = true; act = .fall
        passThru = true; dropOwner = f.owner
        stackFor(f.owner)                                                            // The level of the landing spot from the start of the fall; so it doesn't pop in the moment it lands on a front window after falling from the floor level
      }
    case let .follow(x):                                                             // Go in front of the cursor and look up
      guard let f = floor else { act = .fall; break }
      let tx = min(max(x, f.x0 + halfW), f.x1 - halfW), d = tx - pos.x
      if abs(d) < 3 || t > actUntil { standLook = NSEvent.mouseLocation.x > pos.x ? 1 : -1; act = .stand; actUntil = t + 2.5 }
      else { pos.x += (d > 0 ? 1 : -1) * min(abs(d), 46 * CGFloat(mdt)) }
    case .stalk:                                                                     // Stalk, then pounce
      guard let f = floor else { act = .fall; break }
      if t > actUntil {
        let m = NSEvent.mouseLocation, above = m.y - headY
        if above > 10, above < 150, abs(m.x - pos.x) < 70 {
          pounceBoost = above * 0.8; targetFloor = f.id; floorID = nil
          act = .jump(pos, CGPoint(x: min(max(m.x, f.x0 + halfW), f.x1 - halfW), y: pos.y), t, 0.6)
        } else { decide() }                                                         // The cursor has gone away
      }
    case .descend:
      if t >= climbRestUntil { pos.y -= 55 * CGFloat(dt) }
      if Double.random(in: 0...1) < dt / 6 { climbRestUntil = t + 0.6 }                // Occasionally hesitate
      if pos.y <= slideStop + 4 * scale { vel = .init(dx: 0, dy: 0); act = .fall }      // Hop down from the bottom edge
      if let f = floors.filter({ $0.y <= pos.y + 3 && $0.y >= pos.y - 6 && pos.x >= $0.x0 && pos.x <= $0.x1 }).max(by: { $0.y < $1.y }) { pos.y = f.y; floorID = f.id; landUntil = t + 0.14; dustT0 = t; decide() }
    case .slide:                                                                     // Side slide: speeds up like falling (slightly less from rubbing the wall); on reaching the bottom edge it falls at that speed
      vel.dx = 0; vel.dy = max(-1100, min(vel.dy, -60) - 1900 * CGFloat(dt))
      let ny = pos.y + vel.dy * CGFloat(dt)
      if let f = floors.filter({ $0.y <= pos.y + 3 && $0.y >= ny - 0.5 && pos.x >= $0.x0 && pos.x <= $0.x1 }).max(by: { $0.y < $1.y }) {
        pos.y = f.y; floorID = f.id; vel = .init(dx: 0, dy: 0); landUntil = t + 0.14; dustT0 = t; decide()
      } else { pos.y = ny; if pos.y <= slideStop { act = .fall } }
    case .peek, .sitEdge, .hum, .cheer:
      if floor == nil { act = .fall } else if t > actUntil { if case .peek(let d) = act { act = .walk(-d); actUntil = t + .random(in: 1.5...3) } else { decide() } }
    case .work, .stand:
      if floor == nil { act = .fall } else if t > actUntil { standLook = 0; decide() }
    case .yawn:
      if floor == nil { act = .fall } else if t > actUntil { if mood == .sleep { act = .sleep } else { decide() } }
    case .stretch:
      if floor == nil { act = .fall } else if t > actUntil { decide() }
    case .sleep:
      if floor == nil { act = .fall }
    case .drag: break
    case let .react(_, t0, dur):
      if floor == nil { act = .fall } else if t - t0 > dur { if poutNext { pout() } else { decide() } }
    }
    if prof, Double(DispatchTime.now().uptimeNanoseconds - swA) / 1e6 > 2 { FileHandle.standardError.write("  slow act-switch\n".data(using: .utf8)!) }
    if case .fall = act {} else { spinning = false; fallCheckT = t; passThru = false; dropOwner = nil; ballistic = false; thrown = false; handFall = false; fallOwner = nil }
    if case .walkTo = act {} else { walkHop = false }
    applyStacking()
    // Prevent App Nap (power saving that slows timers of hidden apps) only while moving; jumping while covered finished in one tick and looked like teleporting
    let moving: Bool = { switch act { case .jump, .fall, .drag, .dive, .sneak, .slide, .descend, .climb, .walkOff: return true; default: return false } }()
    if moving && napToken == nil { napToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "pet motion") }
    else if !moving, let tk = napToken { ProcessInfo.processInfo.endActivity(tk); napToken = nil }
    switch act { case .climb, .descend: break; default: climbFrom = nil; climbRestAt = .infinity; climbRestUntil = 0 }
    if hidden {                                                                  // If not visible, leave the image alone and only move the position
      let walking: Bool = { switch act { case .walk, .walkOff, .stroll, .roll, .follow: return true; default: return false } }()   // Walking while covered also at its own speed (one step per slow tick made it crawl)
      place(); stepChat(t); stepBadge(pose(t)); schedule(inTransit ? 1.0 / 60 : walking ? 1.0 / 30 : (hiddenSince > 0 && t - hiddenSince < 8 ? 0.8 : 2)); return   // If just covered, wake often to find a way out
    }
    profile("mouse") { mouseLife(t) }
    profile("render") { render(t) }
    profile("notice") { stepNotice(t) }
    profile("chat") { stepChat(t) }
    // Only actions that change position get 30 per second, in-place animations 12, and 4 while sleeping
    let fps: Double
    switch act {
    case .fall, .jump, .drag, .slide, .dive: fps = 60                                         // Throws and jumps follow the display refresh smoothly (brief, so the cost is small)
    case .walk, .roll, .walkTo, .sneak, .stalk, .follow, .walkOff, .stroll: fps = 24
    case .climb, .descend: fps = t < climbRestUntil ? 6 : 24
    case .react, .cheer, .hum, .sitEdge, .hang, .peek, .yawn, .stretch: fps = 12
    case .sleep: fps = t < cheerUntil || chatUntil > t ? 12 : 3              // z rises slowly, so 3 is enough
    case .stand where !(t < cheerUntil || showing != nil || chatUntil > t || t - gestT0 < 1.2): fps = 4
    default: fps = (t < cheerUntil || showing != nil || chatUntil > t || t - gestT0 < 1.2) ? 12 : 5   // Laptop tapping has a 0.2 second beat, so 5
    }
    // Dense while moving a window, while the mouse moves nearby, or while petting (so no gesture is missed)
    schedule(t < rideUntil || rideOff != .zero ? 1.0 / 60 : 1 / (t < rideUntil || t < pettedUntil || (mouseNear && t - mouseStill < 1) || chatTyping ? max(fps, 24) : (floor?.owner.hasPrefix("w") == true && NSEvent.pressedMouseButtons & 1 != 0 ? max(fps, 24) : fps)))   // While typing, letters appear evenly. On a window, dense only while the mouse is pressed (the global monitor wakes it the moment of the press)
    profile("hover") { hover() }
  }
  var sweaty: Bool {
    let w = list.filter { $0.mood == .work }, e = Date().timeIntervalSince1970
    return w.count >= 3 || w.contains { e - $0.since > 15 * 60 }
  }
  /// If the user moves the window it is standing (or hanging) on, ride along. A hard shake makes it lose its grip, and if the window closes or goes down it is startled and falls
  func stepRide(_ t: Double) {
    var owner = floor?.owner
    if case .hang(let o, _) = act { owner = o }
    guard let o = owner, o.first == "w", let num = UInt32(o.dropFirst()) else { rideOwner = ""; dragMouse = nil; return }
    if NSEvent.pressedMouseButtons & 1 != 0, t < rideUntil, rideOwner == o, floor?.owner == o {   // Dragging the window with the mouse: the window moves exactly like the mouse; move along each tick by the mouse delta
      let m = NSEvent.mouseLocation
      if let l = dragMouse, m != l {
        let dx = m.x - l.x, dy = m.y - l.y
        rideRect = rideRect.offsetBy(dx: dx, dy: dy); rideUntil = t + 0.6
        shiftRide(o, dx, dy, t, smooth: false)
      }
      dragMouse = m
    } else if dragMouse != nil { dragMouse = nil; lastRide = 0 }                      // Released: query right away and smoothly correct the remaining error
    let el = t - lastRide
    let pressed = NSEvent.pressedMouseButtons & 1 != 0
    if el < (t < rideUntil || pressed ? 0 : (mood == .sleep ? 2 : 1)) { return }   // Every tick while pressed, otherwise every 1 second (2 seconds when asleep); a drag is woken immediately by the global monitor at the moment of the press
    lastRide = t
    guard !rideQuerying else { return }
    rideQuerying = true
    sceneQ.async { [weak self] in                                                    // A single window query (a few ms) also runs off main; this was what caused the hitch at the moment of release
      let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(num)) as? [[String: Any]])?.first
      DispatchQueue.main.async {
        guard let self else { return }
        self.rideQuerying = false
        var cur = self.floor?.owner; if case .hang(let ho, _) = self.act { cur = ho }
        guard cur == o else { return }                                               // It was moved elsewhere in the meantime
        self.applyRide(o: o, info: info, el: el, t: self.now)
      }
    }
  }
  var rideQuerying = false
  var rideOff = CGVector.zero, placeT = 0.0, dragMouse: CGPoint?                                         // Window position updates arrive sparsely; only the visible position chases the real position with a short delay so it doesn't stutter (drawing ahead made it jitter on slow drags)
  func applyRide(o: String, info: [String: Any]?, el: Double, t: Double) {
    guard let info, info[kCGWindowIsOnscreen as String] as? Bool == true, let b = info[kCGWindowBounds as String] as? [String: CGFloat], let H = screenFrames.first?.height else {
      rideOwner = ""; floorID = nil; vel = .init(dx: 0, dy: 0); act = .fall
      floors.removeAll { $0.owner == o }                                          // So it doesn't stand again on the floor of a vanished window
      lastFloors = 0; sceneActiveUntil = t + 3                                    // Re-measure right away
      if t - spaceChangedAt < 2.5 {                                               // Vanished due to a desktop switch: don't get startled, land gently
        if chatty >= 2, showing == nil, t - lastChat > 6, Double.random(in: 0...1) < 0.5 { say(any(T(["어? 화면이 바뀌었네", "여기는 어디지?", "슝~ 이사 왔다", "새 책상이다!"], ["Huh? New screen!", "Where am I?", "Whoosh~ we moved!", "Ooh, a new desk!"])), t) }
      } else {
        startleUntil = t + 0.7; fallInFront()
        if info == nil, chatty > 0, showing == nil, t - lastChat > 4 { say(line(.startle, ctx), t) }   // The window closed
      }
      return
    }
    let r = CGRect(x: b["X"] ?? 0, y: H - (b["Y"] ?? 0) - (b["Height"] ?? 0), width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    guard rideOwner == o else { rideOwner = o; rideRect = r; return }
    // Shrinking fast with no mouse button down: being minimized (⌘M) or hidden, the genie animation pulls the window into the Dock.
    // Don't ride it down there (that looked like a teleport); let go and fall from where it was
    if dragMouse == nil, NSEvent.pressedMouseButtons & 1 == 0, r.width < rideRect.width * 0.8 || r.height < rideRect.height * 0.8 {
      rideOwner = ""; floorID = nil; vel = .init(dx: 0, dy: 0); act = .fall; startleUntil = t + 0.7
      floors.removeAll { $0.owner == o }; lastFloors = 0; sceneActiveUntil = t + 3; fallInFront()
      return
    }
    let dx = r.minX - rideRect.minX, dy = r.maxY - rideRect.maxY
    if dragMouse != nil {                                                            // Dragging with the mouse: the mouse already moved it; queries arrive late, so correct only when far off
      if dx != 0 || dy != 0 { rideUntil = t + 0.6 }
      if hypot(dx, dy) > 40 { rideRect = r; shiftRide(o, dx, dy, t, smooth: true) }
      return
    }
    rideRect = r
    guard dx != 0 || dy != 0 else { return }
    rideUntil = t + 0.6
    if hypot(dx, dy) / CGFloat(max(el, 1.0 / 60)) > 3200 {                           // If shaken too hard, it loses its grip (falls below the floor it was moved to)
      floorID = nil; vel = CGVector(dx: dx / CGFloat(max(el, 1.0 / 60)) * 0.4, dy: 0); act = .fall; startleUntil = t + 0.5
      shiftFloors(o, dx, dy); if dy > 0 { pos.y = min(pos.y, rideRect.maxY - 1) }; return
    }
    shiftRide(o, dx, dy, t, smooth: true)
  }
  /// The window it stood on closed, hid (Esc, ⌘W, ⌘H) or minimized: fall in front of all windows, like after being let go.
  /// At the plain fall level it dropped to the desktop level at once and vanished behind the windows that were behind it (or the app that came forward), then walked out at the bottom (2026-11-23)
  /// If nothing visible is straight below (a window behind covers the floor there), drift sideways onto the nearest visible floor so it doesn't land hidden and walk out
  func fallInFront() {
    if !onTop { stackedOn = nil; window.level = .floating; window.orderFrontRegardless(); restackBubbles() }
    handFall = true; if prof { flingTrace = now + 3 }
    let ok = floors.filter { $0.y < pos.y - 4 && $0.x1 - $0.x0 >= halfW * 2 + 8 && !$0.id.hasSuffix(":x") }
    if ok.contains(where: { pos.x >= $0.x0 + 4 && pos.x <= $0.x1 - 4 }) { return }
    guard let f = ok.min(by: { abs(min(max(pos.x, $0.x0 + halfW), $0.x1 - halfW) - pos.x) < abs(min(max(pos.x, $1.x0 + halfW), $1.x1 - halfW) - pos.x) }) else { return }
    let tx = min(max(pos.x, f.x0 + halfW), f.x1 - halfW)
    guard abs(tx - pos.x) < 420 else { return }
    vel.dx = (tx - pos.x) / CGFloat(sqrt(2 * Double(pos.y - f.y) / 2600)); ballistic = true   // Plain fall gravity is 2600; ballistic keeps the sideways speed so it lands there
  }
  func shiftFloors(_ o: String, _ dx: CGFloat, _ dy: CGFloat) {
    for i in floors.indices where floors[i].owner == o {                              // Move the window's floor along too
      let f = floors[i]; floors[i] = Floor(id: f.id, owner: f.owner, kind: f.kind, y: f.y + dy, x0: f.x0 + dx, x1: f.x1 + dx, bottom: f.bottom + dy, edgeL: f.edgeL, edgeR: f.edgeR, rect: f.rect.offsetBy(dx: dx, dy: dy))
    }
  }
  /// The window being ridden moved by dx and dy: move the floor and the pet together. If smooth, the visible position chases with a short delay (for sparse query values)
  func shiftRide(_ o: String, _ dx: CGFloat, _ dy: CGFloat, _ t: Double, smooth: Bool) {
    shiftFloors(o, dx, dy)
    let si = screenIdx(pos)
    pos.x += dx; pos.y += dy; hangY += dy
    if smooth, hypot(dx, dy) < 120 { rideOff.dx -= dx; rideOff.dy -= dy }      // Leave the visible position alone and chase briefly (immediately if moved too far)
    if let si, si < screenFrames.count, screenIdx(pos) == nil || !screenFrames.contains(where: { $0.insetBy(dx: halfW, dy: 0).contains(CGPoint(x: pos.x, y: pos.y + 1)) }) {
      let s = screenFrames[si]; pos.x = min(max(pos.x, s.minX + halfW), s.maxX - halfW)   // If the window goes off screen, let go at the edge
      floorID = nil; vel = .init(dx: 0, dy: 0); act = .fall; startleUntil = t + 0.5; return
    }
    if t > wobbleUntil - 0.1 { wobbleUntil = t + 0.25 }                               // Balancing
  }
  /// When the user comes back after being away over 5 minutes, greet them with a wave (only reads the input device history, no permission needed)
  var awayChecking = false
  func stepAway(_ t: Double) {
    guard t - lastIdleCheck > 2, !awayChecking else { return }
    lastIdleCheck = t; awayChecking = true
    sceneQ.async { [weak self] in                                                    // Session and input queries (a few ms) run off main
      let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
      let kinds: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
      let idle = kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
      DispatchQueue.main.async { self?.awayChecking = false; self?.applyAway(locked: locked, idle: idle) }
    }
  }
  func applyAway(locked: Bool, idle: Double) {
    let t = now
    screenLocked = locked                                                         // Lock screen: the screen is locked, not the pet being covered
    let cal = Calendar.current, now0 = Date(), hh = cal.component(.hour, from: now0)
    if cal.component(.minute, from: now0) == 0, lastHourSaid != hh, !away, !screenLocked, chatty > 0, showing == nil {   // On-the-hour notification
      lastHourSaid = hh
      let hEn = hourName(hh)                                                       // In English, "3 PM" or "noon"
      say(any(T(["땡! \(hourName(hh))예요", "\(hourName(hh)) 정각!", "벌써 \(hourName(hh))!", "\(hourName(hh))이에요~ 쉬엄쉬엄"], ["Ding! It's \(hEn)!", "\(hEn) on the dot!", "It's \(hEn) already!", "It's \(hEn). Take it easy~"])), t)
      if floor != nil, !uninterruptible { act = .react(.hop, t, 0.7) }
    }
    if idle > 300 { away = true }
    else if away && idle < 4 {
      away = false
      defer { awayDone = 0; missedBanners = 0 }
      guard floor != nil, !uninterruptible else { return }
      act = .react(.wave, t, 1.8)
      if chatty > 0, showing == nil { say(line(.welcome, ctx), t); UD.set(Date().timeIntervalSince1970, forKey: "lastWelcome") }
    }
  }
  /// Mouse play: rubbing left and right over the body is petting; holding the cursor still over the head makes it jump to catch it
  func mouseLife(_ t: Double) {
    let m = NSEvent.mouseLocation, head = headY
    mouseNear = abs(m.x - pos.x) < halfW + 30 && m.y > pos.y - 10 && m.y < head + 150
    if hypot(m.x - lastMouse.x, m.y - lastMouse.y) > 3 { lastMouse = m; mouseStill = t }
    if case .drag = act { strokes.removeAll(); return }
    let onBody = abs(m.x - pos.x) < halfW + 4 && m.y > pos.y - 2 && m.y < head + 4 && NSEvent.pressedMouseButtons == 0
    if onBody && t - mouseStill > 0.4 { touchUntil = t + 0.25 }
    if onBody {
      let d = m.x - strokeX
      if abs(d) > 3 { let dir = d > 0 ? 1 : -1; if dir != strokeDir { strokeDir = dir; strokes.append(t) }; strokeX = m.x }
      strokes.removeAll { t - $0 > 1.6 }
      if strokes.count >= 4 {
        if t > pettedUntil {
          petStart = t
          let n = UD.integer(forKey: "petCount") + 1; UD.set(n, forKey: "petCount")           // As the petting count builds up, it occasionally confesses
          if [10, 30, 50, 100, 200, 500].contains(n), chatty > 0, showing == nil { say(n >= 100 ? T("우리 진짜 친해졌다! (\(n)번째)", "We're besties now! (#\(n))") : T("\(n)번째 쓰다듬기! 좋아~", "Pet #\(n)! I love it~"), t); cheerUntil = t + 2 }
        }
        pettedUntil = t + 1.2
        if t - petStart > 2.5, chatty > 0, showing == nil, t - lastChat > 20 { say(line(.petted, ctx), t) }
      }
    } else { strokes.removeAll(); strokeDir = 0; strokeX = m.x }
    switch act { case .stand, .hum, .cheer, .walk: break; default: return }
    if let f = floor, t > nextFollow, t > pettedUntil + 3, mood != .sleep, t - mouseStill < 0.4, m.y > pos.y - 30, m.y < pos.y + 160,
       abs(m.x - pos.x) > 90, abs(m.x - pos.x) < 420, m.x > f.x0, m.x < f.x1 {                // If the cursor moves on the same floor, follow it
      nextFollow = t + .random(in: 40...75)
      act = .follow(m.x - (m.x > pos.x ? 34 : -34)); actUntil = t + 6; return
    }
    guard let f = floor, t > nextPounce, t > pettedUntil + 3, mood != .sleep else { return }
    let above = m.y - head
    if abs(m.x - pos.x) < 50, above > 15, above < 130, t - mouseStill > 1.0, t - mouseStill < 6 {
      nextPounce = t + .random(in: 15...30)
      _ = f; act = .stalk; actUntil = t + 0.7
    }
  }
  /// Which way to slide down when dropped on a top edge it can't stand on. Only the side where the free span for the body at that height continues to the end of that top edge (nil for a narrow gap blocked by front windows on both sides)
  func slipDir(on w: CGRect) -> CGFloat? {
    let y = w.maxY, band = 15 * scale
    var lo = w.minX - halfW * 2, hi = w.maxX + halfW * 2
    if let s = screenFrames.first(where: { pos.x >= $0.minX && pos.x <= $0.maxX && y >= $0.minY && y <= $0.maxY }) { lo = max(lo, s.minX + halfW); hi = min(hi, s.maxX - halfW) }   // Can't go to the end of a window that extends off screen
    for b in scene.walls where b != w && b.maxY > y + 2 && b.minY < y + band {
      if b.minX <= pos.x && b.maxX >= pos.x { return nil }                         // That very spot is covered
      if b.maxX < pos.x { lo = max(lo, b.maxX) } else { hi = min(hi, b.minX) }
    }
    guard hi - lo >= halfW * 2 + 8 else { return nil }                               // No gap for the body to fit
    // Beyond the end is another top edge at about the same height that it can't stand on either: sliding there only bounces it back.
    // Two overlapping windows whose tops sit right under the menu bar kept it sliding between them forever (2026-11-25)
    let dead = { (x: CGFloat) in self.scene.walls.contains { b in
      b != w && b.minX < x && b.maxX > x && b.maxY >= y - 4 * self.scale && b.minY < y && !self.floors.contains { $0.x0 <= x && $0.x1 >= x && abs($0.y - b.maxY) < 3 } } }
    let canL = lo < w.minX && !dead(w.minX - halfW), canR = hi > w.maxX && !dead(w.maxX + halfW)   // Is it open beyond the end of that top edge
    let dir: CGFloat
    switch (canL, canR) {
    case (true, true): dir = pos.x < w.midX ? -1 : 1
    case (true, false): dir = -1
    case (false, true): dir = 1
    default: return nil
    }
    // Thrown and the end is far: drop in front of the window instead. Along a 3360pt monitor's top it slid for 5 seconds under the menu bar (2026-11-26)
    if handFall && (dir < 0 ? pos.x - w.minX : w.maxX - pos.x) > 600 { return nil }
    return dir
  }
  /// Does it fall into a window (the body center newly enters inside a window); the pet is behind all windows, so it disappears when it enters
  func wallHit(_ w: CGRect, from a: CGPoint, to b: CGPoint) -> Bool {
    let h = 7 * scale
    return w.contains(CGPoint(x: b.x, y: b.y + h)) && !w.contains(CGPoint(x: a.x, y: a.y + h))
  }
  func bounceWalls() {
    guard let s = screenFrames.first(where: { $0.contains(CGPoint(x: pos.x, y: max(pos.y, $0.minY + 1))) }) ?? screenFrames.first(where: { pos.x >= $0.minX && pos.x <= $0.maxX }) else { return }
    if screenFrames.contains(where: { $0 != s && $0.contains(CGPoint(x: pos.x + (vel.dx > 0 ? halfW : -halfW), y: pos.y + 4)) }) { return }   // Crossing to the adjacent screen
    if pos.x < s.minX + halfW { if vel.dx < -600, chatty > 0, showing == nil, now - lastChat > 1.2 { say(line(.bonk, ctx), now) }; pos.x = s.minX + halfW; vel.dx = abs(vel.dx) * 0.6 }
    if pos.x > s.maxX - halfW { if vel.dx > 600, chatty > 0, showing == nil, now - lastChat > 1.2 { say(line(.bonk, ctx), now) }; pos.x = s.maxX - halfW; vel.dx = -abs(vel.dx) * 0.6 }
    if pos.y > s.maxY - 20 { pos.y = s.maxY - 20; vel.dy = min(0, vel.dy) }
  }

  func pose(_ t: Double) -> Pose {
    var p = Pose()
    if t > blinkNext { blinkUntil = t + max(0.11, rate * 1.1); blinkNext = t + (Double.random(in: 0...1) < 0.15 ? max(0.25, rate * 2.5) : (mood == .work ? .random(in: 6...10) : .random(in: 3...6))) }   // Occasionally blinks twice
    let blink = t < blinkUntil
    p.eyes = blink ? .closed : .open
    switch act {
    case let .walk(dir):
      let ph = Int(t * 6) % 2; p.feet = ph + 1; p.lift = ph; p.look = dir > 0 ? 1 : -1
      if chara.kind == .mandu || chara.kind == .cloud { p.squash = ph }
      if humming { p.notes = (t / 1.5).truncatingRemainder(dividingBy: 1); p.eyes = .happy }
    case let .jump(a, b, t0, _):                                                   // Prep: crouch and lean toward the jump direction, then kick off and stretch, then airborne
      let lean = b.x > a.x + 2 ? 1 : (b.x < a.x - 2 ? -1 : 0)
      if t < t0 { p.eyes = .closed; p.feet = 0; p.squash = t0 - t < 0.06 ? 3 : 2; p.shake = lean; if lean != 0 { p.look = lean } }
      else { p.eyes = .wide; p.feet = 3; p.squash = t - t0 < 0.07 ? -2 : -1; if lean != 0 { p.look = lean } }
      if pounceBoost > 0 { p.hands = t > t0; p.look = NSEvent.mouseLocation.x > pos.x ? 1 : -1 }   // Reach out both hands toward the cursor
    case .fall: p.eyes = .wide; p.feet = 3; p.squash = -1
    case .yawn:                                                                    // Mouth wide open, then nod
      let k = (t - (actUntil - 1.6)) / 1.6
      p.eyes = .closed; p.talk = k < 0.6; p.squash = k < 0.6 ? -1 : 1; p.lift = 0
    case .stretch: p.squash = -1; p.hands = true; p.eyes = .happy                   // Big stretch
    case .drag:                                                                    // The body leans away from the pull, and if held a long time it struggles
      p.feet = 3; p.squash = -1
      var vx: CGFloat = 0
      if let a = samples.first, let b = samples.last, b.0 - a.0 > 0.01, t - b.0 < 0.12 { vx = (b.1.x - a.1.x) / CGFloat(b.0 - a.0) }
      p.shake = max(-2, min(2, Int(-vx / 350)))
      if abs(vx) > 1100 { p.eyes = .wide }
      else if t - grabT > 1.8 { p.feet = Int(t / 0.13) % 2 + 1; p.eyes = .closed; p.shake = Int(t / 0.13) % 2 == 0 ? -1 : 1 }
      else { p.eyes = .happy }
    case .work: p.laptop = Int(t * 5) % 2; p.lift = 0; p.squash = Int(t / 1.3) % 2   // Only the hands tap while the body breathes slowly
    case .sleep:
      p.eyes = .closed; p.squash = Int(t / 1.6) % 2 == 0 ? 1 : 2
      let cyc = Int(t / 3.2)                                                         // One breath per 3.2 seconds: three in four are a snot bubble, one is a z
      if cyc % 4 == 3 || chara.sprite != nil { p.z = (t / 2.4).truncatingRemainder(dividingBy: 1) }
      else { let q = t.truncatingRemainder(dividingBy: 3.2) / 3.2; p.snot = q < 0.6 ? q / 0.6 : max(0, 1 - (q - 0.6) / 0.4) }
    case .cheer:
      let waiting = list.filter { $0.mood >= .wait && !acked.contains($0.id) }
      if mood == .ask {
        p.eyes = .wide; p.bubble = .ask; p.count = waiting.count; p.shake = Int(t * 3) % 6 == 0 ? 1 : 0
        if t.truncatingRemainder(dividingBy: 3.5) < 1.1 { p.wave = Int(t / 0.18) % 2; p.eyes = .happy }   // Over here! Wave to call
      } else {
        p.eyes = .happy; p.bubble = .check; p.count = waiting.count
        let c = t.truncatingRemainder(dividingBy: 2.6)
        p.shake = Int(t / 0.6) % 2; p.lift = c < 0.25 ? 1 : 0                       // Quietly sway left and right, occasionally a slight bounce
      }
    case .stand: p.squash = Int(t / 1.3) % 2; if standLook != 0 { p.look = standLook }
    case let .roll(dir): p.rot = Int(t / 0.08) % 4 * (dir > 0 ? 1 : 3); p.eyes = .happy; p.feet = 3
    case .hum: p.eyes = .happy; p.notes = (t / 1.6).truncatingRemainder(dividingBy: 1); p.shake = Int(t / 0.4) % 2 == 0 ? -1 : 0; p.lift = Int(t / 0.4) % 2
    case let .walkTo(x, _):
      let ph = Int(t * 6) % 2; p.feet = ph + 1; p.lift = ph; p.look = x > pos.x ? 1 : -1
    case let .climb(_, side): p.look = side > 0 ? 1 : -1; p.feet = Int(t * 6) % 2 + 1; p.squash = Int(t * 6) % 2; p.eyes = .open
      if t < climbRestUntil { p.feet = 3; p.squash = 0; p.eyes = .closed; p.hands = true; p.sweat = ((t - climbRestUntil) / 1.2 + 10).truncatingRemainder(dividingBy: 1) }   // Hanging and panting
    case .slide: p.eyes = .wide; p.feet = 3; p.squash = 1
    case let .sneak(x, _): let ph = Int(t * 7) % 2; p.feet = ph + 1; p.lift = ph; p.look = x > pos.x ? 1 : -1; p.squash = 1   // Body low, sneaking
    case .dive:
      let k = (t - diveT0) / 0.8
      if k < 0.15 { p.squash = 2; p.eyes = .closed }                                   // Crouch
      else if k < 0.35 { p.lift = Int(sin((k - 0.15) / 0.2 * .pi) * 4); p.squash = -1; p.eyes = .happy; p.feet = 3 }   // Hop
      else { p.sink = Int((k - 0.35) / 0.45 * 22); p.squash = -1; p.eyes = .closed; p.hands = true }   // Cheer, then dive
    case let .walkOff(x): let ph = Int(t * 6) % 2; p.feet = ph + 1; p.lift = ph; p.look = x > pos.x ? 1 : -1
    case let .stroll(x):
      let ph = Int(t * 6) % 2; p.feet = ph + 1; p.lift = ph; p.look = x > pos.x ? 1 : -1
      if humming { p.notes = (t / 1.5).truncatingRemainder(dividingBy: 1); p.eyes = .happy }
    case let .follow(x): let ph = Int(t * 7) % 2; p.feet = ph + 1; p.lift = ph; p.look = x > pos.x ? 1 : -1; p.eyes = .happy
    case .stalk: p.squash = 1; p.eyes = .wide; p.look = NSEvent.mouseLocation.x > pos.x ? 1 : -1; p.shake = Int(t / 0.1) % 2   // Wiggle the rear
    case let .descend(dir):                                                        // Face the wall, alternating hands and feet
      let ph = t < climbRestUntil ? 0 : Int(t * 5) % 2
      p.look = dir > 0 ? -1 : 1; p.hands = true; p.feet = ph + 1; p.lift = ph; p.eyes = t < climbRestUntil ? .wide : .open
    case let .hang(_, dir):                                                      // Hold the corner with both hands and sway
      p.feet = 3; p.squash = -1; p.look = dir > 0 ? -1 : 1; p.hands = true
      p.shake = Int(t / 0.5) % 2 == 0 ? -1 : 1; p.eyes = Int(t / 2.5) % 2 == 0 ? .happy : .open
    case let .peek(dir): p.look = dir > 0 ? 1 : -1; p.down = true
    case .sitEdge:
      p.feet = 3; p.eyes = Int(t / 3) % 3 == 0 ? .happy : (t.truncatingRemainder(dividingBy: 4.3) < 0.13 ? .closed : .open)
      p.lift = -1 + (Int(t / 0.35) % 2); p.notes = (t / 1.8).truncatingRemainder(dividingBy: 1)
    case let .react(r, t0, dur):
      let k = min(1, (t - t0) / dur)
      p.eyes = .happy
      switch r {
      case nil:                                                        // Wakes while sleeping: startled, then drowsy again
        p.eyes = k < 0.6 ? .wide : .closed; p.bubble = k < 0.6 ? .bang : .none; p.lift = k < 0.25 ? 2 : 0
      case .hop?: p.lift = Int(sin(k * .pi) * 9); p.feet = p.lift > 1 ? 3 : 0; p.squash = k < 0.1 || k > 0.9 ? 1 : -1
      case .spin?: p.look = Int(t / 0.11) % 2 == 0 ? -1 : 1; p.squash = Int(t / 0.11) % 2; p.shake = p.look
      case .heart?: p.hearts = k; p.blush = true; p.lift = Int(t / 0.3) % 2
      case .squish?: p.squash = k < 0.35 ? 3 : k < 0.5 ? -2 : k < 0.65 ? 1 : 0; p.eyes = k < 0.35 ? .closed : .happy
      case .dizzy?: p.eyes = .dizzy; p.shake = Int(t / 0.09) % 2 == 0 ? -1 : 1; p.sparkle = (k * 3).truncatingRemainder(dividingBy: 1)
      case .wave?: p.wave = Int(t / 0.18) % 2
      case .shy?: p.eyes = .closed; p.blush = true; p.shake = Int(t / 0.25) % 2; p.look = -1; p.cover = k < 0.75
      case .pout?: p.eyes = .closed; p.blush = true; p.angry = true; p.squash = 1; p.look = NSEvent.mouseLocation.x > pos.x ? -1 : 1; p.shake = k < 0.15 ? p.look : 0   // Puffs cheeks and turns away
      case .party?:                                                                // Two cheer hops + confetti
        let j = k < 0.5 ? k / 0.5 : (k - 0.5) / 0.5
        p.lift = Int(sin(j * .pi) * (k < 0.5 ? 6 : 4)); p.hands = true; p.feet = p.lift > 1 ? 3 : 0; p.confetti = k; p.squash = p.lift == 0 ? 1 : -1
      case .flinch?: p.eyes = .wide; p.squash = 1; p.shake = Int(t / 0.05) % 2 == 0 ? -1 : 1
      case .star?: p.sparkle = k; p.lift = Int(sin(k * .pi) * 3)
      }
    }
    if t < cheerUntil { p.sparkle = 1 - (cheerUntil - t) / 2.5; p.eyes = .happy }
    var idle = false
    switch act { case .stand, .work, .cheer, .hum, .sitEdge: idle = true; default: break }
    // Small gestures (only when still): looking around, stomping, head tilt, stretch; never the same one twice in a row
    if idle && t > nextFidget {
      nextFidget = t + .random(in: 8...20)
      fidget = [0, 1, 2, 3].filter { $0 != lastFidget }.randomElement()!; lastFidget = fidget; fidgetUntil = t + 1.3; lastFidgetQ = Bool.random()
    }
    if idle && t < fidgetUntil {
      switch fidget {
      case 0: p.look = Int(t / 0.33) % 2 == 0 ? -1 : 1; if lastFidgetQ { p.icon = 2 }     // Look around (occasionally a question mark)
      case 1: if p.laptop < 0 { p.feet = Int(t / 0.15) % 2 + 1 }                    // Stomp
      case 2: p.shake = 1; p.look = 1                                               // Head tilt
      default: p.squash = -1                                                        // Stretch
      }
    } else if idle && standLook == 0 {                                              // If the mouse is close, look toward it
      let m = NSEvent.mouseLocation
      if hypot(m.x - pos.x, m.y - (pos.y + 30)) < 220 { p.look = m.x > pos.x + 10 ? 1 : (m.x < pos.x - 10 ? -1 : 0); p.up = m.y > headY + 40 }
    }
    if case .walk(let d) = act, t < stumbleUntil { p.eyes = .wide; p.squash = 1; p.shake = Int(d) }   // Stumble
    if t < landUntil { p.squash = landUntil - t > 0.07 ? 2 : -1 }                   // Landing: squashed with a thud, then stretches slightly
    if t - dustT0 < 0.35 { p.dust = (t - dustT0) / 0.35 }
    if chara.kind == .sprout, idle || mood == .work { p.tail = Int(t / 0.8) % 2 }   // Sprout leaf sways
    if chara.kind == .candle { p.tail = Int(t / 0.25) % 2 }                          // Flame flickers
    if chara.kind == .cloud { switch act { case .stand, .hum, .cheer, .sleep: p.lift = max(p.lift, Int(sin(t * .pi) + 1)); default: break } }   // Cloud floats
    if case .cheer = act, mood == .wait, let s0 = list.filter({ $0.mood == .wait }).map(\.since).min(), Date().timeIntervalSince1970 - s0 > 120 {
      p.feet = 3; p.lift = t.truncatingRemainder(dividingBy: 9) < 0.3 ? 1 : -1; p.shake = 0   // After waiting over 2 minutes, it sits with the badge on and rests, occasionally hopping
    }
    if let g = gest, t - gestT0 < 1.2, idle || { if case .walk = act { return true }; return false }() {                                       // Work gestures (even without speech): commit hop, test sweat, waving when calling a friend
      let k = (t - gestT0) / 1.2
      switch g {
      case .commit: p.lift = Int(sin(min(1, k * 2) * .pi) * 3); p.eyes = .happy
      case .test: p.sweat = k; p.hands = p.laptop < 0
      case .agentStart: p.wave = Int(t / 0.18) % 2
      case .error: if k < 0.3 { p.eyes = .wide; p.squash = 1 }
      case .read, .web: p.icon = 2; p.iconBob = Int(t / 0.3) % 2; if k < 0.5 { p.shake = 1 }   // Head tilt + question mark
      case .edit, .agentDone, .bgDone: p.icon = 1; p.iconBob = Int(t / 0.25) % 2; p.eyes = .wide  // Flash + light bulb
      default: break
      }
    }
    if t - fxT0 < 2.5 { p.fx = fx; p.fxK = (t - fxT0) / 2.5 }                     // Character effects (error rain, completion flowers, etc.)
    if t - propHourAt > 30 {                                                        // Re-read the time only every 30 seconds
      propHourAt = t; let now = Calendar.current.dateComponents([.year, .hour, .minute, .month, .day], from: Date())
      partyOn = SEASONAL && partySeason(year: now.year ?? 0, month: now.month ?? 0, day: now.day ?? 0)
      propHour = now.hour ?? 0; santaOn = SEASONAL && christmasSeason(month: now.month ?? 0, day: now.day ?? 0)
      snowOn = SEASONAL && snowTime(month: now.month ?? 0, minute: now.minute ?? 1)
    }
    p.santa = santaOn                                                               // December 1-26: a Santa hat
    p.party = partyOn                                                               // Launch party: a party hat
    if snowOn, floor != nil { p.snow = (t / 4.5).truncatingRemainder(dividingBy: 1) }   // December: now and then a little snow (on the ground only)
    if propHour >= 7 && propHour < 10, floor != nil { switch act { case .stand, .work, .hum, .cheer: p.mug = Int(t / 0.5) % 2; default: break } }   // Coffee beside it in the morning
    if t < touchUntil && t >= pettedUntil { p.eyes = .closed; p.blush = true; p.look = NSEvent.mouseLocation.x > pos.x ? 1 : -1 }   // Leans in when touched
    if spinning, case .fall = act { p.rot = Int(t / 0.07) % 4 * (vel.dx >= 0 ? 3 : 1); p.eyes = .dizzy }   // Spins when thrown hard
    if case .work = act, sweaty { p.sweat = (t / 1.4).truncatingRemainder(dividingBy: 1) }   // Sweat when there is a lot of work or it takes long
    if t < pettedUntil {                                                            // Petting: cheeks go red with a heart, smiles even while asleep
      p.blush = true; p.eyes = { if case .sleep = act { return .closed } else { return .happy } }()
      if p.hearts < 0 { p.hearts = ((t - petStart) / 1.6).truncatingRemainder(dividingBy: 1) }
      p.squash = Int(t / 0.45) % 2; p.shake = 0
    }
    if t < startleUntil { p.eyes = .wide; p.bubble = .bang; p.feet = 3 }               // Startled!
    if t < wobbleUntil { p.shake = Int(t / 0.07) % 2 == 0 ? -1 : 1; p.eyes = .wide } // Precarious at the edge
    if t < bonkUntil { p.eyes = .dizzy; p.squash = 2; p.shake = Int(t / 0.06) % 2 == 0 ? -1 : 1; p.sparkle = 1 - (bonkUntil - t) / 0.45 }   // Thud!
    if showing != nil || chatUntil > t { p.bubble = .none }
    if chatUntil > t { p.talk = Int(t / 0.16) % 2 == 0 }
    if let sp = chara.sprite, !sp.motions.isEmpty { pickMotion(&p, sp, t) }
    return p
  }
  /// Candidate action names for the current situation (earlier ones take priority) -> the first image present in the pack. For one-shot actions, the frame is chosen by progress
  func pickMotion(_ p: inout Pose, _ sp: Sprite, _ t: Double) {
    var want: [String] = [], prog: Double? = nil
    if t < landUntil { want.append("land") }
    if t < startleUntil { want.append("startle") }
    if t < pettedUntil { want.append("petted") }
    switch act {
    case .walk, .walkTo, .follow, .walkOff, .stroll: want.append("walk")
    case .sneak: want.append("sneak")
    case .roll: want.append("roll")
    case .work: want.append("work")
    case .sleep: want.append("sleep")
    case .yawn: want.append("yawn"); prog = 1 - (actUntil - t) / 1.6
    case .stretch: want.append("stretch"); prog = 1 - (actUntil - t) / 1.0
    case .cheer: want.append(mood == .ask ? "ask" : "cheer")
    case .hum: want.append("hum")
    case let .jump(_, _, t0, dur): if t < t0 { want.append("crouch") } else { want.append(pounceBoost > 0 ? "pounce" : "jump"); prog = max(0, (t - t0) / dur) }
    case .fall, .slide: want.append("fall")
    case .drag: want.append("drag")
    case .climb: want.append("climb")
    case .descend: want.append("descend")
    case .hang: want.append("hang")
    case .sitEdge: want.append("sit")
    case .peek: want.append("peek")
    case .stalk: want.append("stalk")
    case .dive: want.append("dive")
    case let .react(r, t0, dur):
      prog = (t - t0) / dur
      let n: [React: String] = [.hop: "hop", .spin: "spin", .heart: "heart", .squish: "squish", .dizzy: "dizzy", .wave: "wave", .shy: "shy", .star: "star", .pout: "pout", .party: "party", .flinch: "flinch"]
      want.append(r.flatMap { n[$0] } ?? "startle")
    case .stand: break
    }
    if p.talk { want.append("talk") }
    if p.eyes == .closed { want.append("blink") }
    want.append("idle")
    var name = "idle"
    outer: for w in want { for c in [w] + (MOTION_FALLBACK[w] ?? []) where sp.motions[c] != nil { name = c; break outer } }
    guard let m = sp.motions[name] else { p.motion = ""; return }
    p.motion = name
    p.frame = prog.map { min(m.frames.count - 1, Int(max(0, min(0.999, $0)) * Double(m.frames.count))) } ?? Int(t * m.fps) % m.frames.count
  }
  func render(_ t: Double) {
    let p = pose(t)
    var q = p                                                                    // Compare continuous values in frame units (same image is not redrawn)
    q.z = (p.z * 20).rounded(.down); q.sparkle = (p.sparkle * 20).rounded(.down); q.hearts = (p.hearts * 30).rounded(.down); q.notes = (p.notes * 24).rounded(.down); q.snow = (p.snow * 45).rounded(.down)
    stepBadge(p)
    if q != lastPose || chara.id != lastChara || lastKey.isEmpty {
      if chara.id != lastChara || lastKey.isEmpty { drawCache.removeAll() }                 // Cleared when the character or size changes
      lastPose = q; lastChara = chara.id; lastKey = "x"
      if let hit = drawCache[q] { lastCanvas = hit.0; view.image = hit.1 }                   // Repeating poses such as rolling and walking use the pre-drawn images
      else {
        lastCanvas = profile("draw") { draw(chara, p) }; view.image = profile("image") { lastCanvas.image() }
        if drawCache.count >= 96 { drawCache.removeAll(keepingCapacity: true) }
        if let img = view.image { drawCache[q] = (lastCanvas, img) }
      }
      view.needsDisplay = true
    }
    place()
  }
  /// Badge above the head (check count, ?, !); redrawn only when its shape changes
  /// Status bubble (check count, ?, !): same image and same placement as the speech bubble. Redrawn only when its shape changes
  var badgeSpec: BubbleSpec?, badgeSeed = 0, badgeWhat = ""
  func stepBadge(_ p: Pose) {
    guard p.bubble != .none else { if !badgeKey.isEmpty { badgeKey = ""; badgeSpec = nil; badgeWin.orderOut(nil) }; return }
    let who = waitingAgent(ask: p.bubble == .ask)
    let key = "\(p.bubble)|\(p.count)|\(who)|\(TEXT_SIZE)|\(textDot)|\(FONT_FAMILY)"   // Text changes only when the badge newly appears or the count changes (when it changed by itself it looked like a new notification)
    if key != badgeKey {
      let what = "\(p.bubble)|\(p.count)"
      if what != badgeWhat { badgeWhat = what; badgeSeed &+= 1 }
      badgeKey = key
      let n = max(1, min(p.count, 99))
      func pick(_ a: [String]) -> String { a[badgeSeed % a.count] }
      let (text, ink, fill): (String, CGColor, CGColor) = {
        switch p.bubble {
        case .ask: return (pick(n == 1 ? T(["\(ga(who)) 물어볼 게 있대요", "\(ga(who)) 대답을 기다려요", "\(who) 질문이 하나 있어요"], ["\(who) has a question", "\(who) is waiting on you", "\(who) needs your answer"])       // Attach the agent name so even a first-time user knows who is waiting
                                       : T(["\(who) \(n)곳이 대답을 기다려요", "\(who) 질문이 \(n)개예요", "\(who) \(n)곳이 물어볼 게 있대요"], ["\(n) \(who) sessions need you", "\(who) has \(n) questions", "\(n) questions from \(who)"])), cg("#9a7414"), cg("#fbf0d2"))
        case .bang: return ("!", cg("#c9504a"), cg("#fffaf0"))
        case .dots: return ("…", cg("#5a4334"), cg("#fffaf0"))
        default: return (pick(n == 1 ? T(["\(who) 작업이 끝났어요", "\(ga(who)) 확인을 기다려요", "\(who) 작업 하나 다 됐어요!"], ["\(who) finished a task", "\(who) is ready for review", "\(who) is all done!"])
                                     : T(["\(who) 작업 \(n)개가 끝났어요", "\(who) \(n)곳이 확인을 기다려요", "다 된 \(who) 작업 \(n)개!"], ["\(who) finished \(n) tasks", "\(n) \(who) tasks to check", "\(n) \(who) tasks done!"])), cg("#3f8a4a"), cg("#e9f6df"))
        }
      }()
      var spec = BubbleSpec(lines: [(text, ink)], fill: fill, edge: cg("#5a4334")); spec.check = p.bubble == .check
      spec.side = badgeWin.isVisible ? badgeSpec?.side ?? 0 : 0
      if let img = noticeImage(spec.lines, fill: spec.fill, edge: spec.edge, side: spec.side, check: spec.check) { presentBubble(badgeWin, badgeView, &badgeSpec, spec, img) }
    }
    placeBubble(badgeWin, badgeView, &badgeSpec)
  }
  /// Screen y of the top of the head (the top row of the drawn image)
  var headY: CGFloat { petRect.minY + CGFloat(CH - lastCanvas.top) * ds }
  func place() {
    let t = now, decay = CGFloat(exp(-min(t - placeT, 0.1) / 0.07)); placeT = t
    rideOff = abs(rideOff.dx) + abs(rideOff.dy) < 0.5 ? .zero : CGVector(dx: rideOff.dx * decay, dy: rideOff.dy * decay)
    let lead = rideOff
    let o = CGPoint(x: (pos.x + lead.dx - CGFloat(CW) * ds / 2).rounded(), y: (pos.y + lead.dy - CGFloat(CH - GY - 1) * ds).rounded())
    let wf = window.frame, sz = view.frame.size, local = CGPoint(x: o.x - wf.minX, y: o.y - wf.minY)
    // The screen the pet is on: if a big window extends more onto the next screen, macOS draws it only on that screen and the pet briefly vanished. Keep the window inside this screen
    let scr = screenFrames.first { $0.contains(CGPoint(x: o.x + sz.width / 2, y: o.y + sz.height / 2)) }
    // It only needs not to straddle another screen; for a pet standing on the floor, the window extends below the screen by the image's bottom-row margin, which used to be treated as "off screen" and moved the window every frame
    let inScreen = { (r: CGRect) -> Bool in !self.screenFrames.contains { $0 != scr && $0.insetBy(dx: 1, dy: 1).intersects(r) } }
    if local.x >= 0, local.y >= 0, local.x + sz.width <= wf.width, local.y + sz.height <= wf.height, inScreen(wf) {
      if view.frame.origin != local { view.setFrameOrigin(local) }                    // Moves only inside the window (doesn't go through the window server)
    } else {
      var wo = CGPoint(x: o.x - Pet.PADX, y: o.y - Pet.PADY)                            // Reached the edge: move the window back to the pet's center
      if let s = scr {                                                                 // Pull it so it doesn't stick out of the screen, but the pet stays inside the window
        if wf.width <= s.width { wo.x = min(max(wo.x, s.minX), s.maxX - wf.width); wo.x = min(max(wo.x, o.x + sz.width - wf.width), o.x) }
        if wf.height <= s.height { wo.y = min(max(wo.y, s.minY), s.maxY - wf.height); wo.y = min(max(wo.y, o.y + sz.height - wf.height), o.y) }
      }
      let nl = CGPoint(x: o.x - wo.x, y: o.y - wo.y)
      if view.frame.origin != nl { view.setFrameOrigin(nl) }
      if wf.origin != wo { window.setFrameOrigin(wo) }
    }
  }
  // Clicks pass through transparent areas to what is below
  func hover() {
    if case .drag = act { window.ignoresMouseEvents = false; return }
    let m = NSEvent.mouseLocation, f = petRect
    var solid = false
    if f.contains(m) {                                                           // Only when the mouse is inside the window, using the last drawn image
      let x = Int((m.x - f.minX) / ds), y = CH - 1 - Int((m.y - f.minY) / ds)
      for dy in -1...1 { for dx in -1...1 where lastCanvas.alpha(x + dx, y + dy) > 60 { solid = true } }
    }
    if window.ignoresMouseEvents == solid { window.ignoresMouseEvents = !solid }
  }

  // Notification bubbles: one at a time, disappearing after the set time. Clicking goes to that tab
  func stepNotice(_ t: Double) {
    if let _ = showing, t > showUntil { hideNotice() }
    if showing == nil, !notices.isEmpty, !(chatUntil > t && t < chatGate) {        // After the bubble on screen has filled its minimum time, one by one in turn
      let (n, rest) = mergeNotices(notices.removeFirst(), notices); notices = rest   // three or more finished at once: one bubble
      showing = n; showUntil = t + noticeSecs
      if prof { FileHandle.standardError.write("  bubble notice t=\(String(format: "%.2f", t)) \(n.title)\n".data(using: .utf8)!) }
      let tail = doneLine(n)                                                   // The text is chosen on main (together with the recent-lines history)
      let st = toolStyle(n.tool)                                               // Per-agent styling (tools.json)
      let fill = cg(n.ask ? st.askFill ?? "#fbf0d2" : st.fill ?? "#fffaf0"), edge = cg(st.edge ?? "#5a4334"), ink = cg(st.titleColor ?? "#3a2a24")
      let title = st.showLabel ? "\(st.label ?? n.tool) · \(n.title)" : n.title
      sceneQ.async { [weak self] in                                            // Text drawing is in the background (prevents hitches while moving)
        let lines: [(String, CGColor)] = wrapTitle(title).map { ($0, ink) } + [(tail, n.ask ? cg("#9a7414") : cg("#3f8a4a"))]
        let img = noticeImage(lines, fill: fill, edge: edge)
        DispatchQueue.main.async {
          guard let self, let img, self.showing?.id == n.id else { return }
          self.presentBubble(self.noticeWin, self.noticeView, &self.noticeSpec, BubbleSpec(lines: lines, fill: fill, edge: edge), img)
        }
      }
    }
    guard showing != nil else { return }
    placeBubble(noticeWin, noticeView, &noticeSpec)
  }
  func hideNotice() { if prof, showing != nil { FileHandle.standardError.write("  bubble notice-hide t=\(String(format: "%.2f", now))\n".data(using: .utf8)!) }; showing = nil; noticeWin.orderOut(nil) }
  /// Bubble placement: above the head by default. If there's no room above, beside the pet (right, else left) with the tail toward the pet; returns the required tail direction
  func bubbleSlot(_ size: CGSize, gap: CGFloat? = nil, prefer: Int? = nil, force: Bool = false) -> (CGPoint, Int) {   // prefer: the side currently shown; if that side is still free, keep it (so it doesn't alternate between above and beside due to size differences)
    let head = headY + (gap ?? 2 * ds)
    let fr = screenFrames.first(where: { $0.contains(CGPoint(x: pos.x, y: max(pos.y, $0.minY + 1))) }) ?? screenFrames.first ?? .zero
    let v = NSScreen.screens.first(where: { $0.frame == fr })?.visibleFrame ?? fr
    // Windows in front of the pet (all windows + the Dock if the pet is at the desktop level); a bubble overlapping them would be hidden and unseen
    let front = frontWalls() + (dockRect.map { [$0] } ?? [])                         // The Dock bar is in front even of the top level
    func clear(_ r: CGRect) -> Bool { r.minY >= fr.minY && r.maxY <= v.maxY &&   // Down to the very bottom of the screen (the Dock is handled separately as a wall of front)
       r.minX >= fr.minX && r.maxX <= fr.maxX && !front.contains { $0.insetBy(dx: 2, dy: 2).intersects(r) } }
    let ax = min(max((pos.x - size.width / 2).rounded(), fr.minX + 4), fr.maxX - size.width - 4)
    let above = CGPoint(x: ax, y: head.rounded())
    if clear(CGRect(origin: above, size: size)) { return (above, 0) }               // If above is free, above
    let rx = (pos.x + halfW * 0.8).rounded(), lx = (pos.x - halfW * 0.8 - size.width).rounded()
    let hi = min(max((headY - size.height * 0.45).rounded(), fr.minY + 2), v.maxY - size.height)        // Beside the head, slightly above (tail toward the face)
    let lo = min(max(((headY + pos.y) / 2 - size.height / 3).rounded(), fr.minY + 2), v.maxY - size.height)   // If above is blocked, beside the body
    func at(_ side: Int) -> CGPoint? {                                               // Free spots among those
      if side == 0 { return clear(CGRect(origin: above, size: size)) ? above : nil }
      let x = side < 0 ? rx : lx
      return [hi, lo].map { CGPoint(x: x, y: $0) }.first { clear(CGRect(origin: $0, size: size)) }
    }
    // Pull it onto the screen; when every spot in a corner was blocked it went off screen and got cut off
    func fit(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x, fr.minX + 4), fr.maxX - size.width - 4), y: min(max(p.y, fr.minY + 2), v.maxY - size.height)) }
    if let p = prefer, let o = at(p) { return (o, p) }
    if force, let p = prefer { return (fit(p == 0 ? above : CGPoint(x: p < 0 ? rx : lx, y: hi)), p) }   // In mid-air it doesn't change spot and keeps following that side
    for y in [hi, lo] {
      if clear(CGRect(origin: CGPoint(x: rx, y: y), size: size)) { return (CGPoint(x: rx, y: y), -1) }   // Right (tail on the left)
      if clear(CGRect(origin: CGPoint(x: lx, y: y), size: size)) { return (CGPoint(x: lx, y: y), 1) }    // Left (tail on the right)
    }
    // If there is no free spot, the most visible one: after pulling it onto the screen, subtract the area hidden by front windows and the area covering the pet's body
    let body = CGRect(x: pos.x - halfW, y: pos.y, width: halfW * 2, height: max(1, headY - pos.y))
    func area(_ a: CGRect, _ b: CGRect) -> CGFloat { let i = a.intersection(b); return i.isNull ? 0 : i.width * i.height }
    func seen(_ o: CGPoint) -> CGFloat {
      let r = CGRect(origin: o, size: size)
      return r.width * r.height - front.reduce(0) { $0 + area($1, r) } - 2 * area(body, r)
    }
    let cands = [(above, 0), (CGPoint(x: rx, y: hi), -1), (CGPoint(x: lx, y: hi), 1), (CGPoint(x: rx, y: lo), -1), (CGPoint(x: lx, y: lo), 1)].map { (fit($0.0), $0.1) }
    let best = cands.map { seen($0.0) }.max() ?? 0
    if let p = prefer, let c = cands.filter({ $0.1 == p }).max(by: { seen($0.0) < seen($1.0) }), seen(c.0) >= best - size.width * size.height * 0.1 { return c }   // If the current side is nearly equal, keep it
    return cands.first { seen($0.0) >= best } ?? (fit(above), 0)
  }
  /// If the position changes and the tail direction differs, redraw the same text
  var bubbleKeys: [ObjectIdentifier: String] = [:], sceneGen = 0
  var sideAt: [ObjectIdentifier: Double] = [:]                                   // When the bubble side was decided; for the next 1.5 seconds stay on that side (image size differs by tail direction, so it flipped between above and beside)
  func placeBubble(_ win: NSWindow, _ view: NoticeView, _ spec: inout BubbleSpec?) {
    guard var sp = spec else { return }
    let key = "\(Int(pos.x)),\(Int(headY)),\(Int(win.frame.width))x\(Int(win.frame.height)),\(stackedOn ?? -1),\(sceneGen),\(sp.side),\(view.image.map { ObjectIdentifier($0).hashValue } ?? 0)"
    if bubbleKeys[ObjectIdentifier(win)] == key { return }                            // If the pet, bubble and window layout are unchanged, skip the placement computation (screen list query)
    defer { bubbleKeys[ObjectIdentifier(win)] = key }
    let k = textDot / CGFloat(RENDER_M)
    let airborne: Bool = { switch act { case .jump, .fall, .drag, .dive, .slide, .roll: return true; default: return false } }()   // While rolling, the image rotates and head height keeps changing   // While jumping or falling, above and side were blocked and freed, so it alternated
    let hold = now - (sideAt[ObjectIdentifier(win)] ?? -9) < 1.5
    var (o, side) = bubbleSlot(win.frame.size, prefer: sp.side, force: airborne || hold)
    if side != sp.side, let img = noticeImage(sp.lines, fill: sp.fill, edge: sp.edge, side: side, check: sp.check, reveal: sp.reveal, tail: tailDX(o, win.frame.size, side)) {
      sp.side = side; sp.tail = tailDX(o, win.frame.size, side); spec = sp; healthBubbleSide(win, side); sideAt[ObjectIdentifier(win)] = now
      view.image = img; view.needsDisplay = true
      win.setContentSize(NSSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k))
      let (o2, _) = bubbleSlot(win.frame.size, prefer: side); win.setFrameOrigin(o2); return
    }
    let cur = win.frame.origin
    // When only the head bobs in place (cheering, humming, laptop), leave the bubble alone; following point by point made the window server work 12 times per second
    if win.isVisible, abs(o.x - cur.x) < 0.5, o.y - cur.y <= ds + 0.5, cur.y - o.y <= 3 * ds { o.y = cur.y }
    if cur != o { win.setFrameOrigin(o) }
    let td = tailDX(o, win.frame.size, side)
    if abs(td - sp.tail) >= 2 || (td == 0) != (sp.tail == 0), let img = noticeImage(sp.lines, fill: sp.fill, edge: sp.edge, side: side, check: sp.check, reveal: sp.reveal, tail: td) {
      sp.tail = td; spec = sp; view.image = img; view.needsDisplay = true      // Move only the tail; size stays the same
    }
  }
  /// How many points to shift the tail of the bubble above from the bubble's center; even if the bubble is pushed off the screen edge, the tail still points at the pet
  func tailDX(_ o: CGPoint, _ size: CGSize, _ side: Int) -> Int {
    guard side == 0, textDot > 0 else { return 0 }
    let half = Int(size.width / textDot) / 2 - 5
    return min(max(Int(((pos.x - o.x - size.width / 2) / textDot).rounded()), -half), half)
  }
  /// Put the new image on the bubble: decide position, tail direction and size first, then show it (it used to appear once at the previous position and tail direction, then move on the next tick and flicker left and right)
  func presentBubble(_ win: NSWindow, _ view: NoticeView, _ spec: inout BubbleSpec?, _ new: BubbleSpec, _ image: CGImage) {
    let k = textDot / CGFloat(RENDER_M)
    var sp = new, img = image
    var size = NSSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
    let shown = win.isVisible, prefer = shown ? spec?.side : nil                  // A newly appearing bubble doesn't follow the side of the previous bubble
    let airborne: Bool = { switch act { case .jump, .fall, .drag, .dive, .slide, .roll: return true; default: return false } }()
    let hold = shown && now - (sideAt[ObjectIdentifier(win)] ?? -9) < 1.5
    var (o, side) = bubbleSlot(size, prefer: prefer, force: shown && (airborne || hold))
    if side != sp.side, let im = noticeImage(sp.lines, fill: sp.fill, edge: sp.edge, side: side, check: sp.check, reveal: sp.reveal) {
      img = im; sp.side = side
      size = NSSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
      o = bubbleSlot(size, prefer: side, force: true).0
    }
    let td = tailDX(o, size, sp.side)
    if td != sp.tail, let im = noticeImage(sp.lines, fill: sp.fill, edge: sp.edge, side: sp.side, check: sp.check, reveal: sp.reveal, tail: td) { img = im; sp.tail = td }
    if !shown || spec?.side != sp.side { sideAt[ObjectIdentifier(win)] = now }
    if shown, let old = spec, old.side != sp.side { healthBubbleSide(win, sp.side) }
    spec = sp
    view.image = img; view.needsDisplay = true
    let f = NSRect(origin: o, size: size)
    if win.frame != f { win.setFrame(f, display: false) }
    bubbleKeys[ObjectIdentifier(win)] = nil
    stickBubble(win)
  }

  // ---- Chatter ----
  /// Tail-read only the transcripts of working (or asking) sessions. Idle sessions are let go
  func syncTails() {
    let live = chatty > 0 ? Set(list.filter { ($0.mood == .work || $0.mood == .ask) && $0.tool == "claude" }.map(\.id)) : []   // Only Claude's transcript can be tailed
    for (sid, tl) in tails where !live.contains(sid) { tl.stop(); tails[sid] = nil }
    for sid in live where tails[sid] == nil && !tailPending.contains(sid) {
      tailPending.insert(sid)
      ioQ.async { [weak self] in
        let u = self?.sources.lazy.compactMap { $0.jsonl(sid) }.first
        DispatchQueue.main.async {
          guard let self else { return }
          self.tailPending.remove(sid)
          let still = self.chatty > 0 && self.list.contains { $0.id == sid && ($0.mood == .work || $0.mood == .ask) }
          if still, self.tails[sid] == nil, let u, let tl = Tail(path: u.path, emit: { [weak self] c in self?.chat(c) }) { self.tails[sid] = tl }
        }
      }
    }
  }
  /// Decide whether to speak: subagents, background, errors, tests and commits are important; reads, edits and commands only occasionally
  /// Praise only once when crossing a threshold; not again for the same count, and counted again when it drops to one or two (so it doesn't feel like nagging)
  var praisedWork = 2, agentStarts: [Double] = [], praisedAgents = 0
  func praiseSessions(_ n: Int, tool: String? = "claude", label: String = T("클로드", "Claude")) {
    if n <= 1 { praisedWork = 2; return }
    guard n > praisedWork else { return }
    praisedWork = n
    let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    let best = UD.double(forKey: "bestWorkDay") == day ? UD.integer(forKey: "bestWork") : 0
    if n > best { UD.set(day, forKey: "bestWorkDay"); UD.set(n, forKey: "bestWork") }
    guard polledOnce, chatty > 0 else { return }                                   // Don't praise what was already running when the app started
    say(praiseLine(sessions: n, record: n > best && best >= 3, label: label, custom: tool.map { toolStyle($0).praise } ?? []), now)
    cheerUntil = now + 1.5
  }
  /// If friends are called 3rd, 5th, 8th or 12th within 90 seconds, return that count
  func agentBurst(_ t: Double) -> Int? {
    agentStarts = agentStarts.filter { t - $0 < 90 } + [t]
    if agentStarts.count == 1 { praisedAgents = 0 }
    let n = agentStarts.count
    guard [3, 5, 8, 12].contains(n), n > praisedAgents else { return nil }
    praisedAgents = n; return n
  }
  func chat(_ c: Chat) {
    let t = now
    switch c { case .commit, .test, .agentStart, .error, .read, .web, .edit, .agentDone, .bgDone: gest = c; gestT0 = t; default: break }
    if case .error = c { fx = 1; fxT0 = t }   // Gestures happen regardless of how much it talks
    if case .agentStart = c, let n = agentBurst(t) { cheerUntil = t + 1.5; if chatty > 0 { say(praiseLine(agents: n), t) }; return }
    guard chatty > 0, showing == nil else { return }
    if t < chatUntil - 0.5 { return }                                              // Don't cover the previous line before it has been read
    let important: Bool
    switch c { case .agentStart, .agentDone, .bgStart, .bgDone, .error, .test, .commit: important = true; default: important = false }
    let gap: Double = [0, 12, 5, 2.5][chatty]
    if t - lastChat < (important ? gap * 0.5 : gap) { return }
    if !important {
      if chatty == 1 { return }
      if Double.random(in: 0...1) > (chatty == 3 ? 0.6 : 0.3) { return }
    }
    say(line(c, ctx), t)
    if case .agentStart = c { cheerUntil = t + 1.2 }                           // Sparkle when calling a friend
    if case .error = c { errs = errs.filter { t - $0 < 60 } + [t]; if errs.count >= 3, !uninterruptible, floor != nil { errs.removeAll(); act = .react(.dizzy, t, 1.2) } }   // Errors are common: dizzy only on three in a row
  }
  /// Speak: text drawing (a few to ~10 ms) runs in the background, and it is shown when done
  var sayToken = 0, chatSpec: BubbleSpec?, noticeSpec: BubbleSpec?
  /// Bubble queue: a bubble on screen is guaranteed at least 2.2 seconds; lines that arrive meanwhile wait in line (max 3, those older than 6 seconds are dropped)
  static let CHAT_MIN = 3.2
  var chatQueue: [(String, Double)] = [], chatShownAt = 0.0
  func say(_ text: String, _ t: Double) {
    lastChat = t
    if showing != nil || chatUntil > t && t < chatGate {          // The previous line hasn't been fully read yet or a completion bubble is up: queue it (so it isn't covered the moment it appears)
      if !chatQueue.contains(where: { $0.0 == text }) { chatQueue.append((text, t)); if chatQueue.count > 3 { chatQueue.removeFirst() } }
      return
    }
    showChat(text, t)
  }
  // Speaking style: occasionally flash "..." (typing) briefly, then type the letters one by one
  var typeText = "", typeShown = 0, typeNext = 0.0, dotsFrom = 0.0, dotsUntil = 0.0, dotsPhase = 0, chatGate = 0.0
  static func typeDelay(_ c: Character) -> Double { "!?.~…,".contains(c) ? 0.17 : 0.055 }   // 0.055 seconds per character, a short pause after punctuation
  var chatTyping: Bool { chatUntil > now && (now < dotsUntil || typeShown < typeText.count) }
  func showChat(_ text: String, _ t: Double) {
    let dots = Double.random(in: 0...1) < 0.35 ? Double.random(in: 0.7...1.5) : 0
    if prof { FileHandle.standardError.write("  bubble chat t=\(String(format: "%.2f", t)) \(text)\n".data(using: .utf8)!) }
    let typing = text.reduce(0) { $0 + Pet.typeDelay($1) }
    chatShownAt = t; dotsFrom = t; dotsUntil = t + dots; dotsPhase = 0
    typeText = text; typeShown = dots > 0 ? 0 : 1; typeNext = t + dots + Pet.typeDelay(text.first ?? " ")
    chatUntil = t + dots + typing + max(Pet.CHAT_MIN, min(6.5, 2.6 + Double(text.count) * 0.16))   // Reading time after typing: 3.2 seconds for a short line to 6.5 seconds for a long one
    chatGate = t + dots + typing + Pet.CHAT_MIN                                      // After typing, leave at least this long to read (the next line queues)
    if dots > 0 { renderChat("...", reveal: 1) } else { renderChat(text, reveal: 1) }
  }
  func renderChat(_ text: String, reveal: Int) {
    sayToken &+= 1; let token = sayToken
    let side = chatWin.isVisible ? chatSpec?.side ?? 0 : 0, tail = chatWin.isVisible ? chatSpec?.tail ?? 0 : 0   // A newly appearing line is drawn with the tail on top, and the position is decided when it is shown
    sceneQ.async { [weak self] in
      let img = self?.profile("say") { noticeImage([(text, cg("#3a2a24"))], fill: cg("#ffffff"), edge: cg("#8a7a68"), side: side, reveal: reveal, tail: tail) }
      DispatchQueue.main.async {
        guard let self, let img = img ?? nil, token == self.sayToken, self.chatUntil > self.now else { return }
        var sp = BubbleSpec(lines: [(text, cg("#3a2a24"))], fill: cg("#ffffff"), edge: cg("#8a7a68")); sp.side = side; sp.reveal = reveal; sp.tail = tail
        self.presentBubble(self.chatWin, self.chatView, &self.chatSpec, sp, img)
      }
    }
  }
  func stepTyping(_ t: Double) {
    guard chatUntil > t else { return }
    if t < dotsUntil {                                                               // One, two, three dots cycle
      let ph = Int((t - dotsFrom) / 0.28) % 3 + 1
      if ph != dotsPhase { dotsPhase = ph; renderChat("...", reveal: ph) }
      return
    }
    guard typeShown < typeText.count, t >= typeNext else { return }
    let cs = Array(typeText)
    while typeShown < cs.count && t >= typeNext { typeShown += 1; typeNext += typeShown < cs.count ? Pet.typeDelay(cs[typeShown - 1]) : 0 }   // Even if ticks are late, catch up at its own speed
    renderChat(typeText, reveal: typeShown)
  }
  func stepChat(_ t: Double) {
    // If quiet for a while, mutter to itself (not done when set to quiet or off)
    if chatty >= 2, showing == nil, !list.isEmpty, t > nextIdleChat {
      nextIdleChat = t + (chatty == 3 ? .random(in: 25...50) : .random(in: 60...140))
      if t - lastChat > 15 && nextIdleChat > 0 && !inTransit { say(line(mood == .sleep ? .sleepy : .idle, ctx), t) }
    }
    chatQueue.removeAll { t - $0.1 > 12 }                                          // Drop lines that waited too long (generous wait time behind typing and completion bubbles)
    if !chatQueue.isEmpty, showing == nil, chatUntil == 0 || t > chatUntil || t >= chatGate {   // If the previous line has filled its minimum time, the next line
      showChat(chatQueue.removeFirst().0, t)
    }
    if chatUntil > 0 && (t > chatUntil || showing != nil) { if prof { FileHandle.standardError.write("  bubble chat-hide t=\(String(format: "%.2f", t))\n".data(using: .utf8)!) }; chatUntil = 0; chatWin.orderOut(nil) }
    guard chatUntil > 0 else { return }
    stepTyping(t)
    placeBubble(chatWin, chatView, &chatSpec)
  }

  func openNotice() {
    guard let n = showing else { return }
    hideNotice(); ack()
    DispatchQueue.global().async { openSession(pid: n.pid, id: n.id, tool: n.tool, name: n.title) }
  }

  // Drag, throw, click
  var busy: Bool { switch act { case .react, .jump, .fall: return true; default: return false } }
  var ignoring = false, grabPos = CGPoint.zero, grabFloor: String?, grabAct: Act = .stand
  func grab(_ e: NSEvent) {
    let t0 = now
    clicks = clicks.filter { t0 - $0 < 1.6 } + [t0]
    if clicks.count >= 3 { poutNext = true }                            // Rapid clicks: it sulks after the current action ends
    nextGoal = nil
    ignoring = busy                                                     // No reaction while an animation is running
    if ignoring { return }
    let m = NSEvent.mouseLocation
    grabOffset = CGPoint(x: m.x - pos.x, y: m.y - pos.y); grabStart = m; grabPos = pos; grabFloor = floorID; grabAct = act
    liftCtx = ctx; liftSaid = false                                                 // State before being picked up (was it asleep, was it working)
    if !onTop { stackedOn = nil; window.level = .floating; window.orderFrontRegardless(); restackBubbles() }   // While held, in front of all windows (so it doesn't hide when passing over a window)
    samples = [(now, m)]; act = .drag; floorID = nil; grabT = now; carriedSaid = false; schedule(1.0 / 60)
  }
  func dragTo() {
    if ignoring { return }
    let m = NSEvent.mouseLocation
    pos = CGPoint(x: m.x - grabOffset.x, y: m.y - grabOffset.y)
    samples.append((now, m)); samples = samples.filter { now - $0.0 < 0.1 }
    if !liftSaid, hypot(m.x - grabStart.x, m.y - grabStart.y) > 6 {                // The moment it is lifted
      liftSaid = true
      if chatty > 0, showing == nil, Double.random(in: 0...1) < 0.75 { say(line(.lifted, liftCtx), now) }
    }
    if !carriedSaid, now - grabT > 2.5, chatty >= 2, showing == nil { carriedSaid = true; say(line(.carried, ctx), now) }
    if chatty > 0, showing == nil, now - lastChat > 3, ctx.fast { say(line(.carried, ctx), now) }   // Shaken hard: says it is dizzy
    place()                                                                      // Per event, only the window position; drawing the pose is done by the 60 per second tick
  }
  func release() {
    if ignoring { ignoring = false; return }
    let m = NSEvent.mouseLocation
    if hypot(m.x - grabStart.x, m.y - grabStart.y) < 4 {
      pos = grabPos; floorID = grabFloor
      if floor == nil { act = .fall } else { act = grabAct; poke() }
      return
    }
    if let a = samples.first, now - a.0 > 0.01, now - (samples.last?.0 ?? 0) < 0.08 {
      let dt = CGFloat(now - a.0)
      let k: CGFloat = 0.6, cap: CGFloat = 1600                                  // Reduce the hand speed: with 0.8 and 2200 and floaty gravity it flew across the screen to another monitor (2900pt)
      vel = CGVector(dx: max(-cap, min(cap, (m.x - a.1.x) / dt * k)), dy: max(-cap, min(cap, (m.y - a.1.y) / dt * k)))
    } else { vel = .init(dx: 0, dy: 0) }
    if vel.dy < 260 { vel.dy = min(vel.dy, -260) }                                // If simply released, it starts falling right away (with only gravity from a standstill it looked like it hovered briefly); something thrown upward still rises (this line used to block upward throws entirely)
    spinning = hypot(vel.dx, vel.dy) > 1200
    let speed = hypot(vel.dx, vel.dy)
    thrown = speed > 400; handFall = true
    nextMigrate = max(nextMigrate, now + 60)                                      // A spot moved by hand: it doesn't dive straight back to the cursor's screen (it went back in 2 seconds right after being thrown to another monitor)
    lastTick = now; schedule(1.0 / 60)                                            // Draw the first frame right away
    // On release it falls down by default; while falling it lands on the first visible top edge (window or widget) or the floor (it doesn't catch on corners of covered windows)
    if chatty > 0 {
      if speed > 800, Double.random(in: 0...1) < 0.8 { say(line(.thrown, ctx), now) }      // Thrown
      else if speed < 150 { dropSaid = true }                                            // Released gently: says one line on landing
    }
    act = .fall
  }

  // Menu: session list (choosing goes to that tab) + settings
  /// Acknowledgment (clicking the pet): those sessions stop the badge and nagging. If they go back to work and finish again, it notifies again
  func ack() {
    acked = Set(list.filter { $0.mood >= .wait }.map(\.id))
    notices.removeAll { acked.contains($0.id) }
    if let n = showing, acked.contains(n.id) { hideNotice() }
    applyMood()
  }
  /// Left click: reaction only, no menu (with many sessions open, the list itself is noise)
  var lastReact: React?
  func poke() {
    ack()
    if mood == .sleep, case .sleep = act { act = .react(nil, now, 1.6); return }   // Woken from sleep and startled
    if poutNext { pout(); return }
    let r = POKE_REACTS.filter { $0 != lastReact }.randomElement()!
    lastReact = r
    let dur: Double = [.hop: 0.7, .spin: 1.1, .heart: 1.8, .squish: 1.0, .dizzy: 1.6, .wave: 1.4, .shy: 1.5, .star: 1.2][r] ?? 1.2
    act = .react(r, now, dur)
  }
  /// Rapid clicks make it puff its cheeks and sulk; more makes it run away
  func pout() {
    poutNext = false
    let t = now, many = clicks.filter { t - $0 < 3 }.count >= 6
    if many, floor != nil { act = .roll(NSEvent.mouseLocation.x > pos.x ? -1 : 1); actUntil = t + 1.0; if chatty > 0 { say(line(.flee, ctx), t) } }
    else { act = .react(.pout, t, 1.4); if chatty > 0, showing == nil { say(line(.pout, ctx), t) } }
    clicks.removeAll()
  }
  /// Right click: settings
  func showMenu() {
    ack()
    let menu = NSMenu()
    func sub(_ title: String, _ items: [(String, Bool, Selector, Any)]) {
      let m = NSMenu()
      for (t, on, sel, v) in items {
        let it = NSMenuItem(title: t, action: sel, keyEquivalent: ""); it.target = self; it.representedObject = v; it.state = on ? .on : .off; m.addItem(it)
      }
      menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
    }
    func cur<T: Equatable>(_ opts: [(String, T)], _ v: T) -> String { opts.first { $0.1 == v }?.0 ?? "" }
    let live = list.filter { $0.mood != .sleep }
    if doneToday > 0 { menu.addItem(withTitle: T("오늘 끝낸 일 \(doneToday)개", "Finished Today: \(doneToday)"), action: nil, keyEquivalent: "") }
    if !list.isEmpty {                                                             // Sessions: what each is doing; choose one to jump to it
      let count = { (m: Mood) in self.list.filter { $0.mood == m }.count }
      let head = T("세션 \(list.count)개 — 일함 \(count(.work)) · 기다림 \(count(.wait) + count(.ask))", "\(list.count) sessions — \(count(.work)) working · \(count(.wait) + count(.ask)) waiting")
      let m = NSMenu()
      for s in (live.isEmpty ? list : live).prefix(20) {
        let mark = s.mood == .ask ? "?" : s.mood == .wait ? "✓" : s.mood == .work ? "…" : s.mood == .free ? "·" : "z"
        let who = s.tool == "claude" ? "" : "\(s.label) · "
        let it = NSMenuItem(title: "\(mark)  \(who)\(s.name)", action: #selector(openListed(_:)), keyEquivalent: ""); it.target = self; it.representedObject = s.id; m.addItem(it)
      }
      if !live.isEmpty && live.count < list.count { m.addItem(.separator()); m.addItem(withTitle: T("쉬는 세션 \(list.count - live.count)개", "\(list.count - live.count) resting"), action: nil, keyEquivalent: "") }
      menu.addItem(withTitle: head, action: nil, keyEquivalent: "").submenu = m
    }
    sub(T("잠깐 숨기기", "Hide for a While"), [(T("15분", "15 Minutes"), false, #selector(snooze(_:)), 15.0), (T("1시간", "1 Hour"), false, #selector(snooze(_:)), 60.0), (T("3시간", "3 Hours"), false, #selector(snooze(_:)), 180.0)])
    menu.addItem(.separator())
    let sizes = [(T("작게", "Small"), 2), (T("보통", "Medium"), 3), (T("크게", "Large"), 4)], texts = [(T("아주 작게", "Tiny"), 1), (T("작게", "Small"), 2), (T("보통", "Medium"), 3), (T("크게", "Large"), 4)]
    let talks = [(T("수다쟁이", "Chatty"), 3), (T("보통", "Normal"), 2), (T("과묵", "Quiet"), 1), (T("끄기", "Off"), 0)]
    sub(T("캐릭터: \(chara.name)", "Character: \(chara.name)"), ALL_CHARAS.map { ($0.name, $0.id == chara.id, #selector(setChara(_:)), $0.id) })
    if let cm = menu.items.last?.submenu {                                          // Where packs go
      cm.addItem(.separator())
      for (title, sel) in [(T("다른 캐릭터 받기…", "More Characters…"), #selector(openCommunity)), (T("캐릭터 폴더 열기", "Open Characters Folder"), #selector(openCharas)), (T("캐릭터 다시 불러오기", "Reload Characters"), #selector(reloadCharas)), (T("이 캐릭터 GIF로 저장", "Save This Character as GIF"), #selector(saveGIF))] {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: ""); it.target = self; cm.addItem(it)
      }
    }
    sub(T("크기: \(cur(sizes, Int(scale)))", "Size: \(cur(sizes, Int(scale)))"), sizes.map { ($0.0, Int(scale) == $0.1, #selector(setScale(_:)), $0.1) })
    menu.addItem(.separator())
    sub(T("돌아다니기: \(["느긋", "보통", "활발"][roam])", "Wandering: \(["Lazy", "Normal", "Lively"][roam])"), T(["느긋", "보통", "활발"], ["Lazy", "Normal", "Lively"]).enumerated().map { ($0.element, roam == $0.offset, #selector(setRoam(_:)), $0.offset) })
    sub(T("수다: \(cur(talks, chatty))", "Chattiness: \(cur(talks, chatty))"), talks.map { ($0.0, chatty == $0.1, #selector(setChatty(_:)), $0.1) })
    sub(T("글꼴: \(FONT_FAMILIES[fontFamily].label)", "Font: \(FONT_FAMILIES[fontFamily].label)"), FONT_FAMILIES.enumerated().map { ($0.element.label, fontFamily == $0.offset, #selector(setFontFamily(_:)), $0.offset) })
    sub(T("말풍선 글자: \(cur(texts, noticeScale))", "Bubble Text: \(cur(texts, noticeScale))"), texts.map { ($0.0, noticeScale == $0.1, #selector(setNoticeScale(_:)), $0.1) })
    let langs: [(String, String)] = [(T("시스템 따라", "System"), ""), ("한국어", "ko"), ("English", "en")], langNow = UD.string(forKey: "lang") ?? ""
    sub(T("언어", "Language") + ": \(cur(langs, langNow))", langs.map { ($0.0, langNow == $0.1, #selector(setLang(_:)), $0.1) })
    let season = NSMenuItem(title: SEASONAL ? T("악세사리 끄기", "Turn Off Accessories") : T("악세사리 켜기", "Turn On Accessories"), action: #selector(toggleSeasonal), keyEquivalent: "")
    season.target = self; menu.addItem(season)
    let snd = NSMenuItem(title: T("끝나면 소리 내기", "Play a Sound When Done"), action: #selector(toggleSound), keyEquivalent: "")
    snd.target = self; snd.state = soundOn ? .on : .off; menu.addItem(snd)
    menu.addItem(.separator())
    if let u = availableUpdate, BUILD_KIND == "release" {
      let it = NSMenuItem(title: T("업데이트 \(u.version) 설치", "Install Update \(u.version)"), action: #selector(installUpdateNow), keyEquivalent: ""); it.target = self; menu.addItem(it)
    } else {
      let it = NSMenuItem(title: T("업데이트 확인…", "Check for Updates…"), action: #selector(checkUpdatesNow), keyEquivalent: ""); it.target = self; menu.addItem(it)
    }
    let au = NSMenuItem(title: BUILD_KIND == "release" ? T("자동으로 업데이트", "Update Automatically") : T("새 업데이트 알려 주기", "Tell Me About New Versions"), action: #selector(toggleAutoUpdate), keyEquivalent: "")
    au.target = self; au.state = UD.bool(forKey: "autoUpdate") ? .on : .off; menu.addItem(au)
    let cli = NSMenuItem(title: T("명령줄 도구 설치 (다른 에이전트 연결용)", "Install Command-Line Tools (for other agents)"), action: #selector(installCLINow), keyEquivalent: ""); cli.target = self; menu.addItem(cli)
    menu.addItem(.separator())
    let login = NSMenuItem(title: T("로그인할 때 켜기", "Launch at Login"), action: #selector(toggleLogin), keyEquivalent: ""); login.target = self
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
    menu.addItem(withTitle: T("종료", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    NSApp.activate(ignoringOtherApps: true)
    let hold = floor != nil && { if case .sleep = act { return false } else if case .work = act { return false } else { return true } }()
    if hold { act = .stand; actUntil = now + 3600 }                                // Stays put under its menu (it used to walk off with the menu left behind)
    menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX, y: CGFloat(CH - lastCanvas.top) * ds), in: view)   // returns when the menu closes
    if hold, case .stand = act { actUntil = now + 0.6 }
  }
  /// For a first-time user: explain what it does in a few bubbles, and ask once whether to start at login (it never enables it without asking).
  /// Skipped for people who used an earlier version (login item or character already chosen)
  func onboard() {
    guard UD.object(forKey: "onboarded") == nil else { return }
    UD.set(true, forKey: "onboarded")
    if UD.object(forKey: "loginItem") != nil || UD.object(forKey: "chara") != nil { return }
    var lines = T(["안녕! 난 도트 친구야", "에이전트 일이 끝나면 알려줄게", "물어볼 게 생겨도 알려줄게", "나를 누르면 그 터미널로 가", "오른쪽 클릭하면 설정이야"],
                  ["Hi! I'm your Dot Buddy", "I'll tell you when agents finish", "...or when they have a question", "Click me to jump to that terminal", "Right-click me for settings"])
    if list.isEmpty { lines.append(T("Claude Code를 켜 봐!", "Try starting Claude Code!")) }
    for (i, l) in lines.enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(i) * 4.5) { [weak self] in guard let self else { return }; self.say(l, self.now) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(lines.count) * 4.5) { [weak self] in self?.askLogin() }
  }
  func askLogin() {
    let a = NSAlert()
    a.messageText = T("맥에 로그인할 때 도트 친구도 켤까요?", "Launch Dot Buddy at login?")
    a.informativeText = T("나중에 펫을 오른쪽 클릭해 바꿀 수 있어요.", "You can change this later by right-clicking the pet.")
    a.addButton(withTitle: T("켜기", "Launch at Login")); a.addButton(withTitle: T("나중에", "Not Now"))
    let upd = NSButton(checkboxWithTitle: T("하루 한 번 업데이트를 확인하고, 쉬는 동안 알아서 설치(GitHub 에만 물어봐요)", "Check for new versions once a day and update while idle (asks GitHub only)"), target: nil, action: nil)
    upd.state = .on; upd.sizeToFit(); a.accessoryView = upd
    NSApp.activate(ignoringOtherApps: true)
    let on = a.runModal() == .alertFirstButtonReturn
    UD.set(upd.state == .on, forKey: "autoUpdate"); if upd.state == .on { startUpdateChecks() }
    UD.set(on, forKey: "loginItem")
    guard on else { return }
    try? SMAppService.mainApp.register()
    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
  }
  // ---------- Sound (off unless turned on in the menu) ----------
  var soundOn: Bool { UD.bool(forKey: "sound") }
  var lastSound = -99.0
  /// A short system sound when a session finishes or asks; one at most every 2 seconds, none while hidden for a while
  func chime(ask: Bool) {
    guard soundOn, !snoozed, now - lastSound > 2 else { return }
    lastSound = now
    if prof { FileHandle.standardError.write("  sound \(ask ? "ask" : "done") t=\(String(format: "%.2f", now))\n".data(using: .utf8)!) }
    NSSound(named: ask ? "Tink" : "Glass")?.play()
  }
  @objc func toggleSound() { UD.set(!soundOn, forKey: "sound"); lastSound = -99; chime(ask: false) }   // turning it on plays it once so you hear what it sounds like
  // ---------- Finished today (shown at the top of the menu) ----------
  var today: Double { Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 }
  var doneToday: Int { UD.double(forKey: "doneDay") == today ? UD.integer(forKey: "doneToday") : 0 }
  func countDone(_ n: Int) {
    guard n > 0 else { return }
    let c = doneToday; UD.set(today, forKey: "doneDay"); UD.set(c + n, forKey: "doneToday")
    if prof { FileHandle.standardError.write("  done-today \(c + n)\n".data(using: .utf8)!) }
  }
  // ---------- Hide for a while ----------
  var snoozeUntil = 0.0, snoozed = false
  @objc func snooze(_ it: NSMenuItem) {
    guard let mins = it.representedObject as? Double else { return }
    snoozeUntil = now + mins * 60; snoozed = true; hideNotice(); chatUntil = 0
    for w in [window, noticeWin, chatWin, badgeWin] as [NSWindow?] { w?.orderOut(nil) }
    schedule(0.5)
  }
  /// Session list (menu): choosing one goes to its terminal, like clicking its bubble
  @objc func openListed(_ it: NSMenuItem) {
    guard let id = it.representedObject as? String, let s = list.first(where: { $0.id == id }) else { return }
    ack()
    DispatchQueue.global().async { openSession(pid: s.pid, id: s.id, tool: s.tool, name: s.name) }
  }

  // ---------- Updates (see Update.swift) ----------
  var availableUpdate: UpdateInfo?, updateTimer: Timer?, updating = false
  /// Automatic checks: a day after the last one (or a minute after launch if that's overdue), then every 6 hours look again whether a day has passed
  func startUpdateChecks() {
    updateTimer?.invalidate(); updateTimer = nil
    if let from = UD.string(forKey: "updatedFrom") {                              // first launch after a self-update
      UD.removeObject(forKey: "updatedFrom")
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in guard let self else { return }; self.cheerUntil = self.now + 2; self.say(T("업데이트했어요! \(from) → \(APP_VERSION)", "Updated! \(from) → \(APP_VERSION)"), self.now) }
    }
    guard UD.bool(forKey: "autoUpdate") else { return }
    let tick = { [weak self] in
      guard let self, Date().timeIntervalSince1970 - UD.double(forKey: "lastUpdateCheck") > 23 * 3600 else { return }
      self.checkForUpdates(manual: false)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: tick)
    let t = Timer(timeInterval: 6 * 3600, repeats: true) { _ in tick() }; t.tolerance = 600
    RunLoop.main.add(t, forMode: .common); updateTimer = t
  }
  func checkForUpdates(manual: Bool) {
    UD.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
    if manual { say(T("업데이트 확인할게요…", "Checking for updates…"), now) }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let r = latestRelease()
      DispatchQueue.main.async {
        guard let self else { return }
        switch r {
        case .failure(let e): if manual { self.say(T("확인 못 했어요: ", "Couldn't check: ") + describe(e), self.now) }
        case .success(let u):
          guard versionNewer(u.version, than: APP_VERSION) else { if manual { self.say(T("최신 버전이에요 (\(APP_VERSION))", "You're up to date (\(APP_VERSION))"), self.now) }; return }
          let first = self.availableUpdate?.version != u.version
          self.availableUpdate = u
          if BUILD_KIND != "release" { if manual || first { self.say(T("새 업데이트 \(u.version)! git pull 하고 build.sh", "\(u.version) is out! git pull && ./build.sh"), self.now) }; return }
          if UD.bool(forKey: "autoUpdate") { if manual { self.installUpdateNow() } else { self.installWhenIdle() }; return }   // asking by hand with automatic updates on means "get it now"
          if manual || first { self.say(T("새 업데이트 \(u.version)! 오른쪽 클릭해서 설치", "\(u.version) is out! Right-click to install"), self.now) }
        }
      }
    }
  }
  /// Automatic install waits until no agent is working or waiting on you, then swaps and relaunches.
  /// Someone who keeps agents busy all day never gets that quiet moment, so after waiting INSTALL_WAIT it installs anyway
  var idleWaitSince = 0.0
  static let INSTALL_WAIT = 3.0 * 3600
  func installWhenIdle() {
    guard availableUpdate != nil, !updating else { return }
    let busy = list.contains(where: { $0.mood == .work || $0.mood == .ask }) || showing != nil || !notices.isEmpty   // any session still working or asking (the pet's own mood shows only the most urgent one)
    if idleWaitSince == 0 { idleWaitSince = Date().timeIntervalSince1970 }
    if busy, Date().timeIntervalSince1970 - idleWaitSince < Pet.INSTALL_WAIT {
      DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in self?.installWhenIdle() }; return
    }
    idleWaitSince = 0
    installUpdateNow()
  }
  @objc func installCLINow() {
    let dir = NSHomeDirectory() + "/.local/bin"
    switch installCLI(dir) {
    case .success: say(onPath(dir) ? T("dotbuddy·dotbuddy-hook 깔았어!", "Installed dotbuddy and dotbuddy-hook!") : T("~/.local/bin 에 깔았어! PATH 에 넣어 줘", "Installed in ~/.local/bin, add it to PATH"), now)
    case .failure(let e): say(T("못 깔았어요: ", "Couldn't install: ") + e.localizedDescription, now)
    }
  }
  @objc func checkUpdatesNow() { checkForUpdates(manual: true) }
  @objc func installUpdateNow() {
    guard let u = availableUpdate, !updating else { return }
    updating = true
    say(T("업데이트 받는 중…", "Downloading the update…"), now)
    let from = APP_VERSION
    DispatchQueue.global(qos: .utility).async { [weak self] in
      // Ask again right before downloading: the version found at the last check can be stale (a newer one came out meanwhile and
      // installing the old one meant updating twice, 0.3.6 → 0.3.7 → 0.3.8 on 2026-11-23). If asking fails, install the one already found
      var u = u
      if case .success(let l) = latestRelease(), versionNewer(l.version, than: u.version) { u = l }
      let r = installUpdate(u)
      DispatchQueue.main.async {
        guard let self else { return }
        self.updating = false
        switch r {
        case .success(let path): UD.set(from, forKey: "updatedFrom"); UD.synchronize(); relaunch(path)
        case .failure(let e): self.availableUpdate = nil; self.say(T("업데이트 못 했어요: ", "Update failed: ") + describe(e), self.now)
        }
      }
    }
  }
  @objc func toggleSeasonal() { UD.set(!SEASONAL, forKey: "seasonal"); propHourAt = -99 }   // the hat comes or goes on the next frame
  @objc func toggleAutoUpdate() {
    let on = !UD.bool(forKey: "autoUpdate"); UD.set(on, forKey: "autoUpdate")
    if on { UD.set(0, forKey: "lastUpdateCheck") }
    startUpdateChecks()
  }
  @objc func toggleLogin() {
    let s = SMAppService.mainApp, on = s.status == .enabled
    do { if on { try s.unregister() } else { try s.register() } } catch { say(T("로그인 항목을 못 바꿨어", "Couldn't change Login Items"), now); return }
    UD.set(!on, forKey: "loginItem")
    if s.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }   // When permission must be granted in System Settings
  }
  /// Change language: restarts the app so character names and mutterings change all at once
  @objc func setLang(_ it: NSMenuItem) {
    guard let v = it.representedObject as? String, v != (UD.string(forKey: "lang") ?? "") else { return }
    if v.isEmpty { UD.removeObject(forKey: "lang") } else { UD.set(v, forKey: "lang") }
    UD.synchronize()
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
    try? p.run(); NSApp.terminate(nil)
  }
  @objc func setRoam(_ it: NSMenuItem) { guard let v = it.representedObject as? Int else { return }; roam = v; UD.set(v, forKey: "roam") }
  @objc func setChatty(_ it: NSMenuItem) {
    guard let v = it.representedObject as? Int else { return }
    chatty = v; UD.set(v, forKey: "chatty"); syncTails()
    if v == 0 { chatUntil = 0; chatWin.orderOut(nil) }
  }
  @objc func setFontFamily(_ it: NSMenuItem) {
    guard let v = it.representedObject as? Int else { return }
    fontFamily = v; UD.set(FONT_FAMILIES[v].id, forKey: "fontFamily"); badgeKey = ""
    if let n = showing { hideNotice(); notices.insert(n, at: 0) }
    say(T("이 글꼴 어때?", "How's this font?"), now)
  }
  @objc func setNoticeScale(_ it: NSMenuItem) {
    guard let v = it.representedObject as? Int else { return }
    noticeScale = v; UD.set(v, forKey: "textSize2"); updateRenderM(); badgeKey = ""
    if let n = showing { hideNotice(); notices.insert(n, at: 0) }                // Currently shown ones also get the new size
  }
  @objc func openCharas() {
    try? FileManager.default.createDirectory(at: CHARAS_DIR, withIntermediateDirectories: true)
    NSWorkspace.shared.open(CHARAS_DIR)
  }
  /// The character on screen as a short looping GIF in Downloads (to share), shown in Finder — drawn by a second copy of the app so the settings here stay as they are
  @objc func saveGIF() {
    guard let exe = Bundle.main.executablePath else { return }
    let id = chara.id, file = id.replacingOccurrences(of: "pack:", with: "").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }, fm = FileManager.default
    let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
    var out = dir.appendingPathComponent("dot-buddy-\(file).gif"), n = 2
    while fm.fileExists(atPath: out.path) { out = dir.appendingPathComponent("dot-buddy-\(file)-\(n).gif"); n += 1 }
    say(T("GIF 그리는 중~", "Drawing a GIF~"), now)
    let target = out
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let ok = run(exe, ["--demo-gif", target.path, "chara:" + id], timeout: 60) != nil && FileManager.default.fileExists(atPath: target.path)
      DispatchQueue.main.async {
        guard let self else { return }
        if ok { NSWorkspace.shared.activateFileViewerSelecting([target]); self.cheerUntil = self.now + 1.2 }
        self.say(ok ? T("다운로드 폴더에 저장했어요!", "Saved to Downloads!") : T("GIF를 못 만들었어요", "Couldn't make the GIF"), self.now)
      }
    }
  }
  /// Community characters window (talks to GitHub only once it opens)
  var community: CommunityWindow?
  @objc func openCommunity() {
    if let c = community { c.show(); return }
    let c = CommunityWindow { [weak self] id, name in
      guard let self else { return }
      ALL_CHARAS = mergeCharas(loadCustomCharas())
      self.chara = findChara(id); UD.set(id, forKey: "chara"); self.lastKey = ""; self.resize(); self.cheerUntil = self.now + 1.2
      self.say(T("\(name) 왔어!", "\(name) is here!"), self.now)
    }
    c.onClose = { [weak self] in self?.community = nil }
    c.onRemoved = { [weak self] id, name in                                         // If it was the one on screen, the first character takes over
      guard let self else { return }
      ALL_CHARAS = mergeCharas(loadCustomCharas())
      guard self.chara.id == id else { return }
      self.chara = findChara(CHARAS[0].id); UD.set(self.chara.id, forKey: "chara"); self.lastKey = ""; self.resize(); self.cheerUntil = self.now + 1.2
      self.say(T("\(name) 잘 가~", "Bye, \(name)~"), self.now)
    }
    community = c; c.show()
  }
  @objc func reloadCharas() {
    ALL_CHARAS = mergeCharas(loadCustomCharas())
    chara = findChara(chara.id)
    lastKey = ""; resize(); cheerUntil = now + 1.2
    say(T("캐릭터 \(ALL_CHARAS.filter { $0.sprite != nil }.count)개 불러왔어!", { let c = ALL_CHARAS.filter { $0.sprite != nil }.count; return c == 1 ? "Loaded 1 character!" : "Loaded \(c) characters!" }()), now)
  }
  /// A character dropped on the pet: install it off the main thread, then switch to it
  func installChara(_ u: URL) {
    say(T("받는 중…", "Unpacking…"), now)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let r = installDroppedChara(u)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        switch r {
        case .success(let (id, name)):
          ALL_CHARAS = mergeCharas(loadCustomCharas())
          self.chara = findChara(id); UD.set(id, forKey: "chara"); self.lastKey = ""; self.resize(); self.cheerUntil = self.now + 1.2
          self.say(T("\(name) 왔어!", "\(name) is here!"), self.now)
        case .failure(let e): self.say(describe(e), self.now)
        }
      }
    }
  }
  @objc func setChara(_ it: NSMenuItem) {
    guard let id = it.representedObject as? String, let c = ALL_CHARAS.first(where: { $0.id == id }) else { return }
    chara = c; UD.set(id, forKey: "chara"); cheerUntil = now + 1.2; lastKey = ""; resize()
  }
  @objc func setScale(_ it: NSMenuItem) {
    guard let v = it.representedObject as? Int else { return }
    scale = CGFloat(v); UD.set(v, forKey: "scale"); lastKey = ""; resize(); refreshFloors(force: true)
  }
}
