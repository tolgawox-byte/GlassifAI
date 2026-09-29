# Voice actions (LEVEL 1, on the phone)

The app recognises explicit commands itself (`VoiceActionIntentBridge`) on the final transcript, runs them locally and tells the voice model the result to say. No model or cloud is involved; results are spoken only after the store or iOS confirmed them.

## Priority

1. **Stop speaking** (the voice session, before the bridge).
2. **Stopping a recording** and asking about it ("kaydı durdur", "kayıt yapıyor musun?") — even while a yes/no question waits, and even when the voice session took the words for "stop speaking".
3. **The answer to a waiting confirmation** (yes / no / morning / evening).
4. Cancel a running task.
5. **Photos, videos, "galeriye kaydet"** ("fotoğraf çek", "bunun fotoğrafını çek ve not al: …").
6. **Dealer Mode** ("VIN oku", "hasar ekle: …", "Bu araç tamam").
7. **Timers and the shopping list.**
8. **Undo** ("son yaptığını geri al").
9. Profile, translation of the view, messages, **notes** (the user's verb wins over time words), note queries, reminders, tasks, day plan, calendar, task lists, routines and reviews, calls, contacts, directions, clipboard, memory.
10. The answer to the bridge's own question ("Neyi not alayım?").

Anything else goes to the voice model (and, if delegated, to the agent router).

## Safety

- Only the user's own words reach this parser; text the camera, OCR or the web brought in never can, so nothing seen can take a photo, record, call or send.
- Media commands never run from a model's delegation.
- Calls, messages and shares need a tap; deleting a note or a memory waits for a yes.
- Questions and talk about a command are not the command ("video nasıl çekilir?", "VIN nedir?", "yeni araç almak istiyorum").

## Tests

`AutoLoomNoteReliabilityTests`, `AutoLoomVoiceFirstTests`, `AutoLoomVoiceActionTests`, `AutoLoomRayBanMediaCommandTests`, `AutoLoomDealerTests`, `AutoLoomDailyLifeTests` (Turkish, English, paraphrases and negatives).
