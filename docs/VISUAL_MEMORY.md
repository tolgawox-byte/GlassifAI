# Visual memory ("Visual Second Brain")

A visual memory is one view of the camera that you explicitly asked the assistant to remember ("bunu hatırla"). The cloud vision model writes a short description, and at the same time the iPhone reads the text and recognises objects in the image on the device, so the memory can later be found by what was written or seen ("anahtarımı en son nerede gördüm?"), even offline. A photo is kept only if you allowed it, and the place only if you allowed it. An optional Scene Timeline (off by default) keeps one line of text per scene while Live Vision runs, for a week. Nothing is recorded continuously. Code: `Runtime/VisualMemory.swift`, `AssistantOrchestrator.runVisualMemory` (`Runtime/AssistantOrchestrator.swift`).

## Settings

Settings → Memory → "Görsel anılar / Visual memories" (also Memory → Visual memory):

| Setting | Default | Effect |
|---|---|---|
| Visual memories | Off | Needed for "bunu hatırla" to save a view. Memory itself must be on |
| Keep the photo ("Fotoğrafı sakla") | Off | Keeps a 480 px thumbnail in the memory record and a 1,600 px JPEG in `Application Support/AutoLoom/VisualMemories/` |
| Attach the place ("Konumu ekle") | Off | One location fix and place name per memory (asks for When-In-Use location) |
| Scene Timeline ("Sahne zaman çizelgesi") | Off | See below |

## Saving a visual memory

Say, with the camera on (Ray-Ban or iPhone) and visual memories on:
- "Bunu hatırla", "Remember this" — when nothing else is said, the view is the content.
- "Anahtarımı buraya bıraktığımı hatırla" — a place word ("buraya", "burada", "şurada", "orada", "here", "there") makes a memory visual.

Without the camera or with visual memories off, a bare "bunu hatırla" saves your previous sentence (if it has at least three words) as an ordinary memory, or asks what to remember; "bunu hatırla: …" with words saves those words.

What happens (`runVisualMemory`):
1. A **high-detail** image of the current view is prepared.
2. The **cloud vision model** describes it (like any visual question; the image leaves the phone for this).
3. In parallel, **on the device** (`VisualAnalysis`, Apple Vision): text recognition in Turkish and English (accurate level, first 1,500 characters) and up to six object labels with confidence ≥ 0.3.
4. If the cloud description fails, the memory is saved from the on-device reading alone, marked "Bu iPhone'da okundu (çevrimdışı) — nesneler: …; yazı: …", and the assistant says only what the phone read. If neither produced text, nothing is saved.
5. The description (≤ 600 characters) is saved as a memory of kind `visual`; the on-device text and labels, the active Dealer Mode vehicle and the optional photo's file name go to `Application Support/AutoLoom/visual-memories.json`.

Files are written with `completeFileProtectionUntilFirstUserAuthentication`.

## "Nerede gördüm?" — searching your visual memories

| Say | Result |
|---|---|
| "Anahtarımı en son nerede gördüm?", "Cüzdanımı nerede görmüştüm?", "Where did I last see my keys?" | The best match: when, where (if a place was saved) and the vehicle; its photo opens on the phone |
| "Bugün neler gördüm?", "What did I see today?" | Today's visual memories and, if on, today's Scene Timeline lines |
| "Görsel anılarımı göster" | The gallery |

How matching works (`VisualMemorySearch.find`), all on the iPhone:
- Question words ("en son", "nerede", "gördüm", "where", "see") are dropped.
- Each remaining word is matched by stem against the description, the text read in the photo, the object labels, the place, tags and the vehicle's name.
- Object labels from Apple Vision are English, so Turkish words are expanded: anahtar ↔ key, cüzdan ↔ wallet, gözlük ↔ glasses, telefon ↔ phone, araba/araç ↔ car, çanta ↔ bag, şemsiye ↔ umbrella, kitap ↔ book, bilgisayar ↔ computer, saat ↔ watch/clock, kulaklık ↔ headphones, şarj ↔ charger, kalem ↔ pen, fatura/fiş ↔ invoice/receipt, lastik/teker ↔ tire/wheel, kapı ↔ door, masa ↔ table, kutu/koli ↔ box, ilaç ↔ medicine, belge/evrak/kağıt ↔ document, kart ↔ card, bardak/kupa ↔ cup, şişe ↔ bottle, ayakkabı ↔ shoes, ceket/mont ↔ jacket, bisiklet ↔ bicycle, kedi ↔ cat, köpek ↔ dog.
- Score = share of the words found; ties go to the newest.
- **Never a guess**: with no match the answer is "Görsel anılarında “…” yok. Sadece “bunu hatırla” dediğin şeyleri bilirim." and the gallery opens. The answer always says it is a saved memory, not what the camera sees now.
- With Memory off: "Hafıza kapalı; görsel anı yok."

"Anahtarımı nereye bıraktım?" (placed, not seen) is answered from ordinary memories, not this search.

## Scene Timeline (opt-in)

- Off by default. Turn it on in Settings → Memory or on the Visual memory screen.
- Works only while **Live Vision** runs: each new Live Vision note may add one line.
- A line is the first sentence of the note, at most 90 characters, **text only, never an image**.
- At least 120 s after the previous line, and skipped when it says nearly the same thing (word overlap ≥ 0.8).
- Lines older than 7 days are removed when a new line is added. "Zaman çizelgesini sil" deletes all of them.
- The last 20 lines are listed on the Visual memory screen.

## "Ne değişti?"

- Only while Live Vision is on ("Ne değişti?", "Bir şey değişti mi?", "Şimdi ne değişti?", "What changed?"). Otherwise the words go to the voice model as an ordinary question; "bu güncellemede ne değişti?" is never taken.
- The app compares the **last two Live Vision notes** of this run (up to six are kept in memory). With fewer than two: "Henüz karşılaştıracak iki görüntü yok."
- The voice model is told to say what changed between the two notes only, and to say nothing important changed when they describe the same scene. No old frame is described as the current view.

## Deleting

| Where | Deletes |
|---|---|
| Visual memory → a memory → Sil / Delete | The memory, its on-device reading and its photo |
| Settings → Memory → Clear all AutoLoom memory | All memories, including every visual memory and its index entry |
| Visual memory screen → "Zaman çizelgesini sil" | The Scene Timeline |
| Privacy center → Delete all local data | Memories, the visual memory index and photos, and the Scene Timeline |

## Privacy summary

- Saved only when you ask; the camera image goes to the cloud vision model for the description, like any visual question.
- Text and object recognition run on the iPhone.
- Photo and place are separate opt-ins. The Scene Timeline is text only, opt-in, and kept a week.
- Visual memories are not in iOS Spotlight unless "Include memories" is on (then only their text).

## Status

| Item | Status |
|---|---|
| "Nerede gördüm?" search with TR/EN object names, "bugün neler gördüm?" | WORKING (unit tests) |
| Scene Timeline rules (opt-in, first sentence, 120 s, 7 days) | WORKING (unit tests) |
| Offline description from on-device reading; photos kept only when given | WORKING (unit tests) |
| Saving a visual memory from the glasses | PHYSICAL_TEST_REQUIRED |
| "Ne değişti?" during Live Vision | PHYSICAL_TEST_REQUIRED |
| Place names | REQUIRES_PERMISSION (location) |
