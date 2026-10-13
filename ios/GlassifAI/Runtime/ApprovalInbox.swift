import SwiftUI

/// Everything waiting for the user's decision in one place (plan 2.4,
/// research F10): the action waiting on this iPhone and the tasks the paired
/// PC holds. Each still needs its own tap or the user's own yes; nothing is
/// approved in bulk.
struct ApprovalInboxView: View {
  @ObservedObject private var orchestrator = AssistantOrchestrator.shared
  @ObservedObject private var pc = PCCompanionStore.shared

  var body: some View {
    List {
      Section {
        if let pending = orchestrator.pendingAction {
          PendingActionCard(pending: pending)
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        } else {
          Text(L.t("Nothing is waiting on this iPhone.", "Bu iPhone'da bekleyen bir şey yok."))
            .foregroundStyle(.secondary)
        }
      } header: {
        Text(L.t("On this iPhone", "Bu iPhone'da"))
      } footer: {
        Text(L.t(
          "One action waits here at a time; a new request replaces it. It expires if left alone.",
          "Burada aynı anda bir işlem bekler; yeni bir istek onun yerini alır. Bekletilirse süresi dolar."))
      }
      if pc.link != nil {
        Section {
          if pc.pendingApprovals.isEmpty {
            Text(L.t("No PC task is waiting for approval.", "Onay bekleyen bilgisayar görevi yok."))
              .foregroundStyle(.secondary)
          } else {
            PCApprovalRows(store: pc)
          }
          if !pc.isReachable {
            Label(
              L.t("The PC has not answered in the last 30 seconds; this list may be out of date.",
                  "Bilgisayar son 30 saniyede yanıt vermedi; bu liste güncel olmayabilir."),
              systemImage: "wifi.exclamationmark")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        } header: {
          Text(L.t("On your PC", "Bilgisayarında"))
        } footer: {
          Text(L.t(
            "These wait on the PC itself, so they are still here after the app restarts.",
            "Bunlar bilgisayarın kendisinde bekler; uygulama yeniden açılınca da buradadır."))
        }
      }
    }
    .navigationTitle(L.t("Approvals", "Onaylar"))
    .task {
      if pc.link != nil { await pc.refresh() }
    }
  }
}
