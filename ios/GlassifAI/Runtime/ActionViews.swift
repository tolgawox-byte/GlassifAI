import SwiftUI

/// Confirmation card for an iPhone action. CONFIRM actions can also be
/// confirmed by voice; STRONG CONFIRM actions (anything that opens another
/// app or contacts someone) are only ever done by a tap here. What the card
/// reports afterwards comes from iOS: "sent" only when Messages sent it,
/// "shared" only when the share sheet finished.
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
      if let alternative = plan.alternativeDate {
        Text(L.t("Or did you mean ", "Yoksa şunu mu kastettiniz: ") +
             TimePhraseParser.describe(alternative, hasTime: true, turkish: L.isTurkish) + "?")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
      if plan.risk == .strongConfirm {
        Text(L.t("Tap to confirm. A spoken \"yes\" is not enough for this.",
                 "Onaylamak için dokunun. Bunun için sesli \"evet\" yeterli değil."))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 10) {
        primaryButton
        Button(L.t("Cancel", "Vazgeç"), role: .cancel) { orchestrator.cancelPendingAction() }
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

  private var confirmTitle: String {
    switch plan.kind {
    case .forgetMemory: L.t("Forget", "Unut")
    case .agentTask: L.t("Send to agent", "Ajana gönder")
    default: L.t("Confirm", "Onayla")
    }
  }

  @ViewBuilder
  private var primaryButton: some View {
    switch plan.kind {
    case .createReminder, .createEvent, .saveNote, .listReminders, .todayEvents, .upcomingEvents, .copyText,
         .scheduleNotification, .findContact, .forgetMemory, .agentTask, .none:
      Button(confirmTitle) {
        working = true
        Task {
          _ = await orchestrator.confirmPendingAction(byVoice: false)
          working = false
        }
      }
      .buttonStyle(.borderedProminent)
    case .openMaps:
      Button(L.t("Open in Maps", "Haritalar'da aç")) {
        guard let destination = plan.location, let url = DeviceActionExecutor.mapsURL(for: destination) else { return }
        openURL(url) { accepted in
          orchestrator.completeTapAction(
            accepted ? "Opened directions to \(destination)" : "Maps could not be opened",
            feedback: accepted
              ? ActionFeedback(kind: .directions, title: L.t("Directions opened", "Yol tarifi açıldı"))
              : ActionFeedback.failed(L.t("Maps could not be opened", "Haritalar açılamadı")))
        }
      }
      .buttonStyle(.borderedProminent)
    case .openURL:
      Button(L.t("Open link", "Bağlantıyı aç")) {
        guard let url = plan.url, URLSafety.isPublicWebURL(url) else { return }
        openURL(url) { accepted in
          orchestrator.completeTapAction(accepted ? "Opened \(url.host ?? "link")" : "The link could not be opened")
        }
      }
      .buttonStyle(.borderedProminent)
    case .call:
      Button(L.t("Call", "Ara")) {
        guard let phone = plan.phone, let url = DeviceActionExecutor.callURL(for: phone) else { return }
        // iOS asks once more before dialling; the app never says a call
        // was made.
        openURL(url) { accepted in
          orchestrator.completeTapAction(
            accepted ? "The call screen opened for \(plan.recipient ?? phone)" : "The call screen could not be opened",
            feedback: accepted
              ? ActionFeedback(kind: .call, title: L.t("Call screen opened", "Arama ekranı açıldı"))
              : ActionFeedback.failed(L.t("Call screen could not be opened", "Arama ekranı açılamadı")))
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(plan.phone == nil)
    case .message:
      Button(L.t("Write in Messages", "Mesajlar'da yaz")) { openMessages() }
        .buttonStyle(.borderedProminent)
    case .shareText:
      Button {
        let text = plan.text ?? ""
        let opened = SystemSheets.presentShare(text: text) { completed in
          orchestrator.shareSheetFinished(completed)
        }
        if opened { orchestrator.completeTapAction("Share sheet opened") }
      } label: {
        Label(L.t("Share", "Paylaş"), systemImage: "square.and.arrow.up")
      }
      .buttonStyle(.borderedProminent)
    }
  }

  /// Messages' own compose sheet (the user sends), or the Messages app
  /// when the sheet is not available.
  private func openMessages() {
    let body = plan.text ?? ""
    if SystemSheets.presentMessage(phone: plan.phone, body: body, finished: { result in
      orchestrator.messageSheetFinished(result)
    }) {
      orchestrator.completeTapAction("Messages opened; sending is up to the user")
      return
    }
    guard let url = DeviceActionExecutor.messageURL(phone: plan.phone, body: body) else { return }
    openURL(url) { accepted in
      orchestrator.completeTapAction(
        accepted ? "Message opened in Messages; sending is up to the user" : "Messages could not be opened",
        feedback: accepted ? nil : ActionFeedback.failed(L.t("Messages could not be opened", "Mesajlar açılamadı")))
    }
  }
}
