# Voice commands (Turkish first)

What to say to AutoLoom, grouped by area. Explicit commands are recognised on the iPhone by `VoiceActionIntentBridge` (LEVEL 1, no model) from the user's own final words, run locally, and only then does the voice model say the result. Everything else goes to the voice model. The phrases below come from the Action Catalog examples (checked by `AutoLoomActionCatalogTests`) and from the parser files and their tests (`VoiceMediaCommands`, `VoiceDealerCommands`, `VoiceDailyCommands`, `VoiceCommandsExtra`, `Documents`, `MusicControl`, `UserRoutines`, `RemoteAssist`, `Skills`, `ShortcutRunner`, `VisualMemory`). The full list with risks and statuses is in [ACTION_CATALOG.md](ACTION_CATALOG.md).

## How a sentence is handled

1. **Conversation control** ("Dur", "Kapat") is handled by the voice session first (`ConversationCommands`).
2. **Recording control**: "kaydı durdur", "kayıt yapıyor musun?" — even while a yes/no question waits.
3. **Answers** to a waiting action: yes, no, morning/evening, "hayır, cumartesi".
4. **Cancel** a running task ("iptal et", "vazgeç").
5. **Ray-Ban photo and video**, then **Dealer Mode**, then **parking, QR codes, timers, shopping list**, then **undo**.
6. The rest in this order: name, "neler yapabilirsin?", "ne değişti?", documents, music, Remote Assist, skills, shortcuts, translation, messages, notes, note questions, reminders, moving a task, tasks, day plan, calendar, task questions, routines, own routines, calls, contact questions, directions, clipboard, "nerede gördüm?", memory, search.
7. The answer to the app's own question ("Neyi not alayım?").

Tips:
- The name is optional: "AutoLoom, not al: …", "Jarvis, …"; near spellings such as "Oto lum" count. Leading "tamam", "peki", "şimdi", "lütfen", "bir de" are ignored.
- Dealer and camera commands must be the whole request: "yeni araç almak istiyorum", "VIN nedir?", "video nasıl çekilir?" are conversation.
- Text read by the camera, OCR or the web never reaches this parser, so nothing seen can trigger an action.
- Several commands in one sentence run in order (up to five parts, each a command on its own): "Alışveriş listesine süt ekle ve 10 dakika timer kur". Words after a colon stay together: "Not al: süt ve ekmek al" is one note.

## "Dur", "Kaydı durdur" and "Müziği durdur"

| Say | When | What happens |
|---|---|---|
| "Dur", "Sus", "Bekle", "Bir dakika", "Stop", "Wait" | The assistant is speaking | The answer is silenced at once. A recording, music or timer is **not** touched |
| "Dur" | The assistant is silent | Not a command; the voice model hears it and at most says "Dinliyorum" |
| "Jarvis dur", "AutoLoom stop" (with the name) | Speaking / silent | Stops the answer / **ends the conversation** |
| "Kaydı durdur", "Videoyu durdur", "Çekimi bitir", "Stop recording" | A Ray-Ban recording runs | Stops and saves the video. The parser checks it first, even while a yes/no question waits; "Stop recording" said over an answer also silences the answer |
| "Müziği durdur", "Şarkıyı durdur", "Müziği kapat", "Pause the music" | Music plays | Pauses the system Music player. "Dur" alone never pauses music |
| "Timerı durdur", "Zamanlayıcıyı iptal et" | A timer runs | Cancels the timer |
| "Paylaşımı durdur", "Stop sharing" | Remote Assist runs | Stops sharing at once |
| "Kapat", "Konuşmayı bitir", "Görüşürüz", "Goodbye" | Any time | Ends the conversation after a short goodbye |

The stop and end words can be turned off in Settings → Name & conversation → "Sesli durdurma komutları / Spoken stop commands" (on by default).

## Notes, tasks, reminders

| Say | What happens |
|---|---|
| "Not al: yarın kamerayı getir", "Şunu not et: yarın lastikler değişecek", "Mercedes cuma gelecek, bunu not al" | Note saved on the iPhone (linked to the active vehicle). The verb decides: a day word does not make it a reminder |
| "Notlarım neler?", "Mercedes için aldığım notları söyle", "Bu notu sil" | Reads or finds notes; deleting waits for "evet" |
| "Görev oluştur: lastikleri kontrol et", "Yarına görev oluştur: Civic evraklarını hazırla", "Todo'ya ekle: sigorta" | AutoLoom task (with a due date when said) |
| "Görevlerim neler?", "Lastik görevini tamamla", "Lastik görevini cumaya ertele" | Lists, completes, moves a task |
| "Yarın 10'da Ahmet'i aramayı hatırlat", "20 dakika sonra fırını kapatmayı hatırlat" | Apple Reminder with an alarm |
| "Eve varınca süt almayı hatırlat", "İşten çıkınca Ahmet'i aramayı hatırlat" | Location reminder at the saved home/work address |
| "20 dakika sonra bana haber ver" | Local notification |
| "Cuma 3'te toplantı ekle", "Bugün takvimimde ne var?", "Bugün ne yapmam gerekiyor?" | Calendar event (asks when the time is unclear), calendar, day plan |
| "Evet", "Hayır", "Akşam", "Hayır, cumartesi", "Son yaptığını geri al" | Answer, correct or undo the last local action |

