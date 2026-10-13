use codex_api::ApiError;
use codex_api::AuthProvider;
use codex_api::Provider;
use codex_api::RealtimeCallClient;
use codex_api::RealtimeContextAppendChannel;
use codex_api::RealtimeEvent;
use codex_api::RealtimeEventParser;
use codex_api::RealtimeOutputModality;
use codex_api::RealtimeSessionConfig;
use codex_api::RealtimeSessionMode;
use codex_api::RealtimeTranscriptState;
use codex_api::RealtimeWebsocketClient;
use codex_api::RealtimeWebsocketWriter;
use codex_api::ReqwestTransport;
use codex_api::RetryConfig;
use codex_api::TransportError;
use codex_http_client::HttpClientBuilder;
use codex_protocol::protocol::ConversationTextParams;
use codex_protocol::protocol::ConversationTextRole;
use codex_protocol::protocol::RealtimeVoice;
use http::HeaderMap;
use http::HeaderValue;
use http::StatusCode;
use http::header::AUTHORIZATION;
use serde_json::Value;
use serde_json::json;
use std::collections::VecDeque;
use std::ffi::CStr;
use std::ffi::CString;
use std::os::raw::c_char;
use std::ptr::null_mut;
use std::sync::Arc;
use std::sync::LazyLock;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::thread;
use std::time::Duration;
use std::time::Instant;

const BRIDGE_VERSION: &str = "autoloom-bridge-4";
/// How much of a failed call's response body the app may see (diagnostics).
const MAX_ERROR_BODY_BYTES: usize = 600;

/// The exact instructions of the device-verified baseline build. Used by the
/// original entry point and as the fallback when no options are supplied.
const BASELINE_INSTRUCTIONS: &str = "You are GlassifAI, a concise and interruptible smart-glasses assistant. Never claim to see without current visual context. Whenever the user asks what they see, refers to an object, sign, screen, color, document, or scene, create a client delegation for current visual context, wait for the returned speakable context, then answer naturally.";
const BASELINE_MODEL: &str = "gpt-live-1-codex";
const MAX_INSTRUCTIONS_BYTES: usize = 16_000;
const MAX_INITIAL_ITEMS: usize = 8;
const MAX_INITIAL_ITEM_BYTES: usize = 4_000;
const MAX_QUEUED_EVENTS: usize = 256;
const MAX_PENDING_COMMANDS: usize = 8;
const MAX_RECONNECT_ATTEMPTS: u32 = 6;
/// The HTTP client has no timeout of its own: a stalled network must not
/// leave the app waiting forever for a call.
const CALL_CREATE_TIMEOUT: Duration = Duration::from_secs(20);
const SIDEBAND_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// A sideband that stayed connected this long starts a fresh reconnect budget.
/// A socket that is accepted and closed at once keeps counting instead.
const STABLE_CONNECTION: Duration = Duration::from_secs(30);
/// A 404 before the first connect can mean the new call is not registered
/// yet (openai/codex#35094), so it is retried this many times.
const FIRST_CONNECT_NOT_FOUND_RETRIES: u32 = 3;

#[derive(Clone)]
struct OAuthAuth {
    access_token: String,
    account_id: String,
}

impl AuthProvider for OAuthAuth {
    fn add_auth_headers(&self, headers: &mut HeaderMap) {
        if let Ok(value) = HeaderValue::from_str(&format!("Bearer {}", self.access_token)) {
            headers.insert(AUTHORIZATION, value);
        }
        if let Ok(value) = HeaderValue::from_str(&self.account_id) {
            headers.insert("chatgpt-account-id", value);
        }
    }
}

#[derive(Clone)]
enum SidebandCommand {
    Complete { handoff_id: String, text: String },
    ContextAppend { text: String, speakable: bool },
    Close,
}

static SIDEBAND: LazyLock<StdMutex<Option<tokio::sync::mpsc::UnboundedSender<SidebandCommand>>>> =
    LazyLock::new(|| StdMutex::new(None));
static SIDEBAND_STATUS: LazyLock<StdMutex<String>> =
    LazyLock::new(|| StdMutex::new("idle".to_string()));
static SIDEBAND_EVENTS: LazyLock<StdMutex<VecDeque<String>>> =
    LazyLock::new(|| StdMutex::new(VecDeque::new()));
/// Incremented for every new call. A sideband thread only reports status and
/// events while its generation is current, so a late event from a previous
/// call can never reach the next conversation.
static SIDEBAND_GENERATION: AtomicU64 = AtomicU64::new(0);

