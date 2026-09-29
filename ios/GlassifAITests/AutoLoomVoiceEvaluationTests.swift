import Foundation
import XCTest

@testable import GlassifAI

/// Voice evaluation: everyday Turkish first (fillers, suffixes, the
/// assistant's name, polite forms), then English, then command chains. Each
/// phrase must reach its ActionCatalog key through the same parser as speech.
/// The per-area accuracy is printed as VOICE_EVAL lines (shown on the CI
/// run page); the test fails below the bar and lists every miss.
@MainActor
final class AutoLoomVoiceEvaluationTests: XCTestCase {
  private struct Sample {
    let area: String
    let text: String
    let tags: Set<String>
    let expected: String
  }

  private static func s(_ area: String, _ text: String, _ expected: String, _ tags: Set<String> = []) -> Sample {
    Sample(area: area, text: text, tags: tags, expected: expected)
  }

  private static let samples: [Sample] = [
    // Notes
    s("notes", "Not al: yarın bankaya uğra", "saveNote"),
    s("notes", "Şunu not et: lastik basıncı 32", "saveNote"),
    s("notes", "Hadi not al süt bitti", "saveNote"),
    s("notes", "AutoLoom not al müşteri cuma arayacak", "saveNote"),
    s("notes", "Lütfen not al: Corolla'nın anahtarı ofiste", "saveNote"),
    s("notes", "Take a note: call the bank tomorrow", "saveNote"),
    s("notes", "Notlarım neler?", "listNotes"),
    s("notes", "Son notumu göster", "listNotes"),
    // Tasks
    s("tasks", "Görev oluştur: lastikleri kontrol et", "createTask"),
    s("tasks", "Yarına görev oluştur: Civic evraklarını hazırla", "createTask"),
    s("tasks", "Todo'ya ekle: sigorta", "createTask"),
    s("tasks", "Add a task: order tires", "createTask"),
    s("tasks", "Görevlerim neler?", "listTasks"),
    // Reminders and notifications
    s("reminders", "Yarın saat 9'da bankayı aramamı hatırlat", "createReminder"),
    s("reminders", "Akşam 7'de ilaç içmeyi hatırlat", "createReminder"),
    s("reminders", "Remind me to call Ahmet tomorrow at 10", "createReminder"),
    s("reminders", "20 dakika sonra bana haber ver", "notify"),
    // Timers and the shopping list
    s("daily", "10 dakikalık zamanlayıcı kur", "timer.start"),
    s("daily", "Set a timer for 3 minutes", "timer.start"),
    s("daily", "Ne kadar kaldı?", "timer.remaining", ["timer"]),
    s("daily", "Alışveriş listesine süt ekle", "shopping.add"),
    s("daily", "Alışveriş listemde ne var?", "shopping.read"),
    s("daily", "Add milk to my shopping list", "shopping.add"),
    s("daily", "Park yerimi kaydet", "parking.save"),
    s("daily", "Beni arabama götür", "parking.directions"),
    s("daily", "Müzik çal", "music.play"),
    s("daily", "Sonraki şarkı", "music.next"),
    s("daily", "Müziği durdur", "music.pause"),
    // Camera and recording
    s("camera", "Fotoğraf çek", "takePhoto"),
    s("camera", "Bir fotoğraf çeksene", "takePhoto"),
    s("camera", "Take a photo", "takePhoto"),
    s("camera", "Video kaydına başla", "startRecording"),
    s("camera", "Kaydı durdur", "stopRecording"),
    s("camera", "Stop recording", "stopRecording"),
    s("camera", "Galeriye kaydet", "saveCaptureToPhotos"),
    // Memory and visual memory
    s("memory", "Arabamın P2 katında olduğunu hatırla", "saveMemory"),
    s("memory", "Ne hatırlıyorsun?", "listMemories"),
    s("memory", "Kapı kodunu unut", "forgetMemory"),
    s("memory", "Anahtarımı en son nerede gördüm?", "findVisual"),
    s("memory", "Bugün neler gördüm?", "findVisual"),
    // Dealer
    s("dealer", "Yeni araç", "dealer.startVehicle"),
    s("dealer", "VIN oku", "dealer.readVIN"),
    s("dealer", "Kilometreyi oku", "dealer.readOdometer"),
    s("dealer", "Kilometre 45 bin 320", "dealer.setOdometer"),
    s("dealer", "Hasar ekle: sağ ön çamurluk çizik", "dealer.addDamage"),
    s("dealer", "Sağ ön jant çizik, not et", "dealer.addDamage", ["vehicle"]),
    s("dealer", "Kaç foto kaldı?", "dealer.photoChecklist", ["vehicle"]),
    s("dealer", "Bu araç tamam", "dealer.finishVehicle"),
    s("dealer", "Recall kontrol et", "dealer.recallCheck"),
    s("dealer", "VIN'i çöz", "dealer.decodeVIN"),
    s("dealer", "Lastiği oku", "dealer.readTire"),
    s("dealer", "Kondisyon raporu", "dealer.conditionReport"),
    s("dealer", "Kaç kilometre?", "vehicleQuestion", ["vehicle"]),
    s("dealer", "Bayi özeti", "dealer.dealerBriefing"),
    // Documents, translation, sharing, search, help
    s("more", "Fişi kaydet", "document.saveReceipt"),
    s("more", "Bu ay ne harcadım?", "document.spending"),
    s("more", "Bu belgeyi özetle", "document.summarize"),
    s("more", "Bu tabelayı Türkçeye çevir", "translateView", ["camera"]),
    s("more", "Paylaşımı durdur", "remoteAssist.stop"),
    s("more", "Neler yapabilirsin?", "capabilities"),
    s("more", "Geçen hafta Corolla ile ilgili kaydettiğim şeyi bul", "search"),
    s("more", "Son yaptığını geri al", "undoLast"),
  ]

