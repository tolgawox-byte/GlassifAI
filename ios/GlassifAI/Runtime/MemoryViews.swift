import SwiftUI
import UIKit

/// The Memory tab: what the user asked the assistant to remember, and their
/// AutoLoom notes. Everything here is stored only on this iPhone.
struct MemoryTabView: View {
  enum Section: String, CaseIterable, Identifiable {
    case memories
    case notes
    var id: String { rawValue }
  }

  @ObservedObject private var store = MemoryStore.shared
  @State private var section: Section = .memories
  @State private var query = ""
  @State private var showNewMemory = false
  @State private var showNewNote = false
  @State private var confirmDeleteAll = false

  var body: some View {
    NavigationStack {
      List {
        Picker(L.t("Show", "Göster"), selection: $section) {
          Text(L.t("Memories", "Anılar")).tag(Section.memories)
          Text(L.t("Notes", "Notlar")).tag(Section.notes)
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

        if !store.isEnabled && section == .memories {
          SwiftUI.Section {
            Label(L.t("Memory is off. Turn it on in Settings → Memory.", "Hafıza kapalı. Ayarlar → Hafıza'dan açın."),
                  systemImage: "brain")
              .foregroundStyle(.secondary)
          }
        }
        if let error = store.storageError {
          SwiftUI.Section {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.orange)
          }
        }

        switch section {
        case .memories: memoriesContent
        case .notes: notesContent
        }
      }
      .searchable(text: $query, prompt: L.t("Search memories and notes", "Anılarda ve notlarda ara"))
      .navigationTitle(L.t("Memory", "Hafıza"))
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button {
              if section == .memories { showNewMemory = true } else { showNewNote = true }
            } label: {
              Label(section == .memories ? L.t("New memory", "Yeni anı") : L.t("New note", "Yeni not"),
                    systemImage: "plus")
            }
            .disabled(section == .memories && !store.isEnabled)
            Button(role: .destructive) { confirmDeleteAll = true } label: {
              Label(section == .memories ? L.t("Delete all memories", "Tüm anıları sil") : L.t("Delete all notes", "Tüm notları sil"),
                    systemImage: "trash")
            }
            .disabled(section == .memories ? store.memories.isEmpty : store.notes.isEmpty)
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .accessibilityLabel(L.t("More", "Daha fazla"))
        }
      }
      .confirmationDialog(
        section == .memories ? L.t("Delete all memories?", "Tüm anılar silinsin mi?") : L.t("Delete all notes?", "Tüm notlar silinsin mi?"),
        isPresented: $confirmDeleteAll, titleVisibility: .visible
      ) {
        Button(L.t("Delete all", "Tümünü sil"), role: .destructive) {
          if section == .memories { store.deleteAllMemories() } else { store.deleteAllNotes() }
        }
      } message: {
        Text(L.t("This cannot be undone.", "Bu geri alınamaz."))
      }
      .sheet(isPresented: $showNewMemory) {
        NavigationStack { MemoryEditorView(record: nil) }
      }
      .sheet(isPresented: $showNewNote) {
        NavigationStack { NoteEditorView(note: nil) }
      }
    }
  }

  // MARK: Memories

  @ViewBuilder
  private var memoriesContent: some View {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      let hits = store.search(trimmed, limit: 30)
      SwiftUI.Section(L.t("Results", "Sonuçlar")) {
        if hits.isEmpty {
          Text(L.t("Nothing found.", "Bir şey bulunamadı.")).foregroundStyle(.secondary)
        }
        ForEach(hits) { hit in
          switch hit.item {
          case .memory(let record): memoryLink(record)
          case .note(let note): noteLink(note)
          }
        }
      }
    } else if store.memories.isEmpty {
      SwiftUI.Section {
        VStack(alignment: .leading, spacing: 8) {
          Text(L.t("Nothing saved yet", "Henüz bir şey kaydedilmedi")).font(.headline)
          Text(L.t("Say “remember that my car is on level P2” or “bunu hatırla” while looking at something. Only what you ask is saved.",
                   "“Arabamın P2 katında olduğunu hatırla” ya da bir şeye bakarken “bunu hatırla” deyin. Yalnızca istediğiniz kaydedilir."))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
      }
    } else {
      let pinned = store.memories.filter(\.pinned)
      let weekAgo = Date().addingTimeInterval(-7 * 86_400)
      let recent = store.memories.filter { !$0.pinned && $0.createdAt >= weekAgo }
      let older = store.memories.filter { !$0.pinned && $0.createdAt < weekAgo }
      if !pinned.isEmpty {
        SwiftUI.Section(L.t("Pinned", "Sabitlenenler")) { ForEach(pinned) { memoryLink($0) } }
      }
      if !recent.isEmpty {
        SwiftUI.Section(L.t("Recent", "Son eklenenler")) { ForEach(recent) { memoryLink($0) } }
      }
      ForEach(MemoryCategory.allCases) { category in
        let items = older.filter { $0.category == category }
        if !items.isEmpty {
          SwiftUI.Section(category.label) { ForEach(items) { memoryLink($0) } }
        }
      }
    }
  }

  private func memoryLink(_ record: MemoryRecord) -> some View {
    NavigationLink {
      MemoryDetailView(record: record)
    } label: {
      MemoryRow(record: record)
    }
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) { store.delete(record) } label: {
        Label(L.t("Forget", "Unut"), systemImage: "trash")
      }
    }
    .swipeActions(edge: .leading) {
      Button { store.setPinned(record, !record.pinned) } label: {
        Label(record.pinned ? L.t("Unpin", "Sabitlemeyi kaldır") : L.t("Pin", "Sabitle"),
              systemImage: record.pinned ? "pin.slash" : "pin")
      }
      .tint(.orange)
    }
  }

  // MARK: Notes

  @ViewBuilder
  private var notesContent: some View {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let notes = trimmed.isEmpty
      ? store.notes
      : store.search(trimmed, limit: 40).compactMap { hit -> NoteRecord? in
        if case .note(let note) = hit.item { return note }
        return nil
      }
    SwiftUI.Section {
      if notes.isEmpty {
        Text(trimmed.isEmpty
             ? L.t("No notes yet. Say “not al: …” or “save a note”.", "Henüz not yok. “Not al: …” deyin.")
             : L.t("Nothing found.", "Bir şey bulunamadı."))
          .foregroundStyle(.secondary)
      }
      ForEach(notes) { noteLink($0) }
    } footer: {
      Text(L.t("Apple Notes has no API for other apps; use Share on a note to copy it there.",
               "Apple Notlar diğer uygulamalara açık değil; notu oraya aktarmak için Paylaş'ı kullanın."))
    }
  }

  private func noteLink(_ note: NoteRecord) -> some View {
    NavigationLink {
      NoteDetailView(note: note)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
          Text(note.title).lineLimit(1)
        }
        Text(note.content)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) { store.deleteNote(note) } label: {
        Label(L.t("Delete", "Sil"), systemImage: "trash")
      }
    }
  }
}