fn is_current(generation: u64) -> bool {
    SIDEBAND_GENERATION.load(Ordering::SeqCst) == generation
}

fn set_sideband_status(generation: u64, status: impl Into<String>) {
    if !is_current(generation) {
        return;
    }
    if let Ok(mut current) = SIDEBAND_STATUS.lock() {
        *current = status.into();
    }
}

fn enqueue_sideband_event(generation: u64, event: String) {
    if !is_current(generation) {
        return;
    }
    if let Ok(mut events) = SIDEBAND_EVENTS.lock() {
        events.push_back(event);
        while events.len() > MAX_QUEUED_EVENTS {
            events.pop_front();
        }
    }
}

/// Options for `glassifai_codex_realtime_start_v2`, parsed leniently: every
/// missing or invalid field falls back to the baseline value.
struct StartOptions {
    instructions: String,
    model: String,
    voice: RealtimeVoice,
    /// Set when the requested voice was not a known voice name, so the app
    /// can report the substitution instead of hiding it.
    voice_note: Option<String>,
    delegation_ack_filler: bool,
    initial_items: Vec<ConversationTextParams>,
}

impl Default for StartOptions {
    fn default() -> Self {
        Self {
            instructions: BASELINE_INSTRUCTIONS.to_string(),
            model: BASELINE_MODEL.to_string(),
            voice: RealtimeVoice::Juniper,
            voice_note: None,
            delegation_ack_filler: true,
            initial_items: Vec::new(),
        }
    }
}

fn truncate_utf8(text: &str, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text.to_string();
    }
    let mut end = max_bytes;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_string()
}

fn parse_start_options(raw: &str) -> StartOptions {
    let mut options = StartOptions::default();
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return options;
    };
    if let Some(instructions) = value.get("instructions").and_then(Value::as_str)
        && !instructions.trim().is_empty()
    {
        options.instructions = truncate_utf8(instructions, MAX_INSTRUCTIONS_BYTES);
    }
    if let Some(model) = value.get("model").and_then(Value::as_str)
        && !model.trim().is_empty()
    {
        options.model = model.trim().to_string();
    }
    if let Some(voice) = value.get("voice").and_then(Value::as_str) {
        let requested = voice.trim().to_lowercase();
        match serde_json::from_value::<RealtimeVoice>(json!(requested.as_str())) {
            Ok(parsed) => options.voice = parsed,
            Err(_) if !requested.is_empty() => {
                options.voice_note = Some(format!(
                    "unknown voice '{}'; used {}",
                    truncate_utf8(&requested, 40),
                    options.voice.wire_name()
                ));
            }
            Err(_) => {}
        }
    }
    if let Some(filler) = value.get("delegation_ack_filler").and_then(Value::as_bool) {
        options.delegation_ack_filler = filler;
    }
    if let Some(items) = value.get("initial_items").and_then(Value::as_array) {
        options.initial_items = items
            .iter()
            .filter_map(|item| {
                let text = item.get("text").and_then(Value::as_str)?.trim();
                if text.is_empty() {
                    return None;
                }
                let role = match item.get("role").and_then(Value::as_str) {
                    Some("assistant") => ConversationTextRole::Assistant,
                    Some("developer") => ConversationTextRole::Developer,
                    _ => ConversationTextRole::User,
                };
                Some(ConversationTextParams {
                    text: truncate_utf8(text, MAX_INITIAL_ITEM_BYTES),
                    role,
                })
            })
            .take(MAX_INITIAL_ITEMS)
            .collect();
    }
    options
}

/// A short, stable name for the kind of failure.
fn error_kind(error: &ApiError) -> &'static str {
    match error {
        ApiError::Transport(TransportError::Http { .. }) => "http",
        ApiError::Transport(TransportError::Timeout) => "timeout",
        ApiError::Transport(_) => "network",
        ApiError::Api { .. } => "api",
        ApiError::RateLimit(_) => "rate_limit",
        ApiError::InvalidRequest { .. } => "invalid_request",
        ApiError::QuotaExceeded | ApiError::UsageNotIncluded => "quota",
        ApiError::ServerOverloaded => "overloaded",
        _ => "other",
    }
}

