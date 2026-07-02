import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../agent/proxy_client.dart';

/// The AI provider ปิ่น uses for inference. 'pin' = our free blind proxy
/// (Gemini, our key). Everything else is "bring your own key": the device calls
/// the provider DIRECTLY (see [ProxyClient.infer]) — the key and paid traffic
/// never touch our proxy. Keys live ONLY in device secure storage; not synced.
class AiConfig {
  final String provider; // pin | openrouter | openai | gemini | claude
  final String? key;
  final String model;
  final String? baseUrl; // openai-compatible custom endpoint only
  const AiConfig({
    this.provider = 'pin',
    this.key,
    this.model = ProxyClient.defaultOpenRouterModel,
    this.baseUrl,
  });

  /// True when a BYO provider is active and has what it needs to run.
  bool get enabled {
    if (provider == 'pin') return false;
    if (provider == 'openai') return (baseUrl?.isNotEmpty ?? false);
    return key?.isNotEmpty ?? false; // openrouter / gemini / claude
  }

  /// Short label for the settings row value.
  String get label {
    if (!enabled) return 'ปิ่น';
    final m = model.trim();
    final name = switch (provider) {
      'openrouter' => 'OpenRouter',
      'openai' => 'OpenAI-compatible',
      'gemini' => 'Gemini',
      'claude' => 'Claude',
      _ => provider,
    };
    return m.isEmpty ? name : '$name · ${m.split('/').last}';
  }
}

class AiSettings extends ValueNotifier<AiConfig> {
  AiSettings._() : super(const AiConfig());
  static final AiSettings instance = AiSettings._();

  static const _storage = FlutterSecureStorage();
  static const _kProvider = 'ai_provider';
  static const _kKey = 'ai_key';
  static const _kModel = 'ai_model';
  static const _kBaseUrl = 'ai_base_url';
  // Legacy (pre-multi-provider) keys — migrated on first load.
  static const _kOldKey = 'openrouter_key';
  static const _kOldModel = 'openrouter_model';
  static const _kOldOn = 'openrouter_on';

  /// Load the saved config at boot so [devProxy] reads it synchronously.
  /// Best-effort: defaults to the free 'pin' provider on any error.
  Future<void> load() async {
    try {
      var provider = await _storage.read(key: _kProvider);
      var key = await _storage.read(key: _kKey);
      var model = await _storage.read(key: _kModel);
      final baseUrl = await _storage.read(key: _kBaseUrl);
      // One-time migration: an old OpenRouter-only config → the new shape.
      if (provider == null) {
        final oldOn = (await _storage.read(key: _kOldOn)) == '1';
        final oldKey = await _storage.read(key: _kOldKey);
        if (oldOn && (oldKey?.isNotEmpty ?? false)) {
          provider = 'openrouter';
          key = oldKey;
          model = await _storage.read(key: _kOldModel);
        }
      }
      value = AiConfig(
        provider: (provider == null || provider.isEmpty) ? 'pin' : provider,
        key: (key?.isEmpty ?? true) ? null : key,
        model: (model == null || model.isEmpty)
            ? ProxyClient.defaultOpenRouterModel
            : model,
        baseUrl: (baseUrl?.isEmpty ?? true) ? null : baseUrl,
      );
    } catch (_) {/* free 'pin' tier */}
  }

  /// Persist + apply.
  Future<void> save({
    required String provider,
    String? key,
    String? model,
    String? baseUrl,
  }) async {
    final k = (key ?? '').trim();
    final m = (model ?? '').trim();
    final b = (baseUrl ?? '').trim();
    await _storage.write(key: _kProvider, value: provider);
    await _storage.write(key: _kKey, value: k.isEmpty ? null : k);
    await _storage.write(
        key: _kModel, value: m.isEmpty ? ProxyClient.defaultOpenRouterModel : m);
    await _storage.write(key: _kBaseUrl, value: b.isEmpty ? null : b);
    value = AiConfig(
      provider: provider,
      key: k.isEmpty ? null : k,
      model: m.isEmpty ? ProxyClient.defaultOpenRouterModel : m,
      baseUrl: b.isEmpty ? null : b,
    );
  }
}
