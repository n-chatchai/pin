import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'pin_theme.dart';

/// Holds the currently selected theme key, persisted across launches.
/// Listen on this to rebuild the app when the user switches theme.
class ThemeController extends ValueNotifier<PinPalette> {
  ThemeController._() : super(PinPalette.all.first);
  static final ThemeController instance = ThemeController._();

  static const _storage = FlutterSecureStorage();
  static const _key = 'theme_key';

  Future<void> load() async {
    final saved = await _storage.read(key: _key);
    if (saved != null) value = PinPalette.byKey(saved);
  }

  Future<void> select(String key) async {
    value = PinPalette.byKey(key);
    await _storage.write(key: _key, value: key);
  }
}
