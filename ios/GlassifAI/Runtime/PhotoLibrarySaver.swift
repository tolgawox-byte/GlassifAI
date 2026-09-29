import Foundation
import Photos
import UIKit

/// Saves Ray-Ban photos and videos to the Photos library with add-only
/// access (NSPhotoLibraryAddUsageDescription): the app can add, never read,
/// so it keeps only the new asset's identifier. A result is reported only
/// after Photos confirmed the change.
enum PhotoLibrarySaver {
  enum SaveError: Error, Equatable {
    /// Photos access was declined or is restricted.
    case permissionDenied
    /// Not asked yet and the app is not on screen to ask.
    case needsPrompt
    case failed(String)

    var reason: String {
      switch self {
      case .permissionDenied: "photos permission off"
      case .needsPrompt: "photos permission not asked yet"
      case .failed(let text): text
      }
    }
  }

  static var addOnlyStatus: PHAuthorizationStatus {
    PHPhotoLibrary.authorizationStatus(for: .addOnly)
  }

  static var permissionState: PermissionState {
    switch addOnlyStatus {
    case .authorized: .granted
    case .limited: .limited
    case .notDetermined: .notAsked
    default: .denied
    }
  }

  /// Asks for add-only access when it was never asked and the app is on
  /// screen (iOS shows its prompt only then).
  @MainActor
  static func ensureAccess() async throws {
    switch addOnlyStatus {
    case .authorized, .limited:
      return
    case .notDetermined:
      guard UIApplication.shared.applicationState == .active else { throw SaveError.needsPrompt }
      let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
      guard status == .authorized || status == .limited else { throw SaveError.permissionDenied }
    default:
      throw SaveError.permissionDenied
    }
  }

  private final class IdentifierBox: @unchecked Sendable {
    var value: String?
  }

  /// Adds a photo (JPEG data as the glasses sent it). Returns the asset's
  /// local identifier.
  @MainActor
  static func savePhoto(_ data: Data) async throws -> String? {
    try await ensureAccess()
    let box = IdentifierBox()
    do {
      try await PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: .photo, data: data, options: nil)
        box.value = request.placeholderForCreatedAsset?.localIdentifier
      }
    } catch {
      throw SaveError.failed(LogSanitizer.sanitize(error.localizedDescription, limit: 120))
    }
    return box.value
  }

  /// Adds a finished video file (the file is copied; the caller deletes it).
  @MainActor
  static func saveVideo(at url: URL) async throws -> String? {
    try await ensureAccess()
    let box = IdentifierBox()
    do {
      try await PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.shouldMoveFile = false
        request.addResource(with: .video, fileURL: url, options: options)
        box.value = request.placeholderForCreatedAsset?.localIdentifier
      }
    } catch {
      throw SaveError.failed(LogSanitizer.sanitize(error.localizedDescription, limit: 120))
    }
    return box.value
  }

  /// Opens the Photos app (add-only access cannot show one asset).
  @MainActor
  static func openPhotosApp() {
    guard let url = URL(string: "photos-redirect://") else { return }
    UIApplication.shared.open(url)
  }
}
