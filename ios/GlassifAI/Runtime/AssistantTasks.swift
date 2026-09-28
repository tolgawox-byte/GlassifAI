import Foundation

/// The logical jobs the assistant can run. The voice model handles plain
/// conversation itself; everything else arrives as a delegation and is routed
/// to one of these.
enum AssistantTaskKind: String, Codable, CaseIterable, Equatable {
  case generalChat = "GENERAL_CHAT"
  case vision = "VISION"
  case webSearch = "WEB_SEARCH"
  case visionPlusWeb = "VISION_PLUS_WEB"
  case deepReasoning = "DEEP_REASONING"
  case localMemory = "LOCAL_MEMORY"
  case authorizedAction = "AUTHORIZED_ACTION"
  /// Research with live web search, written up and saved as a note.
  case report = "REPORT"
  /// A request for the user's own OpenClaw agent gateway.
  case agent = "AGENT"
  /// "Remember what I'm looking at": a description of the current view is
  /// saved as a visual memory (opt-in).
  case visualMemory = "VISUAL_MEMORY"

  var usesCamera: Bool { self == .vision || self == .visionPlusWeb || self == .visualMemory }
  var usesWeb: Bool { self == .webSearch || self == .visionPlusWeb || self == .report }
  /// Brings content the user did not say into the conversation: camera
  /// images and OCR, web results, replies from the user's agent.
  var bringsUntrustedContent: Bool { usesCamera || usesWeb || self == .agent }

  var displayName: String {
    switch self {
    case .generalChat: "Chat"
    case .vision: "Vision"
    case .webSearch: "Web search"
    case .visionPlusWeb: "Vision + web"
    case .deepReasoning: "Reasoning"
    case .localMemory: "Memory"
    case .authorizedAction: "Action"
    case .report: "Report"
    case .agent: "Agent"
    case .visualMemory: "Visual memory"
    }
  }
}

/// How a task's kind was decided. Verified envelopes come from the voice
/// model's structured delegation; tool routing lets the executor model pick
/// tools itself when the delegation carried no valid envelope.
enum RouteOrigin: String, Codable, Equatable {
  case verifiedEnvelope = "verified delegation"
  case toolRouting = "tool routing"
  case typedInput = "typed input"
}

enum AssistantTaskSource: String, Codable, Equatable {
  case voiceDelegation = "voice"
  case typedInput = "typed"
  /// Started by the voice action bridge from the user's own words.
  case voiceIntent = "voice intent"
}

enum AssistantTaskPhase: Equatable {
  case routing
  case capturingFrame
  case searching
  case analyzing
  case reasoning
  case delivering
  case completed
  case cancelled(String)
  case failed(String)

  var isTerminal: Bool {
    switch self {
    case .completed, .cancelled, .failed: true
    default: false
    }
  }
}

/// Wall-clock milestones for one task. For a vision request these map to the
/// T0–T5 latency breakdown: intent, fresh frame, image ready, request sent,
/// first model output, and speech start.
struct TaskTimeline: Equatable {
  var intent: Date
  var frameSelected: Date?
  var imagePrepared: Date?
  var requestSent: Date?
  var firstModelOutput: Date?
  var modelCompleted: Date?
  var delivered: Date?
  var speechStarted: Date?

  func milliseconds(from start: Date?, to end: Date?) -> Int? {
    guard let start, let end else { return nil }
    return Int((end.timeIntervalSince(start) * 1_000).rounded())
  }

  /// Human-readable stage durations; `nil` stages are omitted.
  var breakdown: [(stage: String, ms: Int)] {
    var result: [(stage: String, ms: Int)] = []
    if let value = milliseconds(from: intent, to: frameSelected) { result.append(("camera (fresh frame)", value)) }
    if let value = milliseconds(from: frameSelected, to: imagePrepared) { result.append(("image processing", value)) }
    let requestStart = imagePrepared ?? frameSelected ?? intent
    if let value = milliseconds(from: requestStart, to: requestSent) { result.append(("request setup", value)) }
    if let value = milliseconds(from: requestSent, to: firstModelOutput) { result.append(("network + model first output", value)) }
    if let value = milliseconds(from: firstModelOutput, to: modelCompleted) { result.append(("model streaming", value)) }
    if let value = milliseconds(from: modelCompleted ?? firstModelOutput, to: delivered) { result.append(("handoff to voice", value)) }
    if let value = milliseconds(from: delivered, to: speechStarted) { result.append(("voice start", value)) }
    if let value = milliseconds(from: intent, to: speechStarted ?? delivered) { result.append(("total", value)) }
    return result
  }
}

/// Details of the image a vision task actually used (never the image itself).
struct VisionFrameInfo: Equatable {
  enum Kind: String {
    case video = "VIDEO"
    case photo = "PHOTO"
  }

