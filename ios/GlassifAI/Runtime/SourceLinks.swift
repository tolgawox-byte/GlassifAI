import Foundation

/// Research idea D2-02: a reminder or event made from an AutoLoom note
/// carries a link back to it (`glassifai://item/note/<id>`), which Apple
/// Reminders and Calendar show on the item. Opening a link only shows the
/// item in AutoLoom; it never runs, sends or changes anything, so a link
/// from anywhere is harmless. The idea comes from DearBobby9/NoteV_Glasses
/// (MIT); no code was taken.
enum SourceLink {
  static let scheme = "glassifai"
  static let host = "item"
  static let domains: Set<String> = ["note", "task", "vehicle", "memory"]

  static func url(_ domain: String, _ id: UUID) -> URL? {
    guard domains.contains(domain) else { return nil }
    return URL(string: "\(scheme)://\(host)/\(domain)/\(id.uuidString)")
  }

  /// The item a link names, or nil for anything else. Meta's registration
  /// callbacks use the same scheme without this host.
  static func parse(_ url: URL) -> (domain: String, id: UUID)? {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          parts.scheme?.lowercased() == scheme, parts.host?.lowercased() == host,
          parts.query == nil, parts.fragment == nil else { return nil }
    let path = parts.path.split(separator: "/").map(String.init)
    guard path.count == 2, domains.contains(path[0]), let id = UUID(uuidString: path[1]) else { return nil }
    return (path[0], id)
  }

  /// Shows the item the link names; true when the link was one of these.
  @MainActor
  static func open(_ url: URL) -> Bool {
    guard let (domain, id) = parse(url) else { return false }
    SpotlightIndexer.shared.open(identifier: "\(domain):\(id.uuidString)")
    return true
  }
}
