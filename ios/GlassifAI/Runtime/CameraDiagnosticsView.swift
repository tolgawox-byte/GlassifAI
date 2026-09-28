import SwiftUI

/// Settings → Developer → Camera diagnostics. Every technical camera number
/// lives here; the assistant screen shows none of them.
struct CameraDiagnosticsView: View {
  var glassesStream: StreamSessionViewModel?
  @ObservedObject private var lifecycle = GlassesLifecycleMonitor.shared
  @State private var metrics = FrameMetricsSnapshot()
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue

  var body: some View {
    List {
      Section("Pipeline") {
        row("State", lifecycle.state.rawValue)
        row("Vision available", lifecycle.state.allowsVision ? "yes" : "no")
        row("Screen locked", lifecycle.screenLocked ? "yes" : "no")
        row("Transport", glassesStream?.activeTransport.shortLabel ?? "—")
        if let note = glassesStream?.transportNote { row("Transport note", note) }
        row("DAT SDK", GlassesSDKInfo.datVersion)
        row("Stream state", glassesStream?.lastStreamState ?? "—")
      }
      Section("Glasses frames") {
        row("Requested", glassesStream.map { "\($0.streamProfile.requestedSummary), \($0.activeTransport.shortLabel)" } ?? "—")
        row("Actual", metrics.inputWidth > 0 ? "\(metrics.inputResolution) @ \(String(format: "%.1f", metrics.measuredFPS)) fps" : "no frames")
        row("Codec / sample size", "\(metrics.glassesCodec) · \(metrics.glassesSampleSize)")
        row("Samples raw / compressed", "\(metrics.rawSamples) / \(metrics.compressedSamples)")
        row("Decoded / failures", "\(metrics.decodedFrames) / \(metrics.decodeFailures)")
        row("Background samples / decoded / failures",
            "\(metrics.backgroundSamples) / \(metrics.backgroundDecoded) / \(metrics.backgroundFailures)")
        row("Waiting for keyframe (skipped)", "\(metrics.keyframeWaits)")
        row("Decoder", metrics.softwareDecode ? "software (hardware refused)" : "hardware")
        row("Last decode error",
            metrics.lastDecodeError.map { "\($0), \((metrics.lastDecodeErrorAgeMs ?? 0) / 1_000) s ago" } ?? "none")
        row("Last sample", metrics.lastSampleAgeMs.map { "\($0) ms ago" } ?? "—")
        row("Last frame age", metrics.lastFrameAgeMs.map { "\($0) ms" } ?? "—")
        row("Frame sequence", "\(metrics.latestSequence)")
      }
      Section("Live metrics") {
        if let glassesStream {
          DeveloperOverlay(
            captureSource: CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera,
            glassesStream: glassesStream,
            metrics: metrics)
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        }
        row("Preview", "\(metrics.previewMode) · rendered \(metrics.previewRendered) · dropped \(metrics.previewDropped)")
        row("Processing median / p95", "\(ms(metrics.processingMedianMs)) / \(ms(metrics.processingP95Ms))")
        row("Capture→phone median / p95", "\(ms(metrics.transportMedianMs)) / \(ms(metrics.transportP95Ms))")
      }
      Section("Last image sent to the AI (metadata only)") {
        Text(metrics.lastVisionImage)
          .font(.caption.monospaced())
          .textSelection(.enabled)
        row("Photos requested / received / failed", "\(metrics.photosRequested) / \(metrics.photosReceived) / \(metrics.photoFailures)")
        row("Last photo", "\(metrics.lastPhotoResolution)" + (metrics.lastPhotoLatencyMs.map { " in \($0) ms" } ?? ""))
      }
      Section("Lifecycle transitions") {
        if lifecycle.transitions.isEmpty {
          Text("None yet").foregroundStyle(.secondary)
        }
        ForEach(Array(lifecycle.transitions.reversed())) { transition in
          VStack(alignment: .leading, spacing: 2) {
            Text("\(transition.at.formatted(date: .omitted, time: .standard))  \(transition.from.rawValue) → \(transition.to.rawValue)")
              .font(.caption.weight(.semibold))
            Text(transition.detail)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
      Section {
        Text("Lock-screen test: start a conversation with the Ray-Ban camera, lock the phone, wait 10 s, ask what you are looking at, turn to another object and ask again. The transitions above show whether frames kept arriving and decoding while locked.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Camera diagnostics")
    .task {
      while !Task.isCancelled {
        metrics = FrameStore.shared.snapshot()
        lifecycle.evaluate(reason: nil)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(title).font(.footnote)
      Spacer(minLength: 12)
      Text(value)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }

  private func ms(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0) } ?? "—"
  }
}
