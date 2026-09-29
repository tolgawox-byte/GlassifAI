import Foundation
import MediaPlayer

/// "Müzik çal", "Tarkan şarkısını çal", "sonraki şarkı", "ne çalıyor?":
/// the system Music player (MediaPlayer). Songs are found in the user's own
/// library; the Apple Music catalogue needs MusicKit, which this build does
/// not use. Optional: nothing else depends on it. The voice conversation
/// mixes with music, so starting a song never takes the microphone.
enum MusicCommand: Equatable {
  case play(String?)
  case pause
  case next
  case previous
  case nowPlaying

  var key: String {
    switch self {
    case .play: "play"
    case .pause: "pause"
    case .next: "next"
    case .previous: "previous"
    case .nowPlaying: "nowPlaying"
    }
  }
}

@MainActor
enum MusicControl {
  /// Replaced in tests.
  static var player: () -> MPMusicPlayerController = { MPMusicPlayerController.systemMusicPlayer }
  static var authorization: () async -> MPMediaLibraryAuthorizationStatus = {
    let status = MPMediaLibrary.authorizationStatus()
    guard status == .notDetermined else { return status }
    return await withCheckedContinuation { continuation in
      MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
    }
  }

  /// Songs in the user's library whose title, artist or album contain the words.
  static func librarySongs(matching text: String, limit: Int = 50) -> [MPMediaItem] {
    let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return [] }
    for property in [MPMediaItemPropertyArtist, MPMediaItemPropertyTitle, MPMediaItemPropertyAlbumTitle] {
      let query = MPMediaQuery.songs()
      query.addFilterPredicate(MPMediaPropertyPredicate(value: words, forProperty: property, comparisonType: .contains))
      if let items = query.items, !items.isEmpty { return Array(items.prefix(limit)) }
    }
    return []
  }
}

extension AssistantOrchestrator {
  func runMusic(_ command: MusicCommand, traceID: UUID) async -> IntentOutcome {
    ActionTraceLog.shared.update(traceID) { $0.executor = "MediaPlayer (system Music player)" }
    let player = MusicControl.player()
    func done(_ tr: String, _ en: String, failed: String? = nil) -> IntentOutcome {
      IntentOutcome(
        spoken: BridgeSpeech.done("Result of the user's music command.", tr: tr, en: en), reply: L.t(en, tr), failed: failed,
        said: L.t(en, tr))
    }
    switch command {
    case .play(let query):
      guard let query, !query.isEmpty else {
        player.play()
        MediaResourceCoordinator.shared.note(.music, running: true)
        return done("Müziği başlattım.", "Music is playing.")
      }
      let status = await MusicControl.authorization()
      guard status == .authorized else {
        return done(
          "Müzik kütüphanene erişim izni yok; Ayarlar'dan izin verebilirsin.",
          "I don't have access to your music library; you can allow it in Settings.", failed: "media library permission")
      }
      let songs = MusicControl.librarySongs(matching: query)
      guard !songs.isEmpty else {
        return done(
          "Kütüphanende “\(query)” bulamadım. Apple Music kataloğundan çalmak bu sürümde yok.",
          "I couldn't find “\(query)” in your library. Playing from the Apple Music catalogue isn't in this version.",
          failed: "not in library")
      }
      player.setQueue(with: MPMediaItemCollection(items: songs))
      player.play()
      MediaResourceCoordinator.shared.note(.music, running: true)
      let first = songs[0]
      let name = [first.title, first.artist].compactMap { $0 }.joined(separator: " — ")
      ActionTraceLog.shared.update(traceID) { $0.result = "\(songs.count) songs queued from the library" }
      return done("Çalıyorum: \(name).", "Playing \(name).")
    case .pause:
      player.pause()
      MediaResourceCoordinator.shared.note(.music, running: false)
      return done("Müziği durdurdum.", "Music paused.")
    case .next:
      player.skipToNextItem()
      return done("Sonraki şarkı.", "Next song.")
    case .previous:
      player.skipToPreviousItem()
      return done("Önceki şarkı.", "Previous song.")
    case .nowPlaying:
      guard player.playbackState == .playing, let item = player.nowPlayingItem else {
        return done("Şu an müzik çalmıyor.", "Nothing is playing right now.")
      }
      let name = [item.title, item.artist].compactMap { $0 }.joined(separator: " — ")
      return done("Çalan şarkı: \(name).", "Now playing: \(name).")
    }
  }
}

