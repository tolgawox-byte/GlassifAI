# Ray-Ban photos, videos and the Photos library

**Status: BUILD + UNIT TESTS; PHYSICAL TEST REQUIRED** for everything that needs the glasses (photo capture, recording, locked-screen recording, saving to Photos on the phone).

## Source: the Ray-Ban camera only

Photos and videos come from the glasses stream (DAT 0.5.0), never from the iPhone camera, the preview or a screenshot. If the chosen camera is not the Ray-Ban, or its stream is not running, the app says so ("Ray-Ban kamerası bağlı değil, fotoğraf çekemedim.") and does not fall back to the iPhone.

```
glasses → DAT VideoFrame.sampleBuffer ─┬→ GlassesFrameIngestor sample tap → RayBanVideoRecorder (AVAssetWriter passthrough)
                                      └→ VideoDecoder → FrameStore (vision) ──→ decoded tap (encode fallback only)
DAT capturePhoto(.jpeg) → photoDataPublisher → StillPhotoCoordinator → RayBanMediaCoordinator → Photos (add-only)
```

`RayBanMediaCoordinator` (app lifetime) and `RayBanVideoRecorder` do not depend on the screen or the conversation.

## Photo ("fotoğraf çek")

- DAT `capturePhoto(format: .jpeg)`: the only still capture DAT 0.5 has (DAT 1.0 adds `Camera.photo`). The JPEG is kept as the glasses sent it.
- Shutter sound (iOS system sound 1108) and a haptic after the photo arrives.
- "Fotoğrafı çektim ve galeriye kaydettim." only after `PHPhotoLibrary.performChanges` succeeded.

## Video ("video kaydını başlat" / "kaydı durdur")

States: IDLE → PREPARING (waiting for the first keyframe) → RECORDING (first frame written) → STOPPING → FINALIZING → SAVING_TO_PHOTOS → SAVED / FAILED. One recording at a time ("Zaten kayıt yapıyorum.").

- **HEVC passthrough**: the glasses' compressed samples are written as they are, with their own timestamps and resolution (no decoding, no re-encoding, never upscaled). A file starts at a keyframe. This is how Meta's DAT sample records, and it needs no video hardware, so it keeps working while the phone is locked **if** the stream does (physical test required).
- **Encode fallback**: raw-transport frames, or HEVC the writer refuses to pass through, are encoded to HEVC from the pixel buffers at their own size.
- **Resolution change**: the glasses may step the resolution down on a weak link; the file ends there and a new one starts at the next keyframe ("Video 2 parça halinde galeriye kaydedildi.").
- **Stops itself** when the stream stops ("Ray-Ban bağlantısı kesildi, kayıt durdu."), the phone gets critically warm, free space drops under 80 MB, or no frame arrives within 20 s. Starting needs 300 MB free.
- **Audio: video only.** DAT 0.5.0 has no Ray-Ban camera audio, and the conversation owns the microphone (the glasses' microphone is Bluetooth HFP, which Meta says must be set up before the camera stream). The iPhone microphone is never used for video.
- "Kayıt yapıyor musun?", "Ne kadar oldu?" (while recording) are answered by the app. "Kaydı durdur" is checked before anything else, even a waiting yes/no question, and also when the voice session took it as "stop speaking".

## Photos library

- `NSPhotoLibraryAddUsageDescription`, add-only access: the app can add, never read, the library. It keeps the asset identifier, a label and a small thumbnail.
- Settings → Camera & Ray-Ban → **Save captures**: Always (default) / Ask first ("galeriye kaydet") / Keep in AutoLoom only.
- Nothing is lost: anything Photos did not take (permission off, not asked yet while locked, an error, or the setting) stays in AutoLoom's Captures folder with **Save again** / share. Saves that waited for the permission prompt are retried when the app is back on screen. Temporary recording files are deleted after Photos confirmed the import.
- Nothing is uploaded anywhere.

## Dealer linking

"Bu aracın önünü çek", "Jantın fotoğrafını çek", "Hasarın fotoğrafını çek" set a label (front, rear, side, wheel, tire, damage, interior, VIN, odometer, engine). "Sağ ön jant çizik." then "Fotoğrafını çek" labels the photo from what was just said and keeps those words as its caption. "Bunun fotoğrafını çek ve not al: …" saves the note first, then links the photo to it. `vehicleSessionID` is recorded when a vehicle session is active (the vehicle session itself arrives with Dealer Mode).

## Captures

Explore → Captures (and Settings → Camera & Ray-Ban → Captures): Today / Dealer / Personal, thumbnails, In Photos / In AutoLoom, Save to Photos, share, remove (AutoLoom's copy only; a Photos copy stays). Developer → Camera diagnostics → Ray-Ban media shows the recording state, recorder mode, dropped frames, the last media event, the Photos permission and counts.

## Physical tests

1. Ray-Ban streaming, say "fotoğraf çek": shutter, "Fotoğrafı çektim ve galeriye kaydettim.", the photo in Photos (first time: the add-only prompt).
2. "Jantın fotoğrafını çek": Captures shows it under Dealer with the Wheel label.
3. "Video kaydını başlat", 20 s, "kaydı durdur": the video in Photos, 720×1280 (or what the glasses sent), correct orientation, no sound.
4. Start recording, lock the phone for 30 s, unlock, stop: the video covers the locked time (if the stream kept running while locked).
5. Turn Photos access off in iOS Settings, take a photo: "…galeri izni kapalı; AutoLoom'da sakladım.", then allow it and use Save again.
6. Take the glasses off while recording: "Ray-Ban bağlantısı kesildi, kayıt durdu." and the recorded part is saved.
