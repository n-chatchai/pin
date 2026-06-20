//! Passive Matrix HTTP metadata capture.
//!
//! This is a **read-only observer** of matrix-rust-sdk's own `tracing` spans. It
//! does NOT touch the network, reqwest, TLS, or routing in any way — it simply
//! installs a `tracing_subscriber::Layer` that watches the SDK's
//! `matrix_sdk::http_client` "send" span and forwards the request method, URL,
//! status and elapsed time to Dart as JSON lines.
//!
//! Worst case if anything fails (another global subscriber already installed,
//! a field missing, etc.): **no capture**. It must never affect login/sync, so
//! every failure path falls back to a silent no-op and `Ok(())` to the caller.

use crate::frb_generated::StreamSink;
use once_cell::sync::Lazy;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Instant;
use tracing::field::{Field, Visit};
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::Layer;

/// Dart sink for captured HTTP metadata JSON lines. Set by
/// [`start_matrix_trace`]; swapped on every call so a re-init just retargets it.
static TRACE_SINK: Lazy<Mutex<Option<StreamSink<String>>>> = Lazy::new(|| Mutex::new(None));

/// Whether the global subscriber has been installed. We install exactly once;
/// later calls only swap the sink (the global default cannot be replaced).
static TRACE_INSTALLED: AtomicBool = AtomicBool::new(false);

/// The SDK span we observe.
const HTTP_TARGET: &str = "matrix_sdk::http_client";
const HTTP_SPAN_NAME: &str = "send";

/// Begin passive capture of matrix-sdk HTTP metadata, streaming one JSON line
/// per request to Dart. Safe to call multiple times: the sink is replaced and
/// the global subscriber is installed at most once. Never errors hard — if the
/// subscriber can't be installed (some other global subscriber is already set)
/// capture simply won't happen and `Ok(())` is still returned.
pub fn start_matrix_trace(sink: StreamSink<String>) -> Result<(), String> {
    // Store / replace the sink first so even a no-op install retargets output.
    *TRACE_SINK.lock().unwrap() = Some(sink);

    // Already installed: the layer is running, we just swapped the sink.
    if TRACE_INSTALLED.load(Ordering::SeqCst) {
        return Ok(());
    }

    // Try to install the global subscriber. If another global subscriber is
    // already set, `try_init` returns Err — fail soft (no capture), never break
    // the app.
    let installed = tracing_subscriber::registry()
        .with(HttpLayer)
        .try_init()
        .is_ok();

    if installed {
        TRACE_INSTALLED.store(true, Ordering::SeqCst);
    }

    Ok(())
}

/// Per-span data captured for a single `matrix_sdk::http_client` "send" span.
/// `started` is captured in `on_new_span` and is the reliable source of elapsed
/// time — we never parse the SDK's own `request_duration` field.
struct HttpCall {
    method: Option<String>,
    uri: Option<String>,
    status: Option<String>,
    started: Instant,
}

/// A `tracing` layer that watches only the SDK's HTTP "send" span and emits a
/// JSON metadata line on span close. Purely observational.
struct HttpLayer;

impl<S> Layer<S> for HttpLayer
where
    S: tracing::Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_new_span(
        &self,
        attrs: &tracing::span::Attributes<'_>,
        id: &tracing::span::Id,
        ctx: Context<'_, S>,
    ) {
        let meta = attrs.metadata();
        if meta.target() != HTTP_TARGET || meta.name() != HTTP_SPAN_NAME {
            return;
        }
        if let Some(span) = ctx.span(id) {
            let mut call = HttpCall {
                method: None,
                uri: None,
                status: None,
                started: Instant::now(),
            };
            // Capture any fields already present at span creation.
            attrs.record(&mut FieldVisitor(&mut call));
            span.extensions_mut().insert(call);
        }
    }

    fn on_record(
        &self,
        id: &tracing::span::Id,
        values: &tracing::span::Record<'_>,
        ctx: Context<'_, S>,
    ) {
        if let Some(span) = ctx.span(id) {
            let mut ext = span.extensions_mut();
            if let Some(call) = ext.get_mut::<HttpCall>() {
                // method/uri/status are recorded after creation via span.record(..).
                values.record(&mut FieldVisitor(call));
            }
        }
    }

    fn on_close(&self, id: tracing::span::Id, ctx: Context<'_, S>) {
        if let Some(span) = ctx.span(&id) {
            let ext = span.extensions();
            if let Some(call) = ext.get::<HttpCall>() {
                if call.method.is_some() && call.uri.is_some() {
                    let ms = call.started.elapsed().as_millis() as u64;
                    let line = serde_json::json!({
                        "method": call.method.as_deref().unwrap_or(""),
                        "url": call.uri.as_deref().unwrap_or(""),
                        "status": call.status.as_deref().unwrap_or(""),
                        "ms": ms,
                    })
                    .to_string();
                    if let Some(s) = TRACE_SINK.lock().unwrap().as_ref() {
                        let _ = s.add(line);
                    }
                }
            }
        }
    }
}

/// Visits span fields and copies method/uri/status into the [`HttpCall`].
struct FieldVisitor<'a>(&'a mut HttpCall);

impl<'a> Visit for FieldVisitor<'a> {
    fn record_str(&mut self, field: &Field, value: &str) {
        match field.name() {
            "uri" => self.0.uri = Some(value.to_string()),
            "method" => self.0.method = Some(value.to_string()),
            "status" => self.0.status = Some(value.to_string()),
            _ => {}
        }
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        if field.name() == "status" {
            self.0.status = Some(value.to_string());
        }
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        if field.name() == "status" {
            self.0.status = Some(value.to_string());
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        // Fallback: method arrives as debug(&Method) -> e.g. GET; status may
        // arrive as debug(&StatusCode) -> e.g. 200. Trim any surrounding quotes.
        let s = format!("{value:?}");
        let trimmed = s.trim_matches('"').to_string();
        match field.name() {
            "method" => self.0.method = Some(trimmed),
            "uri" => self.0.uri = Some(trimmed),
            "status" => self.0.status = Some(trimmed),
            _ => {}
        }
    }
}