/// What the service said when a call could not be created, kept structured
/// for the app's diagnostics: the HTTP status, the error's code, param, type
/// and message when the body is JSON, the request id, and a short excerpt of
/// the body. Request headers (and so the token) are never included.
fn error_details(error: &ApiError) -> serde_json::Map<String, Value> {
    let mut details = serde_json::Map::new();
    details.insert("kind".to_string(), json!(error_kind(error)));
    match error {
        ApiError::Transport(TransportError::Http {
            status,
            headers,
            body,
            ..
        }) => {
            details.insert("status".to_string(), json!(status.as_u16()));
            if let Some(headers) = headers {
                for name in ["x-request-id", "request-id", "x-oai-request-id", "cf-ray"] {
                    if let Some(value) = headers.get(name).and_then(|value| value.to_str().ok()) {
                        details.insert("request_id".to_string(), json!(truncate_utf8(value, 120)));
                        break;
                    }
                }
            }
            if let Some(body) = body {
                details.insert(
                    "body_excerpt".to_string(),
                    json!(truncate_utf8(body, MAX_ERROR_BODY_BYTES)),
                );
                if let Ok(parsed) = serde_json::from_str::<Value>(body) {
                    let error_object = parsed.get("error").unwrap_or(&parsed);
                    for key in ["code", "param", "type", "message"] {
                        match error_object.get(key) {
                            Some(Value::String(text)) => {
                                details.insert(key.to_string(), json!(truncate_utf8(text, 300)));
                            }
                            Some(Value::Null) | None => {}
                            Some(other) => {
                                details.insert(
                                    key.to_string(),
                                    json!(truncate_utf8(&other.to_string(), 300)),
                                );
                            }
                        }
                    }
                }
            }
        }
        ApiError::Api { status, message } => {
            details.insert("status".to_string(), json!(status.as_u16()));
            details.insert("message".to_string(), json!(truncate_utf8(message, 300)));
        }
        ApiError::InvalidRequest { message } => {
            details.insert("message".to_string(), json!(truncate_utf8(message, 300)));
        }
        ApiError::RateLimit(message) => {
            details.insert("status".to_string(), json!(429));
            details.insert("message".to_string(), json!(truncate_utf8(message, 300)));
        }
        ApiError::Transport(TransportError::Timeout) => {
            details.insert(
                "message".to_string(),
                json!("the service did not answer in time (timed out)"),
            );
        }
        _ => {
            details.insert("message".to_string(), json!(truncate_utf8(&error.to_string(), 300)));
        }
    }
    details
}

fn sideband_session_ended(error: &ApiError) -> bool {
    matches!(
        error,
        ApiError::Api { status, .. } if *status == StatusCode::NOT_FOUND || *status == StatusCode::GONE
    )
}

fn reconnect_delay(attempt: u32) -> Duration {
    let exponent = attempt.saturating_sub(1).min(5);
    Duration::from_millis((200u64 << exponent).min(5_000))
}

/// The reconnect attempt after a connection ended: a fresh budget only when
/// the connection was stable, so an accept-then-close loop still ends.
fn attempt_after_disconnect(attempt: u32, connected_for: Duration) -> u32 {
    if connected_for >= STABLE_CONNECTION {
        1
    } else {
        attempt.saturating_add(1)
    }
}

/// Whether a failed connect ends the sideband. A 404/410 means the call is
/// over once the sideband has been connected; before that it is retried a few
/// times, since the call may not be registered yet.
fn connect_failure_is_final(error: &ApiError, ever_connected: bool, attempt: u32) -> bool {
    if attempt > MAX_RECONNECT_ATTEMPTS {
        return true;
    }
    sideband_session_ended(error) && (ever_connected || attempt > FIRST_CONNECT_NOT_FOUND_RETRIES)
}

fn push_pending(pending: &mut VecDeque<SidebandCommand>, command: SidebandCommand) {
    pending.push_back(command);
    while pending.len() > MAX_PENDING_COMMANDS {
        pending.pop_front();
    }
}

async fn send_command(
    speakable: &RealtimeWebsocketWriter,
    commentary: &RealtimeWebsocketWriter,
    command: &SidebandCommand,
) -> Result<&'static str, String> {
    match command {
        SidebandCommand::Complete { handoff_id, text } => speakable
            .send_conversation_function_call_output(handoff_id.clone(), text.clone())
            .await
            .map(|()| "delegation sent")
            .map_err(|error| error.to_string()),
        SidebandCommand::ContextAppend { text, speakable: true } => speakable
            .send_conversation_item_create(text.clone(), ConversationTextRole::User)
            .await
            .map(|()| "context sent")
            .map_err(|error| error.to_string()),
        SidebandCommand::ContextAppend { text, speakable: false } => commentary
            .send_conversation_item_create(text.clone(), ConversationTextRole::User)
            .await
            .map(|()| "context sent")
            .map_err(|error| error.to_string()),
        SidebandCommand::Close => Ok("closing"),
    }
}

