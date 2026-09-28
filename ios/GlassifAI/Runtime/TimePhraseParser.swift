import Foundation

/// A time the user said, resolved by deterministic code (never by a model).
struct ParsedTime: Equatable {
  let date: Date
  /// A clock time was said or implied ("sabah" → 09:00). False for a date
  /// only ("yarın", "15 Ekim").
  let hasTime: Bool
  /// Morning and evening were both plausible ("saat 8'de"); the assistant
  /// should ask which one before saving.
  let isAmbiguous: Bool
  /// The other reading when ambiguous.
  let alternative: Date?
  /// The time came from a part of the day ("yarın sabah" → 09:00).
  let usedDefaultTime: Bool
  /// A day was said ("yarın", "cuma", "15 Ekim", "in 2 days").
  var hasDay = false
  /// The words that were understood (diagnostics).
  let matched: String
}

/// Turns Turkish and English time phrases into dates: "yarın saat 7'de",
/// "20 dakika sonra", "cuma akşam 8", "15 Ekim 14:30", "tomorrow at 7 pm",
/// "in half an hour", "next Monday morning". Pure and unit-tested.
enum TimePhraseParser {
  private enum Meridiem { case am, pm }

  private enum PartOfDay {
    case morning, noon, afternoon, evening, night, tonight

    var defaultHour: Int {
      switch self {
      case .morning: 9
      case .noon: 12
      case .afternoon: 15
      case .evening: 19
      case .night: 21
      case .tonight: 20
      }
    }
  }

  private struct Components {
    var relativeSeconds: TimeInterval?
    var dayOffset: Int?
    var weekday: Int?
    var nextWeek = false
    var month: Int?
    var day: Int?
    var year: Int?
    var hour: Int?
    var minute = 0
    var meridiem: Meridiem?
    var part: PartOfDay?
    /// Written as a 24-hour clock ("07:30", "11:00"), so not ambiguous.
    var twentyFourHour = false
    var matched: [String] = []

    var hasDay: Bool { dayOffset != nil || weekday != nil || (month != nil && day != nil) }
  }

  // MARK: Vocabulary (normalized: lowercase, Turkish letters folded)

  private static let numberWords: [String: Double] = [
    "yarim": 0.5, "bir": 1, "iki": 2, "uc": 3, "dort": 4, "bes": 5, "alti": 6, "yedi": 7, "sekiz": 8,
    "dokuz": 9, "on": 10, "on bir": 11, "on iki": 12, "on bes": 15, "yirmi": 20, "yirmi bes": 25,
    "otuz": 30, "kirk": 40, "kirk bes": 45, "elli": 50,
    "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30,
    "forty five": 45, "forty": 40, "fifty": 50, "half an": 0.5, "half a": 0.5,
  ]

  private static let countPattern =
    #"(\d+(?:[.,]\d+)?|half an|half a|forty five|kirk bes|yirmi bes|on bes|on bir|on iki|yarim|bir|iki|uc|dort|bes|alti|yedi|sekiz|dokuz|on|yirmi|otuz|kirk|elli|an|a|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty)"#

  private static let hourWordPattern =
    #"(on iki|on bir|dokuz|sekiz|yedi|alti|dort|bes|iki|uc|bir|on|eleven|twelve|three|seven|eight|four|five|nine|one|two|six|ten)"#

  private static let months: [String: Int] = [
    "ocak": 1, "subat": 2, "mart": 3, "nisan": 4, "mayis": 5, "haziran": 6, "temmuz": 7, "agustos": 8,
    "eylul": 9, "ekim": 10, "kasim": 11, "aralik": 12,
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
    "september": 9, "october": 10, "november": 11, "december": 12,
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10,
    "nov": 11, "dec": 12,
  ]

  private static var monthPattern: String {
    "(" + months.keys.sorted { $0.count > $1.count }.joined(separator: "|") + ")"
  }

  /// Calendar weekday numbers (1 = Sunday).
  private static let weekdays: [String: Int] = [
    "pazartesi": 2, "sali": 3, "carsamba": 4, "persembe": 5, "cumartesi": 7, "cuma": 6,
    "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7, "sunday": 1,
  ]

  // MARK: Public API

