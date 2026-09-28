# Native iPhone tools

## Flow

Explicit spoken commands are recognised by the app itself (Jarvis v1.1, `VoiceActionIntentBridge`); everything else can still be delegated by the voice model as before.

```
"Jarvis, yarın saat 10'da patronu aramamı hatırlat"
  → final transcript → VoiceActionIntentBridge (LEVEL 1): createReminder, title "Patronu ara"
  → TimePhraseParser on the user's words: Mon 28 Sep 10:00 (never a model's date)
  → validation (title, not in the past) → tool switch (Settings → Tools)
  → permission (Reminders): granted → run · not asked, app on screen → iOS prompt · otherwise kept for 10 min
  → stage by risk: SAFE runs now · CONFIRM waits for "evet" or a tap · STRONG CONFIRM waits for a tap
  → DeviceActionExecutor (EventKit) → success only after iOS returned the saved identifier
  → Tasks tab refreshed → the voice model says it once ("Tamam, yarın saat onda hatırlatacağım.")

voice model: TASK: action | QUERY: …   (commands the parser does not recognise)
  → ActionGuard (email, money, deleting data, code, posting → refused locally, no model call)
  → planner model → strict JSON (device_action) → DeviceActionParser → same staging as above
```

The model plans at most; deterministic code validates and executes. Text from web pages, images, OCR or signs never becomes an action, recipient, number or link — only the user's own words reach the bridge.

This is enforced in code as well as in the prompts: when camera, web or agent content has entered the conversation in the current user turn (vision, vision + web, visual memory, web search, report, agent), a change the planner model proposes in that same turn (reminder, event, note, notification, copy) is raised from SAFE to CONFIRM and waits for a spoken yes or a tap. Reading actions stay SAFE, and outbound actions need a tap anyway. Commands the local parser reads from the user's own words are not affected. Test: `AutoLoomActionTests.testChangesPlannedAfterUntrustedContentWaitForAYes`.

## Registry

| Tool | Actions | Risk | Permission |
|---|---|---|---|
| Reminders | create_reminder, list_reminders | **SAFE** (explicit request; an unclear time is asked first) | Reminders (full access), asked on first use |
| Calendar | today_events, upcoming_events, create_event, "yarın ne var?" | **SAFE** (explicit request; an unclear time is asked first) | Calendars (full for reading, write-only is enough to add) |
| AutoLoom Notes | save_note | SAFE | none |
| AutoLoom Tasks | local tasks ("görev oluştur") | SAFE | none (Notifications only for an optional alert) |
| Memory | forget_memory (memory flow only) | CONFIRM | none |
| Notifications | schedule_notification | SAFE | Notifications, asked on first use |
| Contacts lookup | find_contact (+ name resolution for calls/messages) | SAFE (read-only) | Contacts, asked on first use |
| Maps | open_maps | STRONG CONFIRM | none |
| Open link | open_url (public http/https only; SSRF guard) | STRONG CONFIRM | none |
| Clipboard | copy_text | SAFE | none |
| Share | share_text | STRONG CONFIRM | none |
| Phone call | call | STRONG CONFIRM | none (tel: link; the Phone app places the call) |
| Message | message | STRONG CONFIRM | none (Messages opens with the text; the user presses Send) |

Every tool has a switch in Settings → Tools, plus a master "Allow iPhone actions" switch. Section 70 of the brief: save note, save memory, list tasks and read the calendar are SAFE; an ambiguous event and deleting a memory need a yes; calls, messages, external sharing and destructive changes need a tap.

## Deterministic time parsing

`TimePhraseParser` (unit-tested, `AutoLoomJarvisTests`, `AutoLoomVoiceActionTests`):

| Said | Resolved (Sunday 27 Sep 2026, 20:00) |
|---|---|
| "20 dakika sonra", "in half an hour", "1,5 saat sonra" | now + 20 min / 30 min / 90 min |
| "yarın saat 10'da", "saat 3'te" | Mon 10:00 / Mon 15:00 — **not** ambiguous (9–11 mean the morning, 1–5 the afternoon) |
| "yarın saat 7'de", "8'de" | Mon 07:00 / 08:00, **ambiguous** → asks "sabah mı akşam mı?"; the answer ("akşam", "sabah olan", "20:00") is read by the bridge |
| "yarın akşam 7'de", "tomorrow at 7 pm" | Mon 19:00 |
| "cuma 3'e" | Fri 2 Oct 15:00 (an hour in the dative after a day word) |
| "yarın sabah" | Mon 09:00 (default for the part of day) |
| "cuma akşam 8" | Fri 2 Oct 20:00 |
| "15 Ekim 14:30" / "15 Ekim'de" | 15 Oct 14:30 / 15 Oct, no time |
| "gece 2'de", "8'e çeyrek kala" | Mon 02:00 / Mon 07:45 |
| "bir de süt al", "anahtar onda", "pazara gidince", "Salih'i ara", "3'e böl" | not a time (no false match) |

Rules:
- The planner (LEVEL 2) copies the user's words; an ISO timestamp from a model is ignored and the user's request is parsed instead.
- Two-digit clock times ("07:30", "11:00") are 24-hour. 6, 7 and 8 o'clock without "sabah/akşam/am/pm" are ambiguous when both readings are ahead, and the assistant asks before saving.
- Past times are refused ("That time is in the past").
- A reminder with no time ("süt almayı hatırlat") → "Ne zaman hatırlatayım?"; "fark etmez" saves it without a time.

## Tasks tab

AutoLoom tasks and Apple Reminders together:
- **Today** (due today or overdue), **Upcoming** (later, and undated), **Completed** (AutoLoom: last 20; Reminders: last 7 days).
- AutoLoom tasks: add, edit (natural-language "when" field), complete, delete; an optional notification at the due time when notifications are allowed.
- Apple Reminders through EventKit: complete, delete (confirmation), reschedule; "Connect" card when access was not asked yet.
- Notifications scheduled by the assistant are listed and can be cancelled.
- Everything the assistant creates by voice appears immediately (the store is observed; Reminders are reloaded after each spoken action).

## Not supported

Email, purchases, payments, deleting the user's data (except the app's own memories, tasks and the user's reminders in the Tasks tab, all with confirmation), posting publicly, code or deployment changes, and deleting calendar events by voice.
