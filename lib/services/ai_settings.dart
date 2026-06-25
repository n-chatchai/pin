import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../agent/proxy_client.dart';

/// The user's optional OpenRouter "bring your own key" config. When enabled,
/// the device calls OpenRouter **directly** (see [ProxyClient.infer]) — the key
/// and the paid traffic never touch our proxy. The key lives ONLY in device
/// secure storage; it isn't synced, so the user re-enters it on each device.
class AiConfig {
  final bool enabled; // true only when on AND a key is present
  final String? key;
  final String model;
  const AiConfig({
    this.enabled = false,
    this.key,
    this.model = ProxyClient.defaultOpenRouterModel,
  });
}

class AiSettings extends ValueNotifier<AiConfig> {
  AiSettings._() : super(const AiConfig());
  static final AiSettings instance = AiSettings._();

  static const _storage = FlutterSecureStorage();
  static const _kKey = 'openrouter_key';
  static const _kModel = 'openrouter_model';
  static const _kOn = 'openrouter_on';

  /// Load the saved config into memory at boot so [devProxy] reads it
  /// synchronously. Best-effort: defaults to free tier on any error.
  Future<void> load() async {
    try {
      final key = await _storage.read(key: _kKey);
      final model = await _storage.read(key: _kModel);
      final on = (await _storage.read(key: _kOn)) == '1';
      value = AiConfig(
        enabled: on && (key?.isNotEmpty ?? false),
        key: (key?.isEmpty ?? true) ? null : key,
        model: (model == null || model.isEmpty)
            ? ProxyClient.defaultOpenRouterModel
            : model,
      );
    } catch (_) {/* free tier */}
  }

  /// Persist + apply. Enabling without a key falls back to disabled (free).
  Future<void> save({
    required bool enabled,
    String? key,
    String? model,
  }) async {
    final k = (key ?? '').trim();
    final m = (model ?? '').trim().isEmpty
        ? ProxyClient.defaultOpenRouterModel
        : model!.trim();
    final on = enabled && k.isNotEmpty;
    await _storage.write(key: _kKey, value: k.isEmpty ? null : k);
    await _storage.write(key: _kModel, value: m);
    await _storage.write(key: _kOn, value: on ? '1' : '0');
    value = AiConfig(enabled: on, key: k.isEmpty ? null : k, model: m);
  }
}
