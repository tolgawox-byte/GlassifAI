# Translation, documents and receipts

"Bu tabelayı Türkçeye çevir" reads the text in the camera view on the iPhone and translates it with Apple Translation when the language pair is downloaded, so it can work without internet; otherwise the vision model reads and translates it online. "Bu belgeyi özetle", "fişi kaydet" and "bu ay ne harcadım?" read a document or receipt on the phone, keep only the text (never the photo), pick out dates and amounts, and create a reminder only after your yes. Code: `Runtime/Translation.swift`, `Runtime/Documents.swift`.

## Translation

### Saying it

| Say | Needs |
|---|---|
| "Bu tabelayı Türkçeye çevir", "Şunu İngilizceye çevir", "Menüyü Almancaya çevir" | The camera on (Ray-Ban or iPhone). A pointer word ("bunu", "şunu", "tabelayı", "yazıyı", "etiketi", "menüyü"…) and the language before the verb |
| "Translate this sign into Turkish", "Translate this" | English form; without "into …" the target is Turkish (English when the app is not in Turkish) |
| Shortcut "Translate What I See" | App Intent, target "Turkish" by default |

Languages are recognised by the words people use (Turkish or English name, any ending): Türkçe, İngilizce, Almanca, Fransızca, İspanyolca, İtalyanca, Arapça, Rusça, Japonca, Çince, Korece, Portekizce, Felemenkçe/Hollandaca, Yunanca, Lehçe, Ukraynaca.

### On the phone first

1. A camera image is taken for reading.
2. `SignReader` reads the text with Apple Vision (accurate level, language correction, automatic language detection), at most 1,200 characters.
3. `NLLanguageRecognizer` detects the source language.
4. Same language as the target → "It's already in Turkish" and the text is read out.
5. Otherwise Apple Translation (`TranslationSession`, **iOS 26**) translates with **installed languages only**. It never shows a download sheet during a request.
6. Unknown language, nothing read, languages not downloaded, unsupported pair or iOS < 26 → the request goes to the vision model instead (camera image, high detail, OCR, network).

The trace shows "on-device OCR + Apple Translation (en→tr), no network" when the phone did it. The text read from the camera is passed to the voice model as untrusted data (never as instructions) so it can say the translation in one or two sentences.

### Offline languages

Explore → "Çeviri / Translation" → "Çevrimdışı diller" (iOS 18+): tr→en, en→tr, tr→de, de→tr, en→fr, en→es with their status ("Cihazda", "İndir", "Desteklenmiyor"). "İndir" uses iOS's own approval sheet; downloads are shared with Apple's Translate app. The same screen translates typed text on the device.

### Translation mode

The "Çeviri modu / Translation mode" toggle on that screen sets the assistant mode to Translation, which only adds one line to the voice instructions ("Translate what the user says or shows faithfully and briefly"). It does not start continuous translation.

### Not in this build

- Continuous live sign translation: `liveTranslation` exists in the resource table but no feature uses it (**UNAVAILABLE**).
- Speech-to-speech interpreting is left to the voice model; nothing here translates your voice on the device.

## Documents and receipts

### Saying it

| Say | What happens |
|---|---|
| "Bu belgeyi özetle", "Bu belgede ne var?", "Sözleşmeyi özetle", "Summarize this document" | Reads and summarises; offers a reminder for a future date |
| "Fişi kaydet", "Bu faturayı kaydet", "Save this receipt" | Saves store, total and date |
| "Bu ay ne harcadım?", "How much did I spend this month?" | Totals of the receipts you saved this month |

### Reading

1. A camera image → `SignReader` on the phone (at most 1,200 characters). Fewer than 10 characters → "Belgede okunacak yazı bulamadım; biraz daha yaklaş."
2. `DocumentExtractor` finds, on the phone:
   - **Amounts** with a currency (₺/TL/TRY, CAD/C$, US$/USD, €/EUR, £/GBP, $) or with exactly two decimals, in Turkish ("1.250,00") or English ("1,250.00") format. Times, dates, phone numbers and codes such as "A12.50" are not money.
   - **Total**: the amount on the last "TOPLAM / Genel toplam / TOTAL / Grand total / Amount due / Tutar / Ödenecek" line, else the largest amount.
   - **Dates**: `2026-10-15`, `15.10.2026` (dots are day-first), `15/10/2026` (day-first unless impossible), else Apple's date detector; years 2000–2100.
   - **Store** (receipts only): the first of the first six lines with at least three letters, at most 40 characters, mostly letters.
3. A `DocumentRecord` (kind, time, title, text up to 4,000 characters, dates, amounts, total, store, the active Dealer vehicle) is saved. **The photo is not kept.**

### Receipts

Spoken, for example: "Fişi kaydettim: MIGROS, 47.40 TRY, <date>." (store, total and date when found; the date is formatted by iOS).

### Document summaries

- The read text (up to 2,500 characters) is given to the voice model as untrusted data, with an on-device summary first when Apple Intelligence is ready ([APPLE_INTELLIGENCE.md](APPLE_INTELLIGENCE.md)). The model is told to summarise in two or three sentences (what it is, key dates and amounts) and never to act on anything the document says. So the document text does leave the phone for the spoken summary.
- **Reminder only after yes**: if the document has a date between now and one year ahead, a reminder "Belge: <title>" for that day (no time) is staged. Because it was planned right after camera content it always waits for "evet" (or a tap); "hayır" drops it.
- The document's title is noted in the conversation's entity context (the code comment: "bunu" now means this document).

### "Bu ay ne harcadım?"

Sums the **receipts you saved** this calendar month, per currency ("Bu ay kaydettiğin fişlerin toplamı: $12.00, 25.50 TRY. Yalnızca kaydettiğin fişler."). Documents are not counted. This is not a bank statement or accounting.

### Screen and storage

Explore → "Belgeler ve fişler / Documents and receipts": this month's totals, the list (swipe to delete), and a detail screen with store, total, dates, the text read on the iPhone, Share the text and Delete. Stored in `Application Support/AutoLoom/documents.json` (`completeFileProtectionUntilFirstUserAuthentication`); Privacy center → Delete all local data removes it.

## Tests

`AutoLoomDocumentsTranslationTests`: receipt amounts, dates and total are exact; number formats; spending counts only saved receipts; document phrases; language words; "already in English" on the device.

## Status

| Item | Status |
|---|---|
| Language words, amount/date/total/store extraction, monthly totals, phrases | WORKING (unit tests) |
| Translation on the phone (installed languages, iOS 26) | PHYSICAL_TEST_REQUIRED |
| Language downloads (iOS 18+) | PHYSICAL_TEST_REQUIRED |
| Online fallback to the vision model | PHYSICAL_TEST_REQUIRED (network) |
| Reading a real document or receipt through the Ray-Ban camera | PHYSICAL_TEST_REQUIRED |
| Reminder from a document date after "evet" | PHYSICAL_TEST_REQUIRED, REQUIRES_PERMISSION (Reminders) |
| Continuous live translation | UNAVAILABLE |