English: "Take a note: buy tires", "Add a task: call the bank", "Remind me to call mom tomorrow at 9".

## Memory and visual memory

| Say | What happens |
|---|---|
| "Bunu hatırla: arabam siyah", "Unutma: kapı kodu 4512", "Ahmet yarın gelecek, bunu hatırla" | Saved to memory (only because you asked) |
| "Hatırlıyor musun kapı kodunu?", "Ne hatırlıyorsun?", "Geçen hafta bununla ilgili ne konuşmuştuk?" | Recall, list, earlier conversations |
| "Kapı kodunu unut" | Deleted after "evet" |
| "Benim adım Tolga", "Benim adım ne?" | Name saved / said |
| "Bunu hatırla", "Anahtarımı buraya bıraktığımı hatırla" (camera on, visual memories on) | Visual memory of the current view ([VISUAL_MEMORY.md](VISUAL_MEMORY.md)) |
| "Anahtarımı en son nerede gördüm?", "Cüzdanımı nerede görmüştüm?" | Searches your visual memories and opens the photo if one was kept |
| "Bugün neler gördüm?", "Görsel anılarımı göster" | Today's visual memories and Scene Timeline lines |

"Anahtarımı nereye bıraktım?" is a memory question, not a visual search. English: "Remember that my car is black", "Where did I last see my keys?".

## Camera (Ray-Ban) and Live Vision

| Say | What happens |
|---|---|
| "Fotoğraf çek", "Jantın fotoğrafını çek", "Bu aracın önünü çek" | Ray-Ban photo (never the iPhone camera), labelled for Dealer Mode |
| "Bunun fotoğrafını çek ve not al: sağ ön jant çizik" | Photo plus a note |
| "Video kaydını başlat", "Kayda başla", "Kaydı durdur" | Silent Ray-Ban video (DAT 0.5 has no camera audio), saved when stopped |
| "Kayıt yapıyor musun?", "Ne kadar oldu?" (while recording) | Recording status |
| "Galeriye kaydet" | The newest capture kept only in AutoLoom goes to Photos |
| "QR kodu oku", "Barkodu oku" | Read on the phone; a link, number or Wi-Fi network is never opened or joined |
| "Bakmaya devam et", "Canlı görüşü aç", "Canlı görüşü kapat" | Live Vision on/off — decided by the voice model; needs a conversation and a camera |
| "Ne değişti?", "Bir şey değişti mi?" (Live Vision on) | Compares the last two scene notes; otherwise it is an ordinary question |
| "Ne görüyorum?", "Şunu oku", "Bu tabelada ne yazıyor?" | The voice model delegates; the app sends a fresh frame (high detail for reading) |

Not commands: "video nasıl çekilir?", "not al: fotoğraf çek" (a note), "yarın fotoğraf çekmeyi hatırlat" (a reminder). English: "Take a photo", "Start recording", "Keep watching", "What changed?".

## Translation, documents, receipts

| Say | What happens |
|---|---|
| "Bu tabelayı Türkçeye çevir", "Şunu İngilizceye çevir" (camera on) | Read and translated on the phone when the languages are downloaded; otherwise by the vision model |
| "Bu belgeyi özetle", "Bu belgede ne var?" | Text read on the phone; a future date is offered as a reminder, created only after "evet" |
| "Fişi kaydet", "Bu faturayı kaydet" | Store, total and date saved (text only, no photo) |
| "Bu ay ne harcadım?" | Sum of the receipts you saved this month, per currency |

English: "Translate this sign into Turkish", "Summarize this document", "Save this receipt". Details: [TRANSLATION_AND_DOCUMENTS.md](TRANSLATION_AND_DOCUMENTS.md).

## Dealer SuperMode

