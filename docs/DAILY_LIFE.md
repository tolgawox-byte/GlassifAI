# Daily life

**Status: BUILD + UNIT TESTS** unless marked. Everything here is on the phone and works offline.

| Feature | Say | Notes |
|---|---|---|
| Notes | "not al: …", "bunu not et", "notlarım neler?", "Mercedes için aldığım notları söyle", "bu notu sil" | `docs/VOICE_ARCHITECTURE.md` |
| Tasks | "görev oluştur: …", "yarına görev oluştur", "todo'ya ekle", "bunu yapmam lazım" | `docs/TASKS.md` |
| Reminders, calendar, notifications | "yarın 10'da hatırlat", "takvime ekle", "20 dakika sonra haber ver" | Apple Reminders / Calendar / local notifications |
| **Timers** | "10 dakika timer kur", "yumurta için 7 dakika timer", "timerı durdur", "ne kadar kaldı?" | A local notification rings in the background; the assistant says "Süre doldu" in a conversation; a chip counts down. **PHYSICAL TEST REQUIRED** for ringing while locked |
| **Shopping list** | "alışveriş listesine süt ve ekmek ekle", "sütü alışveriş listesine ekle", "alışveriş listemde ne var?", "sütü alışveriş listesinden çıkar" | Explore → Shopping list; duplicates skipped; Turkish accusative forms ("sütü", "ekmeği") stored as "Süt", "Ekmek" |
| **Evening / weekly review** | "Bugün ne yaptım?", "bu hafta ne yaptım?" | Counted from notes, done tasks, memories, captures and vehicles on the phone; nothing guessed |
| **Undo** | "Son yaptığını geri al", "geri al", "undo" | The last local action within 10 minutes: a note, task, memory, shopping addition, timer, damage note or odometer reading. **Never** a call, message or share |
| Morning briefing, start of work | "günün özeti", "işe başlıyorum" | Tasks, reminders, calendar; weather only from a real web search |
| Day plan | "Bugün ne yapmam gerekiyor?" | |
| Calls, messages, maps, clipboard, share | "Ahmet'i ara", "Ahmet'e … yaz", "beni eve götür", "bunu kopyala" | Never sent or called without the user's tap |
| Photos and videos | "fotoğraf çek", "video kaydını başlat", "kaydı durdur" | `docs/RAYBAN_MEDIA.md` |
| Modes | Settings → Personality → Mode | Automatic / General / Dealer / Daily life / Travel / Shopping / Translation / DIY / Accessibility; Dealer is automatic while a vehicle is active |

Not in this build (**UNAVAILABLE** here): location-based reminders, QR/barcode scanning, receipts and expense notes, flight tracking, a dedicated parking command (visual memory with "Attach the place" covers "nereye park ettiğimi hatırla"), command chaining and "Hayır, cuma değil cumartesi" corrections, a home-screen widget, Live Activities.
