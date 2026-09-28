# Native iPhone tools

## Flow

```
voice model: TASK: action | QUERY: yarın saat 7'de bana süt almayı hatırlat
  → ActionGuard (email, money, deleting data, code, posting → refused locally, no model call)
  → planner model → strict JSON (device_action): {"action":"create_reminder","title":"Süt al","when":"yarın saat 7'de",…}
  → DeviceActionParser: validates; the time is resolved by TimePhraseParser from the user's words
  → tool switch (Settings → Tools) → contacts lookup for call/message by name
  → stage by risk: SAFE runs now · CONFIRM waits for "evet" or a tap · STRONG CONFIRM waits for a tap
  → DeviceActionExecutor (EventKit, UserNotifications, Contacts, pasteboard, SwiftData)
  → success reported only after iOS confirms it (saved identifier, pending notification present)
```

The model plans; deterministic code validates and executes. Text from web pages, images, OCR or signs never becomes an action, recipient, number or link.

## Registry

| Tool | Actions | Risk | Permission |
|---|---|---|---|
| Reminders | create_reminder, list_reminders | CONFIRM (create) / SAFE (list) | Reminders (full access), asked on first use |
| Calendar | today_events, upcoming_events, create_event | SAFE (read) / CONFIRM (create) | Calendars (full for reading, write-only is enough to add) |
| AutoLoom Notes | save_note | SAFE | none |
| Memory | forget_memory (memory flow only) | CONFIRM | none |
| Notifications | schedule_notification | SAFE | Notifications, asked on first use |
| Contacts lookup | find_contact (+ name resolution for calls/messages) | SAFE (read-only) | Contacts, asked on first use |
| Maps | open_maps | STRONG CONFIRM | none |
| Open link | open_url (public http/https only; SSRF guard) | STRONG CONFIRM | none |
| Clipboard | copy_text | SAFE | none |
| Share | share_text | STRONG CONFIRM | none |
| Phone call | call | STRONG CONFIRM | none (tel: link; the Phone app places the call) |
| Message | message | STRONG CONFIRM | none (Messages opens with the text; the user presses Send) |

Every tool has a switch in Settings → Tools, plus a master "Allow iPhone actions" switch.

## Deterministic time parsing

`TimePhraseParser` (unit-tested, `AutoLoomJarvisTests`):

| Said | Resolved (Sunday 27 Sep 2026, 20:00) |
|---|---|
| "20 dakika sonra", "in half an hour", "1,5 saat sonra" | now + 20 min / 30 min / 90 min |
| "yarın saat 7'de" | Mon 07:00, **ambiguous** → asks "07:00 or 19:00?" |
| "yarın akşam 7'de", "tomorrow at 7 pm" | Mon 19:00 |
| "yarın sabah" | Mon 09:00 (default for the part of day) |
| "cuma akşam 8" | Fri 2 Oct 20:00 |
| "15 Ekim 14:30" / "15 Ekim'de" | 15 Oct 14:30 / 15 Oct, no time (reminder without alarm) |
| "gece 2'de", "8'e çeyrek kala", "saat 3'te" | Mon 02:00 / Mon 07:45 / Mon 15:00 |
| "bir de süt al", "anahtar onda", "pazara gidince", "Salih'i ara" | not a time (no false match) |

Rules:
- The planner copies the user's words; an ISO timestamp from the model is ignored and the user's request is parsed instead.
- Two-digit clock times ("07:30", "11:00") are 24-hour. Hours without "sabah/akşam/am/pm" are ambiguous when both readings are ahead, and the assistant asks before saving.
- Past times are refused ("That time is in the past").

## Tasks tab

Apple Reminders through EventKit: Today (incl. overdue), Upcoming (incl. no due date), Completed (last 7 days). Create (with a natural-language "when" field), complete, delete (confirmation dialog) and reschedule. Notifications scheduled by the assistant are listed and can be cancelled.

## Not supported

Email, purchases, payments, deleting the user's data (except the app's own memories and the user's reminders in the Tasks tab, both with confirmation), posting publicly, code or deployment changes, and deleting calendar events by voice.
