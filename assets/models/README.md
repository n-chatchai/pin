# On-device embedding model

`lib/agent/embedder.dart` loads two files from this dir at runtime and runs them
through ONNX Runtime in Rust (`rust/src/api/embed.rs`) — entirely on the phone, so
the plaintext never leaves the E2EE boundary.

## Already provisioned

- `embed.onnx` — multilingual-e5-small, int8 quantized, 384-dim (~112 MB)
- `tokenizer.json` — its HuggingFace fast-tokenizer (~17 MB)

Both are fetched from [`Xenova/multilingual-e5-small`](https://huggingface.co/Xenova/multilingual-e5-small)
and bundled into the app. Verified end-to-end on host by
`cargo test -p rust_lib_pin embeds_thai_semantically` (Thai related-pair beats
unrelated-pair). To re-fetch:

```bash
base=https://huggingface.co/Xenova/multilingual-e5-small/resolve/main
curl -L $base/onnx/model_quantized.onnx -o assets/models/embed.onnx
curl -L $base/tokenizer.json            -o assets/models/tokenizer.json
```

The model is multilingual (Thai-capable). Swapping it is just replacing these two
files — `embedder.dart` and `embed.rs` are model-agnostic (they feed
`token_type_ids` only when the model declares it, so BERT and RoBERTa families
both work).

## ONNX Runtime native lib — automatic

`rust/Cargo.toml` uses `ort` with `download-binaries`: cargo fetches a prebuilt
ONNX Runtime for each build target and links it statically. There is **nothing to
bundle or sign by hand** — `flutter build` compiles the Rust crate per target and
ort pulls the right runtime.

Caveat: verified on the host (macOS arm64). The iOS/Android arm64 prebuilts are
downloaded at build time by `pyke` — if a target ever lacks one, the build errors
clearly; fall back to `ort` `load-dynamic` (bundle `libonnxruntime` yourself) or
`candle` (pure-Rust, no native lib). `embed.rs`'s FFI surface stays identical.

## Repo note

These are large binaries (~129 MB total). Prefer git-lfs for `*.onnx` /
`tokenizer.json` so the git history doesn't bloat, or drop them in at CI/build time.