/// Waits for the reconnect delay while still accepting commands. Returns true
/// when the sideband should shut down.
async fn wait_for_reconnect(
    rx: &mut tokio::sync::mpsc::UnboundedReceiver<SidebandCommand>,
    pending: &mut VecDeque<SidebandCommand>,
    delay: Duration,
) -> bool {
    let sleep = tokio::time::sleep(delay);
    tokio::pin!(sleep);
    loop {
        tokio::select! {
            _ = &mut sleep => return false,
            command = rx.recv() => match command {
                Some(SidebandCommand::Close) | None => return true,
                Some(command) => push_pending(pending, command),
            },
        }
    }
}

async fn run_sideband(
    generation: u64,
    provider: Provider,
    config: RealtimeSessionConfig,
    call_id: String,
    headers: HeaderMap,
    mut rx: tokio::sync::mpsc::UnboundedReceiver<SidebandCommand>,
) {
    let client = RealtimeWebsocketClient::new(provider);
    let mut pending: VecDeque<SidebandCommand> = VecDeque::new();
    let mut attempt: u32 = 0;
    let mut ever_connected = false;
    loop {
        if !is_current(generation) {
            return;
        }
        // Bounded, and a close request is honoured while the handshake runs.
        let connect = tokio::time::timeout(
            SIDEBAND_CONNECT_TIMEOUT,
            client.connect_webrtc_sideband(
                config.clone(),
                &call_id,
                headers.clone(),
                HeaderMap::new(),
                RealtimeTranscriptState::default(),
            ),
        );
        tokio::pin!(connect);
        let outcome = loop {
            tokio::select! {
                outcome = &mut connect => break outcome,
                command = rx.recv() => match command {
                    Some(SidebandCommand::Close) | None => return,
                    Some(command) => push_pending(&mut pending, command),
                },
            }
        };
        let connected_at = Instant::now();
        let connection = match outcome
            .unwrap_or_else(|_| Err(ApiError::Transport(TransportError::Timeout)))
        {
            Ok(connection) => {
                ever_connected = true;
                set_sideband_status(generation, "connected");
                connection
            }
            Err(error) => {
                attempt += 1;
                if connect_failure_is_final(&error, ever_connected, attempt) {
                    set_sideband_status(generation, format!("ended: connect failed: {error}"));
                    return;
                }
                set_sideband_status(generation, format!("reconnecting ({attempt}): {error}"));
                if wait_for_reconnect(&mut rx, &mut pending, reconnect_delay(attempt)).await {
                    return;
                }
                continue;
            }
        };

        let speakable = connection
            .writer()
            .with_context_append_channel(RealtimeContextAppendChannel::Speakable);
        let commentary = connection
            .writer()
            .with_context_append_channel(RealtimeContextAppendChannel::Commentary);
        let events = connection.events();

        // Deliver anything that was queued while the socket was down.
        let mut failure: Option<String> = None;
        while let Some(command) = pending.pop_front() {
            match send_command(&speakable, &commentary, &command).await {
                Ok(status) => set_sideband_status(generation, status),
                Err(error) => {
                    pending.push_front(command);
                    failure = Some(format!("send failed: {error}"));
                    break;
                }
            }
        }

        let reason = match failure {
            Some(reason) => reason,
            None => loop {
                tokio::select! {
                    command = rx.recv() => match command {
                        Some(SidebandCommand::Close) | None => return,
                        Some(command) => match send_command(&speakable, &commentary, &command).await {
                            Ok(status) => set_sideband_status(generation, status),
                            Err(error) => {
                                push_pending(&mut pending, command);
                                break format!("send failed: {error}");
                            }
                        },
                    },
                    event = events.next_event() => match event {
                        Ok(Some(RealtimeEvent::HandoffRequested(handoff))) => {
                            enqueue_sideband_event(generation, json!({
                                "type": "delegation.created",
                                "item": {
                                    "type": "delegation",
                                    "target": "client",
                                    "id": handoff.handoff_id,
                                    "content": [{
                                        "type": "input_text",
                                        "text": handoff.input_transcript,
                                    }],
                                },
                            }).to_string());
                            set_sideband_status(generation, "delegation received");
                        }
                        Ok(Some(RealtimeEvent::Error(error))) => {
                            set_sideband_status(generation, format!("server error: {error}"));
                        }
                        Ok(Some(_)) => {}
                        Ok(None) => break "server closed".to_string(),
                        Err(error) => break format!("receive failed: {error}"),
                    },
                }
            },
        };

        attempt = attempt_after_disconnect(attempt, connected_at.elapsed());
        if attempt > MAX_RECONNECT_ATTEMPTS {
            set_sideband_status(generation, format!("ended: {reason}"));
            return;
        }
        set_sideband_status(generation, format!("reconnecting ({attempt}): {reason}"));
        if wait_for_reconnect(&mut rx, &mut pending, reconnect_delay(attempt)).await {
            return;
        }
    }
}

