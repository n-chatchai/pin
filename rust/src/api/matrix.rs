//! Matrix client API exposed to Flutter via flutter_rust_bridge.
//!
//! Wraps matrix-sdk (Apache-2.0) so the Dart side never touches the AGPL
//! matrix-dart-sdk. All E2EE (Olm/Megolm via vodozemac) is handled here by
//! matrix-sdk transparently — Dart only sees plaintext bodies.

use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::sync::Mutex;
use tokio::runtime::Runtime;
use tokio::sync::RwLock;

use matrix_sdk::{
    authentication::matrix::MatrixSession,
    config::SyncSettings,
    ruma::{
        events::{
            reaction::SyncReactionEvent,
            receipt::{ReceiptType, SyncReceiptEvent},
            typing::SyncTypingEvent,
            room::{
                message::{
                    MessageType, Relation, SyncRoomMessageEvent, TextMessageEventContent,
                },
                MediaSource,
            },
        },
        serde::Raw,
        OwnedEventId, RoomId,
    },
    media::{MediaFormat, MediaRequestParameters},
    store::RoomLoadSettings,
    Client, Room, SessionMeta, SessionTokens,
};

/// Dedicated multi-threaded tokio runtime that drives all matrix-sdk futures.
/// frb invokes our (non-async) functions on its own worker threads, so blocking
/// on this runtime never stalls the Dart isolate.
static RT: Lazy<Runtime> = Lazy::new(|| Runtime::new().expect("tokio runtime"));

/// Logged-in clients, keyed by ROLE: "user" = the human's account, "pin" = the
/// companion ปิ่น account the on-device agent posts as. Two concurrent matrix
/// sessions run on one device for the 2-account E2EE DM. Replaced on
/// login/restore, removed on logout.
static CLIENTS: Lazy<RwLock<HashMap<String, Client>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));

/// Default role for the existing single-session callers (download_media,
/// list_rooms, recovery, etc.) — the human's account.
const USER_ROLE: &str = "user";

/// Sink for live decrypted messages, set by [`start_sync`]. Shared by all
/// clients; Dart filters by room_id / sender. Each emitted [`ChatMessage`]
/// carries the receiving client's role so Dart can tell which session saw it.
static MSG_SINK: Lazy<Mutex<Option<StreamSink<ChatMessage>>>> =
    Lazy::new(|| Mutex::new(None));

/// Handles to the background sync loops spawned by [`start_sync`], keyed by
/// role. Held so logout (and a defensive login) can `abort()` the right one —
/// otherwise the spawned task keeps its own `Client` clone alive, syncing the
/// previous account into the store and leaking it into the next login.
static SYNC_TASKS: Lazy<Mutex<HashMap<String, tokio::task::JoinHandle<()>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Abort the background sync loop for `role` if one is running, releasing its
/// `Client` clone and the store handle it keeps open.
fn stop_sync(role: &str) {
    if let Some(handle) = SYNC_TASKS.lock().unwrap().remove(role) {
        handle.abort();
    }
}

// ---------------------------------------------------------------------------
// Data transferred to Dart
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct Session {
    pub homeserver: String,
    pub user_id: String,
    pub device_id: String,
    pub access_token: String,
}

#[derive(Clone)]
pub struct RoomSummary {
    pub id: String,
    pub name: String,
    pub is_encrypted: bool,
}