  static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedTime? {
    var s = " " + normalize(text) + " "
    var c = Components()
    extractRelative(&s, &c)
    if let seconds = c.relativeSeconds {
      return ParsedTime(
        date: now.addingTimeInterval(seconds), hasTime: true, isAmbiguous: false, alternative: nil,
        usedDefaultTime: false, matched: c.matched.joined(separator: " + "))
    }
    extractDate(&s, &c)
    extractClock(&s, &c)
    extractDay(&s, &c)
    extractPartOfDay(&s, &c)
    guard c.hasDay || c.hour != nil || c.part != nil else { return nil }
    return resolve(c, now: now, calendar: calendar)
  }

  /// A readable time for confirmations: "Pazartesi 28 Eylül, 07:00".
  static func describe(_ date: Date, hasTime: Bool, turkish: Bool) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: turkish ? "tr_TR" : "en_US")
    formatter.setLocalizedDateFormatFromTemplate(hasTime ? "EEEEdMMMMHHmm" : "EEEEdMMMM")
    return formatter.string(from: date)
  }

  static func normalize(_ text: String) -> String {
    var s = text.lowercased(with: Locale(identifier: "tr_TR"))
    s = s.replacingOccurrences(of: "ı", with: "i")
    s = s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    s = s.replacingOccurrences(of: "a.m.", with: "am").replacingOccurrences(of: "p.m.", with: "pm")
    s = s.replacingOccurrences(of: "’", with: " ").replacingOccurrences(of: "'", with: " ")
    // A decimal comma ("1,5 saat") becomes a point before commas are removed.
    s = replace(#"(\d),(\d)"#, in: s, with: "$1.$2")
    // Keep "." and ":" only between digits (7:30, 7.30, 15.10.2026).
    s = replace(#"(?<!\d)[.:]|[.:](?!\d)"#, in: s, with: " ")
    s = replace(#"[,;!?()\[\]"]"#, in: s, with: " ")
    s = replace(#"\s+"#, in: s, with: " ")
    return s.trimmingCharacters(in: .whitespaces)
  }

  // MARK: Extraction (each match is blanked so it is not read twice)

  private static func extractRelative(_ s: inout String, _ c: inout Components) {
    // "20 dakika sonra", "yarım saat sonra", "bir buçuk saat sonra", "3 gün sonra"
    let turkish = #"\b"# + countPattern + "( bucuk)? (dakika|dk|saat|gun|hafta) (sonra|icinde)"
    if let match = firstMatch(turkish, in: s), let quantity = amount(match.groups[1]) {
      let value = quantity + (match.groups[2] != nil ? 0.5 : 0)
      switch match.groups[3] {
      case "dakika", "dk": c.relativeSeconds = value * 60
      case "saat": c.relativeSeconds = value * 3_600
      case "gun": c.dayOffset = Int(value.rounded())
      default: c.dayOffset = Int((value * 7).rounded())
      }
      c.matched.append(match.text)
      blank(match.range, in: &s)
      return
    }
    // "in 20 minutes", "in half an hour", "in 2 days"
    let english = #"\bin "# + countPattern + " (minutes?|mins?|hours?|hrs?|days?|weeks?)( and a half)?"
    if let match = firstMatch(english, in: s), let quantity = amount(match.groups[1]) {
      let value = quantity + (match.groups[3] != nil ? 0.5 : 0)
      let unit = match.groups[2] ?? ""
      if unit.hasPrefix("min") {
        c.relativeSeconds = value * 60
      } else if unit.hasPrefix("h") {
        c.relativeSeconds = value * 3_600
      } else if unit.hasPrefix("day") {
        c.dayOffset = Int(value.rounded())
      } else {
        c.dayOffset = Int((value * 7).rounded())
      }
      c.matched.append(match.text)
      blank(match.range, in: &s)
    }
  }

  private static func extractDate(_ s: inout String, _ c: inout Components) {
    // 15.10.2026 or 15/10/2026 (day first)
    if let match = firstMatch(#" (\d{1,2})[./](\d{1,2})[./](\d{4}) "#, in: s),
       let day = int(match.groups[1]), let month = int(match.groups[2]), let year = int(match.groups[3]),
       (1...12).contains(month), (1...31).contains(day) {
      c.day = day
      c.month = month
      c.year = year
      c.matched.append(match.text)
      blank(match.range, in: &s)
      return
    }
    // "15 ekim", "15 ekimde", "15th of october", "15 ekim 2026"
    let dayFirst = #" (\d{1,2})(?:st|nd|rd|th)?(?: of)? "# + monthPattern + #"(?:de|da|te|ta|a|e|ya|ye)?(?: (\d{4}))?\b"#
    if let match = firstMatch(dayFirst, in: s), let day = int(match.groups[1]),
       let month = months[match.groups[2] ?? ""], (1...31).contains(day) {
      c.day = day
      c.month = month
      c.year = int(match.groups[3])
      c.matched.append(match.text)
      blank(match.range, in: &s)
      return
    }
    // "october 15", "ekim 15"
    let monthFirst = " " + monthPattern + #" (\d{1,2})(?:st|nd|rd|th)?(?: (\d{4}))?\b"#
    if let match = firstMatch(monthFirst, in: s), let month = months[match.groups[1] ?? ""],
       let day = int(match.groups[2]), (1...31).contains(day) {
      c.day = day
      c.month = month
      c.year = int(match.groups[3])
      c.matched.append(match.text)
      blank(match.range, in: &s)
    }
  }

  private static func extractClock(_ s: inout String, _ c: inout Components) {
    func take(_ match: Match, hour: Int?, minute: Int = 0, meridiem: Meridiem? = nil) -> Bool {
      guard let hour, (0...24).contains(hour), (0...59).contains(minute) else { return false }
      c.hour = hour == 24 ? 0 : hour
      c.minute = minute
      if let meridiem { c.meridiem = meridiem }
      c.matched.append(match.text)
      blank(match.range, in: &s)
      return true
    }
    // "7'yi çeyrek geçe" → 7:15, "8'e çeyrek kala" → 7:45 (before "gece" can be read as night)
    if let match = firstMatch(#"(\d{1,2}) (?:[a-z]{1,2} )?ceyrek gece"#, in: s),
       take(match, hour: int(match.groups[1]), minute: 15) { return }
    if let match = firstMatch(#"(\d{1,2}) (?:[a-z]{1,2} )?ceyrek kala"#, in: s), let hour = int(match.groups[1]),
       take(match, hour: (hour + 23) % 24, minute: 45) { return }
    // English: "half past 7", "quarter past 7", "quarter to 8"
    if let match = firstMatch(#"half past (\d{1,2})"#, in: s), take(match, hour: int(match.groups[1]), minute: 30) {
      return
    }
    if let match = firstMatch(#"quarter past (\d{1,2})"#, in: s), take(match, hour: int(match.groups[1]), minute: 15) {
      return
    }
    if let match = firstMatch(#"quarter to (\d{1,2})"#, in: s), let hour = int(match.groups[1]),
       take(match, hour: (hour + 23) % 24, minute: 45) { return }
    // 19:30, 7.30, "saat 7 30", optionally followed by am/pm
    if let match = firstMatch(#"(\d{1,2})[:.](\d{2})(?: ?(am|pm))?"#, in: s),
       take(match, hour: int(match.groups[1]), minute: int(match.groups[2]) ?? 0, meridiem: meridiem(match.groups[3])) {
      c.twentyFourHour = (match.groups[1]?.count ?? 0) == 2 && match.groups[3] == nil
      return
    }
    if let match = firstMatch(#"saat (\d{1,2}) (\d{2})\b"#, in: s),
       take(match, hour: int(match.groups[1]), minute: int(match.groups[2]) ?? 0) { return }
    // "7 buçuk(ta)", "saat 7 buçuk", "yedi buçukta"
    if let match = firstMatch(#"(?:saat )?(\d{1,2}) bucuk(?:ta)?"#, in: s),
       take(match, hour: int(match.groups[1]), minute: 30) { return }
    if let match = firstMatch(#"\b(?:saat )?"# + hourWordPattern + #" bucuk(?:ta)?"#, in: s),
       take(match, hour: hourWord(match.groups[1]), minute: 30) { return }
    // "7 pm", "7pm", "at 7", "at 7 am", "7 o clock"
    if let match = firstMatch(#"\b(\d{1,2}) ?(am|pm)\b"#, in: s),
       take(match, hour: int(match.groups[1]), meridiem: meridiem(match.groups[2])) { return }
    if let match = firstMatch(#"\bat (\d{1,2})(?: (am|pm|o clock))?\b"#, in: s),
       take(match, hour: int(match.groups[1]), meridiem: meridiem(match.groups[2])) { return }
    if let match = firstMatch(#"\b(\d{1,2}) o clock\b"#, in: s), take(match, hour: int(match.groups[1])) { return }
    if let match = firstMatch(#"\bat "# + hourWordPattern + #"(?: (am|pm|o clock))?\b"#, in: s),
       take(match, hour: hourWord(match.groups[1]), meridiem: meridiem(match.groups[2])) { return }
    // Turkish: "saat 7", "saat yedi", "7'de" (→ "7 de"), "yedide"
    if let match = firstMatch(#"saat (\d{1,2})\b(?: (?:de|da|te|ta))?"#, in: s),
       take(match, hour: int(match.groups[1])) { return }
    if let match = firstMatch(#"saat "# + hourWordPattern + #"(?:de|da|te|ta)?\b"#, in: s),
       take(match, hour: hourWord(match.groups[1])) { return }
    if let match = firstMatch(#"\b(\d{1,2}) (?:de|da|te|ta)\b"#, in: s), take(match, hour: int(match.groups[1])) {
      return
    }
    // "sabah 9", "akşam sekizde", "ogleden sonra 3": the part of the day is
    // kept, because the match removes those words.
    let partWords = "(sabah|aksam|gece|oglen|ogleden sonra|morning|evening|night|afternoon)"
    if let match = firstMatch(#"\b"# + partWords + #" (\d{1,2})\b"#, in: s), let hour = int(match.groups[2]) {
      let partText = match.groups[1] ?? ""
      if take(match, hour: hour) { c.part = part(partText) ?? c.part }
      return
    }
    if let match = firstMatch(#"\b"# + partWords + " " + hourWordPattern + #"(?:de|da|te|ta)?\b"#, in: s),
       let hour = hourWord(match.groups[2]) {
      let partText = match.groups[1] ?? ""
      if take(match, hour: hour) { c.part = part(partText) ?? c.part }
      return
    }
    // A spelled-out hour with a locative ("yedide") only after a day word:
    // on its own "birde", "onda" or "ikide" are ordinary words.
    if let match = firstMatch(#"(?<=yarin |bugun |tomorrow |today )"# + hourWordPattern + #"(?:de|da|te|ta)\b"#, in: s),
       take(match, hour: hourWord(match.groups[1])) { return }
  }

  private static func extractDay(_ s: inout String, _ c: inout Components) {
    let dayWords: [(String, Int, PartOfDay?)] = [
      ("yarindan sonra", 2, nil), ("obur gun", 2, nil), ("day after tomorrow", 2, nil),
      ("bu aksam", 0, .evening), ("bu gece", 0, .night), ("tonight", 0, .tonight),
      ("bugun", 0, nil), ("today", 0, nil), ("yarin", 1, nil), ("tomorrow", 1, nil),
    ]
    for (word, offset, part) in dayWords {
      if let match = firstMatch(#"\b"# + word + #"\b"#, in: s) {
        if c.dayOffset == nil { c.dayOffset = offset }
        if let part, c.part == nil { c.part = part }
        c.matched.append(match.text)
        blank(match.range, in: &s)
        break
      }
    }
    if let match = firstMatch(#"\b(hafta sonu|this weekend|weekend)\b"#, in: s), c.weekday == nil {
      c.weekday = 7
      c.matched.append(match.text)
      blank(match.range, in: &s)
    }
    // Weekdays, longest names first so "cumartesi" is not read as "cuma".
    // "Pazar" alone also means "market", so Sunday needs "pazar günü" or a
    // week word.
    let names = weekdays.keys.sorted { $0.count > $1.count }.joined(separator: "|")
    let suffixes = #"(?:ya|ye|a|e|da|de|ta|te|dan|den|ki|yi|i| gunu)?"#
    let pattern = #"\b(haftaya |gelecek |onumuzdeki |next |this |bu |on )?("# + names + #"|pazar gunu)"# + suffixes + #"\b"#
    if let match = firstMatch(pattern, in: s) {
      let name = match.groups[2] ?? ""
      let modifier = (match.groups[1] ?? "").trimmingCharacters(in: .whitespaces)
      c.weekday = name == "pazar gunu" ? 1 : weekdays[name]
      c.nextWeek = ["haftaya", "gelecek", "onumuzdeki", "next"].contains(modifier)
      c.matched.append(match.text)
      blank(match.range, in: &s)
    } else if let match = firstMatch(#"\b(haftaya|gelecek|onumuzdeki|next|this|bu) (pazar|sunday)\b"#, in: s) {
      c.weekday = 1
      c.nextWeek = ["haftaya", "gelecek", "onumuzdeki", "next"].contains(match.groups[1] ?? "")
      c.matched.append(match.text)
      blank(match.range, in: &s)
    }
  }

  private static func extractPartOfDay(_ s: inout String, _ c: inout Components) {
    let parts: [(String, PartOfDay)] = [
      ("ogleden sonra", .afternoon), ("aksamustu", .afternoon), ("gece yarisi", .night), ("midnight", .night),
      ("sabah", .morning), ("morning", .morning), ("oglen", .noon), ("ogle", .noon), ("noon", .noon),
      ("midday", .noon), ("afternoon", .afternoon), ("aksam", .evening), ("evening", .evening),
      ("gece", .night), ("night", .night),
    ]
    for (word, part) in parts {
      if let match = firstMatch(#"\b"# + word + #"\b"#, in: s) {
        if c.part == nil { c.part = part }
        if word == "gece yarisi" || word == "midnight" {
          if c.hour == nil { c.hour = 0; c.minute = 0 }
        }
        c.matched.append(match.text)
        blank(match.range, in: &s)
        return
      }
    }
  }

  // MARK: Resolution

  private static func resolve(_ c: Components, now: Date, calendar: Calendar) -> ParsedTime? {
    let today = calendar.startOfDay(for: now)
    var base = today
    var explicitDay = false
    if let offset = c.dayOffset {
      base = calendar.date(byAdding: .day, value: offset, to: today) ?? today
      explicitDay = true
    } else if let month = c.month, let day = c.day {
      var components = calendar.dateComponents([.year], from: now)
      components.year = c.year ?? components.year
      components.month = month
      components.day = day
      guard var date = calendar.date(from: components) else { return nil }
      if c.year == nil, date < today { date = calendar.date(byAdding: .year, value: 1, to: date) ?? date }
      base = date
      explicitDay = true
    } else if let weekday = c.weekday {
      base = nextWeekday(weekday, nextWeek: c.nextWeek, from: today, calendar: calendar)
      explicitDay = true
    }
    let matched = c.matched.joined(separator: " + ")

    guard c.hour != nil || c.part != nil else {
      return ParsedTime(
        date: base, hasTime: false, isAmbiguous: false, alternative: nil, usedDefaultTime: false, matched: matched,
        hasDay: explicitDay)
    }

    let usedDefault = c.hour == nil
    let resolved: (hour: Int, alternative: Int?, dayShift: Int)
    if let h = c.hour {
      resolved = meridiemHour(h, meridiem: c.meridiem, part: c.part, twentyFourHour: c.twentyFourHour)
    } else {
      resolved = (c.part?.defaultHour ?? 9, nil, 0)
    }
    let hour = resolved.hour
    let alternativeHour = resolved.alternative

    func at(_ hour: Int, shift: Int) -> Date? {
      let day = calendar.date(byAdding: .day, value: shift, to: base) ?? base
      return calendar.date(bySettingHour: hour, minute: c.minute, second: 0, of: day)
    }

    guard var date = at(hour, shift: resolved.dayShift) else { return nil }
    var alternative = alternativeHour.flatMap { at($0, shift: resolved.dayShift) }

    if let alternativeHour, !explicitDay {
      // No day given: the next time this clock time comes round.
      let candidates = [at(hour, shift: 0), at(alternativeHour, shift: 0)].compactMap { $0 }
      if let first = candidates.filter({ $0 > now }).min() {
        date = first
        alternative = candidates.first { $0 != first }
      } else {
        date = at(hour, shift: 1) ?? date
        alternative = at(alternativeHour, shift: 1)
      }
    } else if !explicitDay, date <= now {
      date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
      alternative = alternative.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
    } else if c.weekday != nil, c.dayOffset == nil, c.month == nil, date <= now {
      // "pazartesi 9'da" said on Monday after nine: next week's Monday.
      date = calendar.date(byAdding: .day, value: 7, to: date) ?? date
      alternative = alternative.flatMap { calendar.date(byAdding: .day, value: 7, to: $0) }
    } else if date <= now, let later = alternative, later > now {
      // "bugün 8'de" said at ten in the morning: the evening is meant.
      alternative = date
      date = later
    }
    // Only ask "morning or evening?" when both readings are still ahead.
    let ambiguous = alternative.map { $0 > now } ?? false
    return ParsedTime(
      date: date, hasTime: true, isAmbiguous: ambiguous, alternative: ambiguous ? alternative : nil,
      usedDefaultTime: usedDefault, matched: matched, hasDay: explicitDay)
  }

  /// The 24-hour value for a spoken hour, the other reading when both
  /// morning and evening are plausible, and a day shift for "gece 12".
  private static func meridiemHour(
    _ h: Int, meridiem: Meridiem?, part: PartOfDay?, twentyFourHour: Bool = false
  ) -> (Int, Int?, Int) {
    if h >= 13 || h == 0 { return (h, nil, 0) }
    if twentyFourHour, meridiem == nil, part == nil { return (h, nil, 0) }
    if let meridiem {
      switch meridiem {
      case .am: return (h == 12 ? 0 : h, nil, 0)
      case .pm: return (h == 12 ? 12 : h + 12, nil, 0)
      }
    }
    if let part {
      switch part {
      case .morning: return (h == 12 ? 0 : h, nil, 0)
      case .noon: return (h == 12 ? 12 : (h <= 5 ? h + 12 : h), nil, 0)
      case .afternoon, .evening, .tonight: return (h == 12 ? 12 : h + 12, nil, 0)
      case .night:
        if h == 12 { return (0, nil, 1) }
        return (h >= 6 ? h + 12 : h, nil, 0)
      }
    }
    if h == 12 { return (12, nil, 0) }
    // No morning/evening word: 7–11 → morning first, 1–6 → afternoon first.
    return h >= 7 ? (h, h + 12, 0) : (h + 12, h, 0)
  }

  private static func nextWeekday(_ weekday: Int, nextWeek: Bool, from today: Date, calendar: Calendar) -> Date {
    let current = calendar.component(.weekday, from: today)
    var delta = (weekday - current + 7) % 7
    if nextWeek {
      // Same weekday of the following calendar week.
      var weekCalendar = calendar
      weekCalendar.firstWeekday = 2
      let startOfWeek = weekCalendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
      let nextWeekStart = weekCalendar.date(byAdding: .day, value: 7, to: startOfWeek) ?? today
      let offsetInWeek = (weekday + 5) % 7  // Monday = 0 … Sunday = 6
      return weekCalendar.date(byAdding: .day, value: offsetInWeek, to: nextWeekStart) ?? today
    }
    if delta < 0 { delta += 7 }
    return calendar.date(byAdding: .day, value: delta, to: today) ?? today
  }

  // MARK: Helpers

  private struct Match {
    let range: NSRange
    let groups: [String?]
    let text: String
  }

  private static func firstMatch(_ pattern: String, in s: String) -> Match? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = s as NSString
    guard let result = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    var groups: [String?] = []
    for index in 0..<result.numberOfRanges {
      let range = result.range(at: index)
      groups.append(range.location == NSNotFound ? nil : ns.substring(with: range))
    }
    return Match(
      range: result.range, groups: groups,
      text: ns.substring(with: result.range).trimmingCharacters(in: .whitespaces))
  }

  private static func blank(_ range: NSRange, in s: inout String) {
    let ns = s as NSString
    s = ns.replacingCharacters(in: range, with: String(repeating: " ", count: range.length))
  }

  private static func replace(_ pattern: String, in s: String, with template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
    return regex.stringByReplacingMatches(
      in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
  }

  private static func int(_ text: String?) -> Int? {
    text.flatMap { Int($0) }
  }

  private static func amount(_ text: String?) -> Double? {
    guard let text else { return nil }
    if let value = Double(text.replacingOccurrences(of: ",", with: ".")) { return value }
    return numberWords[text]
  }

  private static func hourWord(_ text: String?) -> Int? {
    guard let text, let value = numberWords[text], value >= 1, value <= 12, value == value.rounded() else { return nil }
    return Int(value)
  }

  private static func meridiem(_ text: String?) -> Meridiem? {
    switch text {
    case "am": .am
    case "pm": .pm
    default: nil
    }
  }

  private static func part(_ text: String) -> PartOfDay? {
    switch text {
    case "sabah", "morning": .morning
    case "oglen": .noon
    case "ogleden sonra", "afternoon": .afternoon
    case "aksam", "evening": .evening
    case "gece", "night": .night
    default: nil
    }
  }
}
