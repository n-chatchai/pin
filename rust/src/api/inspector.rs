//! DEBUG-only in-process HTTP forwarding proxy for inspecting Matrix traffic.
//!
//! matrix-rust-sdk does all its Matrix HTTP over its own (TLS) reqwest client,
//! invisible to a Dart-side inspector. To capture full request/response bodies
//! we route matrix-sdk through this LOCAL plaintext proxy: matrix-sdk talks
//! `http://127.0.0.1:PORT` (plaintext → we log it), and this proxy forwards each
//! request to the real homeserver over HTTPS, logging the request + response.
//!
//! Production safety: this is inert unless [`start_matrix_inspector`] is called.
//! When it is never called, [`INSPECTOR_PORT`] stays `None` and `build_client`
//! (in `matrix.rs`) routes straight to the real homeserver, byte-identical to
//! before.

use crate::frb_generated::StreamSink;
use http_body_util::BodyExt;
use hyper::body::Bytes;
use once_cell::sync::Lazy;
use std::convert::Infallible;
use std::sync::Mutex;

use super::matrix::RT;

/// Sink for one-JSON-line-per-call inspector logs, set by
/// [`start_matrix_inspector`]. Each line is `{method,url,status,ms,req,resp}`.
pub(crate) static INSPECTOR_SINK: Lazy<Mutex<Option<StreamSink<String>>>> =
    Lazy::new(|| Mutex::new(None));

/// The port the in-process proxy bound to (`127.0.0.1:PORT`). `Some` once the
/// inspector has started; `build_client` checks this to decide whether to route
/// matrix-sdk through the proxy. Stays `None` in production.
pub(crate) static INSPECTOR_PORT: Lazy<Mutex<Option<u16>>> = Lazy::new(|| Mutex::new(None));

/// The real homeserver base URL (e.g. `https://pin-chat.tokens2.io:6167`) that
/// the proxy forwards to. Set by `build_client` whenever the inspector is live,
/// so we always forward to the homeserver the app is actually configured for.
pub(crate) static INSPECTOR_UPSTREAM: Lazy<Mutex<Option<String>>> =
    Lazy::new(|| Mutex::new(None));

/// Forwarding HTTP client (real TLS to the homeserver). 65s timeout so the
/// `/sync` long-poll (server holds up to ~30-60s) completes rather than erroring
/// right as the server is about to respond. Same `rustls` TLS backend matrix-sdk
/// uses, so no second TLS stack is pulled in.
static FORWARD_CLIENT: Lazy<reqwest::Client> = Lazy::new(|| {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(65))
        // DEBUG-only inspector forwarding to the user's own homeserver over the
        // loopback: skip cert verification so this separate client never fails
        // the handshake (matrix-sdk uses rustls-platform-verifier; ours may not
        // pick up the same trust anchors). Not a security boundary — the real
        // matrix-sdk connection still verifies normally in production.
        .danger_accept_invalid_certs(true)
        .build()
        .expect("forwarding reqwest client")
});

/// Max chars of each body we log before truncating (keeps lines bounded).
const MAX_BODY_LOG: usize = 8000;

/// Emit one inspector log line to Dart, if a sink is registered.
fn emit_log(line: String) {
    if let Some(sink) = INSPECTOR_SINK.lock().unwrap().as_ref() {
        let _ = sink.add(line);
    }
}

/// Render a body's bytes for the log: UTF-8 text (truncated) when it decodes,
/// otherwise a `[binary N bytes]` placeholder.
fn body_for_log(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(s) => {
            if s.chars().count() > MAX_BODY_LOG {
                let truncated: String = s.chars().take(MAX_BODY_LOG).collect();
                format!("{truncated}…(truncated)")
            } else {
                s.to_string()
            }
        }
        Err(_) => format!("[binary {} bytes]", bytes.len()),
    }
}

type ProxyResponse = hyper::Response<http_body_util::Full<Bytes>>;

fn plain_response(status: u16, body: &str) -> ProxyResponse {
    hyper::Response::builder()
        .status(status)
        .body(http_body_util::Full::new(Bytes::from(body.to_owned())))
        .expect("static response builds")
}