extension VoiceActionIntentBridge {
  /// Music commands say "müzik", "şarkı" or "music"/"song"; "dur" alone
  /// stops the assistant, never the music.
  static func music(_ u: Utterance) -> VoiceBridgeDecision? {
    guard u.count <= 9 else { return nil }
    let exact: [([String], MusicCommand)] = [
      (["muzik", "cal"], .play(nil)), (["muzigi", "baslat"], .play(nil)), (["muzik", "ac"], .play(nil)),
      (["muzigi", "ac"], .play(nil)), (["play", "music"], .play(nil)), (["play", "some", "music"], .play(nil)),
      (["muzigi", "durdur"], .pause), (["muzigi", "kapat"], .pause), (["sarkiyi", "durdur"], .pause),
      (["pause", "the", "music"], .pause), (["stop", "the", "music"], .pause), (["pause", "music"], .pause),
      (["sonraki", "sarki"], .next), (["siradaki", "sarki"], .next), (["sarkiyi", "gec"], .next), (["next", "song"], .next),
      (["skip", "this", "song"], .next), (["onceki", "sarki"], .previous), (["previous", "song"], .previous),
      (["ne", "caliyor"], .nowPlaying), (["bu", "sarki", "ne"], .nowPlaying), (["hangi", "sarki", "caliyor"], .nowPlaying),
      (["whats", "playing"], .nowPlaying), (["what", "song", "is", "this"], .nowPlaying),
    ]
    var rest = u
    rest.trimTrailing(["lutfen", "please"])
    if let match = exact.first(where: { rest.keys == $0.0 }) {
      return VoiceBridgeDecision(.music(match.1), "music \"\(match.0.joined(separator: " "))\"")
    }
    // "Tarkan şarkısını çal", "Tarkan'dan bir şarkı çal", "play Yesterday by the Beatles".
    if rest.ends(with: ["cal"]), rest.count >= 3 {
      var what = rest.dropping((rest.count - 1)..<rest.count)
      guard what.containsAny(["sarkisini", "sarkilarini", "sarki", "albumunu", "muzigini"]) else { return nil }
      what.removeKeys(["sarkisini", "sarkilarini", "sarki", "bir", "albumunu", "muzigini", "biraz"])
      guard !what.isEmpty else { return VoiceBridgeDecision(.music(.play(nil)), "music play") }
      return VoiceBridgeDecision(.music(.play(stripAblative(what.text))), "music play (library search)")
    }
    if rest.starts(with: ["play"]), rest.count >= 2, !rest.containsAny(["video", "recording", "clip", "game"]) {
      var what = rest.dropping(0..<1)
      // "Play Yesterday by the Beatles": the title is enough for the library.
      if let by = what.keys.firstIndex(of: "by"), by > 0 { what = what.dropping(by..<what.count) }
      what.removeKeys(["some", "songs", "song", "the", "music", "from"])
      guard !what.isEmpty else { return VoiceBridgeDecision(.music(.play(nil)), "music play") }
      guard !what.isOnly(["it", "that", "this", "again"]) else { return nil }
      return VoiceBridgeDecision(.music(.play(what.text)), "music play (library search)")
    }
    return nil
  }

  /// "Tarkan'dan" → "Tarkan".
  private static func stripAblative(_ text: String) -> String {
    for suffix in ["'dan", "'den", "'tan", "'ten", "’dan", "’den", "’tan", "’ten"] where text.hasSuffix(suffix) {
      return String(text.dropLast(suffix.count))
    }
    return text
  }
}
