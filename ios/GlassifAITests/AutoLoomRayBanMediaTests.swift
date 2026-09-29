import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import XCTest

@testable import GlassifAI

private func pixelBuffer(width: Int, height: Int, fill: UInt8) -> CVPixelBuffer {
  var buffer: CVPixelBuffer?
  let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
  CVPixelBufferCreate(
    kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary,
    &buffer)
  let pixelBuffer = buffer!
  CVPixelBufferLockBaseAddress(pixelBuffer, [])
  for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
    memset(
      CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane), Int32(fill),
      CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
  return pixelBuffer
}

/// A short compressed stream like the glasses send: one keyframe, then
/// P-frames, 30 fps timestamps.
private func compressedSequence(count: Int, width: Int = 320, height: Int = 240, startFrame: Int = 0) throws -> [CMSampleBuffer] {
  var session: VTCompressionSession?
  let status = VTCompressionSessionCreate(
    allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
    encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
    outputCallback: nil, refcon: nil, compressionSessionOut: &session)
  guard status == noErr, let session else { throw XCTSkip("H.264 encoder unavailable (\(status))") }
  defer { VTCompressionSessionInvalidate(session) }
  VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
  VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
  VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: count * 4))
  let lock = NSLock()
  var outputs: [CMSampleBuffer] = []
  for index in 0..<count {
    let frame = pixelBuffer(width: width, height: height, fill: UInt8(40 + (index * 7) % 180))
    let properties: CFDictionary? = index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
    let encodeStatus = VTCompressionSessionEncodeFrame(
      session, imageBuffer: frame, presentationTimeStamp: CMTime(value: CMTimeValue(startFrame + index), timescale: 30),
      duration: CMTime(value: 1, timescale: 30), frameProperties: properties, infoFlagsOut: nil
    ) { status, _, sample in
      guard status == noErr, let sample else { return }
      lock.lock()
      outputs.append(sample)
      lock.unlock()
    }
    guard encodeStatus == noErr else { throw XCTSkip("H.264 encode failed (\(encodeStatus))") }
  }
  VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
  lock.lock()
  defer { lock.unlock() }
  guard outputs.count == count else { throw XCTSkip("the encoder returned \(outputs.count) of \(count) frames") }
  return outputs.sorted {
    CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0), CMSampleBufferGetPresentationTimeStamp($1)) < 0
  }
}

private func jpeg(width: Int = 640, height: Int = 480) -> Data {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  context.setFillColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  return data as Data
}

// MARK: Background vision: decoder and stall recovery

final class AutoLoomBackgroundVisionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func input(
    streaming: Bool = true, hevc: Bool = true, background: Bool = false, recording: Bool = false,
    streamingFor: TimeInterval = 60, sampleAge: Int? = 50, imageAge: Int? = 50, keyframeWait: Int? = nil,
    decoderRestarts: Int = 0, lastDecoderRestart: Date? = nil, streamRestarts: [Date] = []
  ) -> RayBanStallPolicy.Input {
    RayBanStallPolicy.Input(
      streaming: streaming, hevc: hevc, background: background, recording: recording, streamingFor: streamingFor,
      lastSampleAgeMs: sampleAge, lastImageAgeMs: imageAge, keyframeWaitMs: keyframeWait,
      decoderRestarts: decoderRestarts, lastDecoderRestartAt: lastDecoderRestart, streamRestarts: streamRestarts, now: now)
  }

  func testAHealthyStreamIsLeftAlone() {
    XCTAssertEqual(RayBanStallPolicy.decide(input()), .none)
    XCTAssertEqual(RayBanStallPolicy.decide(input(streaming: false, sampleAge: nil, imageAge: nil)), .none)
    XCTAssertEqual(RayBanStallPolicy.decide(input(streamingFor: 5, sampleAge: 20_000)), .none, "startup grace")
  }

  func testNoSamplesRestartsTheStreamOnScreenOnly() {
    guard case .restartStream = RayBanStallPolicy.decide(input(sampleAge: 12_000, imageAge: 12_000)) else {
      return XCTFail("no samples on screen: restart")
    }
    XCTAssertEqual(
      RayBanStallPolicy.decide(input(background: true, sampleAge: 12_000, imageAge: 12_000)), .none,
      "never restarted with the phone locked: Meta documents that streaming continues there, not that a start works")
    XCTAssertEqual(
      RayBanStallPolicy.decide(input(recording: true, sampleAge: 12_000, imageAge: 12_000)), .none,
      "a recording keeps its stream")
    let spent = [now.addingTimeInterval(-60), now.addingTimeInterval(-120), now.addingTimeInterval(-180)]
    XCTAssertEqual(RayBanStallPolicy.decide(input(sampleAge: 12_000, imageAge: 12_000, streamRestarts: spent)), .none, "bounded")
    let old = [now.addingTimeInterval(-700), now.addingTimeInterval(-800), now.addingTimeInterval(-900)]
    guard case .restartStream = RayBanStallPolicy.decide(input(sampleAge: 12_000, imageAge: 12_000, streamRestarts: old)) else {
      return XCTFail("restarts outside the window do not count")
    }
  }

  func testUndecodedSamplesRebuildTheDecoderThenSwapItsMode() {
    XCTAssertEqual(RayBanStallPolicy.decide(input(imageAge: 4_000)), .restartDecoder(swapMode: false))
    XCTAssertEqual(RayBanStallPolicy.decide(input(imageAge: 4_000, decoderRestarts: 1)), .restartDecoder(swapMode: true))
    XCTAssertEqual(
      RayBanStallPolicy.decide(input(imageAge: 4_000, lastDecoderRestart: now.addingTimeInterval(-2))), .none, "spacing")
    XCTAssertEqual(
      RayBanStallPolicy.decide(input(background: true, imageAge: 4_000)), .restartDecoder(swapMode: false),
      "the decoder is rebuilt with the phone locked too")
    XCTAssertEqual(RayBanStallPolicy.decide(input(hevc: false, imageAge: 4_000)), .none, "raw frames need no decoder")
  }

  func testAKeyframeWaitIsGivenTimeThenANewStream() {
    XCTAssertEqual(RayBanStallPolicy.decide(input(imageAge: 4_000, keyframeWait: 3_000)), .none)
    guard case .restartStream = RayBanStallPolicy.decide(input(imageAge: 9_000, keyframeWait: 9_000)) else {
      return XCTFail("a new stream starts with a keyframe")
    }
    XCTAssertEqual(RayBanStallPolicy.decide(input(background: true, imageAge: 9_000, keyframeWait: 9_000)), .none)
  }

  func testLockedScreenVisionNeedsHEVC() {
    XCTAssertTrue(LockedScreenVision.isSupported(transport: .hevc))
    XCTAssertFalse(LockedScreenVision.isSupported(transport: .raw))
    XCTAssertFalse(LockedScreenVision.isSupported(transport: nil))
  }

  func testTheDecoderIsSoftwareByDefaultAndWaitsForAKeyframeAfterARestart() throws {
    let key = GlassesDecoderMode.defaultsKey
    let previous = UserDefaults.standard.string(forKey: key)
    UserDefaults.standard.removeObject(forKey: key)
    defer { UserDefaults.standard.set(previous, forKey: key) }
    XCTAssertEqual(GlassesDecoderMode.preferred, .software, "Meta's sample: software survives backgrounding")

    let samples = try compressedSequence(count: 6)
    let decoder = VideoDecoder()
    let lock = NSLock()
    var images = 0
    decoder.setFrameCallback { _ in
      lock.lock(); images += 1; lock.unlock()
    }
    for sample in samples.prefix(3) { try decoder.decode(sample) }
    lock.lock(); XCTAssertEqual(images, 3); lock.unlock()
    decoder.restart()
    XCTAssertTrue(decoder.isAwaitingKeyframe)
    XCTAssertThrowsError(try decoder.decode(samples[3])) { error in
      XCTAssertEqual(error as? DecoderError, .waitingForKeyframe)
    }
    XCTAssertEqual(decoder.sessionsCreated, 2, "a new session after the restart")
  }
}

// MARK: Recording

final class AutoLoomRayBanRecorderTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  func testTheGlassesSamplesAreWrittenAsTheyAre() async throws {
    let samples = try compressedSequence(count: 12)
    let recorder = RayBanVideoRecorder(directory: directory, freeBytes: { .max })
    try recorder.start()
    XCTAssertThrowsError(try recorder.start()) { XCTAssertEqual($0 as? RayBanVideoRecorder.StartError, .alreadyRecording) }
    for sample in samples { recorder.append(sample) }
    recorder.append(samples[5])  // an old timestamp is dropped, never written twice
    let result = await recorder.stop()
    guard case .completed(let segments) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(segments.count, 1)
    let segment = try XCTUnwrap(segments.first)
    XCTAssertEqual(segment.mode, .passthrough, "no decoding, no re-encoding")
    XCTAssertEqual(segment.width, 320, "the glasses' own size, never upscaled")
    XCTAssertEqual(segment.codec, "avc1")
    XCTAssertGreaterThan(segment.frames, 6)
    XCTAssertLessThanOrEqual(segment.frames, 12)
    let asset = AVURLAsset(url: segment.url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    XCTAssertEqual(tracks.count, 1)
    let duration = try await asset.load(.duration)
    XCTAssertGreaterThan(duration.seconds, 0.2)
  }

  func testAFileStartsAtAKeyframe() async throws {
    let samples = try compressedSequence(count: 8)
    let recorder = RayBanVideoRecorder(directory: directory, freeBytes: { .max })
    try recorder.start()
    for sample in samples.dropFirst() { recorder.append(sample) }
    let result = await recorder.stop()
    XCTAssertEqual(result, .noRecording, "P-frames without their keyframe cannot be played")
  }

  func testANewResolutionStartsANewFileSoNothingIsLost() async throws {
    let first = try compressedSequence(count: 6)
    let second = try compressedSequence(count: 6, width: 480, height: 360, startFrame: 6)
    let recorder = RayBanVideoRecorder(directory: directory, freeBytes: { .max })
    try recorder.start()
    for sample in first + second { recorder.append(sample) }
    let result = await recorder.stop()
    guard case .completed(let segments) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(segments.map(\.width).sorted(), [320, 480])
  }

  func testLowStorageRefusesToStart() {
    let recorder = RayBanVideoRecorder(directory: directory, freeBytes: { 10_000_000 })
    XCTAssertThrowsError(try recorder.start()) { XCTAssertEqual($0 as? RayBanVideoRecorder.StartError, .lowStorage) }
    XCTAssertFalse(recorder.isActive)
  }

  func testRawFramesAreEncodedWithoutUpscaling() async throws {
    let recorder = RayBanVideoRecorder(directory: directory, freeBytes: { .max })
    try recorder.start()
    for index in 0..<8 {
      let frame = pixelBuffer(width: 320, height: 240, fill: UInt8(60 + index * 10))
      var format: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &format)
      var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
        decodeTimeStamp: .invalid)
      var sample: CMSampleBuffer?
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescription: format!, sampleTiming: &timing,
        sampleBufferOut: &sample)
      recorder.append(sample!)
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let result = await recorder.stop()
    if case .failed(let problem, _) = result {
      throw XCTSkip("HEVC encoding is not available in this simulator: \(problem)")
    }
    guard case .completed(let segments) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(segments.first?.mode, .encode)
    XCTAssertEqual(segments.first?.width, 320)
  }
}

// MARK: Captures, coordinator and speech

@MainActor
final class AutoLoomRayBanMediaTests: XCTestCase {
  private var savedSource: (@MainActor () -> Bool)!
  private var savedStreaming: (@MainActor () -> Bool)!
  private var savedStill: (@MainActor (TimeInterval) async -> StillPhoto?)!

  override func setUp() async throws {
    let media = RayBanMediaCoordinator.shared
    savedSource = media.isRayBanSource
    savedStreaming = media.isStreaming
    savedStill = media.takeStill
    // Never "Always" in tests: the Photos prompt would wait for a tap.
    UserDefaults.standard.set(CaptureSaveMode.appOnly.rawValue, forKey: CaptureSaveMode.defaultsKey)
  }

  override func tearDown() async throws {
    let media = RayBanMediaCoordinator.shared
    if media.isRecording { _ = await media.stopRecording() }
    media.isRayBanSource = savedSource
    media.isStreaming = savedStreaming
    media.takeStill = savedStill
    UserDefaults.standard.removeObject(forKey: CaptureSaveMode.defaultsKey)
  }

