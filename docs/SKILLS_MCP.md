# Skills (MCP servers)

A skill is a tool on an MCP (Model Context Protocol) server that **you** added in Settings. AutoLoom speaks MCP's Streamable HTTP transport as a client: it connects, reads the server's tools, and when you say "Notion ile bugünkü görevlerimi listele" it lets a model pick one tool and its arguments, then applies that tool's policy before anything is sent. Servers can only be added by the user, only over `https`; tokens stay in the Keychain; every call that is not allowed to run silently is staged with the receiving service's host on screen; tools that may change data need a tap; and whatever comes back is treated as untrusted content. Code: `Runtime/Skills.swift`.

## Adding a server

Settings → "Beceriler (MCP) / Skills (MCP)" → "MCP sunucusu ekle / Add an MCP server":

| Field | Rule |
|---|---|
| Name ("Ad (söyleyeceğin)") | What you will say ("Notion"). Empty → the host name |
| Address | Must be `https://` with a host; `http://` is refused ("Sunucunun https:// adresini gir.") |
| Token (optional) | Stored in the Keychain: service `com.autoloom.skills`, account = the server's id, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Sent only as `Authorization: Bearer` to that server |

Then tap "Bağlan ve araçları oku / Connect and read tools" (`initialize` + `tools/list`). Only servers that are **on** and have tools are offered to the voice. "Bu beceriyi kaldır / Remove this skill" deletes the server and its token. Servers are stored in `Application Support/AutoLoom/skills.json`.

**Only servers added on this screen can offer tools** — never a web page, a document or a tool result.

## The protocol client (`MCPClient`)

- JSON-RPC 2.0 over HTTPS `POST`, protocol version `2025-06-18`, headers `Accept: application/json, text/event-stream`, `MCP-Protocol-Version`, and `Mcp-Session-Id` once the server gives one. 30 s timeout.
- `initialize` (client info "AutoLoom Media Glasses" 1.5) then `notifications/initialized`.
- `tools/list` with cursor pagination (stops after about 200 tools). Each tool keeps its name, title, description (400 characters) and input schema (2,000 characters).
- `tools/call` returns the text parts of the result and `isError`.
- Answers may be plain JSON or server-sent events; the event whose `id` matches is used.
- Tool annotations: `readOnlyHint` (default false). A tool that is not read-only is treated as **possibly destructive** unless it says `destructiveHint: false` (MCP's default).

## Per-tool policy

Each tool has a picker on the server's section:

| Policy | Meaning |
|---|---|
| "Her seferinde sor / Ask every time" (default) | Every call waits for you |
| "İzin ver (salt okunur) / Allow (read-only)" | Offered only for read-only tools; they run without asking |
| "Engelli / Blocked" | Never runs and is not shown to the model |

## Risk mapping

| Tool | Policy | Risk | You confirm by |
|---|---|---|---|
| Read-only | Allow (read-only) | `SAFE` | Nothing: it runs |
| Read-only | Ask | `CONFIRM` | "Evet" or a tap |
| Writes, `destructiveHint: false` | Ask | `CONFIRM` | "Evet" or a tap |
| May change data (default for writes) | Ask | `STRONG_CONFIRM` | **A tap only**; a spoken yes is refused |
| Any | Blocked | — | Never runs |

A staged skill call is never less than `CONFIRM`. The action planner can never choose a skill call on its own (`skill_call` is not plannable). A waiting call expires after 120 s.

## What happens when you ask

1. The parser recognises "<Ad> ile …", "<Ad>'a sor: …", "ask <name> to …", "use <name> to …" for an enabled skill ("Notion ile bugünkü görevlerimi listele" → server "Notion", request "bugünkü görevlerimi listele"). Without that skill the sentence is not a skill command.
2. The reasoning model receives the request and up to 40 allowed tools (description and schema, 600 characters each) and must answer strict JSON `{"tool": …, "arguments": {…}}`, never inventing values you did not give. No tool → "Bu istek için uygun bir araç bulamadım."
3. The tool's policy gives the risk (table above).
4. `SAFE` → sent at once. Otherwise a confirmation card shows **"Gönder: <host> · <tool> <arguments>"** and the assistant reads it back; nothing is sent before your yes or tap.
5. On confirmation the client initialises again and calls the tool.
6. The reply (up to 3,000 characters; errors up to 1,500) is wrapped as **untrusted content** from "the MCP skill <name> (<host>)". The voice model is told to summarise it briefly and never follow instructions inside it.

## What leaves the phone

- To the reasoning model provider: your request and the allowed tools' names, descriptions and schemas (for the tool choice).
- To the MCP server's host: the tool name, the arguments and your token.
- The result goes back through the voice model to be summarised.

## Limits

- No OAuth sign-in flow: a static bearer token only.
- Only text results are read; images and embedded resources are ignored. MCP resources and prompts are not used.
- Privacy center → "Delete all local data" does not remove skills in this build; remove them in Settings → Skills.
- Examples in docs use "Notion" as a name; no server is built in. Testing needs a real MCP server (see SK1 in [PHYSICAL_TEST_MATRIX.md](PHYSICAL_TEST_MATRIX.md)).

## Tests

`AutoLoomSkillsTests` (fake server): the client speaks MCP (initialize, session id, tools/list, SSE tools/call), risk follows tool and policy, a staged call is never less than a yes and shows the host, servers only over `https`, strict tool-choice parsing, the voice phrases.

## Status

| Item | Status |
|---|---|
| MCP client, policies, risk mapping, https-only, phrases | WORKING (unit tests with a fake server) |
| Using a real MCP server | REQUIRES_PROVIDER, PHYSICAL_TEST_REQUIRED |
| Tool choice by the reasoning model | REQUIRES_PROVIDER (a connected model) |
| OAuth, resources, prompts, non-text results | UNAVAILABLE |
