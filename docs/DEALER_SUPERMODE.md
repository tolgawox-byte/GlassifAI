# Dealer SuperMode

Dealer SuperMode extends [Dealer Mode](DEALER_MODE.md) (vehicle sessions, VIN reading, odometer, damage, checklists, market research, listings) with VIN decoding by NHTSA vPIC, Canadian recall lookups at Transport Canada, tire size and DOT age, lit warning lights, a walk-around, a condition report, a service handoff note, the vehicle's spot on the lot, part numbers, photo quality hints and a morning briefing. Readings from the camera are copied exactly, with `?` for anything unclear; nothing is certified, diagnosed or priced by the app, and nothing is sent to AutoLoom Media automatically. Code: `Runtime/VehicleData.swift`, `DealerSuperMode.swift`, `DealerSuperViews.swift`, `PhotoDirector.swift`, `DealerRunner.swift`, `VoiceDealerCommands.swift`, `UserRoutines.swift` (`DealerBriefing`).

## Commands

| Say | Does |
|---|---|
| "VIN oku", "Şasi numarasını oku" | High-detail read, ISO 3779 check digit ([DEALER_MODE.md](DEALER_MODE.md)); a verified VIN is decoded right away |
| "VIN'i çöz", "VIN'i çözümle" | NHTSA vPIC decode of the saved VIN |
| "Recall kontrol et", "Recall var mı" | Transport Canada lookup by make, model and year |
| "Lastiği oku", "Sağ ön lastiği oku" | Tire size and DOT date from the sidewall |
| "Uyarı ışıklarına bak", "Gösterge paneline bak" | Lit warning lights by name and colour |
| "Sol taraf temiz", "Ön taraf hasarsız" (vehicle active) | One walk-around area checked, no damage |
| "Kondisyon raporu", "Hasar raporu hazırla" | Condition report saved as a note |
| "Servis notu hazırla", "Servise devret" | Service handoff saved as a note |
| "Aracın yerini kaydet" / "Araç nerede duruyor?" (vehicle active) | Lot spot / walking directions to it |
| "Parça numarasını oku" | Part number copied exactly |
| "Aracı dışa aktar" | Condition report through the share sheet |
| "Bayi özeti", "Bugün bayide ne var?" | Dealer briefing |
| "Kaç kilometre?", "VIN'i neydi?", "Rengi ne?", "Ne hasar var?", "Stok numarası ne?", "Bu araç tamam mı?", "Ne eksik?" (vehicle active) | Answered from the vehicle record; the VIN is read as its last six characters |

A command must be the whole request ("VIN nedir?" is a question). The lot, area, spoken-damage ("…, not et") and vehicle-question phrases are recognised only while a vehicle is active; a tire reading is spoken without one but saved only to an active vehicle.

## VIN decoding (NHTSA vPIC)

- `GET https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/<VIN>?format=json`, keyless, 12 s timeout. The VIN leaves the phone for this request only.
- **Only `ErrorCode` "0" is a clean decode.** Codes 1, 5, 6, 11 or 400 mean "probably misread: read it again" and fill nothing. Any other code is partial: only an empty year and make are filled, and the screen says "Kısmen çözüldü; eksikleri sen tamamla."
- A clean decode fills year, make, model and trim unless the identification was confirmed by the user, fills the body style if empty, marks the identification confirmed when the VIN's check digit is verified, and replaces earlier VIN-decoded equipment.
- Equipment kept: drive type, engine (cylinders and displacement), fuel, transmission, body class, each labelled **"VIN'den çözüldü / VIN decoded"**. An empty value or "Not Applicable" means no data, never "not equipped".
- vPIC is US federal data; it is used for identification, not for Canadian specifications.

## Recalls (Transport Canada)

- Official Vehicle Recalls Database API (`data.tc.gc.ca/v1.3`), keyless. The request needs `Accept: application/json`.
- It searches **by make, model and year, never by VIN**. If the model or year is missing and the VIN is verified, the app decodes it first.
- Up to 4 pages of 25 rows. Rows are kept only when the model name matches exactly (the API matches prefixes: "CIVIC HYBRID" is not "CIVIC"); each campaign once.
- Up to 12 campaign summaries are fetched (system, notification type, comment ≤ 600 characters, date). "Safety" means the notification type contains safety or compliance (or has none).
- Spoken wording (TR): "Transport Canada 2018 Honda Civic modeli için N güvenlik geri çağırması listeliyor (sistemler: …); bu arama model yılına göre, VIN'e göre değil (tarih)." Then: "Bu VIN için üreticinin sayfasında (…) kontrol gerekiyor."
- **Never "no recalls"**: zero rows are spoken as "Transport Canada … için kayıt döndürmedi. Bu, geri çağırma olmadığı anlamına gelmez; model adı farklı yazılmış olabilir."
- **Manufacturer VIN pages**: a table of 32 makes (Honda, Toyota, Ford, GM brands, Stellantis brands, Hyundai, Kia, BMW, Mercedes-Benz, Volvo, Tesla…) gives each maker's Canadian recall page. On the vehicle screen, "Bu VIN'i <marka> sayfasında kontrol et" copies the VIN to the clipboard and opens that page; the app never reads those pages.
- If Transport Canada cannot be reached, or the year/make/model are unknown, the voice command falls back to web research with the same rules (by-model results, the date, and "a VIN-specific check is still needed"). With neither make nor VIN it asks to identify the vehicle first.
- The result is stored on the vehicle (`recallCheck`) and listed under Research with its sources.

## Tires and DOT codes

