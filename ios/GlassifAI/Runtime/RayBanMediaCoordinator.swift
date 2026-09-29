import AudioToolbox
import CoreMedia
import Foundation
import UIKit

/// Ray-Ban photos and videos, by voice or by button. Long-lived (app
/// lifetime) and independent of the screen and of the conversation: frames
/// come straight from the glasses stream (the ingestor's sample tap), never
/// from the preview or a screenshot, and never from the iPhone camera.
///
/// Photos: a DAT still capture (`capturePhoto`; DAT 0.5 has no standalone
/// `Camera.photo`). Videos: `RayBanVideoRecorder` (HEVC passthrough). The
/// user hears "saved to Photos" only after Photos confirmed it; anything
/// Photos did not take is kept in AutoLoom, never dropped.
@MainActor
final class RayBanMediaCoordinator: ObservableObject {
  static let shared = RayBanMediaCoordinator()

  enum RecordingState: String, Equatable {
    case idle = "IDLE"
    case preparing = "PREPARING"
    case recording = "RECORDING"
    case stopping = "STOPPING"
    case finalizing = "FINALIZING"
    case savingToPhotos = "SAVING_TO_PHOTOS"
    case saved = "SAVED"
    case failed = "FAILED"

    /// A recording is running (or waiting for its first keyframe).
    var isRecording: Bool { self == .preparing || self == .recording }
    /// The previous recording is still being finished and saved.
    var isFinishing: Bool { self == .stopping || self == .finalizing || self == .savingToPhotos }
  }

  enum Unavailable: Equatable {
    /// The chosen camera is not the Ray-Ban (no iPhone fallback, ever).
    case notRayBanSource
    case notStreaming
    case busy
    case tooWarm
  }

  /// Why a capture stayed in AutoLoom instead of Photos.
  enum KeptReason: Equatable {
    case askFirst
    case appOnly
    case permissionOff
    case needsPrompt
    case saveFailed(String)

    var saveError: String? {
      switch self {
      case .askFirst, .appOnly: nil
      case .permissionOff: "photos permission off"
      case .needsPrompt: "photos permission not asked yet"
      case .saveFailed(let reason): reason
      }
    }
  }

  enum PhotoOutcome: Equatable {
    case saved(CaptureRecord)
    case kept(CaptureRecord, KeptReason)
    case unavailable(Unavailable)
    case failed(String)

    /// The capture that was made, if any.
    var record: CaptureRecord? {
      switch self {
      case .saved(let record), .kept(let record, _): record
      case .unavailable, .failed: nil
      }
    }
  }

  enum StartOutcome: Equatable {
    case started
    case alreadyRecording
    case unavailable(Unavailable)
    case lowStorage
  }

  enum StopReason: Equatable {
    case user
    case streamEnded
    case tooWarm
    case storage
    case writer(String)
    case neverStarted
  }

  enum StopOutcome: Equatable {
    case saved([CaptureRecord])
    case kept([CaptureRecord], KeptReason)
    case notRecording
    /// Stopped before the first frame: no file was made.
    case empty
    case failed(String, kept: [CaptureRecord])
  }

  @Published private(set) var recordingState: RecordingState = .idle
  /// The real start (first frame written); nil while preparing.
  @Published private(set) var recordingStartedAt: Date?
  @Published private(set) var isTakingPhoto = false
  /// For diagnostics: the last media event, never content.
  @Published private(set) var lastEvent = "none"

  let recorder = RayBanVideoRecorder()
  let library: CaptureLibrary
  private var recordingLabel: CaptureLabel?
  private var recordingCaption: String?
  private var recordingNoteID: UUID?
  private var recordingRequestedAt: Date?
  private var recordingThumbnail: Data?
  private var watchTask: Task<Void, Never>?
  private var idleTask: Task<Void, Never>?