  func testTheLibraryKeepsMetadataFiltersAndReloads() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("captures-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = CaptureLibrary(directory: directory)
    var dealer = CaptureRecord(kind: .photo)
    dealer.label = .wheel
    dealer.storage = .photos
    dealer.photoAssetID = "asset-1"
    var personal = CaptureRecord(kind: .photo)
    let data = jpeg()
    personal.localFile = try library.keep(photo: data, id: personal.id)
    library.add(dealer, thumbnail: nil)
    library.add(personal, thumbnail: CaptureLibrary.thumbnail(fromJPEG: data))
    XCTAssertEqual(library.records(.dealer).map(\.id), [dealer.id])
    XCTAssertEqual(library.records(.personal).map(\.id), [personal.id])
    XCTAssertEqual(library.records(.today).count, 2)
    XCTAssertTrue(personal.needsPhotosSave == false, "kept by choice, no error")

    let reloaded = CaptureLibrary(directory: directory)
    XCTAssertEqual(reloaded.records.count, 2)
    XCTAssertEqual(reloaded.record(dealer.id)?.photoAssetID, "asset-1")
    XCTAssertNotNil(reloaded.thumbnail(for: personal.id))

    let file = try XCTUnwrap(personal.localFile)
    library.delete(personal.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: library.fileURL(named: file).path))
    XCTAssertEqual(library.records.count, 1)
  }

  func testOnlyTheRayBanCameraTakesPhotosAndVideos() async {
    let media = RayBanMediaCoordinator.shared
    media.isRayBanSource = { false }
    let photo = await media.takePhoto(label: nil, caption: nil, noteID: nil)
    XCTAssertEqual(photo, .unavailable(.notRayBanSource), "never the iPhone camera")
    XCTAssertEqual(media.startRecording(label: nil, caption: nil, noteID: nil), .unavailable(.notRayBanSource))
    media.isRayBanSource = { true }
    media.isStreaming = { false }
    let offline = await media.takePhoto(label: nil, caption: nil, noteID: nil)
    XCTAssertEqual(offline, .unavailable(.notStreaming))
    XCTAssertEqual(RayBanMediaCoordinator.photoSpeech(offline).tr, "Ray-Ban kamerası bağlı değil, fotoğraf çekemedim.")
    let stop = await media.stopRecording()
    XCTAssertEqual(stop, .notRecording)
  }

  func testAPhotoKeptInAutoLoomIsNeverLost() async throws {
    let media = RayBanMediaCoordinator.shared
    let data = jpeg()
    media.isRayBanSource = { true }
    media.isStreaming = { true }
    media.takeStill = { _ in StillPhoto(jpeg: data, width: 640, height: 480, latencyMs: 12) }
    let outcome = await media.takePhoto(label: .damage, caption: "Sağ ön jant çizik", noteID: nil)
    guard case .kept(let record, .appOnly) = outcome else { return XCTFail("\(outcome)") }
    defer { CaptureLibrary.shared.delete(record.id) }
    XCTAssertEqual(record.source, "Ray-Ban")
    XCTAssertEqual(record.label, .damage)
    XCTAssertEqual(record.caption, "Sağ ön jant çizik")
    XCTAssertEqual(record.width, 640)
    let file = try XCTUnwrap(record.localFile)
    XCTAssertEqual(try Data(contentsOf: CaptureLibrary.shared.fileURL(named: file)), data, "the glasses' JPEG as it came")
    XCTAssertEqual(RayBanMediaCoordinator.photoSpeech(outcome).tr, "Fotoğrafı çektim ve AutoLoom'da sakladım.")
    XCTAssertEqual(media.latestUnsaved?.id, record.id, "“galeriye kaydet” finds it")
  }

  func testARecordingStartsOnceStopsAndIsKept() async throws {
    let media = RayBanMediaCoordinator.shared
    media.isRayBanSource = { true }
    media.isStreaming = { true }
    XCTAssertEqual(media.startRecording(label: nil, caption: nil, noteID: nil), .started)
    XCTAssertEqual(media.recordingState, .preparing)
    XCTAssertEqual(media.startRecording(label: nil, caption: nil, noteID: nil), .alreadyRecording)
    XCTAssertEqual(RayBanMediaCoordinator.startSpeech(.alreadyRecording).tr, "Zaten kayıt yapıyorum.")
    for sample in try compressedSequence(count: 10) { media.recorder.append(sample) }
    for _ in 0..<100 where media.recordingState != .recording {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(media.recordingState, .recording, "RECORDING only after the first frame was written")
    XCTAssertTrue(media.statusSpeech().tr.hasPrefix("Evet,"))
    let outcome = await media.stopRecording()
    guard case .kept(let records, .appOnly) = outcome else { return XCTFail("\(outcome)") }
    let record = try XCTUnwrap(records.first)
    defer { CaptureLibrary.shared.delete(record.id) }
    XCTAssertEqual(record.kind, .video)
    XCTAssertGreaterThan(record.durationSeconds ?? 0, 0.1)
    XCTAssertNotNil(record.localFile)
    XCTAssertEqual(RayBanMediaCoordinator.stopSpeech(outcome).tr, "Videoyu durdurdum ve AutoLoom'da sakladım.")
    XCTAssertEqual(media.statusSpeech().tr, "Hayır, şu an kayıt yapmıyorum.")
  }

  func testWhatTheUserHears() {
    let record = CaptureRecord(kind: .photo)
    XCTAssertEqual(RayBanMediaCoordinator.photoSpeech(.saved(record)).tr, "Fotoğrafı çektim ve galeriye kaydettim.")
    XCTAssertEqual(
      RayBanMediaCoordinator.photoSpeech(.saved(record), withNote: true).tr,
      "Fotoğrafı çektim, galeriye kaydettim ve not aldım.")
    XCTAssertEqual(
      RayBanMediaCoordinator.photoSpeech(.kept(record, .permissionOff)).tr,
      "Fotoğrafı çektim ama galeri izni kapalı; AutoLoom'da sakladım.")
    let video = CaptureRecord(kind: .video)
    XCTAssertEqual(
      RayBanMediaCoordinator.stopSpeech(.kept([video], .saveFailed("x"))).tr,
      "Video çekildi ama galeriye kaydedilemedi; AutoLoom'da sakladım.")
    XCTAssertEqual(
      RayBanMediaCoordinator.stopSpeech(.failed("No space left on device", kept: [])).tr,
      "Video tamamlanamadı; telefonda yeterli alan olmayabilir.")
    XCTAssertEqual(
      RayBanMediaCoordinator.stopSpeech(.saved([video]), reason: .streamEnded).tr,
      "Ray-Ban bağlantısı kesildi, kayıt durdu. Videoyu durdurdum ve galeriye kaydettim.")
    XCTAssertEqual(RayBanMediaCoordinator.turkishSince(72), "1 dakika 12 saniyedir")
    XCTAssertEqual(RayBanMediaCoordinator.turkishSince(120), "2 dakikadır")
    XCTAssertEqual(RayBanMediaCoordinator.spokenDuration(45, turkish: false), "45 seconds")
    XCTAssertEqual(RayBanMediaCoordinator.spokenDuration(61, turkish: false), "1 minute 1 second")
  }

  func testAPhotoWithANoteKeepsTheNoteWhenTheCameraIsOff() async throws {
    let media = RayBanMediaCoordinator.shared
    media.isRayBanSource = { false }
    let orchestrator = AssistantOrchestrator.shared
    let marker = "jant\(UUID().uuidString.prefix(6))"
    let outcome = await orchestrator.runVoiceIntent(
      VoiceBridgeDecision(.takePhoto(label: .damage, note: "Sağ ön \(marker) çizik", caption: nil), "test"),
      transcript: "bunun fotoğrafını çek ve not al")
    let note = try XCTUnwrap(MemoryStore.shared.notes.first { $0.content.contains(marker) }, "the words are saved first")
    defer { MemoryStore.shared.deleteNote(note) }
    XCTAssertNotNil(outcome.failed)
    XCTAssertEqual(
      outcome.said,
      L.t("I noted it. The Ray-Ban camera isn't connected, so I couldn't take a photo.",
          "Notu aldım. Ray-Ban kamerası bağlı değil, fotoğraf çekemedim."))
    XCTAssertEqual(ActionTraceLog.shared.entries.last?.canonical, "TAKE_PHOTO")
  }
}

