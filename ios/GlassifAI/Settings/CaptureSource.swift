import Foundation

/// The camera the assistant uses for visual questions. The raw value is
/// persisted in UserDefaults so changing it applies without a relaunch.
/// `off` keeps conversation, web search, and reasoning working with no camera.
enum CaptureSource: String, CaseIterable {
  case glasses = "glasses"
  case iPhoneCamera = "iphone"
  case off = "off"

  static let defaultsKey = "captureSource"

  var label: String {
    switch self {
    case .iPhoneCamera: "iPhone"
    case .glasses: "Ray-Ban"
    case .off: "Off"
    }
  }

  var systemImage: String {
    switch self {
    case .iPhoneCamera: "iphone"
    case .glasses: "eyeglasses"
    case .off: "video.slash"
    }
  }
}
