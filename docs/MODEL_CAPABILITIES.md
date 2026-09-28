# Model capabilities and routing

How AutoLoom Media Glasses finds out which ChatGPT models your connection can use, and which one it uses for each job.

## Where the list comes from

After sign-in, the app calls the same endpoint Codex uses: `GET chatgpt.com/backend-api/codex/models?client_version=…` with your ChatGPT account token.

The response describes each model (`ModelInfo` in the vendored Codex source, `vendor/codex/codex-rs/protocol/src/openai_models.rs`). The app now keeps these fields; earlier builds kept only the names:

| Field | Used for |
|---|---|
| `slug`, `display_name` | Identity |
| `priority` | Codex's own order; the first model with `visibility: list` is Codex's default |
| `visibility` | `list` (shown in Codex's picker), `hide`, `none` |
| `input_modalities` | Vision needs `image` |
| `supported_reasoning_levels` | The reasoning effort sent is mapped to a level the model lists |
| `support_verbosity` | `text.verbosity` is sent only when supported |
| `web_search_tool_type` | Whether hosted web search returns text or text and images |
| `use_responses_lite` | Codex sends a different request shape to these models; hosted web tools go to a classic model |
| `supports_image_detail_original` | Recorded; the app's images already fit the `high` budget, so `original` is not needed |
| `context_window`, `model_specialty`, `upgrade` | Shown in Settings → AI models |

## What the vendored Codex catalogue says (reference only)

`vendor/codex/codex-rs/models-manager/models.json` is the snapshot Codex ships with. **The live list from your account is what the app uses**; this table only explains the fields.

| Priority | Model | Listed | Images | Responses-lite | Reasoning levels | Web search |
|---|---|---|---|---|---|---|
| 1 | gpt-5.6-sol | yes | yes | yes | low → ultra | text + image |
| 2 | gpt-5.6-terra | yes | yes | yes | low → ultra | text + image |
| 3 | gpt-5.6-luna | yes | yes | yes | low → max | text + image |
| 7 | gpt-5.5 | yes | yes | no | low → xhigh | text + image |
| 16 | gpt-5.4 | hidden | yes | no | low → xhigh | text + image |
| 29 | gpt-5.2 | yes | yes | no | low → xhigh | text |

## Roles and the automatic choice

| Role | Used by | Automatic choice |
|---|---|---|
| Voice (realtime) | The live conversation | `gpt-live-1-codex`, device-verified. `/models` does not list realtime models; Codex itself hard-codes its realtime model. |
| General | Tool routing, chat, memory, action planning | First listed model in the service's order |
| Vision | Camera questions, Live Vision notes | First listed model that accepts images |
| Deep reasoning | `reasoning` and `report` | First listed model, with effort `medium` (mapped to a level it supports) |
| Web and tools | Hosted `web_search`, vision + web | First listed model that is not responses-lite (and accepts images when a photo is attached) |

With the vendored snapshot, this gives exactly the earlier device-verified behaviour: `gpt-5.6-sol` for general and vision, `gpt-5.5` for hosted web search. If the service puts a newer model at the top of your list, Automatic uses it.

### Safety net

- A model the service rejects is recorded as failed (Settings → AI models) and skipped for the rest of the session. The task then retries once with the next model.
- A model is shown as **working** only after a real request through this app succeeded.
- If the endpoint ever rejects the explicit image `detail`, images are resent without it for the rest of the session.

### Overrides

Settings → AI models → *Override per job* lets you pin a model for any role. Only models your connection lists can be chosen, and a pinned model that disappears from the list is ignored. The older all-tasks override from the previous build still works and can be cleared there.

## GPT-6 Astra

The app looks for `astra` or `gpt-6` in slugs and display names on your connection.

- **Exposed:** Settings and Diagnostics show the slug and capabilities. Automatic uses it wherever the service ranks it highest and it supports the job.
- **Not exposed:** Settings shows *"Not exposed to the AutoLoom connection (it may still be available in the ChatGPT app)"*. The ChatGPT app and this connection can differ, because this app uses the Codex endpoints of your account, not the ChatGPT app's own model menu.

Whether GPT-6 Astra appears on this connection **has not been checked yet**. Open Settings → AI models on the phone after installing this build.

## Image detail

Vision requests send `detail: "high"`, as Codex does by default; Codex never sends `low`. Images are prepared to fit the high-detail budget of 2048 px and 2500 patches of 32 px, so the service does not downscale them again. Before this build, no `detail` was sent and the service used its own default.

## Not available through this connection

- ChatGPT chat history and ChatGPT memory. Requests use `store: false`.
- ChatGPT Work, custom GPTs, connectors, and Codex cloud tasks.
- Choosing the realtime voice model from a list; the one verified model is used.
