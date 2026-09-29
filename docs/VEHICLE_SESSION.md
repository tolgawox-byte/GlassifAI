# Vehicle session (`VehicleSession`, `DealerStore`)

A Codable struct in a JSON file (no SwiftData migration risk), one active at a time.

| Field | Notes |
|---|---|
| `id`, `createdAt`, `updatedAt`, `closedAt` | `closedAt` set by "Bu araç tamam" |
| `vin`, `vinVerified` | Saved only when complete; verified = check digit matches |
| `stockNumber`, `year`, `make`, `model`, `trim`, `bodyStyle`, `color`, `location` | Editable on screen |
| `identification` | none / visual guess / confirmed |
| `odometer` | value, km or mi, time, source (spoken / camera) |
| `plate` | Only if the user saves it |
| `status` | intake → inspection → photos → listing → ready → sold → delivered (set automatically on VIN, photos, listing; editable) |
| `damage` | `DamageFinding`: body zone (part, side, front/rear), kind (scratch, dent, crack, broken, paint, rust, chip, tear, stain, wear), the user's words, linked capture ids |
| `interiorNotes`, `mechanicalNotes`, `warningLights` | Text |
| `photoChecklist` | 15 standard shots (front 3/4 left … VIN plate, damage close-ups); a labelled Ray-Ban capture ticks the first matching item |
| `deliveryChecklist`, `testDriveChecklist` | No licence data |
| `taskIDs`, `noteIDs`, `captureIDs`, `memoryIDs` | Links; notes, tasks and captures made while the vehicle is active are linked automatically |
| `research` | Market, recall, parts and listing entries with time |

## Body zones (Turkish / English)

"sağ ön çamurluk" → right front fender; "sol arka çamurluk" → left quarter panel; "ön cam" → windshield; "arka tampon" → rear bumper; "tavan döşemesi" → interior (not the roof); "left rear door" → door, left, rear; wheels ("jant"), tires ("lastik"), mirrors ("ayna"), lights ("far", "stop"), rocker ("marşpiyel"), grille ("ızgara", "panjur"), seats, dashboard, engine, underbody.

## Undo

"Son yaptığını geri al" removes the last damage note or restores the previous odometer reading (see `DAILY_LIFE.md`).