fn spawn_sideband(
    provider: Provider,
    config: RealtimeSessionConfig,
    call_id: String,
    headers: HeaderMap,
) {
    let generation = SIDEBAND_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    set_sideband_status(generation, "connecting");
    if let Ok(mut events) = SIDEBAND_EVENTS.lock() {
        events.clear();
    }
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    if let Ok(mut slot) = SIDEBAND.lock()
        && let Some(previous) = slot.replace(tx)
    {
        let _ = previous.send(SidebandCommand::Close);
    }
    thread::spawn(move || {
        let runtime = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime,
            Err(error) => {
                set_sideband_status(generation, format!("ended: runtime failed: {error}"));
                return;
            }
        };
        runtime.block_on(run_sideband(generation, provider, config, call_id, headers, rx));
    });
}

/// The voice and model a start request really used. Returned with every
/// result so the app can show the selected and the active voice side by side
/// and never hide a fallback.
fn start_summary(
    voice: RealtimeVoice,
    model: &str,
    voice_note: Option<&str>,
) -> serde_json::Map<String, Value> {
    let mut summary = serde_json::Map::new();
    summary.insert("voice".to_string(), json!(voice.wire_name()));
    summary.insert("model".to_string(), json!(model));
    if let Some(note) = voice_note {
        summary.insert("voice_note".to_string(), json!(note));
    }
    summary
}

fn bridge_call(
    access_token: &str,
    account_id: &str,
    sdp: &str,
    options: StartOptions,
) -> serde_json::Value {
    let mut summary = start_summary(options.voice, &options.model, options.voice_note.as_deref());
    let mut headers = HeaderMap::new();
    headers.insert("openai-alpha", HeaderValue::from_static("quicksilver=v2"));
    headers.insert("originator", HeaderValue::from_static("codex_cli_rs"));
    headers.insert(
        "x-oai-attestation",
        HeaderValue::from_static("v1.omplcnJvcl9jb2RlAWlidW5kbGVfaWRwY29tLm9wZW5haS5jb2RleA"),
    );
    if let Ok(value) = HeaderValue::from_str(&uuid::Uuid::new_v4().to_string()) {
        headers.insert("session-id", value.clone());
        headers.insert("thread-id", value);
    }
    let provider = Provider {
        name: "chatgpt".to_string(),
        base_url: "https://chatgpt.com/backend-api/codex".to_string(),
        query_params: None,
        headers: HeaderMap::new(),
        retry: RetryConfig {
            max_attempts: 1,
            base_delay: Duration::from_millis(100),
            retry_429: false,
            retry_5xx: false,
            retry_transport: false,
        },
        stream_idle_timeout: Duration::from_secs(30),
    };
    let client = match HttpClientBuilder::new().build_direct() {
        Ok(client) => client,
        Err(error) => return json!({"ok": false, "error": error.to_string()}),
    };
    let transport = ReqwestTransport::from_http_client(client);
    let auth = Arc::new(OAuthAuth {
        access_token: access_token.to_string(),
        account_id: account_id.to_string(),
    });
    let config = RealtimeSessionConfig {
        instructions: options.instructions,
        initial_items: options.initial_items,
        delegation_ack_filler: Some(options.delegation_ack_filler),
        model: Some(options.model),
        session_id: None,
        event_parser: RealtimeEventParser::FramelessBidi,
        session_mode: RealtimeSessionMode::Conversational,
        output_modality: RealtimeOutputModality::Audio,
        voice: options.voice,
    };
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => return json!({"ok": false, "error": error.to_string()}),
    };
    let sideband_provider = provider.clone();
    let sideband_config = config.clone();
    let mut sideband_headers = headers.clone();
    auth.add_auth_headers(&mut sideband_headers);
    let result = runtime.block_on(async {
        tokio::time::timeout(
            CALL_CREATE_TIMEOUT,
            RealtimeCallClient::new(transport, provider, auth).create_with_session_and_headers(
                sdp.to_string(),
                config,
                headers,
            ),
        )
        .await
        .unwrap_or_else(|_| Err(ApiError::Transport(TransportError::Timeout)))
    });
    match result {
        Ok(response) => {
            spawn_sideband(
                sideband_provider,
                sideband_config,
                response.call_id.clone(),
                sideband_headers,
            );
            summary.insert("ok".to_string(), json!(true));
            summary.insert("sdp".to_string(), json!(response.sdp));
            summary.insert("call_id".to_string(), json!(response.call_id));
            Value::Object(summary)
        }
        Err(error) => {
            summary.insert("ok".to_string(), json!(false));
            summary.insert("error".to_string(), json!(error.to_string()));
            summary.insert(
                "error_details".to_string(),
                Value::Object(error_details(&error)),
            );
            Value::Object(summary)
        }
    }
}

