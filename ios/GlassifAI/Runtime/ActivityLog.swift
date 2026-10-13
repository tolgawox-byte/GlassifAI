import Foundation
import SwiftUI

/// One thing the app did for the user. The title names only the kind of
/// thing ("Reminder — done", "PC: run_command approved"), never its content.
struct ActivityLogEntry: Codable, Equatable, Identifiable {
  enum Kind: String, Codable, CaseIterable {
    case action, approval, pcTask, failure

    var title: String {
      switch self {
      case .action: L.t("Action", "İşlem")
      case .approval: L.t("Approval", "Onay")
      case .pcTask: L.t("PC task", "Bilgisayar görevi")
      case .failure: L.t("Problem", "Sorun")
      }
    }

    var systemImage: String {
      switch self {
      case .action: "checkmark.circle"
      case .approval: "hand.raised"
      case .pcTask: "desktopcomputer"
      case .failure: "exclamationmark.triangle"
      }
    }
  }

  var id = UUID()
  var at: Date
  var kind: Kind
  var title: String
}

/// What the app did on the user's behalf, kept on this iPhone for 30 days
/// (plan 2.5): actions run, approvals given or refused, PC tasks, and
/// problems. No request text, no results, no names.
@MainActor
final class ActivityLog: ObservableObject {
  static let shared = ActivityLog(directory: ScreenshotMode.storeDirectory)

  static let retention: TimeInterval = 30 * 86_400
  static let maxEntries = 1_000

  @Published private(set) var entries: [ActivityLogEntry] = []
  private let fileURL: URL

  init(directory: URL? = nil) {
    let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory).appendingPathComponent("AutoLoom", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    fileURL = base.appendingPathComponent("activity-log.json")
    if let data = try? Data(contentsOf: fileURL) {
      if let decoded = try? JSONDecoder().decode([ActivityLogEntry].self, from: data) {
        entries = decoded
        prune()
      } else {
        LocalJSONFile.setAside(fileURL)
      }
    }
  }

  func record(_ kind: ActivityLogEntry.Kind, _ title: String, at date: Date = Date()) {
    entries.append(ActivityLogEntry(at: date, kind: kind, title: LogSanitizer.sanitize(title, limit: 120)))
    prune(now: date)
    persist()
  }

  func prune(now: Date = Date()) {
    entries.removeAll { now.timeIntervalSince($0.at) > Self.retention }
    if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
  }

  /// Tab-separated lines (time, kind, title), oldest first.
  var exportText: String {
    let formatter = ISO8601DateFormatter()
    return entries.map { "\(formatter.string(from: $0.at))\t\($0.kind.rawValue)\t\($0.title)" }.joined(separator: "\n")
  }

  func deleteEverything() {
    entries = []
    try? FileManager.default.removeItem(at: fileURL)
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}

/// Privacy center → Activity log.
struct ActivityLogView: View {
  @ObservedObject private var log = ActivityLog.shared

  var body: some View {
    List {
      Section {
        if log.entries.isEmpty {
          Text(L.t("Nothing recorded yet.", "Henüz kayıt yok.")).foregroundStyle(.secondary)
        }
        ForEach(log.entries.reversed()) { entry in
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.systemImage)
              .foregroundStyle(entry.kind == .failure ? Color.orange : AutoLoomTheme.electricBlue)
              .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.title)
              Text(entry.kind.title + " · " + entry.at.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      } footer: {
        Text(L.t(
          "What the app did for you in the last 30 days, kept only on this iPhone: the kind of action, approval, PC task or problem, never what you said or what it contained.",
          "Uygulamanın son 30 günde sizin için yaptıkları, yalnızca bu iPhone'da: işlemin, onayın, bilgisayar görevinin ya da sorunun türü; ne söylediğiniz veya içeriği asla."))
      }
    }
    .navigationTitle(L.t("Activity log", "Etkinlik günlüğü"))
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if !log.entries.isEmpty {
          ShareLink(item: log.exportText) {
            Label(L.t("Export", "Dışa aktar"), systemImage: "square.and.arrow.up")
          }
        }
      }
    }
  }
}