struct MemoryRow: View {
  let record: MemoryRecord

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if let data = record.thumbnail, let image = UIImage(data: data) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 44, height: 44)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      } else {
        Image(systemName: record.kind.systemImage)
          .frame(width: 28, height: 28)
          .foregroundStyle(AutoLoomTheme.electricBlue)
      }
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          if record.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
          Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        Text(record.text).font(.subheadline).lineLimit(2)
        Text("\(record.kind.label) · \(record.createdAt.formatted(date: .abbreviated, time: .omitted))" +
             (record.placeName.map { " · \($0)" } ?? ""))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}

struct MemoryDetailView: View {
  let record: MemoryRecord
  @ObservedObject private var store = MemoryStore.shared
  @State private var editing = false
  @State private var confirmForget = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    // A deleted SwiftData object must not be read (for example after
    // "Delete all" in the privacy center while this screen stays open).
    if store.memories.contains(where: { $0 === record }) {
      detail
    } else {
      Text(L.t("This memory was deleted.", "Bu anı silindi."))
        .foregroundStyle(.secondary)
    }
  }

  private var detail: some View {
    List {
      if let data = record.thumbnail, let image = UIImage(data: data) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .listRowInsets(EdgeInsets())
      }
      SwiftUI.Section {
        Text(record.text).textSelection(.enabled)
      }
      SwiftUI.Section {
        LabeledContent(L.t("Type", "Tür"), value: record.kind.label)
        LabeledContent(L.t("Group", "Grup"), value: record.category.label)
        LabeledContent(L.t("Saved", "Kaydedildi"), value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
        LabeledContent(L.t("Source", "Kaynak"), value: record.source)
        if let place = record.placeName { LabeledContent(L.t("Place", "Yer"), value: place) }
        if let recalled = record.lastRecalledAt {
          LabeledContent(L.t("Last used", "Son kullanım"), value: recalled.formatted(date: .abbreviated, time: .shortened))
        }
      }
      SwiftUI.Section {
        Button {
          store.setPinned(record, !record.pinned)
        } label: {
          Label(record.pinned ? L.t("Unpin", "Sabitlemeyi kaldır") : L.t("Pin", "Sabitle"),
                systemImage: record.pinned ? "pin.slash" : "pin")
        }
        Button(role: .destructive) { confirmForget = true } label: {
          Label(L.t("Forget", "Unut"), systemImage: "trash")
        }
      }
    }
    .navigationTitle(record.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(L.t("Edit", "Düzenle")) { editing = true }
      }
    }
    .sheet(isPresented: $editing) {
      NavigationStack { MemoryEditorView(record: record) }
    }
    .confirmationDialog(L.t("Forget this memory?", "Bu anı unutulsun mu?"), isPresented: $confirmForget, titleVisibility: .visible) {
      Button(L.t("Forget", "Unut"), role: .destructive) {
        // Leave the screen first; it must not render a deleted object.
        dismiss()
        let store = store
        let record = record
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 400_000_000)
          store.delete(record)
        }
      }
    }
  }
}