/// Handle one proxied request: collect it, forward to the upstream homeserver
/// over HTTPS, log req+resp, and return the upstream response to matrix-sdk.
/// Never panics; on any error it emits a status-0 log line and returns 502.
async fn proxy_request(
    req: hyper::Request<hyper::body::Incoming>,
) -> Result<ProxyResponse, Infallible> {
    let started = std::time::Instant::now();

    let method = req.method().clone();
    let path_and_query = req
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str().to_string())
        .unwrap_or_else(|| req.uri().path().to_string());
    let req_headers = req.headers().clone();

    // Read the full incoming request body.
    let req_body: Bytes = match req.into_body().collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(e) => {
            emit_log(error_line(&method, "", 0, started, &format!("read request body: {e}")));
            return Ok(plain_response(502, "inspector: failed to read request body"));
        }
    };

    // Resolve the upstream homeserver base.
    let upstream = match INSPECTOR_UPSTREAM.lock().unwrap().clone() {
        Some(u) => u,
        None => {
            emit_log(error_line(&method, "", 0, started, "no upstream set"));
            return Ok(plain_response(502, "inspector: upstream not set"));
        }
    };
    let trimmed = upstream.trim_end_matches('/');
    let url = format!("{trimmed}{path_and_query}");

    // Build the forwarded request: same method + body, all headers except host
    // (reqwest sets host from the upstream URL).
    let r_method = match reqwest::Method::from_bytes(method.as_str().as_bytes()) {
        Ok(m) => m,
        Err(e) => {
            emit_log(error_line(&method, &url, 0, started, &format!("bad method: {e}")));
            return Ok(plain_response(502, "inspector: bad method"));
        }
    };
    let mut fwd = FORWARD_CLIENT.request(r_method, &url);
    for (name, value) in req_headers.iter() {
        if name.as_str().eq_ignore_ascii_case("host") {
            continue;
        }
        fwd = fwd.header(name.as_str(), value.as_bytes());
    }
    fwd = fwd.body(req_body.clone());

    // Forward and await the full upstream response.
    let resp = match fwd.send().await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("inspector forward failed: {url}: {e}");
            emit_log(error_line(&method, &url, 0, started, &format!("forward: {e}")));
            return Ok(plain_response(502, &format!("inspector: upstream request failed: {e}")));
        }
    };

    let status = resp.status();
    let resp_headers = resp.headers().clone();
    let resp_body: Bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(e) => {
            emit_log(error_line(&method, &url, status.as_u16(), started, &format!("read response body: {e}")));
            return Ok(plain_response(502, "inspector: failed to read upstream body"));
        }
    };

    // Log one JSON line.
    let ms = started.elapsed().as_millis() as u64;
    let line = serde_json::json!({
        "method": method.as_str(),
        "url": url,
        "status": status.as_u16(),
        "ms": ms,
        "req": body_for_log(&req_body),
        "resp": body_for_log(&resp_body),
    })
    .to_string();
    emit_log(line);

    // Build the client-facing response: upstream status + headers + body.
    let mut builder = hyper::Response::builder().status(status.as_u16());
    for (name, value) in resp_headers.iter() {
        // Hop-by-hop / framing headers would conflict with the body we re-frame.
        let n = name.as_str();
        if n.eq_ignore_ascii_case("transfer-encoding")
            || n.eq_ignore_ascii_case("content-length")
            || n.eq_ignore_ascii_case("connection")
        {
            continue;
        }
        builder = builder.header(name.as_str(), value.as_bytes());
    }
    let out = builder
        .body(http_body_util::Full::new(resp_body))
        .unwrap_or_else(|_| plain_response(502, "inspector: failed to build response"));
    Ok(out)
}

/// Build a status-0 (or upstream-status) error log line carrying the error.
fn error_line(
    method: &hyper::Method,
    url: &str,
    status: u16,
    started: std::time::Instant,
    err: &str,
) -> String {
    serde_json::json!({
        "method": method.as_str(),
        "url": url,
        "status": status,
        "ms": started.elapsed().as_millis() as u64,
        "req": "",
        "resp": "",
        "error": err,
    })
    .to_string()
}

/// Start (or re-attach) the in-process inspector proxy. Binds `127.0.0.1:0`,
/// spawns an accept loop on the matrix runtime, stores the sink + port, and
/// returns the assigned port. Idempotent: if a port is already bound, this just
/// replaces the sink and returns that port (the existing accept loop keeps
/// serving). DEBUG-only — calling this is what makes `build_client` route
/// matrix-sdk through the proxy.
pub fn start_matrix_inspector(sink: StreamSink<String>) -> Result<u16, String> {
    // Already running: swap the sink, keep the loop + port.
    if let Some(port) = *INSPECTOR_PORT.lock().unwrap() {
        *INSPECTOR_SINK.lock().unwrap() = Some(sink);
        return Ok(port);
    }

    // Bind synchronously on the runtime so we can return the real port.
    let listener = RT
        .block_on(async { tokio::net::TcpListener::bind("127.0.0.1:0").await })
        .map_err(|e| format!("bind inspector: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("local_addr: {e}"))?
        .port();

    *INSPECTOR_SINK.lock().unwrap() = Some(sink);
    *INSPECTOR_PORT.lock().unwrap() = Some(port);

    // Accept loop: one spawned task per connection, served by hyper-util's
    // auto/http1 server with our forwarding service fn.
    RT.spawn(async move {
        loop {
            let (stream, _peer) = match listener.accept().await {
                Ok(pair) => pair,
                Err(e) => {
                    eprintln!("inspector accept error: {e}");
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    continue;
                }
            };
            let io = hyper_util::rt::TokioIo::new(stream);
            RT.spawn(async move {
                let service = hyper::service::service_fn(proxy_request);
                // matrix-sdk talks plaintext HTTP/1.1 to the loopback, so serve
                // http1 directly. (The auto builder needs hyper's http2 feature,
                // which we don't enable — using it dropped connections with an
                // empty reply.) Keep-alive on so matrix-sdk can reuse the socket.
                if let Err(e) = hyper::server::conn::http1::Builder::new()
                    .serve_connection(io, service)
                    .await
                {
                    eprintln!("inspector connection error: {e}");
                }
            });
        }
    });

    Ok(port)
}