fn into_c_string(output: String) -> *mut c_char {
    CString::new(output)
        .unwrap_or_else(|_| CString::new(r#"{"ok":false,"error":"encoding"}"#).expect("literal"))
        .into_raw()
}

/// Original entry point: starts a call with the baseline configuration.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glassifai_codex_realtime_start(
    access_token: *const c_char,
    account_id: *const c_char,
    sdp: *const c_char,
) -> *mut c_char {
    if access_token.is_null() || account_id.is_null() || sdp.is_null() {
        return into_c_string(r#"{"ok":false,"error":"null input"}"#.to_string());
    }
    let access_token = unsafe { CStr::from_ptr(access_token) }.to_string_lossy();
    let account_id = unsafe { CStr::from_ptr(account_id) }.to_string_lossy();
    let sdp = unsafe { CStr::from_ptr(sdp) }.to_string_lossy();
    into_c_string(bridge_call(&access_token, &account_id, &sdp, StartOptions::default()).to_string())
}

/// Starts a call with caller-supplied instructions, voice, model and initial
/// context (JSON). Invalid or missing fields fall back to the baseline values.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glassifai_codex_realtime_start_v2(
    access_token: *const c_char,
    account_id: *const c_char,
    sdp: *const c_char,
    options_json: *const c_char,
) -> *mut c_char {
    if access_token.is_null() || account_id.is_null() || sdp.is_null() {
        return into_c_string(r#"{"ok":false,"error":"null input"}"#.to_string());
    }
    let access_token = unsafe { CStr::from_ptr(access_token) }.to_string_lossy();
    let account_id = unsafe { CStr::from_ptr(account_id) }.to_string_lossy();
    let sdp = unsafe { CStr::from_ptr(sdp) }.to_string_lossy();
    let options = if options_json.is_null() {
        StartOptions::default()
    } else {
        parse_start_options(&unsafe { CStr::from_ptr(options_json) }.to_string_lossy())
    };
    into_c_string(bridge_call(&access_token, &account_id, &sdp, options).to_string())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn glassifai_codex_delegation_complete(
    handoff_id: *const c_char,
    text: *const c_char,
) -> bool {
    if handoff_id.is_null() || text.is_null() {
        return false;
    }
    let handoff_id = unsafe { CStr::from_ptr(handoff_id) }
        .to_string_lossy()
        .into_owned();
    let text = unsafe { CStr::from_ptr(text) }
        .to_string_lossy()
        .into_owned();
    let Ok(slot) = SIDEBAND.lock() else {
        return false;
    };
    slot.as_ref().is_some_and(|sender| {
        sender
            .send(SidebandCommand::Complete { handoff_id, text })
            .is_ok()
    })
}

/// Appends context to the live conversation. `speakable == false` uses the
/// commentary channel, which informs the voice model without being spoken.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glassifai_codex_context_append(text: *const c_char, speakable: bool) -> bool {
    if text.is_null() {
        return false;
    }
    let text = unsafe { CStr::from_ptr(text) }
        .to_string_lossy()
        .into_owned();
    let Ok(slot) = SIDEBAND.lock() else {
        return false;
    };
    slot.as_ref().is_some_and(|sender| {
        sender
            .send(SidebandCommand::ContextAppend { text, speakable })
            .is_ok()
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn glassifai_codex_realtime_close() {
    if let Ok(mut slot) = SIDEBAND.lock()
        && let Some(sender) = slot.take()
    {
        let _ = sender.send(SidebandCommand::Close);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn glassifai_codex_next_sideband_event() -> *mut c_char {
    let event = SIDEBAND_EVENTS
        .lock()
        .ok()
        .and_then(|mut events| events.pop_front());
    let Some(event) = event else {
        return null_mut();
    };
    CString::new(event)
        .unwrap_or_else(|_| CString::new("{}").expect("literal"))
        .into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn glassifai_codex_sideband_status() -> *mut c_char {
    let status = SIDEBAND_STATUS
        .lock()
        .map(|status| status.clone())
        .unwrap_or_else(|_| "status unavailable".to_string());
    CString::new(status)
        .unwrap_or_else(|_| CString::new("status encoding failed").expect("literal"))
        .into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn glassifai_codex_bridge_version() -> *mut c_char {
    CString::new(BRIDGE_VERSION)
        .unwrap_or_else(|_| CString::new("unknown").expect("literal"))
        .into_raw()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn glassifai_codex_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_protocol::protocol::RealtimeVoicesList;

    #[test]
    fn empty_options_keep_baseline_configuration() {
        let options = parse_start_options("");
        assert_eq!(options.instructions, BASELINE_INSTRUCTIONS);
        assert_eq!(options.model, BASELINE_MODEL);
        assert_eq!(options.voice, RealtimeVoice::Juniper);
        assert!(options.delegation_ack_filler);
        assert!(options.initial_items.is_empty());
    }

    #[test]
    fn invalid_voice_falls_back_to_juniper_and_is_reported() {
        let options = parse_start_options(r#"{"voice":"not-a-voice","instructions":"Hi"}"#);
        assert_eq!(options.voice, RealtimeVoice::Juniper);
        assert_eq!(options.instructions, "Hi");
        let note = options.voice_note.unwrap_or_default();
        assert!(note.contains("not-a-voice"), "{note}");
    }

    #[test]
    fn requested_voice_is_applied() {
        let options = parse_start_options(r#"{"voice":" Maple "}"#);
        assert_eq!(options.voice, RealtimeVoice::Maple);
        assert!(options.voice_note.is_none());
    }

    #[test]
    fn start_summary_reports_the_applied_voice_and_model() {
        let summary = start_summary(RealtimeVoice::Cove, "gpt-live-1-codex", None);
        assert_eq!(summary.get("voice"), Some(&json!("cove")));
        assert_eq!(summary.get("model"), Some(&json!("gpt-live-1-codex")));
        assert!(!summary.contains_key("voice_note"));
        let noted = start_summary(RealtimeVoice::Juniper, "m", Some("unknown voice 'x'; used juniper"));
        assert_eq!(noted.get("voice_note"), Some(&json!("unknown voice 'x'; used juniper")));
    }

    #[test]
    fn frameless_voices_match_the_app_catalog() {
        // The app offers exactly the voices Codex accepts for the frameless
        // (v3) realtime protocol that this bridge uses.
        let voices: Vec<&str> = RealtimeVoicesList::builtin()
            .v1
            .iter()
            .map(|voice| voice.wire_name())
            .collect();
        assert_eq!(
            voices,
            ["juniper", "maple", "spruce", "ember", "vale", "breeze", "arbor", "sol", "cove"]
        );
    }

    #[test]
    fn initial_items_are_bounded_and_typed() {
        let items: Vec<Value> = (0..20)
            .map(|index| json!({"role": if index == 0 { "developer" } else { "user" }, "text": format!("item {index}")}))
            .collect();
        let options = parse_start_options(&json!({"initial_items": items}).to_string());
        assert_eq!(options.initial_items.len(), MAX_INITIAL_ITEMS);
        assert_eq!(options.initial_items[0].role, ConversationTextRole::Developer);
    }

    #[test]
    fn reconnect_delay_backs_off_and_caps() {
        assert_eq!(reconnect_delay(1), Duration::from_millis(200));
        assert_eq!(reconnect_delay(2), Duration::from_millis(400));
        assert_eq!(reconnect_delay(10), Duration::from_millis(5_000));
    }

    #[test]
    fn truncation_respects_char_boundaries() {
        assert_eq!(truncate_utf8("çğü", 3), "ç");
    }

    #[test]
    fn http_errors_keep_status_code_param_and_request_id() {
        let mut headers = HeaderMap::new();
        headers.insert("x-request-id", HeaderValue::from_static("req_abc123"));
        let error = ApiError::Transport(TransportError::Http {
            status: StatusCode::BAD_REQUEST,
            url: None,
            headers: Some(headers),
            body: Some(
                r#"{"error":{"message":"Invalid value for voice.","type":"invalid_request_error","param":"session.voice","code":"invalid_value"}}"#
                    .to_string(),
            ),
        });
        let details = error_details(&error);
        assert_eq!(details.get("kind"), Some(&json!("http")));
        assert_eq!(details.get("status"), Some(&json!(400)));
        assert_eq!(details.get("code"), Some(&json!("invalid_value")));
        assert_eq!(details.get("param"), Some(&json!("session.voice")));
        assert_eq!(details.get("type"), Some(&json!("invalid_request_error")));
        assert_eq!(details.get("message"), Some(&json!("Invalid value for voice.")));
        assert_eq!(details.get("request_id"), Some(&json!("req_abc123")));
        assert!(details.contains_key("body_excerpt"));
    }

    #[test]
    fn other_errors_still_report_their_kind_and_bodies_are_bounded() {
        let long_body = "x".repeat(5_000);
        let error = ApiError::Transport(TransportError::Http {
            status: StatusCode::BAD_GATEWAY,
            url: None,
            headers: None,
            body: Some(long_body),
        });
        let details = error_details(&error);
        assert_eq!(details.get("status"), Some(&json!(502)));
        assert!(!details.contains_key("code"), "not JSON: no fields invented");
        let excerpt = details.get("body_excerpt").and_then(Value::as_str).unwrap_or_default();
        assert!(excerpt.len() <= MAX_ERROR_BODY_BYTES);
        let timeout = error_details(&ApiError::Transport(TransportError::Timeout));
        assert_eq!(timeout.get("kind"), Some(&json!("timeout")));
        assert!(!timeout.contains_key("status"));
        let message = timeout.get("message").and_then(Value::as_str).unwrap_or_default();
        assert!(message.contains("timed out"), "the app words a timeout from this: {message}");
    }

    #[test]
    fn a_short_lived_sideband_keeps_counting_and_a_stable_one_starts_over() {
        // Accepted and closed at once, again and again: the budget runs out.
        let mut attempt = 0;
        for _ in 0..MAX_RECONNECT_ATTEMPTS {
            attempt = attempt_after_disconnect(attempt, Duration::from_millis(50));
        }
        assert_eq!(attempt, MAX_RECONNECT_ATTEMPTS);
        assert!(attempt_after_disconnect(attempt, Duration::from_secs(1)) > MAX_RECONNECT_ATTEMPTS);
        // A connection that held for a while starts a fresh budget.
        assert_eq!(attempt_after_disconnect(attempt, STABLE_CONNECTION), 1);
        assert_eq!(attempt_after_disconnect(5, Duration::from_secs(600)), 1);
    }

    #[test]
    fn a_first_connect_not_found_is_retried_but_a_later_one_ends_the_sideband() {
        let not_found = ApiError::Api {
            status: StatusCode::NOT_FOUND,
            message: "realtime websocket handshake failed".to_string(),
        };
        let gone = ApiError::Api {
            status: StatusCode::GONE,
            message: "gone".to_string(),
        };
        for attempt in 1..=FIRST_CONNECT_NOT_FOUND_RETRIES {
            assert!(!connect_failure_is_final(&not_found, false, attempt), "attempt {attempt}");
        }
        assert!(connect_failure_is_final(&not_found, false, FIRST_CONNECT_NOT_FOUND_RETRIES + 1));
        assert!(connect_failure_is_final(&not_found, true, 1), "after a connect, 404 means the call ended");
        assert!(connect_failure_is_final(&gone, true, 1));
        // Other failures are retried until the budget is spent.
        let network = ApiError::Transport(TransportError::Timeout);
        assert!(!connect_failure_is_final(&network, true, MAX_RECONNECT_ATTEMPTS));
        assert!(connect_failure_is_final(&network, true, MAX_RECONNECT_ATTEMPTS + 1));
    }

    #[test]
    fn timeouts_are_bounded() {
        assert!(CALL_CREATE_TIMEOUT <= Duration::from_secs(20));
        assert!(SIDEBAND_CONNECT_TIMEOUT <= Duration::from_secs(10));
        assert!(STABLE_CONNECTION >= Duration::from_secs(30));
    }
}
