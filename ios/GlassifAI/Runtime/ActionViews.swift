import SwiftUI

/// Confirmation card for an iPhone action. CONFIRM actions can also be
/// confirmed by voice; STRONG CONFIRM actions (anything that opens another
/// app or contacts someone) are only ever done by a tap here.
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
        if let destination = plan.location, let url = DeviceActionExecutor.mapsURL(for: destination) {
          openURL(url)
          orchestrator.completeTapAction("Opened directions to \(destination)")
        }
      }
      .buttonStyle(.borderedProminent)
    case .openURL:
      Button(L.t("Open link", "Bağlantıyı aç")) {
        if let url = plan.url, URLSafety.isPublicWebURL(url) {
          openURL(url)
          orchestrator.completeTapAction("Opened \(url.host ?? "link")")
        }
      }
      .buttonStyle(.borderedProminent)
    case .call:
      Button(L.t("Call", "Ara")) {
        if let phone = plan.phone, let url = DeviceActionExecutor.callURL(for: phone) {
          openURL(url)
          orchestrator.completeTapAction("Call started to \(plan.recipient ?? phone)")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(plan.phone == nil)
    case .message:
      Button(L.t("Write in Messages", "Mesajlar'da yaz")) {
        if let url = DeviceActionExecutor.messageURL(phone: plan.phone, body: plan.text) {
          openURL(url)
          orchestrator.completeTapAction("Message opened in Messages; sending is up to the user")
        }
      }
      .buttonStyle(.borderedProminent)
    case .shareText:
      ShareLink(item: plan.text ?? "") {
        Label(L.t("Share", "Paylaş"), systemImage: "square.and.arrow.up")
      }
      .buttonStyle(.borderedProminent)
    }
  }
}
