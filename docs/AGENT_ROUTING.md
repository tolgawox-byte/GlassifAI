# Agent routing

## Requirement analysis (`RequestAnalyzer`)

From the user's words (Turkish and English cues, folded: "ş"→"s", "ı"→"i"…) and the voice model's route, never from camera or web text:

`needsVision`, `needsLiveVideo`, `needsWeb` / `needsCurrentInformation`, `needsDeepReasoning`, `needsCode`, `needsDeviceAction`, `needsMemory`, `needsLongContext`, `isDealer`, `isTranslation`, `isDocument`, `isPlanning`, `needsExternalAgent`, `privacy` (local / minimal / standard), `latency` (instant / interactive / patient), and `researchFacets` (price, recall, known issues, specifications, reviews, availability).

Camera off or web search off in Settings removes the vision or web need before routing.

## Plans (`AgentRouter`)

| Strategy | When | Example |
|---|---|---|
| LOCAL | Device actions and memory; offline | "Not al: yarın kamera getir." (≤ 10 s, never a cloud chain) |
| FAST | The best agent is ChatGPT (always when it is the only provider) | "Bu aracın modeli ne?" |
| SPECIALIST | A connected specialist leads the role | "Bu kod neden hata veriyor?" → Claude |
| TEAM | Seeing + researching with a research specialist, or ≥ 2 research questions on a research specialist (or on ChatGPT in Best quality) | "Bu arabanın Kanada piyasasına bak." → vision (ChatGPT) → research (Perplexity) |

Every plan (`AgentPlan`) records intent, required capabilities, strategy, primary and secondary steps, tools, parallelism, confirmation, privacy, timeout, fallbacks and a short reason. Settings → Intelligence → Routing diagnostics lists them (no words, no answers, no keys).

## Candidates per role

Order: the user's pin → (automatic) the preference for the cost setting → ChatGPT as the compatible fallback; only connected, healthy providers that have the capability; each once.

| Role | Balanced / Best quality | Lower cost / Local first |
|---|---|---|
| Research, dealer | Perplexity → Gemini → OpenRouter → ChatGPT | ChatGPT → Perplexity → … |
| Reasoning | Claude → Gemini → OpenRouter → ChatGPT | ChatGPT → Claude → … |
| Coding | Claude → OpenRouter → Gemini → ChatGPT | ChatGPT → … |
| Documents | Claude → Gemini → OpenRouter → ChatGPT | ChatGPT → … |
| Live vision | Gemini → OpenRouter → ChatGPT | ChatGPT → … |
| Vision, translation, chat, planning | ChatGPT → Gemini/Claude → OpenRouter | ChatGPT → … |

Automatic routing off: ChatGPT and the phone do everything except pinned roles.

## Routing examples (unit-tested)

| Request | Only ChatGPT | With specialists |
|---|---|---|
| "Not al: yarın kamera getir." | LOCAL | LOCAL |
| "Bu aracın modeli ne?" | FAST vision | FAST vision (ChatGPT) |
| "Bu arabanın Kanada piyasasına bak." | FAST vision+web | TEAM: vision → research |
| "Bu 50 sayfalık belgeyi analiz et." | FAST | SPECIALIST document → Claude |
| "Bugün hava nasıl?" | FAST web | SPECIALIST research → Perplexity |
| "Bu kod neden hata veriyor?" | FAST | SPECIALIST coding → Claude |
| "Geçen gün bunu konuşmuştuk, neydi?" | LOCAL memory | LOCAL memory |
| "Şu gördüğüm şeyi sürekli takip et." | FAST live vision | SPECIALIST live vision → Gemini |
| "Ahmet'e 10 dakika gecikeceğimi yaz." | LOCAL | LOCAL |
| "Bu aracın recall'u var mı?" | FAST | SPECIALIST dealer research → Perplexity |
| "Bu aracın piyasa değerini, recall durumunu ve bilinen önemli sorunlarını araştır." | FAST (one call) | TEAM: 3 research questions in parallel (+ a reasoning fuser in Best quality) |

## Execution rules (`AutoLoomAgentOrchestrator`)

- **Fallback**: each provider once; a dropped connection is retried once; a timeout or server error moves on; a refused key or missing credit is never retried and waits for the user; a rate-limited provider is paused for its `Retry-After` (60 s default); if every specialist fails, the existing ChatGPT path answers.
- **Circuit breaker**: three failures in a row pause a provider for 2 minutes, doubling per trip up to 30; a success resets it. Settings shows "Temporarily unavailable", "Rate limited for now" or "Needs attention".
- **Timeouts**: live vision 20 s, chat 30 s, vision 40 s, research 45 s, reasoning/coding/documents 90 s, teams 120 s; no endless spinner.
- **Cancellation**: "dur" cancels the task; every provider call and parallel agent inside it is cancelled (Swift task cancellation reaches URLSession).
- **Parallelism**: only research questions without side effects run in parallel; a question that fails does not sink the others.
- **Fusion** (`ResultFusion`): one answer with a line per question, merged sources (public URLs only, at most 8), and a plain sentence when figures disagree ("Kaynaklar farklı rakamlar veriyor…"); in Best quality a reasoning agent writes the answer from the findings, keeping numbers and dates.