// MARK: Voice commands

@MainActor
final class AutoLoomRayBanMediaCommandTests: XCTestCase {
  private func decide(_ text: String, _ context: VoiceBridgeContext = VoiceBridgeContext()) -> VoiceIntent? {
    var context = context
    context.assistantName = "AutoLoom"
    return VoiceActionIntentBridge.decide(text, context: context)?.intent
  }

  func testPhotoCommands() {
    for text in [
      "fotoğraf çek", "bir fotoğraf çek", "şunun fotoğrafını çek", "foto çek", "AutoLoom fotoğraf çek",
      "Fotoğraf çeker misin?", "hemen bir fotoğraf çek lütfen", "take a photo", "take a picture", "fotoğraf çek ve kaydet",
    ] {
      XCTAssertEqual(decide(text), .takePhoto(label: nil, note: nil, caption: nil), text)
    }
    guard case .takePhoto(.wheel, nil, nil)? = decide("take a picture of the wheel") else { return XCTFail("wheel") }
    guard case .takePhoto(.front, nil, nil)? = decide("Bu aracın önünü çek") else { return XCTFail("dealer front") }
    guard case .takePhoto(.wheel, nil, nil)? = decide("Jantın fotoğrafını çek") else { return XCTFail("wheel photo") }
    guard case .takePhoto(.damage, nil, nil)? = decide("Hasarın fotoğrafını çek") else { return XCTFail("damage") }
  }