#[derive(Clone)]
pub struct ChatMessage {
    pub room_id: String,
    pub event_id: String,
    pub sender: String,
    pub body: String,
    pub timestamp_ms: u64,
    pub is_me: bool,
    /// "text" | "image" | "file" | "audio" | "video" | "reaction"
    pub kind: String,
    /// Event id this message replies to (m.in_reply_to), if any.
    pub reply_to_event_id: Option<String>,
    /// For kind == "reaction": the event being reacted to.
    pub reaction_target: Option<String>,
    /// For kind == "reaction": the emoji/key.
    pub reaction_key: Option<String>,
    /// For media kinds: the mxc:// URL (download handled separately).
    pub media_url: Option<String>,
    pub media_mime: Option<String>,
    /// Raw JSON of the `io.tokens2.flex` card, if this message carries one.
    pub flex_json: Option<String>,
    /// Raw JSON of the `io.tokens2.meta` content key (assistant used/hint), if any.
    pub meta_json: Option<String>,
    /// Role of the client that RECEIVED this event ("user" | "pin"). Dart maps
    /// the event's `sender` against the known user/pin ids to decide the bubble
    /// side; this just says which session's sync surfaced it.
    pub recv_role: String,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn block<F: std::future::Future>(f: F) -> F::Output {
    RT.block_on(f)
}

fn source_url(source: &MediaSource) -> Option<String> {
    match source {
        MediaSource::Plain(uri) => Some(uri.to_string()),
        MediaSource::Encrypted(file) => Some(file.url.to_string()),
        _ => None,
    }
}

fn emit(msg: ChatMessage) {
    if let Some(sink) = MSG_SINK.lock().unwrap().as_ref() {
        let _ = sink.add(msg);
    }
}

/// Get the logged-in client for `role` ("user" | "pin").
async fn client_for(role: &str) -> Result<Client, String> {
    CLIENTS
        .read()
        .await
        .get(role)
        .cloned()
        .ok_or_else(|| format!("{role} not logged in"))
}

/// The human-account client — used by the existing single-session callers.
async fn current_client() -> Result<Client, String> {
    client_for(USER_ROLE).await
}

/// Resolve a room on a specific client (`role`).
async fn room_by_id_role(role: &str, room_id: &str) -> Result<Room, String> {
    let client = client_for(role).await?;
    let rid = RoomId::parse(room_id).map_err(|_| "bad room id".to_string())?;
    client
        .get_room(&rid)
        .ok_or_else(|| "room not found".to_string())
}

/// Resolve a room on the human-account client.
async fn room_by_id(room_id: &str) -> Result<Room, String> {
    room_by_id_role(USER_ROLE, room_id).await
}

/// Whether `room_id` is present in the user client's local store (no network).
/// A cached room id from a previous account isn't in this client → every room
/// read ("room not found") fails; callers use this to drop a stale cache and
/// re-resolve. Also false for a valid room not yet synced into a fresh store.
pub fn room_in_store(room_id: String) -> bool {
    block(async move {
        let Ok(client) = client_for(USER_ROLE).await else {
            return false;
        };
        match RoomId::parse(&room_id) {
            Ok(rid) => client.get_room(&rid).is_some(),
            Err(_) => false,
        }
    })
}

async fn build_client(homeserver: &str, db_path: &str) -> Result<Client, String> {
    // The /sync long-poll holds for up to 30s server-side; the per-request HTTP
    // timeout MUST exceed that or every sync errors ("error sending request")
    // right as the server is about to respond, and the reconnect loop never
    // delivers events → the chat never renders. Give it generous headroom.
    let request_config = matrix_sdk::config::RequestConfig::new()
        .timeout(std::time::Duration::from_secs(60));
    // SSO URL building (get_sso_login_url) joins paths onto the homeserver, which
    // needs an absolute base — a bare host ("pin-chat.tokens2.io") fails with
    // "relative URL without a base". Default to https when no scheme is given.
    let hs = if homeserver.starts_with("http://") || homeserver.starts_with("https://") {
        homeserver.to_string()
    } else {
        format!("https://{homeserver}")
    };
    Client::builder()
        .homeserver_url(&hs)
        .sqlite_store(db_path, None)
        .request_config(request_config)
        .build()
        .await
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Password login against `homeserver`, persisting crypto + state at `db_path`.
/// Returns the session so Dart can store it in the Keychain/Keystore.
pub fn login(
    role: String,
    homeserver: String,
    db_path: String,
    username: String,
    password: String,
) -> Result<Session, String> {
    block(async move {
        // Explicit password login starts a fresh device + crypto store. Stop any
        // lingering sync loop FOR THIS ROLE (so its Client clone can't rewrite the
        // store mid wipe) then wipe any stale store at this path — login_username
        // can't reuse a store that already holds a different device's OlmAccount.
        stop_sync(&role);
        let _ = std::fs::remove_dir_all(&db_path);
        let client = build_client(&homeserver, &db_path).await?;
        client
            .matrix_auth()
            .login_username(&username, &password)
            .initial_device_display_name("pin")
            .await
            .map_err(|e| e.to_string())?;

        let session = client
            .matrix_auth()
            .session()
            .ok_or_else(|| "login produced no session".to_string())?;

        let out = Session {
            homeserver,
            user_id: session.meta.user_id.to_string(),
            device_id: session.meta.device_id.to_string(),
            access_token: session.tokens.access_token,
        };
        CLIENTS.write().await.insert(role, client);
        Ok(out)
    })
}

/// Restore a previously stored session (no network login). Verifies nothing —
/// the first sync will surface an invalid token.
pub fn restore(
    role: String,
    homeserver: String,
    db_path: String,
    user_id: String,
    device_id: String,
    access_token: String,
) -> Result<(), String> {
    block(async move {
        let client = build_client(&homeserver, &db_path).await?;
        let session = MatrixSession {
            meta: SessionMeta {
                user_id: user_id.parse().map_err(|_| "bad user id".to_string())?,
                device_id: device_id.into(),
            },
            tokens: SessionTokens {
                access_token,
                refresh_token: None,
            },
        };
        client
            .matrix_auth()
            .restore_session(session, RoomLoadSettings::default())
            .await
            .map_err(|e| e.to_string())?;
        CLIENTS.write().await.insert(role, client);
        Ok(())
    })
}

/// Build the SSO login URL the app opens in a browser (Sign in with Google).
/// `redirect_url` is the app deep link the homeserver returns the `loginToken`
/// to. `idp_id` = None uses the homeserver's default provider (we run a single
/// one, Google, so it's implicitly default). Uses a throwaway store so it never
/// touches the real session db.
pub fn sso_login_url(
    homeserver: String,
    db_path: String,
    redirect_url: String,
    idp_id: Option<String>,
) -> Result<String, String> {
    block(async move {
        let tmp = format!("{db_path}.ssotmp");
        let _ = std::fs::remove_dir_all(&tmp);
        let client = build_client(&homeserver, &tmp).await?;
        let url = client
            .matrix_auth()
            .get_sso_login_url(&redirect_url, idp_id.as_deref())
            .await
            .map_err(|e| e.to_string());
        let _ = std::fs::remove_dir_all(&tmp);
        url
    })
}

/// Finish SSO: exchange the `loginToken` from the redirect for a Matrix session,
/// persisting a fresh device + crypto store (same as password login).
pub fn login_token(
    role: String,
    homeserver: String,
    db_path: String,
    token: String,
) -> Result<Session, String> {
    block(async move {
        stop_sync(&role);
        let _ = std::fs::remove_dir_all(&db_path);
        let client = build_client(&homeserver, &db_path).await?;
        client
            .matrix_auth()
            .login_token(&token)
            .initial_device_display_name("pin")
            .await
            .map_err(|e| e.to_string())?;

        let session = client
            .matrix_auth()
            .session()
            .ok_or_else(|| "login produced no session".to_string())?;

        let out = Session {
            homeserver,
            user_id: session.meta.user_id.to_string(),
            device_id: session.meta.device_id.to_string(),
            access_token: session.tokens.access_token,
        };
        CLIENTS.write().await.insert(role, client);
        Ok(out)
    })
}

/// One foreground sync, then the list of joined rooms.
pub fn list_rooms() -> Result<Vec<RoomSummary>, String> {
    block(async move {
        let client = current_client().await?;
        client
            .sync_once(SyncSettings::default())
            .await
            .map_err(|e| e.to_string())?;

        let mut rooms = Vec::new();
        for room in client.joined_rooms() {
            let name = match room.display_name().await {
                Ok(n) => n.to_string(),
                Err(_) => room.room_id().to_string(),
            };
            rooms.push(RoomSummary {
                id: room.room_id().to_string(),
                name,
                is_encrypted: room
                    .latest_encryption_state()
                    .await
                    .map(|s| s.is_encrypted())
                    .unwrap_or(false),
            });
        }
        Ok(rooms)
    })
}

/// Read persona prefs back from room state. Returns the `content` JSON string,
/// or None if never set. Used on startup to rehydrate prefs after a reinstall.
pub fn get_prefs_state(room_id: String) -> Result<Option<String>, String> {
    use matrix_sdk::deserialized_responses::RawAnySyncOrStrippedState as St;
    block(async move {
        let room = room_by_id(&room_id).await?;
        let ev = room
            .get_state_event(
                matrix_sdk::ruma::events::StateEventType::from("io.tokens2.prefs"),
                "",
            )
            .await
            .map_err(|e| e.to_string())?;
        let Some(raw) = ev else { return Ok(None) };
        let json = match raw {
            St::Sync(r) => r.deserialize_as::<serde_json::Value>(),
            St::Stripped(r) => r.deserialize_as::<serde_json::Value>(),
        }
        .map_err(|e| e.to_string())?;
        let content = json.get("content").cloned().unwrap_or(json);
        Ok(Some(content.to_string()))
    })
}

/// Read an arbitrary room STATE event's content JSON (e.g. `io.tokens2.facts` /
/// `.knowledge`) from the `role` client, or None if never set. Generic sibling
/// of [`get_prefs_state`] for cross-device memory sync.
pub fn get_state(
    role: String,
    room_id: String,
    event_type: String,
) -> Result<Option<String>, String> {
    use matrix_sdk::deserialized_responses::RawAnySyncOrStrippedState as St;
    block(async move {
        let room = room_by_id_role(&role, &room_id).await?;
        let ev = room
            .get_state_event(
                matrix_sdk::ruma::events::StateEventType::from(event_type.as_str()),
                "",
            )
            .await
            .map_err(|e| e.to_string())?;
        let Some(raw) = ev else { return Ok(None) };
        let json = match raw {
            St::Sync(r) => r.deserialize_as::<serde_json::Value>(),
            St::Stripped(r) => r.deserialize_as::<serde_json::Value>(),
        }
        .map_err(|e| e.to_string())?;
        let content = json.get("content").cloned().unwrap_or(json);
        Ok(Some(content.to_string()))
    })
}

/// Register the live event handlers on `client`, tagging every emitted
/// [`ChatMessage`] with `role` (which session saw it). Shared by the user and
/// pin sync starts so both stream into the one [`MSG_SINK`].
fn register_handlers(client: &Client, role: String) {
    // Messages (text + media + flex), with reply relation. Uses Raw so we can
    // read the custom `io.tokens2.*` keys from the (decrypted) content.
    let r = role.clone();
    client.add_event_handler(
        move |raw: Raw<SyncRoomMessageEvent>, room: Room, client: Client| {
            let role = r.clone();
            async move {
                let Ok(ev) = raw.deserialize() else { return };
                let Some(orig) = ev.as_original() else { return };
                let (mut kind, body, media_url) = match &orig.content.msgtype {
                    MessageType::Text(t) => ("text", t.body.clone(), None),
                    MessageType::Notice(t) => ("text", t.body.clone(), None),
                    MessageType::Image(c) => ("image", c.body.clone(), source_url(&c.source)),
                    MessageType::File(c) => ("file", c.body.clone(), source_url(&c.source)),
                    MessageType::Audio(c) => ("audio", c.body.clone(), source_url(&c.source)),
                    MessageType::Video(c) => ("video", c.body.clone(), source_url(&c.source)),
                    _ => return,
                };
                // Pull custom payloads (flex card / tasks list / meta) from the
                // raw (decrypted) content. flex_json carries either; kind
                // distinguishes.
                let content = raw.get_field::<serde_json::Value>("content").ok().flatten();
                let flex_json = match content.as_ref() {
                    Some(c) if c.get("io.tokens2.tasks").is_some() => {
                        kind = "tasks";
                        c.get("io.tokens2.tasks").map(|v| v.to_string())
                    }
                    Some(c) if c.get("io.tokens2.events").is_some() => {
                        kind = "events";
                        c.get("io.tokens2.events").map(|v| v.to_string())
                    }
                    Some(c) if c.get("io.tokens2.jobs").is_some() => {
                        kind = "jobs";
                        c.get("io.tokens2.jobs").map(|v| v.to_string())
                    }
                    Some(c) if c.get("io.tokens2.flex").is_some() => {
                        kind = "flex";
                        c.get("io.tokens2.flex").map(|v| v.to_string())
                    }
                    _ => None,
                };
                let meta_json = content
                    .as_ref()
                    .and_then(|c| c.get("io.tokens2.meta"))
                    .map(|v| v.to_string());
                let reply_to = match &orig.content.relates_to {
                    Some(Relation::Reply(r)) => Some(r.in_reply_to.event_id.to_string()),
                    _ => None,
                };
                let is_me = client.user_id().map(|me| me == ev.sender()).unwrap_or(false);
                emit(ChatMessage {
                    room_id: room.room_id().to_string(),
                    event_id: orig.event_id.to_string(),
                    sender: ev.sender().to_string(),
                    body,
                    timestamp_ms: orig.origin_server_ts.0.into(),
                    is_me,
                    kind: kind.to_string(),
                    reply_to_event_id: reply_to,
                    reaction_target: None,
                    reaction_key: None,
                    media_url,
                    media_mime: None,
                    flex_json,
                    meta_json,
                    recv_role: role,
                });
            }
        },
    );

    // Reactions (m.reaction annotations).
    let r = role.clone();
    client.add_event_handler(
        move |ev: SyncReactionEvent, room: Room, client: Client| {
            let role = r.clone();
            async move {
                let Some(orig) = ev.as_original() else { return };
                let ann = &orig.content.relates_to;
                let is_me = client.user_id().map(|me| me == ev.sender()).unwrap_or(false);
                emit(ChatMessage {
                    room_id: room.room_id().to_string(),
                    event_id: orig.event_id.to_string(),
                    sender: ev.sender().to_string(),
                    body: ann.key.clone(),
                    timestamp_ms: orig.origin_server_ts.0.into(),
                    is_me,
                    kind: "reaction".to_string(),
                    reply_to_event_id: None,
                    reaction_target: Some(ann.event_id.to_string()),
                    reaction_key: Some(ann.key.clone()),
                    media_url: None,
                    media_mime: None,
                    flex_json: None,
                    meta_json: None,
                    recv_role: role,
                });
            }
        },
    );

    // Typing notifications (ephemeral). We forward the set of *other* users
    // currently typing as a comma-joined list in `body`; empty = nobody typing.
    let r = role.clone();
    client.add_event_handler(
        move |ev: SyncTypingEvent, room: Room, client: Client| {
            let role = r.clone();
            async move {
                let me = client.user_id().map(|u| u.to_owned());
                let others: Vec<String> = ev
                    .content
                    .user_ids
                    .iter()
                    .filter(|u| me.as_deref() != Some(u.as_ref()))
                    .map(|u| u.to_string())
                    .collect();
                emit(ChatMessage {
                    room_id: room.room_id().to_string(),
                    event_id: String::new(),
                    sender: others.first().cloned().unwrap_or_default(),
                    body: others.join(","),
                    timestamp_ms: 0,
                    is_me: false,
                    kind: "typing".to_string(),
                    reply_to_event_id: None,
                    reaction_target: None,
                    reaction_key: None,
                    media_url: None,
                    media_mime: None,
                    flex_json: None,
                    meta_json: None,
                    recv_role: role,
                });
            }
        },
    );

    // Read receipts (ephemeral). Emit one row per (reader, event) read receipt
    // from someone other than us, so Dart can mark our bubbles as "read".
    let r = role.clone();
    client.add_event_handler(
        move |ev: SyncReceiptEvent, room: Room, client: Client| {
            let role = r.clone();
            async move {
                let me = client.user_id().map(|u| u.to_owned());
                for (event_id, receipts) in ev.content.iter() {
                    let Some(read) = receipts.get(&ReceiptType::Read) else { continue };
                    for (user, _receipt) in read.iter() {
                        if me.as_deref() == Some(user.as_ref()) {
                            continue;
                        }
                        emit(ChatMessage {
                            room_id: room.room_id().to_string(),
                            event_id: event_id.to_string(),
                            sender: user.to_string(),
                            body: event_id.to_string(),
                            timestamp_ms: 0,
                            is_me: false,
                            kind: "receipt".to_string(),
                            reply_to_event_id: None,
                            reaction_target: Some(event_id.to_string()),
                            reaction_key: None,
                            media_url: None,
                            media_mime: None,
                            flex_json: None,
                            meta_json: None,
                            recv_role: role.clone(),
                        });
                    }
                }
            }
        },
    );
}

/// Spawn the forever-sync loop for `role`'s client (aborting any prior loop for
/// that role), and remember the handle so logout/login can abort it.
fn spawn_sync_loop(role: String, client: Client) {
    stop_sync(&role);
    let handle = RT.spawn(async move {
        loop {
            let settings =
                SyncSettings::default().timeout(std::time::Duration::from_secs(30));
            if let Err(e) = client.sync(settings).await {
                // Print the full error source chain — the top-level reqwest
                // message ("error sending request") hides the real cause
                // (timeout vs connection-reset vs TLS vs decode).
                let mut chain = format!("{e}");
                let mut src = std::error::Error::source(&e);
                while let Some(s) = src {
                    chain.push_str(&format!(" | caused by: {s}"));
                    src = s.source();
                }
                eprintln!("matrix sync stopped, reconnecting in 3s: {chain}");
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            }
        }
    });
    SYNC_TASKS.lock().unwrap().insert(role, handle);
}

/// Begin a continuous background sync for the USER client, streaming each
/// decrypted message to Dart. Sets the shared sink. Call once after login/restore.
pub fn start_sync(sink: StreamSink<ChatMessage>) -> Result<(), String> {
    *MSG_SINK.lock().unwrap() = Some(sink);
    let client = block(current_client())?;
    register_handlers(&client, USER_ROLE.to_string());
    spawn_sync_loop(USER_ROLE.to_string(), client);
    Ok(())
}

/// Begin a continuous background sync for a non-default role (e.g. "pin"),
/// reusing the shared sink already set by [`start_sync`]. Events from this
/// client flow into the same Dart stream tagged with `recv_role`.
pub fn start_sync_role(role: String) -> Result<(), String> {
    let client = block(client_for(&role))?;
    register_handlers(&client, role.clone());
    spawn_sync_loop(role, client);
    Ok(())
}

// ---------------------------------------------------------------------------
// Room send / timeline (2-account E2EE DM)
// ---------------------------------------------------------------------------

/// A page of decrypted timeline events, oldest→newest within the page.
#[derive(Clone)]
pub struct TimelinePage {
    /// Pagination token to pass as `from` on the next older page (None = start).
    pub end_token: Option<String>,
    /// Mapped m.room.message events (non-message events are dropped).
    pub messages: Vec<ChatMessage>,
}

/// Map a (decrypted) timeline event's raw JSON to a [`ChatMessage`]. Mirrors the
/// live sync handler so pagination + live render identically. Returns None for
/// non-`m.room.message` events.
fn map_timeline_to_chat(
    raw: &Raw<matrix_sdk::ruma::events::AnySyncTimelineEvent>,
    room_id: &str,
    role: &str,
    me: Option<&str>,
) -> Option<ChatMessage> {
    let etype = raw.get_field::<String>("type").ok().flatten()?;
    if etype != "m.room.message" {
        return None;
    }
    let event_id = raw.get_field::<String>("event_id").ok().flatten().unwrap_or_default();
    let sender = raw.get_field::<String>("sender").ok().flatten().unwrap_or_default();
    let ts = raw.get_field::<u64>("origin_server_ts").ok().flatten().unwrap_or(0);
    let content = raw.get_field::<serde_json::Value>("content").ok().flatten()?;
    let msgtype = content.get("msgtype").and_then(|v| v.as_str()).unwrap_or("m.text");
    let body = content.get("body").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let mut kind = match msgtype {
        "m.image" => "image",
        "m.file" => "file",
        "m.audio" => "audio",
        "m.video" => "video",
        _ => "text",
    };
    let media_url = content
        .get("url")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            content
                .get("file")
                .and_then(|f| f.get("url"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        });
    let flex_json = if content.get("io.tokens2.tasks").is_some() {
        kind = "tasks";
        content.get("io.tokens2.tasks").map(|v| v.to_string())
    } else if content.get("io.tokens2.events").is_some() {
        kind = "events";
        content.get("io.tokens2.events").map(|v| v.to_string())
    } else if content.get("io.tokens2.jobs").is_some() {
        kind = "jobs";
        content.get("io.tokens2.jobs").map(|v| v.to_string())
    } else if content.get("io.tokens2.flex").is_some() {
        kind = "flex";
        content.get("io.tokens2.flex").map(|v| v.to_string())
    } else {
        None
    };
    let meta_json = content.get("io.tokens2.meta").map(|v| v.to_string());
    let reply_to = content
        .get("m.relates_to")
        .and_then(|r| r.get("m.in_reply_to"))
        .and_then(|i| i.get("event_id"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let is_me = me == Some(sender.as_str());
    Some(ChatMessage {
        room_id: room_id.to_string(),
        event_id,
        sender,
        body,
        timestamp_ms: ts,
        is_me,
        kind: kind.to_string(),
        reply_to_event_id: reply_to,
        reaction_target: None,
        reaction_key: None,
        media_url,
        media_mime: None,
        flex_json,
        meta_json,
        recv_role: role.to_string(),
    })
}

/// Post an `m.room.message` to `room_id` from the `role` client, carrying the
/// custom `io.tokens2.flex` / `io.tokens2.meta` keys (so flex cards + used/hint
/// survive). `text_plain()` would drop unknown keys, so we send raw content.
/// Returns the new event id.
pub fn send_text(
    role: String,
    room_id: String,
    body: String,
    flex_json: Option<String>,
    meta_json: Option<String>,
) -> Result<String, String> {
    block(async move {
        let room = room_by_id_role(&role, &room_id).await?;
        let mut content = serde_json::json!({ "msgtype": "m.text", "body": body });
        if let Some(f) = flex_json {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&f) {
                content["io.tokens2.flex"] = v;
            }
        }
        if let Some(m) = meta_json {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&m) {
                content["io.tokens2.meta"] = v;
            }
        }
        let resp = room
            .send_raw("m.room.message", content)
            .await
            .map_err(|e| e.to_string())?;
        Ok(resp.response.event_id.to_string())
    })
}

/// Send an arbitrary E2EE timeline event (`event_type` ≠ m.room.message) with
/// `content_json` as the content. matrix-sdk encrypts it in an E2EE room. It does
/// NOT render in the chat list (which filters to m.room.message). Used to store
/// private data (e.g. the agent's memory) encrypted — the homeserver can't read
/// it, unlike a plaintext state event. Returns the event id (store it in a
/// plaintext state-event pointer so it can be fetched back reliably).
pub fn send_custom_event(
    role: String,
    room_id: String,
    event_type: String,
    content_json: String,
) -> Result<String, String> {
    block(async move {
        let room = room_by_id_role(&role, &room_id).await?;
        let content: serde_json::Value =
            serde_json::from_str(&content_json).map_err(|e| e.to_string())?;
        let resp = room
            .send_raw(&event_type, content)
            .await
            .map_err(|e| e.to_string())?;
        Ok(resp.response.event_id.to_string())
    })
}

/// Fetch + decrypt a single timeline event by id, returning its `content` as a
/// JSON string (None if absent). Pairs with [`send_custom_event`]: read the
/// event id from a state-event pointer, then fetch the encrypted content here.
pub fn fetch_event_content(
    role: String,
    room_id: String,
    event_id: String,
) -> Result<Option<String>, String> {
    block(async move {
        let room = room_by_id_role(&role, &room_id).await?;
        let eid = matrix_sdk::ruma::EventId::parse(&event_id)
            .map_err(|_| "bad event id".to_string())?;
        let ev = room.event(&eid, None).await.map_err(|e| e.to_string())?;
        Ok(ev
            .raw()
            .get_field::<serde_json::Value>("content")
            .ok()
            .flatten()
            .map(|v| v.to_string()))
    })
}

/// Upload `bytes` as an attachment to `room_id` from the `role` client. In an
/// E2EE room matrix-sdk encrypts the upload automatically. Returns the event id.
pub fn send_attachment(
    role: String,
    room_id: String,
    filename: String,
    mime: String,
    bytes: Vec<u8>,
    caption: Option<String>,
) -> Result<String, String> {
    block(async move {
        let room = room_by_id_role(&role, &room_id).await?;
        let mime_t: mime::Mime = mime.parse().map_err(|_| "bad mime".to_string())?;
        // A caption becomes the message body (MSC2530) with the filename moved to
        // the `filename` field — so a voice note rides as one m.audio whose body
        // is its transcript (mic icon + text on every device, no 2nd bubble).
        let mut config = matrix_sdk::attachment::AttachmentConfig::new();
        if let Some(c) = caption {
            config = config.caption(Some(TextMessageEventContent::plain(c)));
        }
        let resp = room
            .send_attachment(filename, &mime_t, bytes, config)
            .await
            .map_err(|e| e.to_string())?;
        Ok(resp.event_id.to_string())
    })
}

/// Paginate `room_id` backward (newest→oldest) from the `role` client. Pass the
/// previous page's `end_token` as `from` to continue older. Returns mapped
/// message events; `messages` is in server (backward) order — Dart reverses.
pub fn room_messages(
    role: String,
    room_id: String,
    from: Option<String>,
    limit: u16,
) -> Result<TimelinePage, String> {
    block(async move {
        let room = room_by_id_role(&role, &room_id).await?;
        let client = client_for(&role).await?;
        let me = client.user_id().map(|u| u.to_string());
        let paginate = |from: Option<String>| {
            let room = room.clone();
            async move {
                let mut opts = matrix_sdk::room::MessagesOptions::backward();
                opts.from = from;
                opts.limit = limit.into();
                room.messages(opts).await.map_err(|e| e.to_string())
            }
        };
        let resp = paginate(from.clone()).await?;
        let mut messages = Vec::new();
        for ev in &resp.chunk {
            if let Some(cm) =
                map_timeline_to_chat(ev.raw(), &room_id, &role, me.as_deref())
            {
                messages.push(cm);
            }
        }
        let mut end = resp.end;
        // Pull missing megolm keys ONLY when the first page has events we can't
        // decrypt (chunk non-empty but mapped to nothing = all `m.room.encrypted`)
        // — recover() imports the backup decryption key but not every room key.
        // If the chunk is simply EMPTY, the timeline just hasn't synced yet; a key
        // download won't help and only adds a slow round-trip, so skip it (the
        // Dart retry + live sync fill it in).
        if from.is_none() && messages.is_empty() && !resp.chunk.is_empty() {
            if let Ok(rid) = RoomId::parse(&room_id) {
                let _ = client
                    .encryption()
                    .backups()
                    .download_room_keys_for_room(&rid)
                    .await;
                let resp2 = paginate(None).await?;
                for ev in &resp2.chunk {
                    if let Some(cm) =
                        map_timeline_to_chat(ev.raw(), &room_id, &role, me.as_deref())
                    {
                        messages.push(cm);
                    }
                }
                end = resp2.end;
            }
        }
        Ok(TimelinePage { end_token: end, messages })
    })
}

/// Whether a key backup exists on the homeserver for the user account. A fresh
/// device must RESTORE (not create) when true — creating would delete the
/// existing backup and lock other devices out. Hits the server (authoritative,
/// unlike the local recovery state which is empty before first sync).
pub fn backup_exists_on_server() -> Result<bool, String> {
    block(async move {
        let client = current_client().await?;
        client
            .encryption()
            .backups()
            .fetch_exists_on_server()
            .await
            .map_err(|e| e.to_string())
    })
}

/// Set the Matrix profile display name for the `role` client's account. The
/// localpart stays a hash (doesn't leak the email in the user_id); the
/// displayname makes the account identifiable in the admin UI.
pub fn set_display_name(role: String, name: String) -> Result<(), String> {
    block(async move {
        let client = client_for(&role).await?;
        client
            .account()
            .set_display_name(Some(&name))
            .await
            .map_err(|e| e.to_string())?;
        Ok(())
    })
}

/// Read the Matrix profile display name for `role`'s account (we set it to the
/// email), or None. Lets a token-restored session still recover the email.
pub fn get_display_name(role: String) -> Result<Option<String>, String> {
    block(async move {
        let client = client_for(&role).await?;
        client.account().get_display_name().await.map_err(|e| e.to_string())
    })
}

/// Get-or-create the encrypted DM between the user account and the ปิ่น account.
/// Acts on the USER client; `create_dm` auto-enables E2EE + invites pin. Returns
/// the room id. The pin client must accept the invite via its own sync.
pub fn get_or_create_pin_dm(pin_uid: String) -> Result<String, String> {
    block(async move {
        let client = current_client().await?;
        let uid = matrix_sdk::ruma::UserId::parse(&pin_uid)
            .map_err(|_| "bad pin user id".to_string())?;
        client
            .sync_once(SyncSettings::default())
            .await
            .map_err(|e| e.to_string())?;
        if let Some(room) = client.get_dm_room(&uid) {
            return Ok(room.room_id().to_string());
        }
        let room = client.create_dm(&uid).await.map_err(|e| e.to_string())?;
        Ok(room.room_id().to_string())
    })
}

/// Accept a pending invite to `room_id` on the `role` client (the pin client
/// joins the DM the user created).
pub fn join_room(role: String, room_id: String) -> Result<(), String> {
    block(async move {
        let client = client_for(&role).await?;
        // NB: no sync_once() here. The pin client's continuous sync loop is
        // already running by now (started in ensurePinSession), and a second
        // sync on the same client blocks on the live 30s long-poll → join took
        // ~30s. join_room_by_id hits POST /rooms/{id}/join directly; the running
        // sync loop picks up the membership afterwards.
        let rid = RoomId::parse(&room_id).map_err(|_| "bad room id".to_string())?;
        client.join_room_by_id(&rid).await.map_err(|e| e.to_string())?;
        Ok(())
    })
}

/// Write a room STATE event (e.g. `io.tokens2.prefs` / `.facts` / `.knowledge`)
/// from the `role` client, so persona/memory sync cross-device. Mirrors
/// [`get_prefs_state`].
pub fn set_state(
    role: String,
    room_id: String,
    event_type: String,
    content_json: String,
) -> Result<(), String> {
    block(async move {
        let room = room_by_id_role(&role, &room_id).await?;
        let value: serde_json::Value =
            serde_json::from_str(&content_json).map_err(|e| e.to_string())?;
        room
            .send_state_event_raw(&event_type, "", value)
            .await
            .map_err(|e| e.to_string())?;
        Ok(())
    })
}

/// Download (and decrypt, if E2EE) the media attached to a message event, write
/// it to a temp file, and return that path. Used to render images inline.
pub fn download_media(room_id: String, event_id: String) -> Result<String, String> {
    block(async move {
        let room = room_by_id(&room_id).await?;
        let client = current_client().await?;
        let eid = OwnedEventId::try_from(event_id.as_str())
            .map_err(|_| "bad event id".to_string())?;
        let ev = room.event(&eid, None).await.map_err(|e| e.to_string())?;
        let parsed: SyncRoomMessageEvent = ev
            .into_raw()
            .cast_unchecked::<SyncRoomMessageEvent>()
            .deserialize()
            .map_err(|e| e.to_string())?;
        let orig = parsed.as_original().ok_or("no content")?;
        let (source, ext) = match &orig.content.msgtype {
            MessageType::Image(c) => (c.source.clone(), "jpg"),
            MessageType::Video(c) => (c.source.clone(), "mp4"),
            MessageType::Audio(c) => (c.source.clone(), "bin"),
            MessageType::File(c) => (c.source.clone(), "bin"),
            _ => return Err("not media".to_string()),
        };
        let req = MediaRequestParameters { source, format: MediaFormat::File };
        let bytes = client
            .media()
            .get_media_content(&req, true)
            .await
            .map_err(|e| e.to_string())?;
        let safe: String = event_id
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
            .collect();
        let path = std::env::temp_dir().join(format!("pin_media_{safe}.{ext}"));
        std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
        Ok(path.to_string_lossy().to_string())
    })
}

/// Enable E2EE key backup + cross-signing + recovery, returning the recovery
/// key for the user to save. With this, a fresh device can restore keys (fixes
/// "can't decrypt on new login"). Called during onboarding.
#[derive(Clone)]
pub struct E2eeStatus {
    pub user_id: String,
    pub device_id: String,
    pub recovery: String,
    pub cross_signing_ready: bool,
    pub device_verified: bool,
}

/// Joined members of a room (user ids) — for the Settings debug section.
pub fn room_members(room_id: String) -> Result<Vec<String>, String> {
    block(async move {
        use matrix_sdk::RoomMemberships;
        let room = room_by_id(&room_id).await?;
        let members = room
            .members(RoomMemberships::JOIN)
            .await
            .map_err(|e| e.to_string())?;
        Ok(members.iter().map(|m| m.user_id().to_string()).collect())
    })
}

/// E2EE diagnostics for the Settings debug section.
pub fn e2ee_status() -> Result<E2eeStatus, String> {
    block(async move {
        use matrix_sdk::encryption::recovery::RecoveryState;
        let client = current_client().await?;
        let enc = client.encryption();
        let recovery = match enc.recovery().state() {
            RecoveryState::Enabled => "enabled",
            RecoveryState::Disabled => "disabled",
            RecoveryState::Incomplete => "incomplete",
            RecoveryState::Unknown => "unknown",
        }
        .to_string();
        let cross_signing_ready = match enc.cross_signing_status().await {
            Some(s) => s.is_complete(),
            None => false,
        };
        let device_verified = matches!(enc.get_own_device().await, Ok(Some(d)) if d.is_verified());
        Ok(E2eeStatus {
            user_id: client.user_id().map(|u| u.to_string()).unwrap_or_default(),
            device_id: client.device_id().map(|d| d.to_string()).unwrap_or_default(),
            recovery,
            cross_signing_ready,
            device_verified,
        })
    })
}

/// Whether key backup/recovery is already set up on the server for this account:
/// "enabled" (a recovery key exists → returning user should RESTORE),
/// "disabled" (first time → CREATE), "incomplete", or "unknown".
pub fn recovery_state() -> Result<String, String> {
    block(async move {
        use matrix_sdk::encryption::recovery::RecoveryState;
        let client = current_client().await?;
        let s = match client.encryption().recovery().state() {
            RecoveryState::Enabled => "enabled",
            RecoveryState::Disabled => "disabled",
            RecoveryState::Incomplete => "incomplete",
            RecoveryState::Unknown => "unknown",
        };
        Ok(s.to_string())
    })
}

pub fn enable_recovery() -> Result<String, String> {
    block(async move {
        let client = current_client().await?;
        client
            .encryption()
            .recovery()
            .enable()
            .await
            .map_err(|e| e.to_string())
    })
}

/// Start fresh when the user lost their recovery key: delete the stale backup
/// on the server, then create a new backup + recovery key.
///
/// We can't use `recovery().disable()` here: when the device holds no usable
/// local backup key (the lost-key case), `backups().disable()` returns
/// "backups are not enabled" and never reaches the server-side delete. And
/// `enable()` on its own returns `BackupExistsOnServer` because the old backup
/// is still there. So we delete the server backup version directly over the CS
/// API (no local key needed), which lets `enable()` create a fresh one. Does
/// not touch cross-signing, so no UIA/password is needed.
pub fn reset_recovery_key() -> Result<String, String> {
    block(async move {
        use matrix_sdk::ruma::api::client::backup::{
            delete_backup_version, get_latest_backup_info,
        };
        let client = current_client().await?;

        // Delete whatever backup version currently exists on the server. Ignore
        // errors: a missing backup (M_NOT_FOUND) just means there's nothing to
        // clear, and `enable()` below will create one regardless.
        if let Ok(info) = client.send(get_latest_backup_info::v3::Request::new()).await {
            let _ = client
                .send(delete_backup_version::v3::Request::new(info.version))
                .await;
        }

        client
            .encryption()
            .recovery()
            .enable()
            .await
            .map_err(|e| e.to_string())
    })
}

/// Fully (re)bootstrap E2EE: set up cross-signing (needs the account password
/// for UIA) + key backup + recovery, and return the new recovery key. Fixes a
/// "cross-signing: not ready / recovery: incomplete" state.
pub fn reset_recovery(password: String) -> Result<String, String> {
    block(async move {
        use matrix_sdk::ruma::api::client::backup::{
            delete_backup_version, get_latest_backup_info,
        };
        use matrix_sdk::ruma::api::client::uiaa::{
            AuthData, MatrixUserIdentifier, Password, UserIdentifier,
        };
        let client = current_client().await?;
        let user = client.user_id().ok_or("not logged in")?.localpart().to_string();
        let auth = AuthData::Password(Password::new(
            UserIdentifier::Matrix(MatrixUserIdentifier::new(user)),
            password,
        ));
        client
            .encryption()
            .bootstrap_cross_signing(Some(auth))
            .await
            .map_err(|e| e.to_string())?;
        // Delete any stale server backup first, otherwise enable() returns
        // "A backup already exists on the homeserver ... does not allow to
        // overwrite it" (the device can't connect to the old, lost-key backup).
        if let Ok(info) = client.send(get_latest_backup_info::v3::Request::new()).await {
            let _ = client
                .send(delete_backup_version::v3::Request::new(info.version))
                .await;
        }
        client
            .encryption()
            .recovery()
            .enable()
            .await
            .map_err(|e| e.to_string())
    })
}

/// Restore E2EE keys on this device using a previously saved recovery key.
pub fn recover_with_key(recovery_key: String) -> Result<(), String> {
    block(async move {
        let client = current_client().await?;
        client
            .encryption()
            .recovery()
            .recover(&recovery_key)
            .await
            .map_err(|e| e.to_string())?;
        Ok(())
    })
}

/// Enable (or reset) key backup + recovery for `role`'s account and return the
/// new recovery key. Deletes any stale server backup first (idempotent across
/// re-runs / lost-key state), then enables. Role-aware sibling of
/// [`reset_recovery_key`] — used to set up recovery on BOTH the user and ปิ่น
/// accounts so one QR can carry both keys.
///
/// Also bootstraps CROSS-SIGNING (not just key backup) so the account has a
/// COMPLETE E2EE identity — backup-only leaves recovery "Incomplete" and the
/// account's keys won't reliably restore/share across devices (the SSO + ปิ่น
/// "sync is broken" symptom). No password/UIA is needed on the FIRST upload:
/// the homeserver (tuwunel) skips UIA when the account has no existing
/// cross-signing keys (MSC3967). This is the passwordless path —
/// `reset_recovery` covers password users via a UIA stage, which SSO/companion
/// accounts can't satisfy.
pub fn ensure_recovery_for(role: String) -> Result<String, String> {
    block(async move {
        use matrix_sdk::ruma::api::client::backup::{
            delete_backup_version, get_latest_backup_info,
        };
        let client = client_for(&role).await?;

        // Best-effort: succeeds with no UIA on first setup (MSC3967). On a re-run
        // the keys already exist → the server demands UIA and this errors, which
        // we ignore and fall through to backup-only (the prior behaviour). So it
        // upgrades fresh accounts to full cross-signing without regressing reset.
        let _ = client.encryption().bootstrap_cross_signing(None).await;

        let mut attempts = 0;
        let mut last_err = String::new();
        
        while attempts < 5 {
            if let Ok(info) = client.send(get_latest_backup_info::v3::Request::new()).await {
                let _ = client
                    .send(delete_backup_version::v3::Request::new(info.version))
                    .await;
            }
            
            match client.encryption().recovery().enable().await {
                Ok(key) => return Ok(key),
                Err(e) => {
                    last_err = e.to_string();
                    attempts += 1;
                    tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                }
            }
        }
        
        Err(format!("Failed after 5 attempts: {}", last_err))
    })
}

pub fn recover_with_key_for(role: String, recovery_key: String) -> Result<(), String> {
    block(async move {
        let client = client_for(&role).await?;
        
        let mut attempts = 0;
        let mut last_err = String::new();
        
        while attempts < 5 {
            match client.encryption().recovery().recover(&recovery_key).await {
                Ok(_) => return Ok(()),
                Err(e) => {
                    last_err = e.to_string();
                    attempts += 1;
                    tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                }
            }
        }
        
        Err(format!("Failed after 5 attempts: {}", last_err))
    })
}

/// Read a secret from a role's E2EE secret storage (4S) — an account-data value
/// encrypted under the recovery key. Returns None if the secret isn't stored.
/// Used for the STABLE companion seed: storing it (vs deriving it from the
/// recovery key) means a recovery-key rotation just re-encrypts the same value,
/// so the companion password never changes. `recovery_key` is the user's
/// recovery key (the 4S secret-storage key).
pub fn secret_get(
    role: String,
    recovery_key: String,
    name: String,
) -> Result<Option<String>, String> {
    block(async move {
        use matrix_sdk::ruma::events::secret::request::SecretName;
        let client = client_for(&role).await?;
        
        // Wait for the first sync so Account Data (secret storage) is loaded
        // before attempting to read from it.
        client
            .sync_once(matrix_sdk::config::SyncSettings::default())
            .await
            .map_err(|e| e.to_string())?;

        let store = client
            .encryption()
            .secret_storage()
            .open_secret_store(&recovery_key)
            .await
            .map_err(|e| e.to_string())?;
        store
            .get_secret(SecretName::from(name))
            .await
            .map_err(|e| e.to_string())
    })
}

/// Store a secret into a role's E2EE secret storage (encrypted under the
/// recovery key). See [`secret_get`].
pub fn secret_put(
    role: String,
    recovery_key: String,
    name: String,
    value: String,
) -> Result<(), String> {
    block(async move {
        use matrix_sdk::ruma::events::secret::request::SecretName;
        let client = client_for(&role).await?;
        
        // Wait for the sync loop to fetch the newly created Account Data.
        // Synapse workers might have a replication delay, so a single sync_once
        // might not be enough. We retry up to 5 times.
        let mut attempts = 0;
        let store = loop {
            client
                .sync_once(matrix_sdk::config::SyncSettings::default())
                .await
                .map_err(|e| e.to_string())?;

            match client
                .encryption()
                .secret_storage()
                .open_secret_store(&recovery_key)
                .await
            {
                Ok(s) => break s,
                Err(e) => {
                    attempts += 1;
                    if attempts >= 5 {
                        return Err(format!("Secret store not ready: {}", e));
                    }
                    tokio::time::sleep(tokio::time::Duration::from_millis(1000)).await;
                }
            }
        };
        store
            .put_secret(SecretName::from(name), &value)
            .await
            .map_err(|e| e.to_string())
    })
}

/// Log out a single role's session ("user" | "pin") and wipe its store. Dart
/// calls this once per role on full logout.
pub fn logout(role: String, db_path: String) -> Result<(), String> {
    block(async move {
        // Stop the background sync FIRST so its Client clone is dropped and the
        // store handle released — otherwise it keeps syncing this account and
        // re-populates the store after we wipe it.
        stop_sync(&role);
        let removed = CLIENTS.write().await.remove(&role);
        if let Some(client) = removed {
            let _ = client.matrix_auth().logout().await;
        }
        // Only tear the shared message sink down once every session is gone.
        if CLIENTS.read().await.is_empty() {
            *MSG_SINK.lock().unwrap() = None;
        }
        // Wipe the on-disk store so the next account can't read this account's
        // cached rooms/keys.
        let _ = std::fs::remove_dir_all(&db_path);
        Ok(())
    })
}

#[frb(sync)]
pub fn is_logged_in() -> bool {
    block(async { CLIENTS.read().await.contains_key(USER_ROLE) })
}
