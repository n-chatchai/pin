# Pending Issues & Architecture Review: On-Device Companion Bot

This document outlines the current state and pending issues of the "2 Matrix Users on 1 Device" (Human + Companion Bot) architecture.

## 1. Architecture Overview
- **True On-Device E2EE:** The device runs two concurrent Matrix sessions via Rust (`role: "user"` and `role: "pin"`). This provides end-to-end encryption out of the box without requiring the server to decrypt messages.
- **Single Source of Truth:** Dart UI selectively filters `recvRole == 'user'` for the chat history, ensuring messages aren't duplicated in the UI while the bot session is maintained purely for sending replies and managing keys.
- **Stateless Proxy:** the `backend-rust` service acts only as a router to the LLM (Gemini/OpenRouter), receiving Prompts + History securely without persisting chat state.

## 2. Resolved Issues

### 2.1 Companion Bot Credential Synchronization
**Status:** RESOLVED
**Solution:** The companion bot's password is now synchronized with the primary user's password (`_userPassword`). When the user logs in on a new device, the app uses their password to automatically authenticate the companion bot. This eliminates the need to store the bot's credentials in Matrix Account Data, making cross-device login seamless.
*Note: If the user changes their password on the Matrix server, the companion's password will diverge. The app currently falls back to cached access tokens, but on a fresh install after a password change, the bot login will fail.*

### 2.2 Cross-Device Recovery Missing Bot Key (The "เครื่องที่สองกู้ไม่ได้" Issue)
**Status:** RESOLVED
**Problem:** The recovery QR code successfully packed both the user's (`u`) and the bot's (`p`) keys. However, when the second device scanned the QR code, `restoreFromRecoveryQr` called `ensurePinSession()` (which logs the bot in and starts its `/sync` loop) and then *immediately* called `rust.recoverWithKeyFor(role: 'pin')`. Because the bot's initial `/sync` had not yet completed, its local crypto store didn't have the `m.secret_storage.default.key.*` account data event. This caused `recovery().recover()` to fail silently (due to the `best-effort` try-catch block), leaving the bot unrecovered on the new device.
**Solution:** Added a retry loop in both `ensure_recovery_for` and `recover_with_key_for` inside the Rust backend. When recovering, it now waits for the initial `/sync` to populate the state store (by retrying up to 5 times with a 2-second delay) before successfully importing the keys. The bot now recovers correctly on the second device.

## 3. Performance & Optimization

### 3.1 Double Long-Polling Overhead
**Severity:** MODERATE
**Location:** `rust/src/api/matrix.rs` (`spawn_sync_loop`)

**Problem:** 
Running two concurrent `/sync` loops (`user` and `pin`) means the mobile app keeps two HTTP connections open continuously. This increases battery drain and network usage. Additionally, every room event is received, decrypted, and parsed twice by the Rust SDK (once for the user, once for the bot).

**Proposed Solution:**
- **Optimize Bot Sync:** The `pin` role's primary duty is to send messages and maintain its device list for E2EE (handling to-device messages). It doesn't need aggressive real-time polling for rendering the UI. We can increase the `timeout` or introduce a delay for the `pin` role's `SyncSettings` to reduce battery footprint.
- Alternatively, explore if the companion bot session can utilize a more passive sync strategy since the `user` session handles all UI-facing event delivery.