  /// Wired by the camera screen.
  var isRayBanSource: @MainActor () -> Bool = { AssistantOrchestrator.shared.captureSource() == .glasses }
  var isStreaming: @MainActor () -> Bool = { false }
  var takeStill: @MainActor (TimeInterval) async -> StillPhoto? = { _ in nil }
  /// The active dealer vehicle, if any (linked to new captures).
  var activeVehicleSessionID: @MainActor () -> UUID? = { DealerStore.shared.active?.id }
  /// Called with every capture saved (Dealer Mode links it to the vehicle
  /// and ticks its photo checklist).
  var captureSaved: @MainActor (CaptureRecord) -> Void = { record in DealerStore.shared.linkCapture(record) }
  /// Tells the user about something they did not just ask for (a recording
  /// that stopped itself); spoken in the conversation or shown as a notice.
  var announce: @MainActor (Speech) -> Void = { speech in
    let orchestrator = AssistantOrchestrator.shared
    let instruction = BridgeSpeech.done(
      "The Ray-Ban video recording ended without the user asking.", tr: speech.tr, en: speech.en)
    if let speak = orchestrator.speakInConversation, speak(instruction) { return }
    orchestrator.postNotice(speech.localized)
  }

  static let preparingLimit: TimeInterval = 20

  private init() {
    library = CaptureLibrary.shared
    recorder.onStarted = { [weak self] date in
      Task { @MainActor in self?.recordingDidStart(at: date) }
    }
    recorder.onProblem = { [weak self] problem in
      Task { @MainActor in await self?.recorderStoppedItself(problem) }
    }
  }

  var isRecording: Bool { recordingState.isRecording }

  var elapsed: TimeInterval? {
    recordingStartedAt.map { Date().timeIntervalSince($0) }
  }

  // MARK: Photo

  func takePhoto(label: CaptureLabel?, caption: String?, noteID: UUID?) async -> PhotoOutcome {
    guard isRayBanSource() else { return .unavailable(.notRayBanSource) }
    guard isStreaming() else { return .unavailable(.notStreaming) }
    guard !isTakingPhoto else { return .unavailable(.busy) }
    isTakingPhoto = true
    defer { isTakingPhoto = false }
    guard let still = await takeStill(6) else {
      lastEvent = "photo: the glasses returned no photo"
      return .failed("no photo from the glasses")
    }
    MediaFeedback.shutter()
    var record = CaptureRecord(kind: .photo)
    record.label = label
    record.caption = caption
    record.noteID = noteID
    record.vehicleSessionID = activeVehicleSessionID()
    record.width = still.width
    record.height = still.height
    record.codec = "JPEG"
    let jpeg = still.jpeg
    let thumbnail = await Task.detached(priority: .utility) { CaptureLibrary.thumbnail(fromJPEG: jpeg) }.value
    // Dealer photos get quality hints (measured here; the photo is kept either way).
    if let vehicleID = record.vehicleSessionID,
       let assessment = await Task.detached(priority: .utility, operation: { PhotoDirector.assess(jpeg: jpeg) }).value {
      record.quality = PhotoDirector.review(assessment, vehicleID: vehicleID)
    }
    switch CaptureSaveMode.current {
    case .always:
      do {
        record.photoAssetID = try await PhotoLibrarySaver.savePhoto(jpeg)
        record.storage = .photos
        library.add(record, thumbnail: thumbnail)
        captureSaved(record)
        lastEvent = "photo saved to Photos"
        return .saved(record)
      } catch {
        return keepPhoto(jpeg, record: record, thumbnail: thumbnail, reason: Self.keptReason(for: error))
      }
    case .ask:
      return keepPhoto(jpeg, record: record, thumbnail: thumbnail, reason: .askFirst)
    case .appOnly:
      return keepPhoto(jpeg, record: record, thumbnail: thumbnail, reason: .appOnly)
    }
  }

  private func keepPhoto(_ jpeg: Data, record: CaptureRecord, thumbnail: Data?, reason: KeptReason) -> PhotoOutcome {
    var record = record
    do {
      record.localFile = try library.keep(photo: jpeg, id: record.id)
    } catch {
      lastEvent = "photo: could not be stored"
      return .failed("the photo could not be stored on this iPhone")
    }
    record.storage = .appOnly
    record.saveError = reason.saveError
    library.add(record, thumbnail: thumbnail)
    captureSaved(record)
    lastEvent = "photo kept in AutoLoom (\(reason.saveError ?? "setting"))"
    return .kept(record, reason)
  }

