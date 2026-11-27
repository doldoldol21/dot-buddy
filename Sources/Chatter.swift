// Reading the transcript tail, and muttering
import AppKit
import CoreText
import ServiceManagement

// ---------- Transcript tail (only the lines newly appended to a working session's jsonl) → things to chatter about ----------
/// Gesture names that come from outside (--signal event <name>) → things to chatter about. agent-start can carry a friend's name, called as "agent-start:name"
let EVENT_NAMES = ["read", "edit", "test", "commit", "shell", "web", "skill", "error", "bg-start", "bg-done", "agent-start", "agent-done"]
func chatEvent(_ s: String) -> Chat? {
  let parts = s.split(separator: ":", maxSplits: 1).map(String.init), name = parts.first ?? ""
  switch name {
  case "read": return .read; case "edit": return .edit; case "test": return .test; case "commit": return .commit
  case "shell": return .shell; case "web": return .web; case "skill": return .skill; case "error": return .error
  case "bg-start": return .bgStart; case "bg-done": return .bgDone; case "agent-done": return .agentDone
  case "agent-start": return .agentStart(parts.count > 1 ? String(parts[1].prefix(20)) : "")
  default: return nil
  }
}
enum Chat { case read, edit, test, commit, shell, bgStart, bgDone, web, skill, agentStart(String), agentDone, error, idle, sleepy, petted, welcome, startle, missed, carried, caught, pout, flee, party, lifted, thrown, dropped, bonk, headBonk, landHard, slip, bounce }
final class Tail {
  let path: String
  private var offset: UInt64, buf = Data()
  private var src: DispatchSourceFileSystemObject?
  private var tools: [String: String] = [:]           // tool_use id → name, only for Agent/Task (when its result arrives, a helper finished)
  private let say: (Chat) -> Void
  /// Reading and parsing run on their own queue (a tool result line can hold a whole file); only the chatter goes to main
  private static let q = DispatchQueue(label: "dotbuddy.tail", qos: .utility)
  private func emit(_ c: Chat) { let say = say; DispatchQueue.main.async { say(c) } }
  init?(path: String, emit: @escaping (Chat) -> Void) {
    guard let a = try? FileManager.default.attributesOfItem(atPath: path), let size = (a[.size] as? NSNumber)?.uint64Value else { return nil }
    self.path = path; self.offset = size; self.say = emit                  // old records are not read again
    let fd = open(path, O_EVTONLY); guard fd >= 0 else { return nil }
    let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: Tail.q)
    s.setEventHandler { [weak self] in self?.kick() }
    s.setCancelHandler { close(fd) }
    s.resume(); src = s
  }
  func stop() { src?.cancel(); src = nil }
  /// Read only the newly appended bytes and process them line by line (if cut off mid-line, the rest is joined on next time)
  private var queued = false
  private func kick() {
    guard !queued else { return }
    queued = true
    Tail.q.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.queued = false; self?.pull() }
  }
  private static let marks = ["\"tool_use\"", "\"tool_result\"", "task-notification"].map { Data($0.utf8) }
  private static let useMark = Data("\"tool_use\"".utf8), noteMark = Data("task-notification".utf8), errMark = Data("\"is_error\":true".utf8)
  private func pull() {
    guard let h = FileHandle(forReadingAtPath: path) else { return }
    defer { try? h.close() }
    let end = (try? h.seekToEnd()) ?? offset
    if end < offset { offset = end; buf.removeAll(); return }               // if the file shrank (rewritten), start again from the end
    guard end > offset else { return }
    try? h.seek(toOffset: offset)
    while offset < end, let d = try? h.read(upToCount: Int(min(end - offset, 512 * 1024))), !d.isEmpty {
      offset += UInt64(d.count); buf.append(d)
    }
    var start = buf.startIndex                                              // walk the lines, then drop them all at once (removing each from the front copied the rest every time)
    while let nl = buf[start...].firstIndex(of: 0x0a) {
      if nl > start { handle(Data(buf[start..<nl])) }
      start = nl + 1
    }
    buf.removeSubrange(buf.startIndex..<start)
    if buf.count > 4 * 1024 * 1024 { buf.removeAll() }                     // drop a huge line with no line break
  }
  private func handle(_ line: Data) {
    guard Tail.marks.contains(where: { line.range(of: $0) != nil }) else { return }    // most lines need no parsing
    if line.range(of: Tail.useMark) == nil, line.range(of: Tail.noteMark) == nil,          // only tool results: all that matters is an error or a helper finishing
       line.range(of: Tail.errMark) == nil, tools.isEmpty { return }
    guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let m = j["message"] as? [String: Any] else { return }
    if j["type"] as? String == "user", let text = m["content"] as? String, text.contains("<task-notification>") { emit(.bgDone); return }
    guard let content = m["content"] as? [[String: Any]] else { return }
    for b in content {
      switch b["type"] as? String {
      case "tool_use"?:
        let name = b["name"] as? String ?? "", inp = b["input"] as? [String: Any] ?? [:]
        if name == "Agent" || name == "Task", let id = b["id"] as? String { tools[id] = name }
        switch name {
        case "Read", "Grep", "Glob", "NotebookRead": emit(.read)
        case "Edit", "Write", "MultiEdit", "NotebookEdit": emit(.edit)
        case "Agent", "Task": emit(.agentStart(inp["subagent_type"] as? String ?? ""))
        case "WebSearch", "WebFetch": emit(.web)
        case "Skill": emit(.skill)
        case "Bash":
          let cmd = (inp["command"] as? String ?? "").lowercased()
          if inp["run_in_background"] as? Bool == true { emit(.bgStart) }
          else if cmd.contains("git commit") { emit(.commit) }
          else if cmd.range(of: #"(?<![\w./-])(pytest|jest|vitest|unittest|selftest\w*|(npm|pnpm|yarn|go|cargo|swift|make|bun) test|run_tests?\w*)"#, options: .regularExpression) != nil,
                  cmd.range(of: #"(^|[;&|(]\s*|\[\s*)test\s+-[a-z]\b"#, options: .regularExpression) == nil { emit(.test) }   // `test -f` is not a test run
          else { emit(.shell) }
        default: break
        }
      case "tool_result"?:
        let id = b["tool_use_id"] as? String ?? ""
        if b["is_error"] as? Bool == true { emit(.error) }
        else if let n = tools[id], n == "Agent" || n == "Task", (j["toolUseResult"] as? [String: Any])?["isAsync"] as? Bool != true { emit(.agentDone) }   // the reply to a background launch only means "launched" — the end comes as a task-notification (bgDone)
        tools[id] = nil
      default: break
      }
    }
  }
}
/// Circumstances when speaking — where it is (height, what it stands on), what it is doing, how many sessions are working and waiting
struct Ctx {
  var high: CGFloat = 0                 // how many pt above the bottom of that screen (above the Dock)
  var on = "base"                       // base·widget·window·air
  var spot = ""                         // sitEdge·hang·sleep
  var chara = ""                        // character id (with the pack: prefix removed) — each character has its own muttering
  var working = 0, waiting = 0, awayDone = 0
  var mood = Mood.sleep, sweaty = false, fast = false
  var days = 0, firstToday = false, missed = 0
  var who = "Claude"                    // agent name of the waiting sessions (that name if all are the same, 'agent' if mixed)
  var hour = Calendar.current.component(.hour, from: Date()), minute = Calendar.current.component(.minute, from: Date())
  var weekday = gregorian().component(.weekday, from: Date())   // 1 Sunday … 7 Saturday
  var month = gregorian().component(.month, from: Date()), day = gregorian().component(.day, from: Date())
  var year = gregorian().component(.year, from: Date())
  var seasonal = SEASONAL               // seasonal lines (December, New Year) unless turned off in the menu
}
/// Mutterings that show each character's personality (mixed in when idle)
let CHARA_LINES: [String: [String]] = [
  "mandu": T(["김 빠지겠다~", "속이 꽉 찼어!", "따끈따끈해", "찜기 생각난다…"], ["Losing my steam~", "Stuffed and happy!", "Warm and toasty", "I miss my steamer..."]),
  "acorn": T(["모자 삐뚤어졌나?", "데구르르~", "다람쥐는 무서워…", "가을 냄새 좋다"], ["Is my cap crooked?", "Rolly rolly~", "Squirrels scare me...", "Smells like autumn"]),
  "sprout": T(["물 한 모금만…", "햇볕 좋다~", "쑥쑥 크는 중!", "잎이 간질간질해"], ["Just a sip of water...", "Sunshine feels nice~", "Growing, growing!", "My leaves tickle"]),
  "cloud": T(["둥실둥실~", "비 올 것 같아?", "바람 타고 갈래", "몽글몽글해"], ["Floaty floaty~", "Smells like rain?", "Riding the breeze~", "So fluffy today"]),
  "candle": T(["바람 불면 꺼질 것 같아", "촛농 흘렀다…", "조용히 밝혀줄게", "불 조심!"], ["One puff and I'm out", "Oops, dripped wax...", "I'll light the way", "Mind the flame!"]),
  "pebble": T(["이끼가 포근해", "구르는 돌엔 이끼가 안 낀대", "꽃 예쁘지?", "단단해서 괜찮아"], ["My moss is so cozy", "Glad I'm not a rolling stone", "Pretty flower, huh?", "Solid as a rock!"]),
]
/// Time-of-day mutterings — lines that fit the current time (hungry at lunch, drowsy in the afternoon…). Empty array if none apply
/// Hour name for AM/PM (hour 0 = midnight). In English: midnight, noon, 3 PM
func hourName(_ h: Int) -> String {
  LANG == .ko ? (h == 0 ? "밤 12시" : h < 12 ? "오전 \(h)시" : h == 12 ? "낮 12시" : "오후 \(h - 12)시")
              : (h == 0 ? "midnight" : h < 12 ? "\(h) AM" : h == 12 ? "noon" : "\(h - 12) PM")
}
/// English time — 3:05 PM (Korean uses hourName + minutes)
func clockName(_ h: Int, _ m: Int) -> String { "\(h % 12 == 0 ? 12 : h % 12):\(m < 10 ? "0" : "")\(m) \(h < 12 ? "AM" : "PM")" }
/// English plural — plural(1, "alert") = "1 alert", plural(3, "alert") = "3 alerts"
func plural(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
func timeLines(_ x: Ctx) -> [String] {
  let t = x.hour * 60 + x.minute, weekend = x.weekday == 1 || x.weekday == 7
  var a: [String] = []
  switch t {
  case 360..<540: a = T(["좋은 아침~", "아침은 먹었어?", "커피 한 잔 할까?", "오늘도 화이팅!", "아직 졸려…"], ["Good morning~", "Had breakfast yet?", "Coffee first?", "We got this today!", "Still sleepy..."])
  case 540..<690: a = T(["오전 집중 시간!", "슬슬 시작해볼까?", "오늘 할 일 많아?"], ["Morning focus time!", "Shall we get going?", "Big to-do list today?"])
  case 690..<810: a = T(["배고파…", "점심 뭐 먹지?", "꼬르륵…", "밥 먹고 하자~", "오늘 점심 메뉴는?", "배에서 소리 나…"], ["So hungry...", "What's for lunch?", "Grumble grumble...", "Lunch first, code later~", "Pizza? Noodles? Both?", "My tummy is talking..."])
  case 810..<900: a = T(["졸려… 식곤증…", "눈꺼풀이 무거워…", "밥 먹었더니 졸리다", "낮잠 5분만…"], ["Food coma... zzz", "Heavy eyelids...", "Lunch made me sleepy", "Just a 5-minute nap..."])
  case 900..<1000: a = T(["간식 시간!", "달달한 거 먹고 싶다", "커피 수혈~", "출출하다…"], ["Snack time!", "Craving something sweet", "Coffee refill, stat~", "A little peckish..."])
  case 1050..<1140: a = weekend ? T(["저녁 뭐 먹지?", "노을 예쁘다~"], ["What's for dinner?", "Pretty sunset~"]) : T(["퇴근 언제 해?", "칼퇴 가자!", "저녁 뭐 먹지?", "오늘 하루도 끝이 보인다"], ["Home time soon?", "Let's log off on time!", "What's for dinner?", "Finish line in sight!"])
  case 1140..<1320: a = T(["저녁은 먹었어?", "오늘 하루도 수고했어", "이제 좀 쉬자~"], ["Had dinner yet?", "Good work today", "Time to unwind~"])
  case 1320..<1440: a = T(["슬슬 잘 시간이야", "너무 무리하지 마", "밤이 깊었어…"], ["Almost bedtime", "Don't push too hard", "It's getting late..."])
  case 0..<300: a = T(["졸려…", "이제 자야 하는데…", "새벽 감성…", "아직 안 자?"], ["So sleepy...", "We should be in bed...", "3 AM thoughts...", "Still up?"])
  default: break
  }
  if weekend && x.hour >= 9 && x.hour < 18 { a += T(["주말인데 일해?", "주말엔 쉬자~"], ["Working on a weekend?", "Weekends are for naps~"]) }
  if x.weekday == 6 && x.hour >= 17 { a += T(["불금이다!", "주말이다!"], ["TGIF!", "Weekend mode: on!"]) }
  if x.weekday == 2 && x.hour >= 9 && x.hour < 12 { a += T(["월요병…", "월요일 힘내자…"], ["Case of the Mondays...", "We can do Monday..."]) }
  if x.seasonal { a += seasonLines(x) }
  return a
}
/// Seasonal mutterings: Christmas in December, the last day of the year, New Year's Day
func seasonLines(_ x: Ctx) -> [String] {
  switch (x.month, x.day) {
  case (12, 24): return T(["오늘은 크리스마스 이브!", "산타 할아버지 오시려나?", "양말 걸어 둬야지~", "착하게 지냈지?"], ["It's Christmas Eve!", "Is Santa on his way?", "Time to hang the stockings~", "Have you been good this year?"])
  case (12, 25): return T(["메리 크리스마스!", "선물 받았어?", "크리스마스에도 일하는 거야?", "케이크 먹자~"], ["Merry Christmas!", "Got any presents?", "Working on Christmas?", "Cake time~"])
  case (12, 31): return T(["올해 마지막 날이야!", "올해도 수고 많았어", "내년에도 같이 하자~"], ["Last day of the year!", "You did great this year", "Let's do next year together~"])
  case (1, 1): return T(["새해 복 많이 받아!", "올해도 잘 부탁해~", "새해 목표 세웠어?"], ["Happy New Year!", "Here's to a great year~", "Any New Year's resolutions?"])
  case (12, 1...23): return T(["모자 어때? 잘 어울려?", "크리스마스가 다가온다~", "눈 왔으면 좋겠다", "캐럴 듣고 싶어", "산타 모자 따뜻해"], ["Like my hat?", "Christmas is coming~", "I hope it snows", "Feels like carol season", "This Santa hat is cozy"])
  default:
    guard partySeason(year: x.year, month: x.month, day: x.day), Int.random(in: 0..<4) == 0 else { return [] }   // three months is long: now and then, not half of every muttering
    return T(["파티 모자 어때?", "오픈 기념 파티 중!", "와 줘서 고마워~", "새 친구들이 생기면 좋겠다"], ["Like my party hat?", "Launch party!", "Thanks for having me~", "Hope we make new friends"])
  }
}
var LAST_LINES: [String] = []
/// Praise — when many Claude sessions run at once (sessions) or friends (agents) are called one after another (agents). record: today's best record
func praiseLine(sessions n: Int = 0, agents: Int = 0, record: Bool = false, label: String = T("클로드", "Claude"), custom: [String] = []) -> String {
  func any(_ a: [String]) -> String {
    let pick = a.filter { !LAST_LINES.contains($0) }.randomElement() ?? a.randomElement()!
    LAST_LINES = Array((LAST_LINES + [pick]).suffix(5)); return pick
  }
  if agents > 0 { return any(T(["친구를 \(agents)명이나 불렀어! 대단해!", "에이전트 \(agents)명 한꺼번에! 멋지다~", "\(agents)명이 같이 뛰는 중이야!", "친구 \(agents)명 출동! 든든해"], ["You called \(agents) friends! Wow!", "\(agents) agents at once! So cool~", "\(agents) friends running together!", "\(agents) friends on the job! Nice"])) }
  if record { return any(T(["오늘 최고 기록! \(label) \(n)개!", "신기록이야! \(n)개 동시에!"], ["Best today! \(label) x\(n)!", "New record! \(n) at once!"])) }
  if !custom.isEmpty { return any(custom.map { $0.replacingOccurrences(of: "{n}", with: "\(n)") }) }   // praise from tools.json
  return any(T(["\(label) \(n)개를 한 번에? 대단해!", "\(n)군데서 동시에 일하다니 멋져!", "와, \(label) \(n)개 출동!", "\(n)개를 같이 굴리다니 손이 몇 개야?"], ["\(label) x\(n) at once? Wow!", "Busy in \(n) places? Amazing!", "Whoa, \(n) \(label) sessions!", "Juggling \(n)? How many hands?"]))
}
/// A short mutter. It never says the content (paths, commands, questions) — only the kind and circumstances. On the floor it does not say things like "so high"
/// Korean subject particle ga/i, chosen by the final consonant of the last syllable — after "Claude", "Codex", "agent" or "GitHub"
func ga(_ w: String) -> String {
  guard let u = w.unicodeScalars.last?.value, (0xAC00...0xD7A3).contains(u) else { return w + "가" }
  return w + ((u - 0xAC00) % 28 == 0 ? "가" : "이")
}
func line(_ c: Chat, _ x: Ctx = Ctx()) -> String {
  func any(_ a: [String]) -> String {
    let pick = a.filter { !LAST_LINES.contains($0) }.randomElement() ?? a.randomElement()!   // do not repeat any of the last 5 lines
    LAST_LINES = Array((LAST_LINES + [pick]).suffix(5)); return pick
  }
  let h = Calendar.current.component(.hour, from: Date()), high = x.high > 350
  switch c {
  case .read: return any(T(["어디 보자…", "읽는 중~", "흠흠 찾는 중", "이거였나?"], ["Let's see...", "Reading~", "Hmm, looking...", "Was it this one?"]))
  case .edit: return any(T(["뚝딱뚝딱!", "고치는 중~", "슥슥 쓰는 중", "여기를 이렇게…"], ["Tap tap tap!", "Fixing it up~", "Scribble scribble", "This goes here..."]))
  case .test: return any(T(["시험 돌려볼게!", "통과해라…!", "두근두근 테스트"], ["Running tests!", "Please pass...!", "Test time, eek!"]))
  case .commit: return any(T(["커밋할게!", "기록 남기는 중~", "저장 쾅!"], ["Committing!", "Saving our history~", "Commit, stamp!"]))
  case .shell: return any(T(["명령 실행!", "타닥타닥", "돌려보는 중~"], ["Running a command!", "Clickety-clack", "Giving it a spin~"]))
  case .bgStart: return any(T(["뒤에서 돌려둘게!", "백그라운드로 슝~", "그동안 딴 거 할게"], ["Running it in back!", "Off to the background~", "I'll do other stuff"]))
  case .bgDone: return any(T(["뒤에 돌린 거 끝났대!", "백그라운드 완료!", "다녀왔어~"], ["Background job's done!", "Background finished!", "I'm back~"]))
  case .web: return any(T(["검색해볼게~", "인터넷 뒤적뒤적", "찾아보는 중!"], ["Let me search~", "Digging the web", "Looking it up!"]))
  case .skill: return any(T(["비법 꺼내는 중!", "스킬 쓸게!"], ["Secret move time!", "Using a skill!"]))
  case let .agentStart(t): return t.isEmpty ? any(T(["친구 불렀어!", "도와줘~ 친구야!"], ["Called a friend!", "Help me, buddy~"])) : any(T(["\(t) 불렀어!", "\(t) 출동!"], ["Called \(t)!", "Go, \(t)!"]))
  case .agentDone: return any(T(["친구가 돌아왔어!", "보고 받았어!", "고마워 친구야~"], ["My friend is back!", "Report received!", "Thanks, buddy~"]))
  case .error: return any(T(["앗, 에러…", "어라? 다시 해볼게", "으앗 실패!"], ["Oops, an error...", "Huh? Let me retry", "Eek, it failed!"]))
  case .idle:
    // lines that fit the current circumstances come first (added twice so they are picked often); general lines only when idle
    var spot: [String] = []
    switch x.spot {
    case "sitEdge": spot += T(["다리 흔들흔들~", "여기 앉아 있을래", "경치 좋다~"], ["Swinging my legs~", "I'll sit here a bit", "Nice view~"])
    case "hang": spot += T(["팔 아파…!", "조금만 버텨야지", "대롱대롱~"], ["My arms hurt...!", "Just hang on...", "Dangle dangle~"])
    default:
      switch x.on {
      case "window": spot += T(["여기 전망 좋다!", "이 창 위 따뜻해", "떨어지면 안 돼…"], ["Great view up here!", "This window is warm", "Mustn't fall..."])
      case "widget": spot += T(["위젯 위 명당!", "여기 자리 좋다~"], ["Best seat: a widget!", "Comfy spot up here~"])
      default: spot += T(["바닥이 제일 편해", "화면 밑 산책 중~"], ["The floor is comfiest", "Strolling the dock~"])
      }
    }
    if high && x.spot != "hang" { spot += T(["높은 데 좋아!", "아래 보면 아찔해…"], ["I like it up high!", "Don't look down..."]) }
    if x.spot != "hang", let cl = CHARA_LINES[x.chara] { spot += cl }
    switch x.mood {
    case .work:
      spot += x.working >= 3 ? T(["다들 바쁘네!", "\(x.working)군데서 일하는 중!"], ["Everyone's busy!", "Working in \(x.working) places!"]) : T(["같이 일하는 중!", "집중 집중"], ["Working together!", "Focus, focus"])
      if x.sweaty { spot += T(["힘내자…!", "오래 걸리네…"], ["Hang in there...!", "This one's taking a while..."]) }
    case .wait: if x.waiting > 0 { spot += [x.waiting > 1 ? T("\(x.who) 작업 \(x.waiting)개 끝났어, 봐줘~", "\(x.waiting) \(x.who) jobs done, look~") : T("\(x.who) 작업 끝났어, 봐줘~", "\(x.who) is done, take a look~"), T("\(ga(x.who)) 확인 기다려!", "\(x.who) is waiting on you!")] }
    case .ask: spot += T(["\(ga(x.who)) 물어볼 게 있대!", "\(ga(x.who)) 대답 기다리는 중~"], ["\(x.who) has a question!", "\(x.who) needs an answer~"])
    case .sleep: spot += T(["다들 쉬는 중~", "조용하다…"], ["Everyone's resting~", "So quiet..."])
    case .free: spot += T(["놀자~", "오늘 뭐 하지?", "심심해~"], ["Let's play~", "What should we do?", "I'm bored~"])
    }
    if Double.random(in: 0...1) < 0.12 {                                          // occasionally tells the current time
      let m = x.minute, clk = clockName(x.hour, m)
      return any(T(["지금 \(hourName(x.hour)) \(m)분이에요", "벌써 \(hourName(x.hour)) \(m)분!", "\(hourName(x.hour)) \(m)분~ 시간 빠르다"], ["It's \(clk) now", "\(clk) already!", "\(clk)~ time flies"]))
    }
    let tl = timeLines(x)                                                          // if there are time-of-day lines, use them for half of the picks (hungry at lunch)
    if !tl.isEmpty && Double.random(in: 0...1) < 0.5 { return any(tl) }
    var a = spot + spot
    if x.working == 0 { a += T(["흥얼흥얼~", "심심하다~", "♪", "뭐 도와줄 거 없어?"], ["Hum de dum~", "So bored~", "La la la~", "Need a hand?"]) }
    return any(a)
  case .sleepy: return any(x.on == "window" ? T(["창 위에서 낮잠…", "음냐…", "zzz…"], ["Window-top nap...", "Mmm... snooze...", "zzz..."]) : T(["음냐…", "쿨…", "zzz…"], ["Mmm... snooze...", "Snore...", "zzz..."]))
  case .petted:
    if x.spot == "sleep" { return any(T(["음냐… 좋아…", "헤헤… zzz"], ["Mmm... nice...", "Hehe... zzz"])) }
    if x.mood == .work { return any(T(["일하는 중인데… 헤헤", "힘이 난다!"], ["I'm working... hehe", "Powered up!"])) }
    return any(T(["헤헤~", "거기 좋아…", "더 쓰다듬어 줘~", "기분 좋다!"], ["Hehe~", "Right there...", "More pats, please~", "That feels nice!"]))
  case .welcome:
    if x.days > 1 && x.firstToday { return any(x.days % 100 == 0 || x.days == 7 || x.days == 30 ? T(["오늘로 \(x.days)일째! 고마워!"], ["Day \(x.days) together! Thank you!"]) : T(["좋은 하루! 오늘로 \(x.days)일째야", "\(x.days)일째 같이 있네~"], ["Have a good one! Day \(x.days)", "Day \(x.days) together~"])) }
    if x.awayDone > 0 { return any(T(["어서와! 그동안 \(x.awayDone)개 끝났어", "왔다! 끝난 거 \(x.awayDone)개 있어"], ["Welcome back! \(plural(x.awayDone, "job")) done", "You're back! \(x.awayDone) finished"])) }
    if x.missed > 0 { return any(T(["어서와! 알림 \(x.missed)개 왔었어", "그동안 알림이 \(x.missed)개나 왔어요"], ["Welcome back! \(plural(x.missed, "alert"))", "You missed \(plural(x.missed, "alert"))"])) }
    if h >= 5 && h < 11 { return any(T(["좋은 아침!", "왔구나! 좋은 아침~"], ["Good morning!", "You're here! Morning~"])) }
    if h >= 11 && h < 14 { return any(T(["밥은 먹고 왔어?", "어서와!"], ["Did you eat lunch?", "Welcome back!"])) }
    if h >= 22 || h < 5 { return any(T(["아직 안 잤어?", "늦게까지 고생이야…"], ["Still up?", "Working late, huh..."])) }
    return any(T(["어서와!", "기다렸어!", "왔다!"], ["Welcome back!", "I missed you!", "You're here!"]))
  case .startle: return any(x.high > 200 ? T(["으악 높아!", "바닥이 없어졌어!"], ["Eek, so high!", "Where'd the floor go?!"]) : T(["어엇!", "깜짝이야!"], ["Whoa!", "You scared me!"]))
  case .missed: return any(T(["놓쳤다!", "다음엔 잡을 거야", "에잇!"], ["Missed it!", "Next time for sure", "Aw, shucks!"]))
  case .caught: return any(T(["잡았다!", "내 거야!", "히히 잡았지?"], ["Got it!", "Mine now!", "Hehe, gotcha!"]))
  case .pout: return any(T(["흥!", "그만 눌러~", "삐졌어…"], ["Hmph!", "Stop poking~", "I'm sulking..."]))
  case .flee: return any(T(["으아 도망가자!", "그만해~!"], ["Run away!", "Stooop~!"]))
  case .party: return any(T(["다 끝났다!", "만세!", "해냈다!"], ["All done!", "Hooray!", "We did it!"]))
  case .lifted:                                                      // just lifted
    if x.spot == "sleep" { return any(T(["으응…? 누구야…", "자는데 왜 들어~", "음냐… 어디 가…"], ["Hm...? Who's there...", "Hey, I was napping~", "Mmm... where to..."])) }
    if x.mood == .work { return any(T(["일하는 중인데요?!", "앗 노트북!", "잠깐만 이것만…"], ["I'm working here?!", "Hey, my laptop!", "Wait, just this bit..."])) }
    return any(T(["으앗!", "들렸다!", "어디 가요?", "높이높이~", "살살 들어줘요", "히익", "우와 공중부양!", "나 납치돼요~"], ["Whoa!", "Up I go!", "Where are we going?", "Up, up, up~", "Gently, please", "Eep!", "Wow, I'm levitating!", "Help, I'm being kidnapped~"]))
  case .thrown: return any(T(["으아아아~!", "날아간다~!", "슝~!", "살려줘요~", "와아아!"], ["Waaaah~!", "I'm flying~!", "Whoosh~!", "Heeelp~", "Wheee!"]))
  case .dropped: return any(T(["고마워요~", "착지!", "여기 좋아요", "내려줬다!", "휴~"], ["Thank you~", "Landed!", "I like it here", "Back on my feet!", "Phew~"]))
  case .bonk: return any(T(["아야!", "쿵!", "벽이다…", "꽈당!", "앗 아파", "튕겼다!"], ["Ouch!", "Thud!", "A wall...", "Bonk!", "Ow, that hurt", "Boing, bounced!"]))
  case .headBonk: return any(T(["머리 쿵!", "아얏 천장!", "윽, 머리…"], ["Head bonk!", "Ow, the ceiling!", "Ugh, my head..."]))
  case .landHard: return any(T(["어지러워…", "별이 보여…", "빙글빙글…", "쿵 했다…"], ["So dizzy...", "Seeing stars...", "Spinny spinny...", "That was a thud..."]))
  case .slip: return any(T(["미끄러워~", "으앗 미끄럼틀!", "슈웅~"], ["Slippery~", "Whoa, a slide!", "Wheee~"]))
  case .bounce: return any(T(["통통!", "튕긴다~", "보잉~"], ["Boing!", "Bouncy~", "Sproing~"]))
  case .carried:
    if x.fast { return any(T(["어지러워~", "천천히~!"], ["So dizzy~", "Slow down~!"])) }
    if high { return any(T(["높다…!", "무서워~ 내려줘"], ["So high...!", "Scary~ put me down"])) }
    return any(T(["내려줘~", "어디 가는 거야?", "산책이다!"], ["Put me down~", "Where are we going?", "Walkies!"]))
  }
}
