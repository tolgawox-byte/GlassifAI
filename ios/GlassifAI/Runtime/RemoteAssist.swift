import Foundation
import Network
import SwiftUI
import UIKit

// MARK: The stream (network queue)

/// Serves the page and the camera stream (MJPEG) to viewers on the same
/// Wi-Fi who typed the room code. Runs on its own queue.
final class RemoteAssistHub: @unchecked Sendable {
  private let queue = DispatchQueue(label: "autoloom.remoteassist")
  private var code = ""
  private var streams: [ObjectIdentifier: NWConnection] = [:]
  private var failures = 0
  /// Called on the main actor with the number of viewers.
  var viewersChanged: @Sendable (Int) -> Void = { _ in }
  /// Called on the main actor after too many wrong codes.
  var tooManyAttempts: @Sendable () -> Void = {}

  static let maxFailures = 10

  func reset(code: String) {
    queue.async {
      self.code = code
      self.failures = 0
    }
  }

  var hasViewers: Bool { queue.sync { !streams.isEmpty } }

  func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, _ in
      guard let self, let data, let request = String(data: data, encoding: .utf8) else {
        connection.cancel()
        return
      }
      self.handle(request, on: connection)
    }
  }

  private func handle(_ request: String, on connection: NWConnection) {
    let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
    let parts = line.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET" else { return reply(connection, status: "405 Method Not Allowed", body: "") }
    let target = String(parts[1])
    let components = URLComponents(string: target)
    switch components?.path ?? "/" {
    case "/stream":
      let given = components?.queryItems?.first { $0.name == "code" }?.value ?? ""
      guard !code.isEmpty, Self.constantTimeEqual(given, code) else {
        failures += 1
        if failures >= Self.maxFailures {
          let callback = tooManyAttempts
          DispatchQueue.main.async { callback() }
        }
        return reply(connection, status: "403 Forbidden", body: "Wrong code")
      }
      let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
      connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        if error != nil {
          connection.cancel()
          return
        }
        self.streams[ObjectIdentifier(connection)] = connection
        self.announceViewers()
      })
      connection.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .failed, .cancelled:
          self.streams[ObjectIdentifier(connection)] = nil
          self.announceViewers()
        default:
          break
        }
      }
    case "/":
      reply(connection, status: "200 OK", body: Self.page, type: "text/html; charset=utf-8")
    default:
      reply(connection, status: "404 Not Found", body: "")
    }
  }

  private func reply(_ connection: NWConnection, status: String, body: String, type: String = "text/plain; charset=utf-8") {
    let data = Data(body.utf8)
    let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
  }

  /// One JPEG to every viewer; a viewer that falls behind is dropped.
  func broadcast(_ jpeg: Data) {
    queue.async {
      let head = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n"
      let part = Data(head.utf8) + jpeg + Data("\r\n".utf8)
      for (key, connection) in self.streams {
        connection.send(content: part, completion: .contentProcessed { [weak self] error in
          guard let self, error != nil else { return }
          self.streams[key] = nil
          connection.cancel()
          self.announceViewers()
        })
      }
    }
  }

  func closeAll() {
    queue.async {
      for connection in self.streams.values { connection.cancel() }
      self.streams.removeAll()
      self.code = ""
      self.announceViewers()
    }
  }

  private func announceViewers() {
    let count = streams.count
    let callback = viewersChanged
    DispatchQueue.main.async { callback(count) }
  }

  static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8)
    let y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var difference: UInt8 = 0
    for index in 0..<x.count { difference |= x[index] ^ y[index] }
    return difference == 0
  }

  static let page = #"""
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>AutoLoom Remote Assist</title></head>
    <body style="margin:0;background:#000;color:#fff;font-family:-apple-system,system-ui,sans-serif;text-align:center">
    <form id="f" style="padding:32px"><p>Telefonda görünen oda kodunu gir · Enter the room code shown on the phone</p>
    <input id="c" inputmode="numeric" autocomplete="off" maxlength="6" style="font-size:28px;width:7em;text-align:center">
    <button style="font-size:22px">Göster · View</button></form>
    <img id="v" alt="" style="max-width:100%;max-height:100vh;display:none">
    <script>
    document.getElementById('f').onsubmit=function(e){e.preventDefault();
    var v=document.getElementById('v');v.src='/stream?code='+encodeURIComponent(document.getElementById('c').value);
    v.style.display='block';document.getElementById('f').style.display='none';};
    </script></body></html>
    """#
}

// MARK: Sharing state (main actor)

/// Remote Assist: a colleague on the same Wi-Fi sees the camera view (about
/// two frames a second, no sound) after typing the room code. It never
/// starts by itself — only from the Start button — and while it runs a red
/// bar with "Paylaşımı durdur" stays on screen. It stops when asked, when
/// the app leaves the screen, after 15 minutes, or after ten wrong codes.
/// Sharing over the internet needs a WebRTC signalling server (not set up).
@MainActor
final class RemoteAssistServer: ObservableObject {
  static let shared = RemoteAssistServer()

  enum StopReason: Equatable {
    case user, background, timeLimit, wrongCodes, cameraStopped, thermal, failed(String)
  }

  @Published private(set) var isSharing = false
  @Published private(set) var code = ""
  @Published private(set) var address: String?
  @Published private(set) var viewers = 0
  @Published private(set) var startedAt: Date?
  @Published private(set) var lastStop: StopReason?

  static let maxDuration: TimeInterval = 15 * 60
  static let frameInterval: TimeInterval = 0.5

  private let hub = RemoteAssistHub()
  private var listener: NWListener?
  private var pump: Task<Void, Never>?

  private init() {
    hub.viewersChanged = { count in Task { @MainActor in RemoteAssistServer.shared.viewers = count } }
    hub.tooManyAttempts = { Task { @MainActor in RemoteAssistServer.shared.stop(.wrongCodes) } }
  }

  /// Starts sharing; returns why not when it cannot.
  func start() -> String? {
    guard !isSharing else { return nil }
    let decision = MediaResourceCoordinator.shared.begin(.remoteAssist)
    guard decision.allowed else {
      return decision.spoken ?? L.t("Start the camera first.", "Önce kamerayı başlat.")
    }
    let listener: NWListener
    do {
      listener = try NWListener(using: .tcp, on: .any)
    } catch {
      MediaResourceCoordinator.shared.end(.remoteAssist)
      return L.t("The local network share could not start.", "Yerel ağ paylaşımı başlatılamadı.")
    }
    code = String(format: "%06d", Int.random(in: 0...999_999))
    hub.reset(code: code)
    let hub = self.hub
    listener.newConnectionHandler = { connection in hub.accept(connection) }
    listener.stateUpdateHandler = { state in
      Task { @MainActor in
        let server = RemoteAssistServer.shared
        switch state {
        case .ready:
          if let port = server.listener?.port?.rawValue, let ip = Self.wifiAddress() {
            server.address = "http://\(ip):\(port)"
          }
        case .failed(let error):
          server.stop(.failed(String(describing: error)))
        default:
          break
        }
      }
    }
    listener.start(queue: DispatchQueue(label: "autoloom.remoteassist.listener"))
    self.listener = listener
    isSharing = true
    startedAt = Date()
    lastStop = nil
    pump = Task { [weak self] in
      while let self, self.isSharing, !Task.isCancelled {
        if let startedAt = self.startedAt, Date().timeIntervalSince(startedAt) > Self.maxDuration {
          self.stop(.timeLimit)
          return
        }
        if hub.hasViewers, let frame = FrameStore.shared.freshFrame(maxAge: 1.5) {
          let pixelBuffer = frame.pixelBuffer
          let jpeg = await Task.detached(priority: .utility) {
            VisionFrameEncoder.encode(pixelBuffer, maxLongSide: 720, quality: 0.55, maxBytes: 220_000)?.jpeg
          }.value
          if let jpeg { hub.broadcast(jpeg) }
        }
        // Half the frame rate when the phone is hot.
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        try? await Task.sleep(nanoseconds: UInt64((hot ? 1.0 : Self.frameInterval) * 1_000_000_000))
      }
    }
    return nil
  }

  func stop(_ reason: StopReason = .user) {
    guard isSharing else { return }
    pump?.cancel()
    pump = nil
    listener?.cancel()
    listener = nil
    hub.closeAll()
    isSharing = false
    code = ""
    address = nil
    viewers = 0
    startedAt = nil
    lastStop = reason
    MediaResourceCoordinator.shared.end(.remoteAssist)
    if reason != .user {
      let (tr, en) = Self.stopSentence(reason)
      AssistantOrchestrator.shared.postNotice(L.t(en, tr))
    }
  }

  static func stopSentence(_ reason: StopReason) -> (String, String) {
    switch reason {
    case .user: ("Paylaşımı durdurdum.", "Sharing stopped.")
    case .background: ("Uygulama arka plana geçtiği için paylaşım durdu.", "Sharing stopped because the app left the screen.")
    case .timeLimit: ("Paylaşım 15 dakika sonunda durdu.", "Sharing stopped after 15 minutes.")
    case .wrongCodes: ("Çok fazla yanlış kod denendiği için paylaşım durdu.", "Sharing stopped after too many wrong codes.")
    case .cameraStopped: ("Kamera kapandığı için paylaşım durdu.", "Sharing stopped because the camera stopped.")
    case .thermal: ("Telefon çok ısındığı için paylaşım durdu.", "Sharing stopped because the phone is too hot.")
    case .failed: ("Paylaşım bir hata yüzünden durdu.", "Sharing stopped because of an error.")
    }
  }

  /// The iPhone's Wi-Fi address (en0), IPv4.
  nonisolated static func wifiAddress() -> String? {
    var result: String?
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
    defer { freeifaddrs(pointer) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
      let interface = entry.pointee
      if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: interface.ifa_name) == "en0" {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count),
                       nil, 0, NI_NUMERICHOST) == 0 {
          result = String(cString: host)
        }
      }
      cursor = interface.ifa_next
    }
    return result
  }
}

// MARK: Voice: "uzaktan yardımı başlat", "paylaşımı durdur"

extension VoiceActionIntentBridge {
  static func remoteAssist(_ u: Utterance) -> VoiceBridgeDecision? {
    guard u.count <= 7 else { return nil }
    let stops: [[String]] = [
      ["paylasimi", "durdur"], ["paylasimi", "bitir"], ["paylasimi", "kapat"], ["paylasimi", "kes"], ["stop", "sharing"],
      ["uzaktan", "yardimi", "kapat"], ["uzaktan", "yardimi", "durdur"], ["stop", "remote", "assist"],
    ]
    if stops.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.remoteAssist(start: false), "remote assist stop")
    }
    let starts: [[String]] = [
      ["uzaktan", "yardimi", "baslat"], ["uzaktan", "yardim", "baslat"], ["goruntumu", "paylas"], ["kamerami", "paylas"],
      ["gordugumu", "paylas"], ["start", "remote", "assist"], ["share", "my", "view"], ["share", "what", "i", "see"],
    ]
    if starts.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.remoteAssist(start: true), "remote assist (opens the Start button)")
    }
    return nil
  }
}

extension AssistantOrchestrator {
  func runRemoteAssist(start: Bool, traceID: UUID) -> IntentOutcome {
    let server = RemoteAssistServer.shared
    ActionTraceLog.shared.update(traceID) { $0.executor = "RemoteAssistServer (local network, room code)" }
    if !start {
      guard server.isSharing else {
        let tr = "Şu an paylaşım yok."
        let en = "Nothing is being shared."
        return IntentOutcome(spoken: BridgeSpeech.done("Nothing was shared.", tr: tr, en: en), reply: L.t(en, tr), said: L.t(en, tr))
      }
      server.stop(.user)
      let tr = "Paylaşımı durdurdum."
      let en = "Sharing stopped."
      return IntentOutcome(
        spoken: BridgeSpeech.done("Remote Assist sharing stopped.", tr: tr, en: en), reply: L.t(en, tr),
        feedback: ActionFeedback(kind: .forgotten, title: L.t("Sharing stopped", "Paylaşım durdu")), said: L.t(en, tr))
    }
    // Starting shares the camera view: only a tap on the phone does it.
    AppNavigator.shared.show(.remoteAssist)
    let tr = "Paylaşımı başlatmak için telefonda Başlat'a dokun; kod ekranda görünecek."
    let en = "Tap Start on the phone to begin sharing; the code will be on screen."
    return IntentOutcome(
      spoken: BridgeSpeech.done("Nothing is shared yet; the user must tap Start on the phone.", tr: tr, en: en),
      reply: L.t(en, tr), said: L.t(en, tr))
  }
}

// MARK: Screens

struct RemoteAssistView: View {
  @ObservedObject private var server = RemoteAssistServer.shared
  @State private var problem: String?

  var body: some View {
    List {
      if server.isSharing {
        Section {
          LabeledContent(L.t("Room code", "Oda kodu")) {
            Text(server.code).font(.title2.monospacedDigit().weight(.bold))
          }
          if let address = server.address {
            LabeledContent(L.t("Address", "Adres")) { Text(address).textSelection(.enabled) }
          } else {
            Text(L.t("Waiting for the Wi-Fi address…", "Wi-Fi adresi bekleniyor…")).foregroundStyle(.secondary)
          }
          LabeledContent(L.t("Watching", "İzleyen"), value: "\(server.viewers)")
          Button(role: .destructive) {
            server.stop(.user)
          } label: {
            Label(L.t("Stop sharing", "Paylaşımı durdur"), systemImage: "stop.circle.fill").font(.headline)
          }
        } footer: {
          Text(L.t(
            "Someone on the same Wi-Fi opens the address in a browser and types the code. Video only, about two frames a second; the connection is not encrypted, so share only on a network you trust.",
            "Aynı Wi-Fi'deki kişi adresi tarayıcıda açıp kodu girer. Yalnızca görüntü, saniyede yaklaşık iki kare; bağlantı şifreli değildir, yalnızca güvendiğin ağda paylaş."))
        }
      } else {
        Section {
          Button {
            problem = server.start()
          } label: {
            Label(L.t("Start sharing my view", "Görüntümü paylaşmaya başla"), systemImage: "video.badge.waveform")
          }
          if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
          if let last = server.lastStop, last != .user {
            Text(L.t(RemoteAssistServer.stopSentence(last).1, RemoteAssistServer.stopSentence(last).0))
              .font(.caption).foregroundStyle(.secondary)
          }
        } footer: {
          Text(L.t(
            "Never starts by itself. While sharing, a red bar stays on screen; it stops when you say “paylaşımı durdur”, when the app leaves the screen, or after 15 minutes. Over the internet it needs a WebRTC server, which is not set up.",
            "Asla kendiliğinden başlamaz. Paylaşım sürerken kırmızı bir çubuk ekranda kalır; “paylaşımı durdur” dediğinde, uygulama ekrandan çıktığında ya da 15 dakika sonunda durur. İnternet üzerinden paylaşım bir WebRTC sunucusu gerektirir; kurulu değil."))
        }
      }
    }
    .navigationTitle(L.t("Remote Assist", "Uzaktan yardım"))
  }
}

/// The bar shown on every screen while the view is shared.
struct RemoteAssistBar: View {
  @ObservedObject private var server = RemoteAssistServer.shared

  var body: some View {
    if server.isSharing {
      HStack(spacing: 10) {
        Circle().fill(Color.red).frame(width: 9, height: 9)
        Text(L.t("Sharing your view", "Görüntün paylaşılıyor") + (server.viewers > 0 ? " · \(server.viewers)" : ""))
          .font(.footnote.weight(.semibold))
        Spacer()
        Button(L.t("Stop", "Durdur")) { server.stop(.user) }
          .font(.footnote.weight(.bold))
          .buttonStyle(.borderedProminent)
          .tint(.red)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(Color.red.opacity(0.18))
    }
  }
}
