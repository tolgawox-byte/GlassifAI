import Foundation

/// Short interface strings in the app's language: Turkish when the assistant
/// language is Turkish (or "match my language" on a Turkish iPhone),
/// otherwise English.
enum L {
  static var isTurkish: Bool {
    switch AssistantPreferences.language {
    case "tr": return true
    case "en": return false
    default: return Locale.current.language.languageCode?.identifier == "tr"
    }
  }

  static func t(_ english: String, _ turkish: String) -> String {
    isTurkish ? turkish : english
  }
}

/// Turns technical failures into short, friendly messages for the main
/// screen. The technical text stays available in Settings → Developer.
enum FriendlyError {
  struct Message: Equatable {
    let title: String
    let detail: String
  }

  static func message(for raw: String) -> Message {
    let lower = raw.lowercased()
    if lower.contains("offline") || lower.contains("not connected to the internet")
      || lower.contains("network connection was lost") || lower.contains("could not connect to the server")
      || lower.contains("-1009") || lower.contains("-1004") || lower.contains("-1005") {
      return Message(
        title: L.t("No internet connection", "İnternet bağlantısı yok"),
        detail: L.t("Check Wi-Fi or mobile data, then tap to try again.",
                    "Wi-Fi veya mobil veriyi kontrol edip tekrar dokunun."))
    }
    if lower.contains("timed out") || lower.contains("took too long") || lower.contains("-1001") {
      return Message(
        title: L.t("The connection is slow", "Bağlantı yavaş"),
        detail: L.t("ChatGPT took too long to answer. Tap to try again.",
                    "ChatGPT geç yanıt verdi. Tekrar denemek için dokunun."))
    }
    if lower.contains("401") || lower.contains("unauthorized") || lower.contains("sign in")
      || lower.contains("sign-in") || lower.contains("refresh token") || lower.contains("account identifier") {
      return Message(
        title: L.t("Please sign in again", "Yeniden giriş yapın"),
        detail: L.t("Your ChatGPT session expired. Open Settings → ChatGPT account.",
                    "ChatGPT oturumunuzun süresi doldu. Ayarlar → ChatGPT hesabı."))
    }
    if lower.contains("429") || lower.contains("rate limit") || lower.contains("usage limit") {
      return Message(
        title: L.t("ChatGPT is busy", "ChatGPT şu an yoğun"),
        detail: L.t("You may have reached a usage limit. Try again in a moment.",
                    "Kullanım sınırına ulaşmış olabilirsiniz. Biraz sonra tekrar deneyin."))
    }
    if lower.contains("interrupted") || lower.contains("disconnected") || lower.contains("ice connection")
      || lower.contains("restarted the audio system") || lower.contains("task channel") {
      return Message(
        title: L.t("The conversation was interrupted", "Konuşma kesildi"),
        detail: L.t("Tap to reconnect.", "Yeniden bağlanmak için dokunun."))
    }
    if lower.contains("microphone") || lower.contains("record permission") {
      return Message(
        title: L.t("Microphone unavailable", "Mikrofon kullanılamıyor"),
        detail: L.t("Allow microphone access in iOS Settings, or end the other call, then try again.",
                    "iOS Ayarlar'dan mikrofon izni verin veya diğer aramayı bitirip tekrar deneyin."))
    }
    return Message(
      title: L.t("Something went wrong", "Bir sorun oluştu"),
      detail: L.t("Tap to try again. Details are in Settings → Developer.",
                  "Tekrar denemek için dokunun. Ayrıntılar Ayarlar → Geliştirici bölümünde."))
  }
}
