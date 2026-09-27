import AVFoundation
import CoreImage
import SwiftUI
import UIKit

@MainActor
final class GlassifAICamera: NSObject, ObservableObject {
  @Published private(set) var isRunning = false
  @Published private(set) var errorMessage: String?

  let captureSession = AVCaptureSession()

  private let sessionQueue = DispatchQueue(label: "ai.glassifai.camera.session")
  private let outputQueue = DispatchQueue(label: "ai.glassifai.camera.frames")
  private let frameThrottle = FrameThrottle(minimumInterval: 0.1)
  private var configured = false

  func start() async {
    let authorized = await requestPermission()
    guard authorized else {
      errorMessage = "Camera access is required to let GlassifAI see with your iPhone."
      return
    }
    do {
      try await configureIfNeeded()
      await withCheckedContinuation { continuation in
        sessionQueue.async { [captureSession] in
          if !captureSession.isRunning { captureSession.startRunning() }
          continuation.resume()
        }
      }
      isRunning = true
      errorMessage = nil
    } catch {
      errorMessage = "The iPhone camera could not start."
    }
  }

  func stop() async {
    await withCheckedContinuation { continuation in
      sessionQueue.async { [captureSession] in
        if captureSession.isRunning { captureSession.stopRunning() }
        continuation.resume()
      }
    }
    isRunning = false
  }

  private func requestPermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
    default: return false
    }
  }

  private func configureIfNeeded() async throws {
    guard !configured else { return }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      sessionQueue.async { [weak self] in
        guard let self else {
          continuation.resume(throwing: CameraError.unavailable)
          return
        }
        do {
          self.captureSession.beginConfiguration()
          defer { self.captureSession.commitConfiguration() }
          self.captureSession.sessionPreset = .high
          guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.unavailable
          }
          let input = try AVCaptureDeviceInput(device: device)
          guard self.captureSession.canAddInput(input) else { throw CameraError.unavailable }
          self.captureSession.addInput(input)

          let output = AVCaptureVideoDataOutput()
          output.alwaysDiscardsLateVideoFrames = true
          output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
          ]
          output.setSampleBufferDelegate(self, queue: self.outputQueue)
          guard self.captureSession.canAddOutput(output) else { throw CameraError.unavailable }
          self.captureSession.addOutput(output)
          if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
          }
          self.configured = true
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

extension GlassifAICamera: AVCaptureVideoDataOutputSampleBufferDelegate {
  nonisolated func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    // The preview layer draws the camera itself. Here we only keep the newest
    // frame (at most ten per second) for vision requests: no main-thread hop,
    // no per-frame image conversion, and only one retained capture buffer.
    guard frameThrottle.shouldAccept(),
          let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    FrameStore.shared.ingest(
      pixelBuffer: pixelBuffer,
      source: .iPhone,
      presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
  }
}

/// Lock-protected rate limiter used on capture callback queues.
final class FrameThrottle: @unchecked Sendable {
  private let minimumInterval: CFTimeInterval
  private let lock = NSLock()
  private var last: CFTimeInterval = 0

  init(minimumInterval: CFTimeInterval) {
    self.minimumInterval = minimumInterval
  }

  func shouldAccept(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard now - last >= minimumInterval else { return false }
    last = now
    return true
  }
}

struct GlassifAICameraPreview: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    return view
  }

  func updateUIView(_ uiView: PreviewView, context: Context) {
    uiView.previewLayer.session = session
  }

  final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  }
}

private enum CameraError: Error {
  case unavailable
}
