import SwiftUI

/// Confirmation card for an iPhone action. Saves can also be confirmed by
/// voice; anything that opens another app or contacts someone is only ever
/// done by a tap here.
struct PendingActionCard: View {
  let pending: PendingDeviceAction
  @ObservedObject private var orchestrator = AssistantOrchestrator.shared
  @Environment(\.openURL) private var openURL
  @State private var working = false

  private var plan: DeviceActionPlan { pending.plan }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(plan.kind.label, systemImage: plan.kind.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(plan.summary)
        .font(.body.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
      if plan.kind == .message, let text = plan.text {
        Text(text)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(4)
      }
      if plan.risk == .needsTap {
        Text("Tap to confirm. A spoken \"yes\" is not enough for this.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 10) {
        primaryButton
        Button("Cancel", role: .cancel) { orchestrator.cancelPendingAction() }
          .buttonStyle(.bordered)
      }
      .controlSize(.regular)
      .disabled(working)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var primaryButton: some View {
    switch plan.kind {
    case .createReminder, .createEvent, .saveNote, .listReminders, .todayEvents, .upcomingEvents, .copyText, .none:
      Button("Save") {
        working = true
        Task {
          _ = await orchestrator.confirmPendingAction(byVoice: false)
          working = false
        }
      }
      .buttonStyle(.borderedProminent)
    case .openMaps:
      Button("Open in Maps") {
        if let destination = plan.location, let url = DeviceActionExecutor.mapsURL(for: destination) {
          openURL(url)
          orchestrator.completeTapAction("Opened directions to \(destination)")
        }
      }
      .buttonStyle(.borderedProminent)
    case .openURL:
      Button("Open link") {
        if let url = plan.url, URLSafety.isPublicWebURL(url) {
          openURL(url)
          orchestrator.completeTapAction("Opened \(url.host ?? "link")")
        }
      }
      .buttonStyle(.borderedProminent)
    case .call:
      Button("Call") {
        if let phone = plan.phone, let url = DeviceActionExecutor.callURL(for: phone) {
          openURL(url)
          orchestrator.completeTapAction("Call started to \(plan.recipient ?? phone)")
        }
      }
      .buttonStyle(.borderedProminent)
    case .message:
      Button("Write in Messages") {
        if let url = DeviceActionExecutor.messageURL(phone: plan.phone, body: plan.text) {
          openURL(url)
          orchestrator.completeTapAction("Message opened in Messages; sending is up to the user")
        }
      }
      .buttonStyle(.borderedProminent)
    case .shareText:
      ShareLink(item: plan.text ?? "") {
        Label("Share", systemImage: "square.and.arrow.up")
      }
      .buttonStyle(.borderedProminent)
    case .agentTask:
      Button("Send to agent") {
        working = true
        Task {
          _ = await orchestrator.confirmPendingAction(byVoice: false)
          working = false
        }
      }
      .buttonStyle(.borderedProminent)
    }
  }
}

/// Settings → AutoLoom Tasks & Notes: saved notes and reports, and the
/// recent tasks of this app run.
struct TasksAndNotesView: View {
  @ObservedObject private var notes = AutoLoomNotesStore.shared
  @ObservedObject private var ledger = AssistantOrchestrator.shared.ledger
  @State private var confirmDeleteAll = false

  var body: some View {
    List {
      Section(
        header: Text("Notes and reports (\(notes.notes.count))"),
        footer: Text("Stored only on this iPhone. Say \"save this as a note\" or \"research this and prepare a report\". Apple Notes has no API for other apps, so use Share to copy a note there.")) {
        if notes.notes.isEmpty {
          Text("No notes yet").foregroundStyle(.secondary)
        }
        ForEach(notes.notes) { note in
          NavigationLink {
            NoteDetailView(note: note)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(note.title).lineLimit(1)
              Text("\(note.source) · \(note.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
        .onDelete { offsets in
          offsets.map { notes.notes[$0].id }.forEach(notes.delete)
        }
      }
      Section("Recent tasks") {
        if ledger.records.isEmpty {
          Text("No tasks yet").foregroundStyle(.secondary)
        }
        ForEach(Array(ledger.records.suffix(12).reversed())) { record in
          VStack(alignment: .leading, spacing: 2) {
            Text("\(record.kind?.displayName ?? "Task") · \(phaseText(record.phase))")
              .font(.footnote.weight(.semibold))
            Text(record.request)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
      }
      if !notes.notes.isEmpty {
        Section {
          Button("Delete all notes", role: .destructive) { confirmDeleteAll = true }
        }
      }
    }
    .navigationTitle("AutoLoom Tasks & Notes")
    .confirmationDialog("Delete all notes?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
      Button("Delete all", role: .destructive) { notes.deleteAll() }
    }
  }

  private func phaseText(_ phase: AssistantTaskPhase) -> String {
    switch phase {
    case .completed: "done"
    case .cancelled: "cancelled"
    case .failed: "failed"
    case .routing, .capturingFrame, .searching, .analyzing, .reasoning, .delivering: "running"
    }
  }
}

private struct NoteDetailView: View {
  let note: AutoLoomNotesStore.Note
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text(note.body)
          .font(.body)
          .textSelection(.enabled)
        if !note.sources.isEmpty {
          Text("Sources")
            .font(.headline)
          ForEach(note.sources, id: \.self) { source in
            Text(source)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(note.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        ShareLink(item: "\(note.title)\n\n\(note.body)")
      }
      ToolbarItem(placement: .bottomBar) {
        Button("Delete", role: .destructive) {
          AutoLoomNotesStore.shared.delete(note.id)
          dismiss()
        }
      }
    }
  }
}