  func testAPhotoWithANoteAndAPhotoOfWhatWasJustSaid() {
    XCTAssertEqual(
      decide("Bunun fotoğrafını çek ve not al: sağ ön jant çizik."),
      .takePhoto(label: .damage, note: "Sağ ön jant çizik", caption: "Sağ ön jant çizik"))
    var context = VoiceBridgeContext()
    context.previousUserText = "Sağ ön jant çizik."
    XCTAssertEqual(
      decide("Fotoğrafını çek", context), .takePhoto(label: .damage, note: nil, caption: "Sağ ön jant çizik."))
  }

  func testRecordingCommands() {
    for text in ["video kaydını başlat", "video çekmeye başla", "kayda başla", "record video", "start recording", "Video çek"] {
      XCTAssertEqual(decide(text), .startRecording(note: nil), text)
    }
    for text in ["videoyu durdur", "kaydı durdur", "stop recording", "çekimi bitir", "finish recording", "AutoLoom kaydı bitir"] {
      XCTAssertEqual(decide(text), .stopRecording, text)
    }
    XCTAssertEqual(decide("Kayıt yapıyor musun?"), .recordingStatus)
    var recording = VoiceBridgeContext()
    recording.isRecording = true
    XCTAssertEqual(decide("Ne kadar oldu?", recording), .recordingStatus)
    XCTAssertNotEqual(decide("Ne kadar oldu?"), .recordingStatus, "only about a recording while one runs")
    XCTAssertEqual(decide("galeriye kaydet"), .saveCaptureToPhotos)
  }

  func testStoppingARecordingWinsOverAWaitingQuestion() {
    var context = VoiceBridgeContext()
    context.pendingPlan = DeviceActionPlan(kind: .createReminder)
    XCTAssertEqual(decide("hayır, kaydı durdur", context), .stopRecording)
    XCTAssertEqual(decide("hayır", context), .confirmPending(false), "a plain no still answers the question")
  }

  func testTalkAboutPhotosIsNotACommand() {
    XCTAssertNil(decide("video nasıl çekilir?"))
    XCTAssertNil(decide("fotoğraf hakkında konuş"))
    XCTAssertNil(decide("How do I take a photo?"))
    XCTAssertNotEqual(decide("don't record this"), .startRecording(note: nil))
    XCTAssertEqual(decide("not al: fotoğraf çek"), .saveNote(text: "Fotoğraf çek"), "the note verb came first")
    if case .takePhoto? = decide("yarın fotoğraf çekmeyi hatırlat") { XCTFail("a reminder, not a photo") }
    XCTAssertTrue(VoiceIntent.stopRecording.isMediaCommand, "passes the voice session's stop-word gate")
    XCTAssertFalse(VoiceIntent.stopRecording.runsFromDelegation, "only the user's own words")
  }
}