struct MemoryEditorView: View {
  let record: MemoryRecord?
  @State private var title = ""
  @State private var text = ""
  @State private var kind: MemoryKind = .fact
  @State private var category: MemoryCategory = .other
  @State private var loaded = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      SwiftUI.Section(L.t("Memory", "Anı")) {
        TextField(L.t("Title", "Başlık"), text: $title)
        TextField(L.t("What to remember", "Hatırlanacak şey"), text: $text, axis: .vertical)
          .lineLimit(3...8)
      }
      SwiftUI.Section {
        Picker(L.t("Type", "Tür"), selection: $kind) {
          ForEach(MemoryKind.allCases) { Text($0.label).tag($0) }
        }
        Picker(L.t("Group", "Grup"), selection: $category) {
          ForEach(MemoryCategory.allCases) { Text($0.label).tag($0) }
        }
      }
    }
    .navigationTitle(record == nil ? L.t("New memory", "Yeni anı") : L.t("Edit memory", "Anıyı düzenle"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button(L.t("Cancel", "Vazgeç")) { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(L.t("Save", "Kaydet")) {
          if let record {
            MemoryStore.shared.update(record, title: title, text: text, kind: kind, category: category)
          } else {
            MemoryStore.shared.remember(text, title: title, kind: kind, category: category, source: "manual")
          }
          dismiss()
        }
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .onAppear {
      guard !loaded else { return }
      loaded = true
      if let record {
        title = record.title
        text = record.text
        kind = record.kind
        category = record.category
      }
    }
    .onChange(of: text) { _, newValue in
      guard record == nil else { return }
      kind = MemoryKind.classify(newValue)
      category = MemoryCategory.classify(newValue + " " + title)
    }
  }
}

struct NoteDetailView: View {
  let note: NoteRecord
  @ObservedObject private var store = MemoryStore.shared
  @State private var editing = false
  @State private var confirmDelete = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    // A deleted SwiftData object must not be read.
    if store.notes.contains(where: { $0 === note }) {
      detail
    } else {
      Text(L.t("This note was deleted.", "Bu not silindi."))
        .foregroundStyle(.secondary)
    }
  }

  private var detail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text(note.content)
          .font(.body)
          .textSelection(.enabled)
        if !note.tags.isEmpty {
          Text(note.tags.map { "#\($0)" }.joined(separator: " "))
            .font(.footnote)
            .foregroundStyle(AutoLoomTheme.electricBlue)
        }
        if !note.links.isEmpty {
          Text(L.t("Sources", "Kaynaklar")).font(.headline)
          ForEach(note.links, id: \.self) { link in
            if let url = URL(string: link), URLSafety.isPublicWebURL(url) {
              Link(url.host ?? link, destination: url).font(.caption)
            } else {
              Text(link).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
        }
        if let place = note.placeName {
          Label(place, systemImage: "mappin.and.ellipse").font(.footnote).foregroundStyle(.secondary)
        }
        Text("\(note.source) · \(note.createdAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(note.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        ShareLink(item: "\(note.title)\n\n\(note.content)")
        Menu {
          Button { editing = true } label: { Label(L.t("Edit", "Düzenle"), systemImage: "pencil") }
          Button { store.setPinned(note, !note.pinned) } label: {
            Label(note.pinned ? L.t("Unpin", "Sabitlemeyi kaldır") : L.t("Pin", "Sabitle"), systemImage: "pin")
          }
          Button(role: .destructive) { confirmDelete = true } label: {
            Label(L.t("Delete", "Sil"), systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .sheet(isPresented: $editing) {
      NavigationStack { NoteEditorView(note: note) }
    }
    .confirmationDialog(L.t("Delete this note?", "Bu not silinsin mi?"), isPresented: $confirmDelete, titleVisibility: .visible) {
      Button(L.t("Delete", "Sil"), role: .destructive) {
        // Leave the screen first; it must not render a deleted object.
        dismiss()
        let store = store
        let note = note
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 400_000_000)
          store.deleteNote(note)
        }
      }
    }
  }
}

struct NoteEditorView: View {
  let note: NoteRecord?
  @State private var title = ""
  @State private var content = ""
  @State private var tags = ""
  @State private var loaded = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      TextField(L.t("Title", "Başlık"), text: $title)
      TextField(L.t("Note", "Not"), text: $content, axis: .vertical)
        .lineLimit(6...20)
      TextField(L.t("Tags (comma separated)", "Etiketler (virgülle)"), text: $tags)
        .textInputAutocapitalization(.never)
    }
    .navigationTitle(note == nil ? L.t("New note", "Yeni not") : L.t("Edit note", "Notu düzenle"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button(L.t("Cancel", "Vazgeç")) { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(L.t("Save", "Kaydet")) {
          let tagList = tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
          if let note {
            MemoryStore.shared.updateNote(note, title: title.isEmpty ? note.title : title, content: content, tags: tagList)
          } else {
            MemoryStore.shared.addNote(title: title, content: content, source: "manual", tags: tagList)
          }
          dismiss()
        }
        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .onAppear {
      guard !loaded else { return }
      loaded = true
      if let note {
        title = note.title
        content = note.content
        tags = note.tags.joined(separator: ", ")
      }
    }
  }
}

/// Settings → Memory.
struct MemorySettingsView: View {
  @ObservedObject private var store = MemoryStore.shared
  @State private var confirmDeleteAll = false

  var body: some View {
    Form {
      SwiftUI.Section(footer: Text(L.t(
        "Only what you explicitly ask is saved (“hatırla”, “kaydet”, “not al”, “unutma”, “remember…”). Memories stay on this iPhone, are searched on the phone, and only the few relevant ones are added to your own ChatGPT requests. Nothing is synced with ChatGPT's memory.",
        "Yalnızca açıkça istediğiniz kaydedilir (“hatırla”, “kaydet”, “not al”, “unutma”). Anılar bu iPhone'da kalır, aramalar telefonda yapılır ve yalnızca ilgili birkaç anı kendi ChatGPT isteklerinize eklenir. ChatGPT hafızasıyla eşitlenmez."))) {
        Toggle(L.t("Memory", "Hafıza"), isOn: $store.isEnabled)
        LabeledContent(L.t("Saved memories", "Kayıtlı anılar"), value: "\(store.memories.count)")
        LabeledContent(L.t("Notes", "Notlar"), value: "\(store.notes.count)")
        LabeledContent(L.t("Storage", "Depolama"),
                       value: store.isPersistent ? L.t("On this iPhone (SwiftData)", "Bu iPhone'da (SwiftData)") : L.t("Temporary (see error)", "Geçici (hataya bakın)"))
      }
      SwiftUI.Section(
        header: Text(L.t("Visual memories", "Görsel anılar")),
        footer: Text(L.t(
          "Say “remember this” while looking at something: a short description of the view is saved. Photos and places are saved only if you turn them on.",
          "Bir şeye bakarken “bunu hatırla” deyin: görüntünün kısa bir açıklaması kaydedilir. Fotoğraf ve konum yalnızca açarsanız kaydedilir."))) {
        Toggle(L.t("Visual memories", "Görsel anılar"), isOn: $store.visualMemoriesEnabled)
          .disabled(!store.isEnabled)
        Toggle(L.t("Keep a small photo", "Küçük fotoğraf sakla"), isOn: $store.saveVisualPhotos)
          .disabled(!store.visualMemoriesEnabled)
        Toggle(L.t("Attach the place", "Konumu ekle"), isOn: $store.attachLocation)
          .disabled(!store.visualMemoriesEnabled)
          .onChange(of: store.attachLocation) { _, on in
            if on { LocationProvider.shared.requestPermission() }
          }
      }
      SwiftUI.Section {
        Button(L.t("Delete all memories", "Tüm anıları sil"), role: .destructive) { confirmDeleteAll = true }
          .disabled(store.memories.isEmpty)
      }
    }
    .navigationTitle(L.t("Memory", "Hafıza"))
    .confirmationDialog(L.t("Delete all memories?", "Tüm anılar silinsin mi?"), isPresented: $confirmDeleteAll, titleVisibility: .visible) {
      Button(L.t("Delete all", "Tümünü sil"), role: .destructive) { store.deleteAllMemories() }
    }
  }
}