- The vision model is asked to copy the size code and the DOT code exactly, `?` for anything uncertain, and not to judge tread or condition.
- The phone parses the size (`215/55R16 93V`: width 125–395, aspect 25–85, R/ZR/D/B, rim 10–24, optional load index and speed rating). An unreadable digit gives no size.
- DOT date: the last four digits after "DOT" (week 1–53, year 2000+), then the age in years.
- Spoken: "Sağ ön: ebat 215/55R16 93V, üretim 23. hafta 2019 (yaklaşık 7.3 yıllık). Diş derinliğini fotoğraftan ölçemem." **Tread depth is never estimated.**
- A reading is saved on the active vehicle only when a size or a DOT date was parsed. The service handoff flags tires older than 6 years.

## Warning lights

The vision model lists only lights that are clearly lit, by standard name and colour, or "none" / "unclear". Up to eight are saved as the vehicle's warning lights. Spoken: "Yanan uyarı lambaları: … Bu bir teşhis değil; servis kontrol etmeli." With the cluster unclear: "biraz yaklaş, kontak açık olmalı". **No diagnosis** is ever given.

## Equipment provenance

Every equipment fact carries a source: "VIN'den çözüldü" (green), "Görüldü" (blue), "Senin onayın" (green), "Doğrulanmadı" (orange). The vehicle screen's footer: a missing value means unknown, never "not equipped". In this build only VIN-decoded equipment is created; nothing yet adds "seen" or "confirmed by you" options.

## Walk-around, condition report, service handoff

- Nine areas: front, rear, left side, right side, roof, interior, underbody, wheels and tires, engine bay. An area counts as looked at when it is marked clean (voice or a tap on the vehicle screen) or has a damage note. After each "temiz" the next unchecked area is suggested. Undo works.
- **Condition report**: title, date, masked VIN with verified/not verified, stock, odometer, colour, every damage note (with photo counts), tires, warning lights, interior and mechanical notes, equipment with its source, areas marked clean and **areas not checked**, photos done/total, the recall wording, and "Bu rapor kaydedilen gözlemlerden oluşur; güvenlik muayenesi veya ekspertiz yerine geçmez." Saved as a note linked to the vehicle.
- **Service handoff**: stock, the **full VIN** (the service needs it; the note stays on the phone unless shared), odometer, warning lights, mechanical notes, damage, tires (older than 6 years flagged), the recall wording or "Geri çağırma kontrolü yapılmadı.", open vehicle tasks, and "Teşhis içermez; yalnızca kaydedilen gözlemler."

## Lot spot and part numbers

- "Aracın yerini kaydet": one When-In-Use location fix (10 m accuracy, 10 s timeout) and a place name when reverse geocoding works; saved on the vehicle; undo works. Without permission or a fix nothing is saved and the reason is said.
- "Araç nerede duruyor?": Apple Maps walking directions to the saved point; opens directly while the app is on screen, otherwise a card waits for a tap. Needs iPhone actions and the Maps tool allowed.
- "Parça numarasını oku": copied exactly (`?` for unclear characters, "none" when nothing is visible), saved under the vehicle's research; the assistant offers to look it up.

## Photo director

After a Ray-Ban photo linked to a vehicle, the phone measures it on a 320-pixel copy (nothing is sent anywhere; the photo is always kept) and speaks one hint:

| Measured | Hint |
|---|---|
| Laplacian variance < 40 | "Fotoğraf bulanık görünüyor; sabit durup tekrar çekebilirsin." |
| Mean brightness < 45 / > 215 | "Fotoğraf karanlık; daha aydınlık bir açı dene." / "Fotoğraf fazla parlak." |
| More than 6 % near-white pixels | "Parlama var; açıyı biraz değiştir." |
| 16×16 thumbnail differs by < 6 from the vehicle's previous photo | "Bir öncekiyle neredeyse aynı." |

## AutoLoom Media adapter

`InventoryAdapter` (name, `isConfigured`, `publish(vehicle)` after the user confirmed) is the only way a vehicle could be sent to AutoLoom Media. **None is registered in this build**; the vehicle screen shows "AutoLoom Media · Bağlı değil" and "AutoLoom Media'ya hiçbir şey otomatik gönderilmez." Until an adapter exists, a vehicle leaves the phone only through the share sheet.

## Dealer briefing

"Bayi özeti" reads only the phone's records: open vehicles, vehicles with photos missing (up to four), no VIN yet, VIN read but recall check not done, damage notes without a photo, vehicle tasks due today. The assistant says it in two or three sentences, most urgent first, and **never reads VINs aloud**. It is also listed among the built-in routines. Explore → Routines → "Proaktif" has an optional daily notification (off by default, 08:00 unless changed) that only says the briefing is ready ("Brifingin hazır. “Günün özeti” ya da “bayi özeti” de."); it never shows tasks, events or vehicles.

## Privacy

Vehicles are stored in `Application Support/AutoLoom/dealer.json`. The VIN goes to NHTSA only for decoding; make, model and year go to Transport Canada; market research (web search) and listing drafts (reasoning) send the vehicle's fact sheet, including the full VIN, to the connected cloud agent; the recall web fallback does the same. No customer, plate (unless typed) or driver's licence data is kept.

## Status

| Item | Status |
|---|---|
| vPIC parsing and decode rules, recall wording and exact-model filter, tire and DOT parsing, reports, photo hints, briefing, voice phrases | WORKING (unit tests with stubbed HTTP) |
| Live vPIC and Transport Canada calls | PHYSICAL_TEST_REQUIRED (network) |
| VIN, tire, warning-light and part-number reading through the Ray-Ban camera | PHYSICAL_TEST_REQUIRED |
| Lot spot | PHYSICAL_TEST_REQUIRED, REQUIRES_PERMISSION (location) |
| "Seen" / "confirmed by you" equipment | PARTIAL (labels exist; nothing creates them) |
| AutoLoom Media adapter | UNAVAILABLE (no adapter; share sheet only) |