  let kind: Kind
  let source: String
  /// FrameStore sequence number of a video frame (nil for photos).
  let sequence: UInt64?
  let pixelFormat: String
  let sourceWidth: Int
  let sourceHeight: Int
  let encodedWidth: Int
  let encodedHeight: Int
  let jpegQuality: Double
  let jpegBytes: Int
  /// Age of the video frame when selected; 0 for a photo taken for this task.
  let frameAgeMs: Int
  /// Time from requesting a still photo to receiving it.
  let captureLatencyMs: Int?
  let reencoded: Bool
  let detail: VisionDetail
  /// How the frame was chosen among recent frames (video only).
  var selection: String?
  /// On-device OCR used as a hint: line count, confidence, time.
  var ocr: String?
  /// Enlarged text crop sent as a second image.
  var crop: String?
  /// The frame was enlarged toward the patch budget for reading.
  var upscaled = false
  /// `detail` value sent with the image(s).
  var imageDetail = "high"
  /// Total image bytes in the request (all images).
  var totalImageBytes: Int?
  /// Proof of origin: pipeline state and transport when the frame was taken
  /// (for example "ScreenLockedStreaming · HEVC (hvc1) decoded glasses sample").
  var pipeline: String?

  /// VIDEO, PHOTO, OCR+VIDEO or OCR+PHOTO.
  var sourceLabel: String {
    ocr == nil ? kind.rawValue : "OCR+\(kind.rawValue)"
  }

  var summary: String {
    let quality = reencoded ? "JPEG q\(String(format: "%.2f", jpegQuality))" : "original JPEG"
    let sequenceText = sequence.map { " #\($0)" } ?? ""
    let latency = captureLatencyMs.map { ", captured in \($0) ms" } ?? ""
    var text = "\(sourceLabel) \(source)\(sequenceText) \(pixelFormat) \(sourceWidth)×\(sourceHeight) → " +
      "\(encodedWidth)×\(encodedHeight)\(upscaled ? " (upscaled)" : ""), \(quality), \(jpegBytes / 1_024) KB, " +
      "age \(frameAgeMs) ms\(latency), \(detail.label) profile, detail=\(imageDetail)"
    if let selection { text += "; \(selection)" }
    if let crop { text += "; crop \(crop)" }
    if let ocr { text += "; OCR \(ocr)" }
    if let totalImageBytes, totalImageBytes != jpegBytes { text += "; request images \(totalImageBytes / 1_024) KB" }
    if let pipeline { text += "; \(pipeline)" }
    return text
  }
}

struct AssistantTaskRecord: Identifiable, Equatable {
  let id: UUID
  let sessionID: UUID
  let turnID: Int
  let handoffID: String?
  let source: AssistantTaskSource
  let request: String
  let startTime: Date
  var kind: AssistantTaskKind?
  var routeOrigin: RouteOrigin?
  var model: String?
  var phase: AssistantTaskPhase = .routing
  var timeline: TaskTimeline
  var frame: VisionFrameInfo?
  /// Vision profile chosen for this task (FAST / BALANCED / HIGH_DETAIL).
  var visionProfile: VisionDetail?
  var sourceCount = 0
  /// Decisions worth tracing (high-detail retry, contact lookup, fallbacks).
  var notes: [String] = []

  var cancelled: Bool {
    if case .cancelled = phase { return true }
    return false
  }

  var completed: Bool { phase == .completed }

  var error: String? {
    if case .failed(let message) = phase { return message }
    return nil
  }
}

/// Tracks every assistant task for the current app run and decides whether a
/// finished task may still speak. Results from cancelled tasks, superseded
/// tasks, or an earlier voice session are dropped.
@MainActor
final class TaskLedger: ObservableObject {
  @Published private(set) var records: [AssistantTaskRecord] = []
  private let historyLimit = 30

  var active: [AssistantTaskRecord] { records.filter { !$0.phase.isTerminal } }
  var latest: AssistantTaskRecord? { records.last }

  func begin(
    sessionID: UUID,
    turnID: Int,
    handoffID: String?,
    source: AssistantTaskSource,
    request: String
  ) -> AssistantTaskRecord {
    let record = AssistantTaskRecord(
      id: UUID(),
      sessionID: sessionID,
      turnID: turnID,
      handoffID: handoffID,
      source: source,
      request: request,
      startTime: Date(),
      timeline: TaskTimeline(intent: Date()))
    records.append(record)
    if records.count > historyLimit {
      records.removeFirst(records.count - historyLimit)
    }
    return record
  }

  func update(_ id: UUID, _ change: (inout AssistantTaskRecord) -> Void) {
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    change(&records[index])
  }

  func record(_ id: UUID) -> AssistantTaskRecord? {
    records.first { $0.id == id }
  }

  /// Marks every non-terminal task as cancelled and returns their IDs.
  @discardableResult
  func cancelAll(reason: String, except keep: UUID? = nil) -> [UUID] {
    var cancelled: [UUID] = []
    for index in records.indices where !records[index].phase.isTerminal && records[index].id != keep {
      records[index].phase = .cancelled(reason)
      cancelled.append(records[index].id)
    }
    return cancelled
  }

  /// A result may be delivered only if its task is still running and belongs
  /// to the live voice session.
  func mayDeliver(_ id: UUID, currentSession: UUID?) -> Bool {
    guard let record = record(id), !record.phase.isTerminal else { return false }
    if record.source == .voiceDelegation {
      return record.sessionID == currentSession
    }
    return true
  }

  func clear() {
    records.removeAll()
  }
}
