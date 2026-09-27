import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import VideoToolbox
import XCTest

@testable import GlassifAI

private func makePixelBuffer(width: Int, height: Int, format: OSType, fill: UInt8) -> CVPixelBuffer {
  var buffer: CVPixelBuffer?
  let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
  CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
  let pixelBuffer = buffer!
  CVPixelBufferLockBaseAddress(pixelBuffer, [])
  if CVPixelBufferIsPlanar(pixelBuffer) {
    for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
      memset(
        CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane), Int32(fill),
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
    }
  } else {
    memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(fill), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
  return pixelBuffer
}

private func makeImageSample(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer {
  var format: CMVideoFormatDescription?
  CMVideoFormatDescriptionCreateForImageBuffer(
    allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
  var timing = CMSampleTimingInfo(
    duration: .invalid, presentationTimeStamp: CMTime(value: 1, timescale: 30), decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  CMSampleBufferCreateReadyWithImageBuffer(
    allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format!,
    sampleTiming: &timing, sampleBufferOut: &sample)
  return sample!
}

private func makeJPEG(width: Int, height: Int) -> Data {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let image = context.makeImage()!
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
  CGImageDestinationFinalize(destination)
  return data as Data
}

/// Encodes one keyframe with VideoToolbox so the compressed-frame path can be
/// tested without glasses.
private func makeCompressedSample(width: Int = 320, height: Int = 240) throws -> CMSampleBuffer {
  var session: VTCompressionSession?
  let status = VTCompressionSessionCreate(
    allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
    encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
    outputCallback: nil, refcon: nil, compressionSessionOut: &session)
  guard status == noErr, let session else { throw XCTSkip("H.264 encoder unavailable (\(status))") }
  defer { VTCompressionSessionInvalidate(session) }
  VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
  let pixelBuffer = makePixelBuffer(
    width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, fill: 100)
  var output: CMSampleBuffer?
  let done = DispatchSemaphore(value: 0)
  let encodeStatus = VTCompressionSessionEncodeFrame(
    session,
    imageBuffer: pixelBuffer,
    presentationTimeStamp: CMTime(value: 0, timescale: 30),
    duration: .invalid,
    frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
    infoFlagsOut: nil
  ) { _, _, sample in
    output = sample
    done.signal()
  }
  guard encodeStatus == noErr else { throw XCTSkip("H.264 encode failed (\(encodeStatus))") }
  VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
  _ = done.wait(timeout: .now() + 5)
  guard let output else { throw XCTSkip("encoder produced no sample") }
  return output
}

final class AutoLoomVisionTests: XCTestCase {

  // MARK: Ray-Ban frames reach the vision store

  func testRawRayBanFrameReachesFrameStore() {
    let store = FrameStore()
    let ingestor = GlassesFrameIngestor(store: store)
    let pixelBuffer = makePixelBuffer(
      width: 504, height: 896, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, fill: 60)
    let result = ingestor.handle(makeImageSample(pixelBuffer))
    XCTAssertTrue(result.handled)
    XCTAssertTrue(result.isFirstFrame)
    let frame = store.freshFrame(maxAge: 1, source: .glasses)
    XCTAssertNotNil(frame)
    XCTAssertEqual(frame?.width, 504)
    XCTAssertFalse(frame?.pixelBuffer === pixelBuffer, "the SDK buffer must be released (copied)")
    let snapshot = store.snapshot()
    XCTAssertEqual(snapshot.glassesCompressed, false)
    XCTAssertEqual(snapshot.rawSamples, 1)
  }

  func testCompressedRayBanFrameIsDecodedIntoFrameStore() throws {
    let store = FrameStore()
    let ingestor = GlassesFrameIngestor(store: store)
    let sample = try makeCompressedSample()
    XCTAssertNil(CMSampleBufferGetImageBuffer(sample))
    let info = GlassesFrameIngestor.describe(sample)
    XCTAssertTrue(info.compressed)
    XCTAssertEqual(info.codec, "avc1")
    XCTAssertEqual(info.width, 320)

    let result = ingestor.handle(sample)
    XCTAssertTrue(result.handled, "compressed frames are handled in the foreground, not only in background")
    let deadline = Date().addingTimeInterval(5)
    while store.latestFrame() == nil && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    let frame = store.freshFrame(maxAge: 5, source: .glasses)
    XCTAssertNotNil(frame, "a decoded glasses frame must be available to vision")
    XCTAssertEqual(frame?.width, 320)
    let snapshot = store.snapshot()
    XCTAssertEqual(snapshot.glassesCompressed, true)
    XCTAssertGreaterThanOrEqual(snapshot.decodedFrames, 1)
    XCTAssertEqual(snapshot.decodeFailures, 0)
  }

  func testWrongSourceAndStaleFramesAreRejectedAndSwitchClears() {
    let store = FrameStore()
    let buffer = makePixelBuffer(width: 64, height: 64, format: kCVPixelFormatType_32BGRA, fill: 3)
    store.ingest(pixelBuffer: buffer, source: .iPhone, presentationTime: .invalid)
    XCTAssertNil(store.freshFrame(maxAge: 1, source: .glasses), "an iPhone frame must never answer a Ray-Ban question")
    store.ingest(pixelBuffer: buffer, source: .glasses, presentationTime: .invalid, arrivedAt: CACurrentMediaTime() - 2)
    XCTAssertNil(store.freshFrame(maxAge: 1, source: .glasses), "stale frame rejected")
    store.ingest(pixelBuffer: buffer, source: .glasses, presentationTime: .invalid)
    XCTAssertNotNil(store.freshFrame(maxAge: 1, source: .glasses))
    store.reset()  // what a camera-source switch does
    XCTAssertNil(store.latestFrame())
  }

  // MARK: Still photos

  func testStillPhotoIsAcceptedOnlyForThePendingRequest() async {
    let coordinator = StillPhotoCoordinator()
    let jpeg = makeJPEG(width: 720, height: 1280)
    XCTAssertFalse(coordinator.deliver(jpeg), "a shutter-button photo with no pending request is ignored")

    let photo = await coordinator.capture(timeout: 2) {
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { coordinator.deliver(jpeg) }
      return true
    }
    XCTAssertEqual(photo?.width, 720)
    XCTAssertEqual(photo?.height, 1280)
    XCTAssertFalse(coordinator.isCapturing)
  }

  func testLatePhotoIsRejected() async {
    let coordinator = StillPhotoCoordinator()
    let photo = await coordinator.capture(timeout: 0.2) { true }
    XCTAssertNil(photo, "no photo before the timeout")
    XCTAssertFalse(coordinator.deliver(makeJPEG(width: 32, height: 32)), "late photo must not be used")
  }

  func testRefusedCaptureAndSecondCaptureInFlight() async {
    let coordinator = StillPhotoCoordinator()
    let refused = await coordinator.capture(timeout: 2) { false }
    XCTAssertNil(refused)

    async let first = coordinator.capture(timeout: 0.5) { true }
    try? await Task.sleep(nanoseconds: 50_000_000)
    let second = await coordinator.capture(timeout: 0.5) { true }
    XCTAssertNil(second, "only one capture may be in flight")
    _ = await first
  }

  func testPhotoProcessorPassesThroughOrFitsToProfile() {
    let small = makeJPEG(width: 720, height: 1280)
    let passed = StillPhotoProcessor.prepare(small, detail: .high)
    XCTAssertEqual(passed?.reencoded, false, "a photo that already fits is not recompressed")
    XCTAssertEqual(passed?.jpeg, small)

    let large = makeJPEG(width: 4032, height: 3024)
    let fitted = StillPhotoProcessor.prepare(large, detail: .high)
    XCTAssertNotNil(fitted)
    XCTAssertEqual(fitted?.reencoded, true)
    XCTAssertLessThanOrEqual(max(fitted?.width ?? 0, fitted?.height ?? 0), 2_048)
    XCTAssertLessThanOrEqual(
      VisionDetail.patches(width: fitted?.width ?? 0, height: fitted?.height ?? 0), VisionDetail.maxPatches)
  }

  // MARK: Vision profiles and routing

  func testVisionProfilesRespectEndpointLimits() {
    let rayBan = VisionDetail.standard.fittedSize(width: 720, height: 1280)
    XCTAssertEqual(rayBan.width, 720)
    XCTAssertEqual(rayBan.height, 1280, "the Ray-Ban stream is never downscaled")
    let phone = VisionDetail.standard.fittedSize(width: 1080, height: 1920)
    XCTAssertEqual(phone.height, 1280)
    let phoneHigh = VisionDetail.high.fittedSize(width: 1080, height: 1920)
    XCTAssertEqual(phoneHigh.height, 1920, "high detail keeps the full iPhone frame")
    let photo = VisionDetail.high.fittedSize(width: 4032, height: 3024)
    XCTAssertLessThanOrEqual(max(photo.width, photo.height), 2_048)
    XCTAssertLessThanOrEqual(VisionDetail.patches(width: photo.width, height: photo.height), VisionDetail.maxPatches)
  }

  func testReadingRequestsUseHighDetail() {
    XCTAssertEqual(DelegationEnvelopeParser.parse("TASK: vision_read | QUERY: Önümdeki yazıyı oku")?.detail, .high)
    XCTAssertEqual(DelegationEnvelopeParser.parse("TASK: vision_read | QUERY: read the VIN")?.command, .task(.vision))
    XCTAssertEqual(DelegationEnvelopeParser.parse("TASK: vision | QUERY: what is this")?.detail, .standard)
    XCTAssertEqual(DelegationEnvelopeParser.parse("TASK: vision_web | QUERY: price of this")?.detail, .high)
    XCTAssertEqual(DelegationEnvelopeParser.parse(#"{"task":"vision","query":"read it","detail":"high"}"#)?.detail, .high)
  }

  func testEncoderUsesHighDetailProfile() {
    let buffer = makePixelBuffer(width: 1080, height: 1920, format: kCVPixelFormatType_32BGRA, fill: 200)
    let standard = VisionFrameEncoder.encode(buffer, detail: .standard, useCPU: true)
    let high = VisionFrameEncoder.encode(buffer, detail: .high, useCPU: true)
    XCTAssertEqual(standard?.height, 1280)
    XCTAssertEqual(high?.height, 1920)
    XCTAssertEqual(high?.quality, VisionDetail.high.jpegQuality)
  }
}

@MainActor
final class AutoLoomAssistantTests: XCTestCase {
  private var savedName: Any?

  override func setUp() async throws {
    savedName = UserDefaults.standard.object(forKey: AssistantIdentity.nameKey)
  }

  override func tearDown() async throws {
    if let savedName {
      UserDefaults.standard.set(savedName, forKey: AssistantIdentity.nameKey)
    } else {
      UserDefaults.standard.removeObject(forKey: AssistantIdentity.nameKey)
    }
  }

  func testAssistantNameValidation() {
    XCTAssertEqual(AssistantIdentity.sanitize("  Jarvis  "), "Jarvis")
    XCTAssertEqual(AssistantIdentity.sanitize("Nova-2"), "Nova-2")
    XCTAssertEqual(AssistantIdentity.sanitize("Çağrı"), "Çağrı")
    XCTAssertEqual(AssistantIdentity.sanitize("Mr   Loom"), "Mr Loom")
    XCTAssertNil(AssistantIdentity.sanitize(""))
    XCTAssertNil(AssistantIdentity.sanitize("    "))
    XCTAssertNil(AssistantIdentity.sanitize("12345"), "needs at least one letter")
    XCTAssertNil(AssistantIdentity.sanitize(String(repeating: "a", count: 40)))
  }

  func testAssistantNamePersistsAndInvalidFallsBackToDefault() {
    XCTAssertEqual(AssistantIdentity.setName("Jarvis"), "Jarvis")
    XCTAssertEqual(AssistantIdentity.name, "Jarvis")
    XCTAssertEqual(AssistantIdentity.setName("!!!"), AssistantIdentity.defaultName)
    XCTAssertEqual(AssistantIdentity.name, AssistantIdentity.defaultName)
  }

  func testAssistantNameAppearsInRealtimeInstructions() {
    let text = AssistantInstructions.realtime(memory: [], assistantName: "Jarvis")
    XCTAssertTrue(text.contains("Your name is Jarvis."))
    XCTAssertTrue(text.contains("Jarvis, what am I looking at?"))
    XCTAssertTrue(text.contains("Do not start answers with your name"))
    XCTAssertTrue(text.contains("vision_read"))
    AssistantIdentity.setName("Friday")
    XCTAssertTrue(AssistantInstructions.realtime(memory: []).contains("Your name is Friday."))
  }

  func testChangingNameKeepsOtherSettings() {
    let defaults = UserDefaults.standard
    let voice = defaults.object(forKey: AssistantPreferences.voiceKey)
    let language = defaults.object(forKey: AssistantPreferences.languageKey)
    defaults.set("marin", forKey: AssistantPreferences.voiceKey)
    defaults.set("tr", forKey: AssistantPreferences.languageKey)
    defer {
      defaults.set(voice, forKey: AssistantPreferences.voiceKey)
      defaults.set(language, forKey: AssistantPreferences.languageKey)
    }
    AssistantIdentity.setName("Alfred")
    XCTAssertEqual(AssistantPreferences.voice, "marin")
    XCTAssertEqual(AssistantPreferences.language, "tr")
  }

  // MARK: Invocation → voice session

  func testInvocationCannotStartTwoSessions() async {
    let coordinator = VoiceStartCoordinator()
    var starts = 0
    var active = false
    coordinator.register(isActive: { active }) { _ in
      starts += 1
      try? await Task.sleep(nanoseconds: 100_000_000)
      active = true
    }
    async let first = coordinator.request(.metaInvocation)
    async let second = coordinator.request(.button)
    let outcomes = await [first, second]
    XCTAssertEqual(starts, 1)
    XCTAssertTrue(outcomes.contains(.started))
    XCTAssertTrue(outcomes.contains(.alreadyActive))
    let third = await coordinator.request(.siriShortcut)
    XCTAssertEqual(third, .alreadyActive, "an active conversation is never restarted")
    XCTAssertEqual(starts, 1)
  }

  func testInvocationBeforeTheScreenIsReadyRunsOnce() async {
    let coordinator = VoiceStartCoordinator()
    let queued = await coordinator.request(.siriShortcut)
    XCTAssertEqual(queued, .queued)
    var starts = 0
    var active = false
    let started = expectation(description: "queued start runs")
    coordinator.register(isActive: { active }) { _ in
      starts += 1
      active = true
      started.fulfill()
    }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertEqual(starts, 1)
  }
}
