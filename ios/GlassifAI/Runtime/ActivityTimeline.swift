import SwiftUI

/// One line of the activity timeline.
struct ActivityItem: Identifiable, Equatable {
  enum Kind: String {
    case note, taskCreated, taskDone, memory, visual, capture, vehicle, document, scene
  }

  let id: String
  let kind: Kind
  let at: Date
  let title: String

  var systemImage: String {
    switch kind {
    case .note: "note.text"
    case .taskCreated: "checklist"
    case .taskDone: "checkmark.circle.fill"
    case .memory: "brain"
    case .visual: "eye"
    case .capture: "camera"
    case .vehicle: "car.fill"
    case .document: "doc.text"
    case .scene: "clock.arrow.circlepath"
    }
  }
}

/// What was saved, done and captured recently, from the phone's own stores.
@MainActor
enum ActivityTimeline {
  static func items(days: Int = 7, now: Date = Date()) -> [ActivityItem] {
    let since = now.addingTimeInterval(-Double(days) * 86_400)
    var items: [ActivityItem] = []
    let memory = MemoryStore.shared
    for note in memory.notes where note.createdAt >= since {
      items.append(ActivityItem(id: "note-\(note.id)", kind: .note, at: note.createdAt, title: note.title))
    }
    for task in memory.tasks {
      if task.createdAt >= since {
        items.append(ActivityItem(id: "task-\(task.id)", kind: .taskCreated, at: task.createdAt, title: task.title))
      }
      if task.completed, let done = task.completedAt, done >= since {
        items.append(ActivityItem(id: "done-\(task.id)", kind: .taskDone, at: done, title: task.title))
      }
    }
    for record in memory.memories where record.createdAt >= since && record.kind != .conversationSummary {
      items.append(ActivityItem(
        id: "memory-\(record.id)", kind: record.kind == .visual ? .visual : .memory, at: record.createdAt, title: record.title))
    }
    for capture in CaptureLibrary.shared.records where capture.createdAt >= since {
      let title = capture.caption ?? (capture.kind == .video ? L.t("Video", "Video") : L.t("Photo", "Fotoğraf"))
      items.append(ActivityItem(id: "capture-\(capture.id)", kind: .capture, at: capture.createdAt, title: title))
    }
    for vehicle in DealerStore.shared.vehicles where vehicle.updatedAt >= since {
      items.append(ActivityItem(id: "vehicle-\(vehicle.id)", kind: .vehicle, at: vehicle.updatedAt, title: vehicle.title))
    }
    for document in DocumentStore.shared.records where document.at >= since {
      items.append(ActivityItem(id: "document-\(document.id)", kind: .document, at: document.at, title: document.title))
    }
    for line in SceneTimeline.shared.entries where line.at >= since {
      items.append(ActivityItem(id: "scene-\(line.id)", kind: .scene, at: line.at, title: line.text))
    }
    return items.sorted { $0.at > $1.at }
  }
}

/// Explore → Timeline.
struct ActivityTimelineView: View {
  @ObservedObject private var memory = MemoryStore.shared
  @ObservedObject private var captures = CaptureLibrary.shared
  @ObservedObject private var dealer = DealerStore.shared
  @State private var days = 7

  var body: some View {
    let items = ActivityTimeline.items(days: days)
    let calendar = Calendar.current
    let groups = Dictionary(grouping: items) { calendar.startOfDay(for: $0.at) }
    List {
      Picker(L.t("Range", "Aralık"), selection: $days) {
        Text(L.t("Today", "Bugün")).tag(1)
        Text(L.t("7 days", "7 gün")).tag(7)
        Text(L.t("30 days", "30 gün")).tag(30)
      }
      .pickerStyle(.segmented)
      if items.isEmpty {
        Text(L.t("Nothing saved in this range.", "Bu aralıkta kayıt yok.")).foregroundStyle(.secondary)
      }
      ForEach(groups.keys.sorted(by: >), id: \.self) { day in
        Section(day.formatted(date: .complete, time: .omitted)) {
          ForEach(groups[day] ?? []) { item in
            HStack(spacing: 12) {
              Image(systemName: item.systemImage)
                .foregroundStyle(item.kind == .taskDone ? Color.green : AutoLoomTheme.electricBlue)
                .frame(width: 22)
              Text(item.title).lineLimit(2)
              Spacer()
              Text(item.at.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .navigationTitle(L.t("Timeline", "Zaman çizelgesi"))
  }
}
