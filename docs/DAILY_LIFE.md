# Daily life

**Status: BUILD + UNIT TESTS** unless marked. Everything here is on the phone and works offline.

| Feature | Say | Notes |
|---|---|---|
| Notes | "not al: …", "bunu not et", "notlarım neler?", "Mercedes için aldığım notları söyle", "bu notu sil" | `docs/VOICE_ARCHITECTURE.md` |
| Tasks | "görev oluştur: …", "yarına görev oluştur", "todo'ya ekle", "bunu yapmam lazım" | `docs/TASKS.md` |
| Reminders, calendar, notifications | "yarın 10'da hatırlat", "takvime ekle", "20 dakika sonra haber ver" | Apple Reminders / Calendar / local notifications |
| **Place reminders** | "eve varınca süt almayı hatırlat", "işten çıkınca Ahmet'i aramayı hatırlat", "remind me to call mom when I get home" | Home and work only, from the addresses the user asked AutoLoom to remember ("Hatırla: ev adresim …"). The address is found on the map once and saved as an Apple Reminders location alarm (150 m, arriving or leaving); **Apple Reminders** rings it, so AutoLoom never tracks location. A time in the same sentence wins. **PHYSICAL TEST REQUIRED** |
| **Timers** | "10 dakika timer kur", "yumurta için 7 dakika timer", "timerı durdur", "ne kadar kaldı?" | A local notification rings in the background; the assistant says "Süre doldu" in a conversation; a chip counts down. **PHYSICAL TEST REQUIRED** for ringing while locked |
| **Shopping list** | "alışveriş listesine süt ve ekmek ekle", "sütü alışveriş listesine ekle", "alışveriş listemde ne var?", "sütü alışveriş listesinden çıkar" | Explore → Shopping list; duplicates skipped; Turkish accusative forms ("sütü", "ekmeği") stored as "Süt", "Ekmek" |
| **Evening / weekly review** | "Bugün ne yaptım?", "bu hafta ne yaptım?" | Counted from notes, done tasks, memories, captures and vehicles on the phone; nothing guessed |
| **Parking** | "park yerimi kaydet", "park yerimi kaydet: B2 katı 45", "arabamı B2 katına park ettim", "arabam nerede?", "beni arabama götür", "park yerini sil" | One location fix when asked (When In Use; never tracked) plus the user's words; Explore → Daily shows it with walking directions. Without location access (or with the phone locked, when iOS gives a When-In-Use app no fix) the words alone are kept, and it says so. **PHYSICAL TEST REQUIRED** for the location fix |
| **QR codes and barcodes** | "QR kodu oku", "barkodu oku", "read the QR code" | The current camera image (high detail) is read on the phone with Vision. A web address, Wi-Fi network, phone number, e-mail, product number or text is read out; nothing is opened, called or joined, and a Wi-Fi password is never read or shown. **PHYSICAL TEST REQUIRED** |
| **Undo** | "Son yaptığını geri al", "geri al", "undo" | The last local action within 10 minutes: a note, task, memory, shopping addition, timer, parking spot, damage note or odometer reading. **Never** a call, message or share |
| Morning briefing, start of work | "günün özeti", "işe başlıyorum" | Tasks, reminders, calendar; weather only from a real web search |
| Day plan | "Bugün ne yapmam gerekiyor?" | |
| Calls, messages, maps, clipboard, share | "Ahmet'i ara", "Ahmet'e … yaz", "beni eve götür", "bunu kopyala" | Never sent or called without the user's tap |
| Photos and videos | "fotoğraf çek", "video kaydını başlat", "kaydı durdur" | `docs/RAYBAN_MEDIA.md` |
| Modes | Settings → Personality → Mode | Automatic / General / Dealer / Daily life / Travel / Shopping / Translation / DIY / Accessibility; Dealer is automatic while a vehicle is active |

Not in this build (**UNAVAILABLE** here): reminders at places other than home and work, receipts and expense notes, flight tracking, command chaining and "Hayır, cuma değil cumartesi" corrections, a home-screen widget, Live Activities.
