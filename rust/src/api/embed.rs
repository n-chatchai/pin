//! On-device text embeddings (multilingual, Thai-capable) exposed to Flutter via
//! flutter_rust_bridge. Runs a sentence-transformer (e.g. multilingual-e5-small)
//! through ONNX Runtime entirely on the phone — the plaintext NEVER leaves the
//! device, so it stays inside the E2EE boundary (unlike the old proxy /embed).
//!
//! Dart loads the bundled model + tokenizer once via [embed_init] (passing the
//! asset bytes, since a Flutter asset has no real filesystem path on mobile),
//! then calls [embed_text] per string. Output is mean-pooled + L2-normalized, so
//! cosine similarity == dot product on the Dart side.
//!
//! ponytail: e5-small int8, mean-pool + L2-norm, linear cosine scan on the Dart
//! side. Swap the model file only if Thai recall is weak; add an ANN index only
//! past ~10k items.

use std::sync::Mutex;

use anyhow::{anyhow, Context, Result};
use once_cell::sync::OnceCell;
use ort::session::Session;
use ort::value::Value;
use tokenizers::Tokenizer;

struct Embedder {
    session: Session,
    tokenizer: Tokenizer,
}

static EMBEDDER: OnceCell<Mutex<Embedder>> = OnceCell::new();

/// Load the ONNX model + tokenizer from in-memory bytes. Idempotent: a second
/// call with an embedder already loaded is a no-op (returns Ok). [model] is the
/// `.onnx` file bytes; [tokenizer_json] is the `tokenizer.json` text.
pub fn embed_init(model: Vec<u8>, tokenizer_json: String) -> Result<()> {
    if EMBEDDER.get().is_some() {
        return Ok(());
    }
    ort::init().commit().ok(); // initialize statically linked ORT
    let tokenizer = Tokenizer::from_bytes(tokenizer_json.as_bytes())
        .map_err(|e| anyhow!("tokenizer load: {e}"))?;
    let session = Session::builder()
        .context("ort session builder")?
        .commit_from_memory(&model)
        .context("ort load model")?;
    EMBEDDER
        .set(Mutex::new(Embedder { session, tokenizer }))
        .map_err(|_| anyhow!("embedder already initialized"))?;
    Ok(())
}

/// ONNX Runtime is reached differently per platform but neither needs an
/// explicit path here: Android `load-dynamic` dlopens `libonnxruntime.so` by
/// soname (jniLibs is on the loader path); iOS links the static framework, so
/// the symbols are present at startup. embed_init just builds the session.
///
/// True once a model is loaded — lets Dart skip embedding (recency fallback)
/// until the model is provisioned.
#[flutter_rust_bridge::frb(sync)]
pub fn embed_ready() -> bool {
    EMBEDDER.get().is_some()
}

/// Embed one string → a mean-pooled, L2-normalized vector. The caller adds any
/// model-specific prefix (e5 wants "query: " / "passage: ") before calling.
/// Errors if [embed_init] hasn't run.
pub fn embed_text(text: String) -> Result<Vec<f32>> {
    let cell = EMBEDDER.get().context("embedder not initialized")?;
    let mut guard = cell.lock().map_err(|_| anyhow!("embedder lock poisoned"))?;
    let Embedder { session, tokenizer } = &mut *guard;

    let enc = tokenizer
        .encode(text, true)
        .map_err(|e| anyhow!("tokenize: {e}"))?;
    let ids: Vec<i64> = enc.get_ids().iter().map(|&x| x as i64).collect();
    let mask: Vec<i64> = enc.get_attention_mask().iter().map(|&x| x as i64).collect();
    let len = ids.len();
    if len == 0 {
        return Err(anyhow!("empty token sequence"));
    }
    // BERT-family models (e5-small/MiniLM) take token_type_ids; RoBERTa-family
    // (xlm-roberta, e5-base/large) do NOT — feed it only when the model declares
    // it, so swapping the model file can't break inference with an extra input.
    let wants_token_type = session
        .inputs
        .iter()
        .any(|i| i.name == "token_type_ids");

    let ids_t = Value::from_array(([1usize, len], ids))?;
    let mask_t = Value::from_array(([1usize, len], mask.clone()))?;

    let mut feeds = ort::inputs![
        "input_ids" => ids_t,
        "attention_mask" => mask_t,
    ];
    if wants_token_type {
        let tt_t = Value::from_array(([1usize, len], vec![0i64; len]))?;
        feeds.push(("token_type_ids".into(), tt_t.into()));
    }

    let outputs = session.run(feeds)?;

    // First output is last_hidden_state: shape [1, seq_len, hidden].
    let (shape, data) = outputs[0].try_extract_tensor::<f32>()?;
    let hidden = *shape.last().context("no hidden dim")? as usize;
    if hidden == 0 {
        return Err(anyhow!("zero hidden dim"));
    }

    // Mean-pool over tokens, weighted by the attention mask (drop padding).
    let mut pooled = vec![0f32; hidden];
    let mut count = 0f32;
    for t in 0..len {
        if mask[t] == 0 {
            continue;
        }
        count += 1.0;
        let base = t * hidden;
        for h in 0..hidden {
            pooled[h] += data[base + h];
        }
    }
    let count = count.max(1.0);
    for h in 0..hidden {
        pooled[h] /= count;
    }
    // L2-normalize so cosine == dot on the Dart side.
    let norm = pooled.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-12);
    for h in 0..hidden {
        pooled[h] /= norm;
    }
    Ok(pooled)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dot(a: &[f32], b: &[f32]) -> f32 {
        a.iter().zip(b).map(|(p, q)| p * q).sum()
    }

    // End-to-end check on the bundled model (host target). Proves the model's
    // I/O names match embed.rs and that Thai is embedded semantically: a related
    // sentence must score higher than an unrelated one. Run: `cargo test`.
    #[test]
    fn embeds_thai_semantically() {
        let model = std::fs::read("../assets/models/embed.onnx")
            .expect("drop assets/models/embed.onnx first (see README)");
        let tok = std::fs::read_to_string("../assets/models/tokenizer.json").unwrap();
        embed_init(model, tok).unwrap();

        let q = embed_text("query: แมวชอบกินปลา".into()).unwrap();
        let related = embed_text("passage: แมวกินปลาเป็นอาหารโปรด".into()).unwrap();
        let unrelated = embed_text("passage: รถยนต์วิ่งบนทางด่วน".into()).unwrap();

        assert_eq!(q.len(), 384, "expected 384-dim, got {}", q.len());
        let sim = dot(&q, &related);
        let dif = dot(&q, &unrelated);
        assert!(sim > dif, "related {sim} must beat unrelated {dif}");
        assert!(sim > 0.75, "related similarity too low: {sim}");
    }
}
