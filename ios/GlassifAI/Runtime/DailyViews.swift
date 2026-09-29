import SwiftUI

/// "⏱ 06:42": the next timer, on the assistant screen.
struct TimerChip: View {
  let timer: AssistantTimer

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "timer")
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(RecordingChip.clock(timer.remaining(now: context.date)))
          .monospacedDigit()
      }
      if let label = timer.label {
        Text(label).lineLimit(1)
      }
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.white)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L.t("Timer", "Zamanlayıcı"))
  }
}

/// Explore → Shopping list: add, tick, remove; on this iPhone only.
struct ShoppingListView: View {
  @ObservedObject private var store = ShoppingListStore.shared
  @State private var newItem = ""

  var body: some View {
    List {
      Section {
        HStack {
          TextField(L.t("Add an item", "Ürün ekle"), text: $newItem)
            .onSubmit(add)
          Button(action: add) { Image(systemName: "plus.circle.fill") }
            .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      } footer: {
        Text(L.t("Or say “alışveriş listesine süt ve ekmek ekle”.", "Veya “alışveriş listesine süt ve ekmek ekle” deyin."))
      }
      Section {
        if store.items.isEmpty {
          Text(L.t("The list is empty.", "Liste boş.")).foregroundStyle(.secondary)
        }
        ForEach(store.items) { item in
          Button {
            store.toggle(item.id)
          } label: {
            HStack {
              Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.done ? Color.green : Color.secondary)
              Text(item.text)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? Color.secondary : Color.primary)
            }
          }
        }
        .onDelete { offsets in
          for index in offsets { store.delete(store.items[index].id) }
        }
      }
      if store.items.contains(where: \.done) {
        Section {
          Button(L.t("Remove ticked items", "İşaretlileri kaldır")) { store.clearDone() }
        }
      }
    }
    .navigationTitle(L.t("Shopping list", "Alışveriş listesi"))
  }

  private func add() {
    store.add(ShoppingListStore.split(newItem))
    newItem = ""
  }
}

/// Running timers with their time left and a cancel button.
struct TimersSection: View {
  @ObservedObject private var center = TimerCenter.shared

  var body: some View {
    if !center.timers.isEmpty {
      Section(L.t("Timers", "Zamanlayıcılar")) {
        ForEach(center.timers) { timer in
          HStack {
            TimerChip(timer: timer)
            Spacer()
            Button(L.t("Cancel", "İptal"), role: .destructive) { center.cancel(label: timer.label) }
              .buttonStyle(.borderless)
          }
        }
      }
    }
  }
}
