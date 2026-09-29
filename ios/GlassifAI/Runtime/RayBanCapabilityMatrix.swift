import SwiftUI

/// What the glasses can do with the linked Meta DAT SDK and this device.
/// A static table per SDK version (from Meta's documentation), refined by
/// runtime probes once DAT 1.0 is linked. Ray-Ban Meta Gen 1 is displayless:
/// nothing display-only is ever shown for it. See `docs/DAT1_MIGRATION.md`.
enum RayBanCapability: String, CaseIterable, Identifiable {
  case cameraStream, highQualityPhoto, audioStream, speech, voiceInvocation, motion, imu, inputs
  case backgroundVideo, backgroundAudio, display

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cameraStream: L.t("Camera stream", "Kamera akışı")
    case .highQualityPhoto: L.t("High-quality photo", "Yüksek kaliteli fotoğraf")
    case .audioStream: L.t("Glasses audio in the stream", "Akışta gözlük sesi")
    case .speech: L.t("Speech recognition on the glasses", "Gözlükte konuşma tanıma")
    case .voiceInvocation: L.t("\"Hey Meta, start AutoLoom\"", "\"Hey Meta, AutoLoom'u başlat\"")
    case .motion: L.t("Motion", "Hareket")
    case .imu: L.t("IMU (accelerometer, gyroscope)", "IMU (ivmeölçer, jiroskop)")
    case .inputs: L.t("Touchpad and capture button", "Dokunmatik yüzey ve çekim düğmesi")
    case .backgroundVideo: L.t("Video with the phone locked", "Telefon kilitliyken video")
    case .backgroundAudio: L.t("Audio with the phone locked", "Telefon kilitliyken ses")
    case .display: L.t("Display", "Ekran")
    }
  }

  /// How it works today, in one line.
  var detail: String {
    switch self {
    case .cameraStream: "DAT Stream, raw or HEVC (hvc1), up to 720×1280, 2–30 fps."
    case .highQualityPhoto: "DAT 1.0 Camera.photo, up to 4032×3024; cannot run while the stream runs. Today: the in-stream capturePhoto JPEG."
    case .audioStream: "DAT 1.0 in-stream PCM audio (beta, dev channels). Today: Bluetooth HFP 8 kHz through iOS."
    case .speech: "DAT 1.0 on-glasses ASR (beta, fixed locale; Turkish unconfirmed). Today: the phone's recogniser over HFP."
    case .voiceInvocation: "DAT 1.0 VoiceInvocationsStream: only launches the app (no spoken request); needs Meta approval."
    case .motion: "DAT 1.0 addMotion, 5–60 Hz (beta)."
    case .imu: "Accelerometer and gyroscope via addMotion; the magnetometer is always nil on Ray-Ban Meta."
    case .inputs: "DAT 1.0 addInputs: touchpad swipes and taps, capture button (beta)."
    case .backgroundVideo: "HEVC keeps streaming in the background with a software decoder; raw pauses."
    case .backgroundAudio: "HFP plus the audio background mode, at the iOS level."
    case .display: "Meta Ray-Ban Display only; Ray-Ban Meta Gen 1 has no display."
    }
  }
}

enum RayBanCapabilityState: String {
  /// Works with the linked SDK on this device class.
  case available
  /// In the SDK but beta: developer / beta release channels only.
  case experimentalDevOnly
  /// In the SDK; support differs per device, decided at runtime.
  case probe
  /// Needs DAT 1.0 (not linked in this build).
  case waitingForDAT1
  case unavailable

  var status: CapabilityStatus {
    switch self {
    case .available: .physicalTestRequired
    case .experimentalDevOnly, .probe: .experimental
    case .waitingForDAT1: .waitingForDAT1
    case .unavailable: .unavailable
    }
  }
}

struct RayBanCapabilityMatrix: Equatable {
  /// The linked Meta Wearables DAT SDK (updated with the package pin).
  static let linkedSDKVersion = "0.5.0"

  let sdkVersion: String
  let deviceHasDisplay: Bool
  /// Runtime results that override the table ("probe" → available / unavailable).
  var probes: [RayBanCapability: Bool] = [:]

  var isDAT1: Bool { (sdkVersion.split(separator: ".").first.flatMap { Int($0) } ?? 0) >= 1 }

  /// Ray-Ban Meta Gen 1 on the linked SDK.
  static let current = RayBanCapabilityMatrix(sdkVersion: linkedSDKVersion, deviceHasDisplay: false)

  func state(_ capability: RayBanCapability) -> RayBanCapabilityState {
    if let probed = probes[capability] { return probed ? .available : .unavailable }
    switch capability {
    case .cameraStream, .backgroundVideo, .backgroundAudio:
      return .available
    case .display:
      return deviceHasDisplay && isDAT1 ? .available : .unavailable
    case .highQualityPhoto, .audioStream, .speech, .motion, .imu, .inputs:
      return isDAT1 ? .experimentalDevOnly : .waitingForDAT1
    case .voiceInvocation:
      return isDAT1 ? .probe : .waitingForDAT1
    }
  }

  func supports(_ capability: RayBanCapability) -> Bool {
    state(capability) == .available
  }

  /// Never show display-only UI on displayless glasses.
  var showsDisplayUI: Bool { supports(.display) }
}

/// Settings → Developer → Ray-Ban capabilities.
struct RayBanCapabilitiesView: View {
  private let matrix = RayBanCapabilityMatrix.current

  var body: some View {
    List {
      Section {
        LabeledContent("Meta DAT SDK", value: matrix.sdkVersion)
        LabeledContent(L.t("Glasses", "Gözlük"), value: "Ray-Ban Meta Gen 1 · " + L.t("no display", "ekransız"))
      } footer: {
        Text(L.t(
          "DAT 1.0 rolls out from 30 September 2026 (glasses firmware V128, Meta AI V290). Its new features are beta and only work in developer or beta release channels; they switch on here after the SDK update and a device check.",
          "DAT 1.0 30 Eylül 2026'dan itibaren dağıtılıyor (gözlük yazılımı V128, Meta AI V290). Yeni özellikleri beta; yalnız geliştirici ya da beta kanallarında çalışıyor. SDK güncellemesi ve cihaz kontrolünden sonra burada açılırlar."))
      }
      Section(L.t("Capabilities", "Yetenekler")) {
        ForEach(RayBanCapability.allCases) { capability in
          let state = matrix.state(capability)
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Text(capability.title).font(.subheadline.weight(.semibold))
              Spacer()
              Text(state.status.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color(state))
            }
            Text(capability.detail).font(.caption).foregroundStyle(.secondary)
          }
          .padding(.vertical, 2)
        }
      }
    }
    .navigationTitle(L.t("Ray-Ban capabilities", "Ray-Ban yetenekleri"))
  }

  private func color(_ state: RayBanCapabilityState) -> Color {
    switch state {
    case .available: .green
    case .experimentalDevOnly, .probe: .orange
    case .waitingForDAT1: AutoLoomTheme.electricBlue
    case .unavailable: .secondary
    }
  }
}
