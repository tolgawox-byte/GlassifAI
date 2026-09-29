# Dealer Mode

**Status: BUILD + UNIT TESTS; PHYSICAL TEST REQUIRED** (reading a real VIN plate and odometer through the Ray-Ban camera, the walkaround with photos).

## Quick commands (Turkish and English)

| Say | Does |
|---|---|
| "Yeni araç" / "new vehicle" | Starts a vehicle session (it becomes active) |
| "VIN oku" / "şasi numarasını oku" / "read the VIN" | High-detail camera read, then a local ISO 3779 check (see below) |
| "Kilometre" / "kilometreyi oku" | Reads the odometer from the camera |
| "Kilometre 45 bin 320" / "odometer 28,500 miles" | Saves what the user said, with unit and time |
| "Hasar ekle: sağ ön çamurluk çizik" / "hasar: ön cam çatlak" | Damage with a normalised body zone and kind |
| "Jantın fotoğrafını çek", "bu aracın önünü çek", "hasarın fotoğrafını çek" | Ray-Ban photo linked to the vehicle; ticks the photo checklist |
| "Foto checklist" / "hangi fotoğraflar kaldı" | The photos still missing |
| "Delivery checklist" / "teslim listesi" | What is left before delivery |
| "Piyasa bak" | Market research with the vehicle's known facts (research agent: Perplexity when connected, else ChatGPT web search); a suggestion only — the dealer decides the price |
| "İlan hazırla" | A listing draft from known facts only (no invented options; known damage stated; unverified identification marked); saved as a note |
| "Araç durumu" / "bayi özeti" | The active vehicle / today's dealer summary |
| "Not al: …", "görev oluştur: …" | Linked to the active vehicle |
| "Bu araç tamam" / "Sonraki araç" | Closes the vehicle (with what is missing) / closes it and starts the next |

A command must be the whole request: "yeni araç almak istiyorum" is conversation; "VIN nedir?" is a question for the voice model.

## VIN

- The camera reads it at high detail with on-device OCR; the model is told to write `?` for any character it cannot read and never to guess.
- `VINValidator`: 17 characters, no I/O/Q (a read "O" is taken as "0" and the correction is stated), the North American check digit at position 9.
- **Never invented**: an unreadable character stays unknown; when the check digit narrows it down, the options are spoken ("14. karakter 4, D, M veya U"); a look-alike that would fix the check digit is reported, not applied ("8. karakter G veya 6").
- A VIN with unknown characters is not saved. A VIN whose check digit does not match is saved as **not verified** (the check digit is mandatory only for North American vehicles).
- The screen shows the last six characters; the shared export has the full VIN.

## Identification

Make/model from the camera are a **visual guess** until confirmed (by a verified VIN or the user); listings and research say so.

## Safety and privacy

- Never "safe to drive" (the Dealer mode instructions say so).
- No driver's licence data: the test-drive checklist has "Licence checked (not stored)".
- The plate is stored only if the user types it; no customer database; nothing is uploaded; vehicle data goes to an agent only as needed for the requested task (research, listing).
- Stored in `Application Support/AutoLoom/dealer.json` on this iPhone; Privacy center → Delete all local data removes it.

## Screens

Explore → Dealer: dashboard (today, open, ready, photos left), the active vehicle card (masked VIN, odometer, status, damage, photo progress, linked items), buttons (Read VIN, Odometer, Next vehicle, Done), every vehicle. Vehicle detail: editable identification, status, damage (swipe to delete), photo / delivery / test-drive checklists, research and drafts, export (share sheet), make active, delete.