  /// Several commands in one sentence, run in order.
  private static let chains: [(text: String, steps: [String])] = [
    ("Not al süt bitti ve 10 dakikalık zamanlayıcı kur", ["saveNote", "timer.start"]),
    ("Alışveriş listesine ekmek ekle sonra park yerimi kaydet", ["shopping.add", "parking.save"]),
  ]

  func testEverydayPhrasesReachTheirActions() {
    var misses: [String] = []
    var byArea: [String: (hit: Int, total: Int)] = [:]
    for sample in Self.samples {
      let context = AutoLoomActionCatalogTests.context(for: sample.tags)
      let reached = VoiceActionIntentBridge.decide(sample.text, context: context)?.intent.catalogKey ?? "nothing"
      let hit = reached == sample.expected
      byArea[sample.area, default: (0, 0)].total += 1
      if hit {
        byArea[sample.area, default: (0, 0)].hit += 1
      } else {
        misses.append("“\(sample.text)” → \(reached) (expected \(sample.expected))")
      }
    }
    var chainMisses: [String] = []
    for chain in Self.chains {
      let decision = VoiceActionIntentBridge.decide(chain.text, context: AutoLoomActionCatalogTests.context(for: []))
      guard case .graph(let steps)? = decision?.intent, steps.map(\.intent.catalogKey) == chain.steps else {
        chainMisses.append("“\(chain.text)” → \(decision?.intent.catalogKey ?? "nothing")")
        continue
      }
    }
    let hits = byArea.values.reduce(0) { $0 + $1.hit }
    let accuracy = Double(hits) / Double(Self.samples.count)
    let areas = byArea.keys.sorted().map { "\($0) \(byArea[$0]!.hit)/\(byArea[$0]!.total)" }.joined(separator: ", ")
    print("VOICE_EVAL accuracy \(String(format: "%.0f", accuracy * 100))% (\(hits)/\(Self.samples.count)) · \(areas) · chains \(Self.chains.count - chainMisses.count)/\(Self.chains.count)")
    for miss in misses + chainMisses { print("VOICE_EVAL miss \(miss)") }
    XCTAssertGreaterThanOrEqual(accuracy, 0.9, "Voice evaluation misses:\n" + misses.joined(separator: "\n"))
    XCTAssertTrue(chainMisses.isEmpty, "Chains missed:\n" + chainMisses.joined(separator: "\n"))
  }
}
