# Physical test matrix

A checklist for a human tester with the real Ray-Ban Meta (Gen 1) glasses and the iPhone. None of these tests can run in CI: they need the glasses' camera, the microphone, iOS permissions, Siri, Spotlight, Apple Intelligence or a real network service. Say the Turkish phrases as written (the English ones are alternatives). Every row starts as **NOT RUN**; replace it with PASS or FAIL and a short note. Features and exact wording are described in the linked docs ([VOICE_COMMANDS.md](VOICE_COMMANDS.md), [DEALER_SUPERMODE.md](DEALER_SUPERMODE.md), [REMOTE_ASSIST.md](REMOTE_ASSIST.md) and the others).

## Setup

- Install the IPA built from commit `8ee1a24` or later; Settings → Developer → Diagnostics shows the commit.
- Glasses connected and streaming (Settings → Camera & Ray-Ban → Ray-Ban). ChatGPT account connected. App language Turkish.
- Allow permissions when iOS asks (Photos add-only, Reminders, Calendar, Location When In Use, Media Library, Local Network).
- Keep a conversation running unless a step says otherwise ("Hey AutoLoom" or the round button).
- After any FAIL, copy Settings → Developer → "İşlem ve görev izi / Action & task trace"; for camera tests also "Camera diagnostics".

## Tests