  static func keptReason(for error: Error) -> KeptReason {
    switch error as? PhotoLibrarySaver.SaveError {
    case .permissionDenied?: .permissionOff
    case .needsPrompt?: .needsPrompt
    case .failed(let reason)?: .saveFailed(reason)
    case nil: .saveFailed(LogSanitizer.sanitize(error.localizedDescription, limit: 120))
    }
  }

  // MARK: Photos library

  /// "Galeriye kaydet" / Save again: adds a capture kept in AutoLoom to
  /// Photos, then removes the app's copy.
  func saveToPhotos(_ id: UUID) async -> Result<CaptureRecord, PhotoLibrarySaver.SaveError> {
    guard let record = library.record(id), let file = record.localFile else {
      return .failure(.failed("nothing to save"))
    }
    let url = library.fileURL(named: file)
    do {
      let assetID: String?
      switch record.kind {
      case .photo: assetID = try await PhotoLibrarySaver.savePhoto(try Data(contentsOf: url))
      case .video: assetID = try await PhotoLibrarySaver.saveVideo(at: url)
      }
      try? FileManager.default.removeItem(at: url)
      library.update(id) {
        $0.storage = .photos
        $0.photoAssetID = assetID
        $0.localFile = nil
        $0.saveError = nil
      }
      lastEvent = "\(record.kind.rawValue) saved to Photos later"
      return .success(library.record(id) ?? record)
    } catch let error as PhotoLibrarySaver.SaveError {
      library.update(id) { $0.saveError = error.reason }
      return .failure(error)
    } catch {
      let reason = LogSanitizer.sanitize(error.localizedDescription, limit: 120)
      library.update(id) { $0.saveError = reason }
      return .failure(.failed(reason))
    }
  }

  /// The newest capture still waiting in AutoLoom.
  var latestUnsaved: CaptureRecord? {
    library.records.first { $0.storage == .appOnly && $0.localFile != nil }
  }

  /// Back on screen: captures whose Photos save failed or waited for the
  /// permission prompt (in the last day) are saved now, when "Always" is on.
  func retryPendingSaves() async {
    guard CaptureSaveMode.current == .always, UIApplication.shared.applicationState == .active else { return }
    let status = PhotoLibrarySaver.addOnlyStatus
    guard status == .authorized || status == .limited || status == .notDetermined else { return }
    let dayAgo = Date().addingTimeInterval(-86_400)
    for record in library.records where record.needsPhotosSave && record.createdAt > dayAgo {
      if case .failure(.permissionDenied) = await saveToPhotos(record.id) { return }
    }
  }

  // MARK: Video

  func startRecording(label: CaptureLabel?, caption: String?, noteID: UUID?) -> StartOutcome {
    if recordingState.isRecording { return .alreadyRecording }
    if recordingState.isFinishing { return .unavailable(.busy) }
    guard isRayBanSource() else { return .unavailable(.notRayBanSource) }
    guard isStreaming() else { return .unavailable(.notStreaming) }
    if ProcessInfo.processInfo.thermalState == .critical { return .unavailable(.tooWarm) }
    do {
      try recorder.start()
    } catch RayBanVideoRecorder.StartError.lowStorage {
      lastEvent = "recording refused: low storage"
      return .lowStorage
    } catch {
      return .alreadyRecording
    }
    idleTask?.cancel()
    recordingLabel = label
    recordingCaption = caption
    recordingNoteID = noteID
    recordingThumbnail = nil
    recordingStartedAt = nil
    recordingRequestedAt = Date()
    recordingState = .preparing
    lastEvent = "recording: waiting for the first keyframe"
    MediaFeedback.recordStart()
    watch()
    return .started
  }

