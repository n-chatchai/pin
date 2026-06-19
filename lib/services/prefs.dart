import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// User preferences shown on the Settings screen (design/pin.html).
/// Persisted locally; these also shape ปิ่น's persona + reminder behaviour
/// (synced to the bot later).
class PinPrefs {
  final String pinName; // เรียกปิ่นว่า
  final String userCall; // ให้ปิ่นเรียกเราว่า
  final String pinSelf; // ปิ่นแทนตัวเองว่า (เช่น ปิ่น/หนู/ผม)
  final String pinEnding; // ปิ่นลงท้ายว่า (เช่น ครับ/คะ/จ้ะ)
  final String lang; // 'th' | 'en'
  final bool langExplicit; // true once the user picks a language by hand
  final bool morningReminder;
  final String morningTime; // HH:MM
  final String quietStart;
  final String quietEnd;
  final bool onboarded;
  final bool debugBot; // show the agent's tool-call trace in chat
  final bool tourDone; // first-run in-chat showcase tour shown once
  final bool personaSetup; // in-chat persona/theme setup done once (after account)

  const PinPrefs({
    this.pinName = 'ปิ่น',
    this.userCall = 'พี่',
    this.pinSelf = 'ปิ่น',
    this.pinEnding = 'ครับ',
    this.lang = 'th',
    this.langExplicit = false,
    this.morningReminder = true,
    this.morningTime = '08:00',
    this.quietStart = '22:00',
    this.quietEnd = '07:00',
    this.onboarded = false,
    this.debugBot = false,
    this.tourDone = false,
    this.personaSetup = false,
  });

  PinPrefs copyWith({
    String? pinName,
    String? userCall,
    String? pinSelf,
    String? pinEnding,
    String? lang,
    bool? langExplicit,
    bool? morningReminder,
    String? morningTime,
    String? quietStart,
    String? quietEnd,
    bool? onboarded,
    bool? debugBot,
    bool? tourDone,
    bool? personaSetup,
  }) =>
      PinPrefs(
        pinName: pinName ?? this.pinName,
        userCall: userCall ?? this.userCall,
        pinSelf: pinSelf ?? this.pinSelf,
        pinEnding: pinEnding ?? this.pinEnding,
        lang: lang ?? this.lang,
        langExplicit: langExplicit ?? this.langExplicit,
        morningReminder: morningReminder ?? this.morningReminder,
        morningTime: morningTime ?? this.morningTime,
        quietStart: quietStart ?? this.quietStart,
        quietEnd: quietEnd ?? this.quietEnd,
        onboarded: onboarded ?? this.onboarded,
        debugBot: debugBot ?? this.debugBot,
        tourDone: tourDone ?? this.tourDone,
        personaSetup: personaSetup ?? this.personaSetup,
      );

  Map<String, String> toMap() => {
        'pinName': pinName,
        'userCall': userCall,
        'pinSelf': pinSelf,
        'pinEnding': pinEnding,
        'lang': lang,
        'langExplicit': langExplicit ? '1' : '0',
        'morningReminder': morningReminder ? '1' : '0',
        'morningTime': morningTime,
        'quietStart': quietStart,
        'quietEnd': quietEnd,
        'onboarded': onboarded ? '1' : '0',
        'debugBot': debugBot ? '1' : '0',
        'tourDone': tourDone ? '1' : '0',
        'personaSetup': personaSetup ? '1' : '0',
      };

  static PinPrefs fromMap(Map<String, String> m) => PinPrefs(
        pinName: m['pinName'] ?? 'ปิ่น',
        userCall: m['userCall'] ?? 'พี่',
        pinSelf: m['pinSelf'] ?? 'ปิ่น',
        pinEnding: m['pinEnding'] ?? 'ครับ',
        lang: m['lang'] ?? 'th',
        langExplicit: m['langExplicit'] == '1',
        morningReminder: m['morningReminder'] != '0',
        morningTime: m['morningTime'] ?? '08:00',
        quietStart: m['quietStart'] ?? '22:00',
        quietEnd: m['quietEnd'] ?? '07:00',
        onboarded: m['onboarded'] == '1',
        debugBot: m['debugBot'] == '1',
        tourDone: m['tourDone'] == '1',
        personaSetup: m['personaSetup'] == '1',
      );
}

/// The user's chosen name for the assistant (defaults to 'ปิ่น'). Use this in
/// user-facing copy instead of a hardcoded 'ปิ่น'. NOT for identity/technical
/// strings (the ปิ่น room name, `_pin` account suffix, account labels) — those
/// must stay stable regardless of the display name.
String get botName => PrefsController.instance.value.pinName;

class PrefsController extends ValueNotifier<PinPrefs> {
  PrefsController._() : super(const PinPrefs());
  static final PrefsController instance = PrefsController._();

  static const _storage = FlutterSecureStorage();
  static const _key = 'prefs';

  Future<void> load() async {
    // Device language: Thai locale → th, anything else → en.
    final detected =
        ui.PlatformDispatcher.instance.locale.languageCode == 'th' ? 'th' : 'en';
    final raw = await _storage.read(key: _key);
    if (raw == null) {
      value = PinPrefs(lang: detected);
      return;
    }
    final map = <String, String>{
      for (final pair in raw.split('\n'))
        if (pair.contains('=')) pair.split('=').first: pair.split('=').skip(1).join('='),
    };
    var p = PinPrefs.fromMap(map);
    // Until the user picks a language by hand, keep following the device — so
    // an English phone shows English even if old saved prefs defaulted to Thai.
    if (!p.langExplicit) p = p.copyWith(lang: detected);
    value = p;
  }

  Future<void> update(PinPrefs p) async {
    value = p;
    final raw = p.toMap().entries.map((e) => '${e.key}=${e.value}').join('\n');
    await _storage.write(key: _key, value: raw);
  }
}