| ID | Feature | Steps (say / do) | Expected | Status |
|---|---|---|---|---|
| M1 | Ray-Ban photo | "Fotoğraf çek" | Shutter sound; "Fotoğrafı çektim ve galeriye kaydettim." only after Photos has it; never the iPhone camera | NOT RUN |
| M2 | Ray-Ban recording | "Video kaydını başlat" → 20 s → "Kayıt yapıyor musun?" → "Kaydı durdur" | Start/stop sounds; the status gives the time so far; a silent video (DAT 0.5) in Photos | NOT RUN |
| M3 | "Dur" vs "Kaydı durdur" | Start a recording; ask "Bana Kanada'daki araç vergilerini anlat"; while it answers say "Dur"; then "Kaydı durdur" | "Dur" silences the answer at once and the recording chip keeps counting; "Kaydı durdur" stops and saves the video | NOT RUN |
| M4 | "Dur" vs "Müziği durdur" | "Müzik çal"; wait until the assistant is silent; say "Dur"; then "Müziği durdur" | After "Dur" the music keeps playing (at most "Dinliyorum"); "Müziği durdur" pauses it | NOT RUN |
| M5 | Photo + note, gallery | "Bunun fotoğrafını çek ve not al: sağ ön jant çizik"; then "Galeriye kaydet" | One photo and one note; "galeriye kaydet" saves the newest capture kept only in AutoLoom | NOT RUN |
| LV1 | Live Vision on | "Bakmaya devam et" (camera streaming) | Short confirmation; "Canlı Görüş" chip; Settings → Performance: notes rise only when the view changes | NOT RUN |
| LV2 | "Ne değişti?" | Right after LV1: "Ne değişti?"; then turn to another room, wait 15 s: "Ne değişti?" | First: "Henüz karşılaştıracak iki görüntü yok."; then a one- or two-sentence difference, nothing invented | NOT RUN |
| LV3 | Live Vision off | "Canlı görüşü kapat"; then "Ne değişti?" | Live Vision ends; the second question is answered as an ordinary question, not a comparison | NOT RUN |
| VM1 | Visual memory save | Settings → Memory: Visual memories on, Keep the photo on. Look at keys on a table: "Anahtarımı buraya bıraktığımı hatırla" | Saved; Memory → Visual memory shows it with a photo and the text/objects read on the phone | NOT RUN |
| VM2 | "Nerede gördüm?" | Later, elsewhere: "Anahtarımı en son nerede gördüm?"; then "Cüzdanımı nerede görmüştüm?" | First: when (and place if on), as a saved memory; the photo opens. Second: "Görsel anılarında … yok. Sadece “bunu hatırla” dediğin şeyleri bilirim." | NOT RUN |
| VM3 | No photo, delete | Keep the photo off; "Bunu hatırla" at a sign; open it and tap Sil | No photo stored; after delete it is not found by VM2-style questions | NOT RUN |
| VM4 | Scene Timeline | Scene Timeline on; Live Vision 5 min through three places; "Bugün neler gördüm?" | Lines of text (≥ 2 min apart) on the Visual memory screen; no photos; the answer mentions them | NOT RUN |
| TR1 | Sign translation offline | Explore → Çeviri: download İngilizce → Türkçe. Airplane Mode on, then Bluetooth (and, if the glasses need it, Wi-Fi without joining a network) back on. Look at an English sign; type "Bu tabelayı Türkçeye çevir" in the Assistant text field (or run the "Translate What I See" shortcut) | Turkish translation on screen; trace executor "on-device OCR + Apple Translation (en→tr), no network" | NOT RUN |
| TR2 | Translation online fallback | Online, a language not downloaded: "Bu tabelayı Türkçeye çevir" | Translated by the vision model; trace "camera (high detail) + OCR + vision model" | NOT RUN |
| DOC1 | Document summary + reminder yes | Look at a letter with a date next month: "Bu belgeyi özetle"; answer "Evet" | 2–3 sentence summary; it offers a reminder for that date; after "Evet" a reminder "Belge: …" is in Apple Reminders | NOT RUN |
| DOC2 | Document reminder no | Repeat DOC1 and answer "Hayır" | No reminder is created | NOT RUN |
| DOC3 | Receipt + spending | At a receipt: "Fişi kaydet"; then "Bu ay ne harcadım?" | Store, total, date spoken; Explore → Belgeler ve fişler lists it with text only; the monthly sum per currency, "Yalnızca kaydettiğin fişler." | NOT RUN |
| DL1 | VIN read + decode | "Yeni araç"; at the VIN plate "VIN oku"; then "VIN'i çöz" | Last six characters; "doğrulandı" only when the check digit matches; unclear characters offered as options; clean decode fills year/make/model and equipment labelled "VIN'den çözüldü" | NOT RUN |
| DL2 | Recall wording | Identified vehicle: "Recall kontrol et"; vehicle screen → "Bu VIN'i <marka> sayfasında kontrol et" | "Transport Canada … modeli için N güvenlik geri çağırması listeliyor …; bu arama model yılına göre, VIN'e göre değil" plus the maker's page; never "geri çağırma yok"; the button copies the VIN and opens the page | NOT RUN |
| DL3 | Recall with no rows | Edit the model to a misspelling; vehicle screen → "Transport Canada'da kontrol et" | "… kayıt döndürmedi … Bu, geri çağırma olmadığı anlamına gelmez …" | NOT RUN |
| DL4 | Tire read | At a sidewall: "Sağ ön lastiği oku" | Size and DOT week/year with age, then "Diş derinliğini fotoğraftan ölçemem."; listed under Lastikler | NOT RUN |
| DL5 | Warning lights | Ignition on with a light lit: "Uyarı ışıklarına bak"; ignition off: again | Lights by name and colour + "Bu bir teşhis değil; servis kontrol etmeli."; then "Net yanan bir uyarı lambası görmedim …" or "Göstergeyi net göremedim …" | NOT RUN |
| DL6 | Condition report | "Sol taraf temiz", "Hasar ekle: sağ ön çamurluk çizik", "Kondisyon raporu", "Aracı dışa aktar" | Note with masked VIN, damage, "Kontrol edilmeyen bölgeler", the disclaimer; the share sheet opens; nothing sent automatically | NOT RUN |
| DL7 | Service handoff | "Servis notu hazırla" | Note with the full VIN, lights, tires, recall status, open tasks, "Teşhis içermez …" | NOT RUN |
| DL8 | Lot spot + directions | At the vehicle: "Aracın yerini kaydet"; walk 100 m; "Araç nerede duruyor?"; repeat with the phone locked | Saved; Maps walking directions open (app on screen); when locked, a card waits for a tap | NOT RUN |
| DL9 | Photo director hint | Vehicle active; move while "Fotoğraf çek"; then the same still shot twice | "Fotoğraf bulanık görünüyor …"; "Bir öncekiyle neredeyse aynı."; every photo kept | NOT RUN |
| DL10 | Part number, briefing | At a part label: "Parça numarasını oku"; then "Bayi özeti" | Number copied with `?` for unclear characters, in the vehicle's Research; briefing counts with no VIN read aloud | NOT RUN |
| RA1 | Remote Assist start/stop | "Uzaktan yardımı başlat"; tap Start (camera streaming); on a laptop on the same Wi-Fi open the address, try a wrong code, then the right one; say "Paylaşımı durdur" | Words alone share nothing; after Start: code, address, red bar on every screen; wrong code refused; ~2 fps video; stops at once. If Start says "Önce kameranın açık olması gerekiyor." while streaming → FAIL (known gap) | NOT RUN |
| RA2 | Remote Assist background | While sharing, go to the Home Screen; come back | Sharing stopped; notice "Uygulama arka plana geçtiği için paylaşım durdu."; the viewer's stream ends | NOT RUN |
| MU1 | Music | "Müzik çal", "Tarkan şarkısını çal", "Sonraki şarkı", "Ne çalıyor?", "Müziği durdur" | System Music player responds; the library prompt appears once; a song not in the library → "Kütüphanende … bulamadım" | NOT RUN |
| RT1 | Own routine | Explore → Rutinler → new "Sabah turu": Alışveriş listesini oku + Görevlerim; say "Sabah turu rutinini başlat" | Steps run in order; an honest "done / not done" summary | NOT RUN |
| RT2 | Built-in routines | "İşe başlıyorum", "Günün özeti", "Bugün ne yaptım?" | Tasks, next event, briefing; counts from the phone only | NOT RUN |
| SK1 | Skills (test MCP server) | Settings → Beceriler (MCP): add "Test" with an `https://` address (and token); "Bağlan ve araçları oku"; set a read-only tool to "İzin ver (salt okunur)"; ask "Test ile …" for a read-only tool, then a writing tool, then a destructive one; try an `http://` address | Read-only allowed runs at once; writing tool shows "Gönder: <host> · <tool> …" and "Evet" works; destructive refuses a spoken yes and runs after a tap; blocked never runs; `http://` refused | NOT RUN |
| SC1 | Own Shortcut | Make a Shortcut "Işıkları Aç"; say "Işıkları Aç kısayolunu çalıştır"; say "Evet"; then tap Run | A card "Kısayolu çalıştır: “Işıkları Aç”"; "Evet" alone does not run it; the tap opens Shortcuts and runs it | NOT RUN |
| SP1 | iOS Spotlight | Note "Corolla sol arka lastik"; put the app in the background; search "Corolla" in iOS Spotlight; tap it; check a vehicle's entry; turn on "Anıları da ekle" | The note appears and opens AutoLoom's search on it; vehicles show only the VIN's last six characters; memories appear only after the toggle | NOT RUN |
| SP2 | Voice search | "Geçen hafta Corolla ile ilgili kaydettiğim şeyi bul" | Top results spoken briefly; the list opens on the phone; nothing guessed when empty | NOT RUN |
| OF1 | Offline mode | Airplane Mode: start a conversation; type "not al: süt al"; type "Bugün hava nasıl?" | "Bağlantı kurulamadı."; the note is saved; the offline notice (or, with Apple Intelligence, "Çevrimdışı — bu iPhone'dan kısa bir yanıt: …"); the "Çevrimdışı" chip | NOT RUN |
| WK1 | Wake phrase | App open, wake phrase on: "Hey AutoLoom" | Nothing until the connection is ready; then chime + "Bağlandım, dinliyorum." once | NOT RUN |
| WK2 | Hands-Free Ready | Hands-Free Ready 30 min, lock the phone, wait 1 min, "Hey AutoLoom" | The conversation starts, or the app honestly shows "paused" | NOT RUN |
| AP1 | Siri and Shortcuts | "Hey Siri, Start AutoLoom"; "Hey Siri, AutoLoom take a photo"; "Hey Siri, New AutoLoom task" | App opens and listens; a Ray-Ban photo; the task is asked for and saved | NOT RUN |
| AI1 | Apple Intelligence | Settings → Intelligence status; say "Not al: Corolla'nın sol arka lastiği değişecek, müşteri cuma teslim istiyor" | Status shows Ready (with or without Turkish); on a supported iPhone the note gets a short title and tags within seconds | NOT RUN |

## Status

| Item | Status |
|---|---|
| All rows above | PHYSICAL_TEST_REQUIRED (NOT RUN) |
| Rows needing an MCP server (SK1) | REQUIRES_PROVIDER |
| Rows needing Apple Intelligence (AI1, part of OF1) | PHYSICAL_TEST_REQUIRED on an eligible iPhone |
| "Hey Meta, start AutoLoom" | WAITING_FOR_DAT1 (not testable in this build) |