  private func recordingDidStart(at date: Date) {
    guard recordingState == .preparing else { return }
    recordingStartedAt = date
    recordingState = .recording
    lastEvent = "recording (\(recorder.currentMode.rawValue))"
    // The list thumbnail from the current decoded glasses frame (CPU only).
    if let frame = FrameStore.shared.freshFrame(maxAge: 1.5, source: .glasses) {
      let buffer = frame.pixelBuffer
      Task { [weak self] in
        let data = await Task.detached(priority: .utility) { CaptureLibrary.thumbnail(fromPixelBuffer: buffer) }.value
        self?.recordingThumbnail = data
      }
    }
  }

  /// Every second while recording: the phone's temperature and a first
  /// frame that never comes.
  private func watch() {
    watchTask?.cancel()
    watchTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let self, !Task.isCancelled, self.recordingState.isRecording else { return }
        if ProcessInfo.processInfo.thermalState == .critical {
          await self.finishAndAnnounce(.tooWarm)
          return
        }
        if self.recordingState == .preparing, let requested = self.recordingRequestedAt,
           Date().timeIntervalSince(requested) > Self.preparingLimit {
          await self.finishAndAnnounce(.neverStarted)
          return
        }
      }
    }
  }

  /// The glasses stream stopped (glasses off, folded, disconnected).
  func streamStopped() {
    guard recordingState.isRecording else { return }
    Task { await finishAndAnnounce(.streamEnded) }
  }

  private func recorderStoppedItself(_ problem: String) async {
    guard recordingState.isRecording else { return }
    await finishAndAnnounce(problem == "storage" ? .storage : .writer(problem))
  }

  private func finishAndAnnounce(_ reason: StopReason) async {
    let outcome = await stopRecording(reason: reason)
    announce(Self.stopSpeech(outcome, reason: reason))
  }

  func stopRecording(reason: StopReason = .user) async -> StopOutcome {
    guard recordingState.isRecording else { return .notRecording }
    watchTask?.cancel()
    recordingState = .stopping
    MediaFeedback.recordStop()
    recordingState = .finalizing
    let result = await recorder.stop()
    recordingStartedAt = nil
    recordingRequestedAt = nil
    let outcome: StopOutcome
    switch result {
    case .noRecording:
      outcome = .empty
      recordingState = .idle
    case .completed(let segments):
      outcome = await store(segments, failure: nil)
    case .failed(let problem, let partial):
      outcome = await store(partial, failure: problem)
    }
    recordingLabel = nil
    recordingCaption = nil
    recordingNoteID = nil
    recordingThumbnail = nil
    lastEvent = "recording stopped (\(Self.describe(reason))): \(Self.describe(outcome))"
    scheduleIdle()
    return outcome
  }

  /// Saves each finished file to Photos (then deletes the temporary file),
  /// or keeps it in AutoLoom.
  private func store(_ segments: [RayBanVideoRecorder.Segment], failure: String?) async -> StopOutcome {
    recordingState = .savingToPhotos
    var saved: [CaptureRecord] = []
    var kept: [CaptureRecord] = []
    var keptReason: KeptReason?
    let mode = CaptureSaveMode.current
    for segment in segments {
      var record = CaptureRecord(kind: .video)
      record.label = recordingLabel
      record.caption = recordingCaption
      record.noteID = recordingNoteID
      record.vehicleSessionID = activeVehicleSessionID()
      record.durationSeconds = segment.duration
      record.width = segment.width
      record.height = segment.height
      record.codec = "\(segment.codec) · \(segment.mode.rawValue)"
      if mode == .always {
        do {
          record.photoAssetID = try await PhotoLibrarySaver.saveVideo(at: segment.url)
          record.storage = .photos
          try? FileManager.default.removeItem(at: segment.url)
          library.add(record, thumbnail: recordingThumbnail)
          captureSaved(record)
          saved.append(record)
          continue
        } catch {
          keptReason = Self.keptReason(for: error)
        }
      } else {
        keptReason = mode == .ask ? .askFirst : .appOnly
      }
      // Photos did not take it (or should not): keep it in AutoLoom.
      do {
        record.localFile = try library.keep(fileAt: segment.url, id: record.id)
      } catch {
        record.localFile = nil
        record.saveError = "the video file could not be kept"
      }
      record.storage = .appOnly
      if record.saveError == nil { record.saveError = keptReason?.saveError }
      library.add(record, thumbnail: recordingThumbnail)
      captureSaved(record)
      kept.append(record)
    }
    if let failure {
      recordingState = .failed
      return .failed(failure, kept: saved + kept)
    }
    recordingState = .saved
    if let keptReason, !kept.isEmpty { return .kept(saved + kept, keptReason) }
    return .saved(saved)
  }

  private func scheduleIdle() {
    idleTask?.cancel()
    idleTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard let self, !Task.isCancelled else { return }
      if self.recordingState == .saved || self.recordingState == .failed { self.recordingState = .idle }
    }
  }

  // MARK: Speech

  /// One short sentence in both languages; `localized` follows the app.
  struct Speech: Equatable {
    let tr: String
    let en: String

    var localized: String { L.t(en, tr) }
  }

  /// The photo director's hint and the damage note the photo was linked to.
  @MainActor
  static func dealerSpeech(for outcome: PhotoOutcome) -> Speech? {
    guard let record = outcome.record, let vehicleID = record.vehicleSessionID else { return nil }
    var tr: [String] = []
    var en: [String] = []
    if let damage = DealerStore.shared.vehicle(vehicleID)?.damage.first(where: { $0.captureIDs.contains(record.id) }) {
      tr.append("Hasar kaydına bağladım: \(damage.title(turkish: true)).")
      en.append("Linked to the damage note: \(damage.title(turkish: false)).")
    }
    if let hintTR = record.quality?.hint(turkish: true), let hintEN = record.quality?.hint(turkish: false) {
      tr.append(hintTR)
      en.append(hintEN)
    }
    guard !tr.isEmpty else { return nil }
    return Speech(tr: tr.joined(separator: " "), en: en.joined(separator: " "))
  }

  static func photoSpeech(_ outcome: PhotoOutcome, withNote: Bool = false) -> Speech {
    switch outcome {
    case .saved:
      return withNote
        ? Speech(tr: "Fotoğrafı çektim, galeriye kaydettim ve not aldım.", en: "I took the photo, saved it to Photos and noted it.")
        : Speech(tr: "Fotoğrafı çektim ve galeriye kaydettim.", en: "I took the photo and saved it to Photos.")
    case .kept(_, let reason):
      let note = withNote ? Speech(tr: " Notu da aldım.", en: " I noted it too.") : Speech(tr: "", en: "")
      let base: Speech
      switch reason {
      case .askFirst:
        base = Speech(
          tr: "Fotoğrafı çektim. Galeriye eklememi istersen “galeriye kaydet” de.",
          en: "I took the photo. Say “save it to Photos” to add it to your library.")
      case .appOnly:
        base = Speech(tr: "Fotoğrafı çektim ve AutoLoom'da sakladım.", en: "I took the photo and kept it in AutoLoom.")
      case .permissionOff:
        base = Speech(
          tr: "Fotoğrafı çektim ama galeri izni kapalı; AutoLoom'da sakladım.",
          en: "I took the photo, but Photos access is off; I kept it in AutoLoom.")
      case .needsPrompt:
        base = Speech(
          tr: "Fotoğrafı çektim; galeri izni için uygulamayı açman gerekiyor, şimdilik AutoLoom'da sakladım.",
          en: "I took the photo; open the app to allow Photos access. For now it is kept in AutoLoom.")
      case .saveFailed:
        base = Speech(
          tr: "Fotoğrafı çektim ama galeriye kaydedemedim; AutoLoom'da sakladım.",
          en: "I took the photo but couldn't save it to Photos; I kept it in AutoLoom.")
      }
      return Speech(tr: base.tr + note.tr, en: base.en + note.en)
    case .unavailable(let why):
      return unavailableSpeech(why, photo: true)
    case .failed:
      return Speech(tr: "Gözlükten fotoğraf alamadım.", en: "The glasses didn't return a photo.")
    }
  }

  static func startSpeech(_ outcome: StartOutcome) -> Speech {
    switch outcome {
    case .started: Speech(tr: "Video kaydını başlattım.", en: "Recording started.")
    case .alreadyRecording: Speech(tr: "Zaten kayıt yapıyorum.", en: "I'm already recording.")
    case .lowStorage:
      Speech(tr: "Telefonda yeterli alan yok, kayıt başlatamadım.", en: "There isn't enough free space on the phone to record.")
    case .unavailable(let why): unavailableSpeech(why, photo: false)
    }
  }

  static func stopSpeech(_ outcome: StopOutcome, reason: StopReason = .user) -> Speech {
    let prefix: Speech
    switch reason {
    case .streamEnded:
      prefix = Speech(tr: "Ray-Ban bağlantısı kesildi, kayıt durdu. ", en: "The Ray-Ban connection dropped, so recording stopped. ")
    case .tooWarm:
      prefix = Speech(tr: "Telefon çok ısındı, kaydı durdurdum. ", en: "The phone got too warm, so I stopped recording. ")
    case .storage:
      prefix = Speech(tr: "Telefonda yer azaldı, kaydı durdurdum. ", en: "The phone is running out of space, so I stopped recording. ")
    case .neverStarted:
      prefix = Speech(tr: "Gözlükten görüntü gelmedi, kayıt başlayamadı. ", en: "No video came from the glasses, so the recording couldn't start. ")
    case .user, .writer:
      prefix = Speech(tr: "", en: "")
    }
    let body: Speech
    switch outcome {
    case .saved(let records):
      body = records.count > 1
        ? Speech(tr: "Video \(records.count) parça halinde galeriye kaydedildi.", en: "The video was saved to Photos in \(records.count) parts.")
        : Speech(tr: "Videoyu durdurdum ve galeriye kaydettim.", en: "I stopped the video and saved it to Photos.")
    case .kept(_, let why):
      switch why {
      case .askFirst:
        body = Speech(
          tr: "Videoyu durdurdum. Galeriye eklememi istersen “galeriye kaydet” de.",
          en: "I stopped the video. Say “save it to Photos” to add it to your library.")
      case .appOnly:
        body = Speech(tr: "Videoyu durdurdum ve AutoLoom'da sakladım.", en: "I stopped the video and kept it in AutoLoom.")
      case .permissionOff, .needsPrompt, .saveFailed:
        body = Speech(
          tr: "Video çekildi ama galeriye kaydedilemedi; AutoLoom'da sakladım.",
          en: "The video was recorded but couldn't be saved to Photos; I kept it in AutoLoom.")
      }
    case .notRecording:
      body = Speech(tr: "Şu an kayıt yapmıyorum.", en: "I'm not recording right now.")
    case .empty:
      body = reason == .neverStarted
        ? Speech(tr: "", en: "")
        : Speech(tr: "Kayıt başlamadan durdu; video oluşmadı.", en: "It stopped before any video was recorded.")
    case .failed(let problem, let kept):
      let storage = problem.lowercased().contains("space") || problem.lowercased().contains("storage")
        || problem.lowercased().contains("disk")
      let first = storage
        ? Speech(tr: "Video tamamlanamadı; telefonda yeterli alan olmayabilir.", en: "The video couldn't be finished; the phone may be out of space.")
        : Speech(tr: "Video tamamlanamadı.", en: "The video couldn't be finished.")
      body = kept.isEmpty
        ? first
        : Speech(tr: first.tr + " Kaydedilebilen kısmı sakladım.", en: first.en + " I kept the part that was recorded.")
    }
    return Speech(
      tr: (prefix.tr + body.tr).trimmingCharacters(in: .whitespaces),
      en: (prefix.en + body.en).trimmingCharacters(in: .whitespaces))
  }

  func statusSpeech(now: Date = Date()) -> Speech {
    switch recordingState {
    case .recording:
      let seconds = recordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
      return Speech(
        tr: "Evet, \(Self.turkishSince(seconds)) kayıt yapıyorum.",
        en: "Yes, I've been recording for \(Self.spokenDuration(seconds, turkish: false)).")
    case .preparing:
      return Speech(
        tr: "Kayıt başlamak üzere; gözlükten ilk görüntüyü bekliyorum.",
        en: "Recording is about to start; I'm waiting for the first frame from the glasses.")
    case .stopping, .finalizing, .savingToPhotos:
      return Speech(tr: "Kaydı bitirdim, videoyu kaydediyorum.", en: "I've stopped and I'm saving the video.")
    case .idle, .saved, .failed:
      return Speech(tr: "Hayır, şu an kayıt yapmıyorum.", en: "No, I'm not recording right now.")
    }
  }

  static func unavailableSpeech(_ why: Unavailable, photo: Bool) -> Speech {
    switch why {
    case .notRayBanSource, .notStreaming:
      return photo
        ? Speech(tr: "Ray-Ban kamerası bağlı değil, fotoğraf çekemedim.", en: "The Ray-Ban camera isn't connected, so I couldn't take a photo.")
        : Speech(tr: "Ray-Ban kamerası bağlı değil, kayıt başlatamadım.", en: "The Ray-Ban camera isn't connected, so I couldn't start recording.")
    case .busy:
      return photo
        ? Speech(tr: "Bir çekim zaten sürüyor, birazdan tekrar dene.", en: "A capture is already in progress; try again in a moment.")
        : Speech(tr: "Önceki videoyu kaydediyorum, birazdan tekrar dene.", en: "I'm still saving the previous video; try again in a moment.")
    case .tooWarm:
      return Speech(tr: "Telefon çok ısındı, şu an kayıt başlatamıyorum.", en: "The phone is too warm to record right now.")
    }
  }

  /// "12 saniyedir", "2 dakikadır": how long, with the Turkish suffix that
  /// follows the last word's vowel.
  static func turkishSince(_ seconds: TimeInterval) -> String {
    let words = spokenDuration(seconds, turkish: true)
    return words + (words.hasSuffix("dakika") ? "dır" : "dir")
  }

  /// Diagnostics only: the kind of result, never the captions.
  static func describe(_ outcome: StopOutcome) -> String {
    switch outcome {
    case .saved(let records): "saved to Photos (\(records.count))"
    case .kept(let records, let reason): "kept in AutoLoom (\(records.count), \(reason.saveError ?? "setting"))"
    case .notRecording: "not recording"
    case .empty: "no frames"
    case .failed(let problem, let kept): "failed: \(problem) (kept \(kept.count))"
    }
  }

  static func describe(_ reason: StopReason) -> String {
    switch reason {
    case .user: "user"
    case .streamEnded: "stream ended"
    case .tooWarm: "too warm"
    case .storage: "storage"
    case .writer: "writer error"
    case .neverStarted: "no first frame"
    }
  }

  /// "1 dakika 12 saniye", "45 seconds".
  static func spokenDuration(_ seconds: TimeInterval, turkish: Bool) -> String {
    let total = max(0, Int(seconds.rounded()))
    let minutes = total / 60
    let rest = total % 60
    if turkish {
      if minutes == 0 { return "\(rest) saniye" }
      return rest == 0 ? "\(minutes) dakika" : "\(minutes) dakika \(rest) saniye"
    }
    func unit(_ value: Int, _ word: String) -> String { "\(value) \(word)\(value == 1 ? "" : "s")" }
    if minutes == 0 { return unit(rest, "second") }
    return rest == 0 ? unit(minutes, "minute") : unit(minutes, "minute") + " " + unit(rest, "second")
  }
}

/// The shutter and record sounds and haptics (iOS system sounds).
enum MediaFeedback {
  @MainActor static func shutter() {
    AudioServicesPlaySystemSound(1108)
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  @MainActor static func recordStart() {
    AudioServicesPlaySystemSound(1117)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  @MainActor static func recordStop() {
    AudioServicesPlaySystemSound(1118)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }
}