| Say | What happens |
|---|---|
| "Yeni araç", "Sonraki araç", "Bu araç tamam", "Araç durumu" | Start / next / close the vehicle; its summary |
| "VIN oku", "Şasi numarasını oku", "VIN'i çöz" | High-detail VIN read with the check digit; NHTSA vPIC decode |
| "Kilometreyi oku", "Kilometre 45 bin 320" | Odometer from the camera / as said |
| "Hasar ekle: sağ ön çamurluk çizik", "Hasar: ön cam çatlak"; with a vehicle active also "Sağ ön jant çizik, not et" | Damage with body zone and kind (starts a vehicle if none is open) |
| "Sol taraf temiz", "Ön taraf hasarsız" (vehicle active) | Area of the walk-around checked |
| "Foto checklist", "Kaç foto kaldı?", "Teslim listesi" | Missing photos / delivery items |
| "Recall kontrol et", "Lastiği oku", "Sağ ön lastiği oku", "Uyarı ışıklarına bak", "Parça numarasını oku" | Canadian recalls, tire size and DOT date, lit warning lights, part number |
| "Kondisyon raporu", "Hasar raporu hazırla", "Servis notu hazırla", "Aracı dışa aktar" | Reports saved as notes; export through the share sheet |
| "Aracın yerini kaydet", "Araç nerede duruyor?" (vehicle active) | Lot spot; walking directions |
| "Piyasa bak", "İlan hazırla", "Bayi özeti" | Market research, listing draft, today's dealer picture |
| "Kaç kilometre?", "VIN'i neydi?", "Ne eksik?" (vehicle active) | Answered from the vehicle's record |

Details: [DEALER_SUPERMODE.md](DEALER_SUPERMODE.md), [DEALER_MODE.md](DEALER_MODE.md).

## Daily life: timers, shopping, parking, music

| Say | What happens |
|---|---|
| "10 dakika timer kur", "Yumurta için 7 dakika timer", "Ne kadar kaldı?" (timer running), "Timerı durdur" | Timer with a local notification ("Eve ne kadar kaldı?" is not about the timer) |
| "Alışveriş listesine süt ve ekmek ekle", "Alışveriş listemde ne var?", "Sütü alışveriş listesinden çıkar" | Shopping list on the iPhone |
| "Park yerimi kaydet: B2 katı 45 numara", "Arabam nerede?", "Beni arabama götür", "Park yerini sil" | One location fix plus your words; walking directions |
| "Müzik çal", "Tarkan şarkısını çal", "Sonraki şarkı", "Önceki şarkı", "Ne çalıyor?", "Müziği durdur" | System Music player; songs by name only from your own library ("Zili çal" is not music) |

English: "Set a timer for 10 minutes", "Add milk to my shopping list", "Where did I park?", "Play some music".

## Routines, Remote Assist, skills, shortcuts

| Say | What happens |
|---|---|
| "İşe başlıyorum", "Günün özeti", "Brifing ver", "Bugün ne yaptım?", "Bu hafta ne yaptım?" | Built-in routines and reviews |
| "Sabah turu rutinini başlat" (or just "Sabah turu" for a name of two words or more) | Your routine from Explore → Routines, step by step, with an honest report |
| "Uzaktan yardımı başlat", "Görüntümü paylaş" | Opens Remote Assist; nothing is shared until you tap Start |
| "Paylaşımı durdur" | Stops sharing |
| "Notion ile bugünkü görevlerimi listele", "Notion'a sor: …", "Ask Notion to list my tasks" | A tool of an MCP server you added ([SKILLS_MCP.md](SKILLS_MCP.md)) |
| "Işıkları Aç kısayolunu çalıştır", "Run the Good Night shortcut" | Your own Shortcut, after a tap on the card |

## Search and help

| Say | What happens |
|---|---|
| "Geçen hafta Corolla ile ilgili kaydettiğim şeyi bul", "Mercedes için çektiğim jant fotoğraflarını göster", "Lastikle ilgili kaydettiklerimi bul" | One on-device search; date words (bugün, dün, bu hafta, geçen hafta, bu ay, geçen ay) and kind words (not, görev, araç, fotoğraf) become filters ([SPOTLIGHT.md](SPOTLIGHT.md)) |
| "Neler yapabilirsin?", "Hangi komutlar var?", "Bayide neler yapabilirsin?", "Kamerayla neler yapabilirsin?" | A few examples by voice; the Command Library opens (on a category when named) |

Also recognised: "Ahmet'i ara", "Ahmet'e mesaj at: geliyorum" (both wait for your tap), "Beni eve götür", "En yakın eczane nerede", "Bunu kopyala", "Bunu paylaş".

## Status

| Area | Status |
|---|---|
| Parsing of every phrase above | WORKING (unit tests; not re-run for this page) |
| Speaking to the glasses and hearing the result | PHYSICAL_TEST_REQUIRED |
| Live Vision start/stop, "Ne görüyorum?", web questions | PHYSICAL_TEST_REQUIRED (voice model decides; needs network) |
| Skills | REQUIRES_PROVIDER (an MCP server you add) |
| Photos, video, VIN, tires, documents, Remote Assist | PHYSICAL_TEST_REQUIRED |
| "Hey Meta, start AutoLoom" | WAITING_FOR_DAT1 |
