# Tools and actions (AutoLoom Tasks)

> Jarvis v1 replaced the risk levels with SAFE / CONFIRM / STRONG CONFIRM, added deterministic time parsing, notifications, contacts lookup, a tool registry and the Tasks tab. The current description is [NATIVE_TOOLS.md](NATIVE_TOOLS.md); memory is in [MEMORY_ARCHITECTURE.md](MEMORY_ARCHITECTURE.md).

What the assistant can do on the iPhone, how each action is confirmed, and what it refuses. Everything here is **implemented and unit-tested, but not yet verified on the phone** (see `TEST_REPORT.md`).

## How a request becomes an action

1. The voice model hears a request that needs the phone ("Jarvis, yarın saat 7'de bana süt almayı hatırlat") and delegates `TASK: action | QUERY: …`.
2. **Local guard, no network.** Requests about email, purchases or payments, deleting data, code repositories or deployment, or public posting are refused right away. The exception is when the request is about a reminder, note, or calendar item: "remind me to buy milk" is fine.
3. **Planning.** The executor model turns the request into exactly one action as strict JSON (schema `device_action`). It is told to take actions only from your own words, never from web pages, images, OCR, or other untrusted content.
4. **Validation on the phone.** Known action only, dates parsed with time zone and never in the past, public web links only (no private-network addresses), phone numbers of 5–17 digits.
5. **Confirmation by risk:**

| Risk | Actions | How it is confirmed |
|---|---|---|
| Read-only | List reminders, today's calendar, upcoming events (7 days), copy text | Runs right away (after the iOS permission prompt) |
| Save | Create reminder, create calendar event, save AutoLoom note, harmless agent requests | A spoken "yes" (`confirm_action`) **or** a tap on Save |
| Needs a tap | Directions (Maps), open link, share, call, message, destructive-sounding agent requests | **Only** a tap on the phone. A spoken "yes" is refused |

Calls and messages open the system Phone and Messages apps. Nothing is sent until you tap Send there. Unconfirmed actions expire after 2 minutes. The confirmation card always shows exactly what will happen.

## Supported actions

| Action | Framework | Notes |
|---|---|---|
| Reminder (with due time and alert) | EventKit | Default Reminders list. iOS asks for Reminders access the first time |
| Reminders list | EventKit | Open reminders due in the next 7 days |
| Calendar today / upcoming | EventKit | Needs full calendar access |
| Calendar event | EventKit | Default calendar; 1 hour long unless an end is given; write-only access is enough |
| AutoLoom note | App storage | On this iPhone only (`Application Support/AutoLoom/notes.json`, complete file protection). Apple Notes has no API for other apps; use Share → Notes |
| Directions | Apple Maps URL | Built by the app from the destination; the model never provides the link |
| Open link | Safari | Public web addresses only (`URLSafety`) |
| Copy / Share | Clipboard / share sheet | |
| Call | `tel:` | Only with a number you said. Contacts are not searched |
| Message | Messages (`sms:`) | Body pre-filled; you choose or confirm the recipient and tap Send |

iOS can only show a permission prompt while the app is on screen. If you ask for a reminder with the phone locked, and before you've ever granted access, the assistant tells you to open the app once.

## Reports ("research this and prepare a report")

`TASK: report` runs web research with hosted search and medium reasoning, and writes a compact report: Summary, Key facts, Details, Sources. The report is saved as an AutoLoom note with its source links, and the assistant speaks a short summary. Notes and reports are in Settings → iPhone actions → AutoLoom Tasks & Notes. You can share them to Apple Notes, Mail, and other apps.

"Look this up and save it" and "create a note from this" use the same machinery (report, or `save_note` with the conversation's last answer).

## Agent gateway (OpenClaw, optional)

Off by default. It connects to **your own** OpenClaw Gateway through its OpenAI-compatible `POST /v1/chat/completions` endpoint, which is disabled by default in OpenClaw. Enable it in the gateway config: `gateway.http.endpoints.chatCompletions.enabled: true`.

- **Setup:** Settings → iPhone actions → Agent gateway: address, agent (default `openclaw/default`), gateway token.
- **Token:** Keychain only, sent only to that address. OpenClaw treats it as an owner credential.
- **Network:** plain `http` is accepted only for loopback, private, carrier-grade NAT (Tailscale `100.64/10`), `.local`, or `*.ts.net` hosts. Public `https` works but is flagged, because OpenClaw recommends keeping the gateway on a private network or tailnet. Local networking is enabled in the app's transport settings for this.
- **Voice:** "Ask my agent …", "check my GitHub repository" → `TASK: agent`. The request is shown for confirmation. Destructive-sounding requests (delete, deploy, push, merge, payments, email, posting) need a tap; others accept a spoken "yes". OpenClaw's own approvals still apply on the gateway.
- **Replies:** treated as untrusted content and summarised aloud; the full text appears on screen.
- **Session:** a stable per-install `user` value, so the agent keeps its conversation between requests.

Without a gateway, "check my GitHub repository" gets an honest answer: that is not connected to this app.

## Shortcuts and Siri

| Shortcut | What it does |
|---|---|
| Start Conversation | "Hey Siri, start AutoLoom" |
| Ask AutoLoom | Siri asks for the question; the answer appears on screen with sources |
| Start Live Vision | Starts a conversation, then Live Vision |

## Not supported

Email, purchases and payments, deleting data, posting to social networks, code changes (unless through your own agent gateway), ChatGPT Work, Codex cloud tasks, and ChatGPT connectors. The assistant says so instead of pretending.
