import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// User preferences shown on the Settings screen (design/pin.html).
/// The persona identity fields are the source-of-truth ONLY in the ปิ่น room
/// state (see toLocalMap) — never persisted on device. Device-local settings
/// (language, reminder times, dev flags) persist via [PrefsController].
class PinPrefs {
  final String pinName; // เรียกปิ่นว่า
  final String userName; // ชื่อ/ชื่อเล่นของผู้ใช้ (ใช้สร้างตัวเลือกคำเรียก)
  final String userCall; // ให้ปิ่นเรียกเราว่า (คำเรียกที่เลือก เช่น พี่บอล)
  final String pinSelf; // ปิ่นแทนตัวเองว่า (เช่น ปิ่น/หนู/ผม) — auto จากคำเรียก
  final String tone; // 'male' | 'female' | 'casual' | 'neutral'
  final String pinEnding; // คำลงท้ายบอกเล่า (derive จาก tone; เก็บไว้ใช้ template)
  final String lang; // 'th' | 'en'
  final bool langExplicit; // true once the user picks a language by hand
  final bool morningReminder;
  final String morningTime; // HH:MM
  final String quietStart;
  final String quietEnd;
  final bool onboarded;
  final bool debugBot; // show the agent's tool-call trace in chat
  final bool personaSetup; // in-chat persona/theme setup done once (after account)
  final String personaMode; // 'basic' | special key (friend/butler/mom/cute) | 'custom'
  final String customCall; // persona=custom: how ปิ่น calls the user
  final String customSelf; // persona=custom: how ปิ่น refers to itself

  const PinPrefs({
    this.pinName = 'ปิ่น',
    this.userName = '',
    this.userCall = 'พี่',
    this.pinSelf = 'ปิ่น',
    this.tone = 'female',
    this.pinEnding = 'ค่ะ',
    this.lang = 'th',
    this.langExplicit = false,
    this.morningReminder = true,
    this.morningTime = '08:00',
    this.quietStart = '22:00',
    this.quietEnd = '07:00',
    this.onboarded = false,
    this.debugBot = false,
    this.personaSetup = false,
    this.personaMode = 'basic',
    this.customCall = '',
    this.customSelf = '',
  });

  PinPrefs copyWith({
    String? pinName,
    String? userName,
    String? userCall,
    String? pinSelf,
    String? tone,
    String? pinEnding,
    String? lang,
    bool? langExplicit,
    bool? morningReminder,
    String? morningTime,
    String? quietStart,
    String? quietEnd,
    bool? onboarded,
    bool? debugBot,
    bool? personaSetup,
    String? personaMode,
    String? customCall,
    String? customSelf,
  }) =>
      PinPrefs(
        pinName: pinName ?? this.pinName,
        userName: userName ?? this.userName,
        userCall: userCall ?? this.userCall,
        pinSelf: pinSelf ?? this.pinSelf,
        tone: tone ?? this.tone,
        pinEnding: pinEnding ?? this.pinEnding,
        lang: lang ?? this.lang,
        langExplicit: langExplicit ?? this.langExplicit,
        morningReminder: morningReminder ?? this.morningReminder,
        morningTime: morningTime ?? this.morningTime,
        quietStart: quietStart ?? this.quietStart,
        quietEnd: quietEnd ?? this.quietEnd,
        onboarded: onboarded ?? this.onboarded,
        debugBot: debugBot ?? this.debugBot,
        personaSetup: personaSetup ?? this.personaSetup,
        personaMode: personaMode ?? this.personaMode,
        customCall: customCall ?? this.customCall,
        customSelf: customSelf ?? this.customSelf,
      );

  /// Apply a ปิ่น room-state persona map (snake_case keys from the
  /// `io.tokens2.prefs` state event) onto this prefs. The room is the single
  /// source of truth for persona, so this is the ONE place that maps it — boot
  /// rehydrate AND chat-open sync both call it, so the field set can't drift
  /// (duplicating it is how `tone` / `persona_mode` got dropped before). A key
  /// absent from the room keeps the current value; `tone` is derived from the
  /// ending for older rooms that predate the tone field.
  PinPrefs copyWithRoomState(Map<String, String> r) => copyWith(
        pinName: r['pin_name'],
        userName: r['user_name'],
        userCall: r['user_call'],
        pinSelf: r['pin_self'],
        tone: r['tone'] ?? toneFromEnding(r['pin_ending'] ?? pinEnding),
        pinEnding: r['pin_ending'],
        personaMode: r['persona_mode'],
        customCall: r['custom_call'],
        customSelf: r['custom_self'],
        lang: r['lang'],
        onboarded: r.containsKey('onboarded') ? r['onboarded'] == '1' : null,
        personaSetup: r.containsKey('persona_setup') ? r['persona_setup'] == '1' : null,
      );

  Map<String, String> toMap() => {
        'pinName': pinName,
        'userName': userName,
        'userCall': userCall,
        'pinSelf': pinSelf,
        'tone': tone,
        'pinEnding': pinEnding,
        'lang': lang,
        'langExplicit': langExplicit ? '1' : '0',
        'morningReminder': morningReminder ? '1' : '0',
        'morningTime': morningTime,
        'quietStart': quietStart,
        'quietEnd': quietEnd,
        'onboarded': onboarded ? '1' : '0',
        'debugBot': debugBot ? '1' : '0',
        'personaSetup': personaSetup ? '1' : '0',
        'personaMode': personaMode,
        'customCall': customCall,
        'customSelf': customSelf,
      };

  /// Keys NOT persisted on device — they are derived from the ปิ่น room state
  /// (the single source of truth) on every launch, so they can't go stale or
  /// diverge across devices. The persona identity, AND `onboarded`/`personaSetup`
  /// (which mean "the room already has a persona") all live in the room, not
  /// here. Only true device-local settings (language, reminders, dev flags)
  /// persist. This is why a fresh account on a shared device never inherits the
  /// previous one's name or "already onboarded" state.
  static const _roomDerivedKeys = {
    'pinName', 'userName', 'userCall', 'pinSelf', 'tone', 'pinEnding',
    'personaMode', 'customCall', 'customSelf', 'onboarded', 'personaSetup', 'lang',
  };
  Map<String, String> toLocalMap() {
    final m = toMap();
    m.removeWhere((k, _) => _roomDerivedKeys.contains(k));
    return m;
  }

  static PinPrefs fromMap(Map<String, String> m) => PinPrefs(
        pinName: m['pinName'] ?? 'ปิ่น',
        userName: m['userName'] ?? '',
        userCall: m['userCall'] ?? 'พี่',
        pinSelf: m['pinSelf'] ?? 'ปิ่น',
        // Migrate pre-tone prefs: derive tone from the saved ending particle.
        tone: m['tone'] ?? toneFromEnding(m['pinEnding'] ?? 'ค่ะ'),
        pinEnding: m['pinEnding'] ?? 'ค่ะ',
        lang: m['lang'] ?? 'th',
        langExplicit: m['langExplicit'] == '1',
        morningReminder: m['morningReminder'] != '0',
        morningTime: m['morningTime'] ?? '08:00',
        quietStart: m['quietStart'] ?? '22:00',
        quietEnd: m['quietEnd'] ?? '07:00',
        onboarded: m['onboarded'] == '1',
        debugBot: m['debugBot'] == '1',
        personaSetup: m['personaSetup'] == '1',
        personaMode: m['personaMode'] ?? 'basic',
        customCall: m['customCall'] ?? '',
        customSelf: m['customSelf'] ?? '',
      );
}

/// Sentence-ending particle for a tone. female swaps ค่ะ↔คะ by sentence type
/// (statement vs question); neutral has none. Used by the live settings preview
/// and onboarding copy (the agent itself gets a prompt instruction, not this).
String toneParticle(String tone, {bool question = false}) {
  switch (tone) {
    case 'male':
      return 'ครับ';
    case 'female':
      return question ? 'คะ' : 'ค่ะ';
    case 'casual':
      return 'จ๊ะ';
    default: // neutral
      return '';
  }
}

/// Reverse map (migration): an old saved ending particle → its tone.
String toneFromEnding(String ending) {
  switch (ending.trim()) {
    case 'ครับ':
      return 'male';
    case 'ค่ะ':
    case 'คะ':
      return 'female';
    case 'จ๊ะ':
    case 'จ้ะ':
      return 'casual';
    case '':
      return 'neutral';
    default:
      return 'female';
  }
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
    // onboarded/personaSetup are room-derived — never trust a persisted value
    // (older builds wrote them, and they go stale). Start false; AfterAuth's
    // rehydrate flips them true iff the ปิ่น room actually carries a persona.
    p = p.copyWith(onboarded: false, personaSetup: false);
    // Until the user picks a language by hand, keep following the device — so
    // an English phone shows English even if old saved prefs defaulted to Thai.
    if (!p.langExplicit) p = p.copyWith(lang: detected);
    value = p;
  }

  Future<void> update(PinPrefs p) async {
    value = p;
    // Persist only device-local settings; persona identity stays room-only.
    final raw =
        p.toLocalMap().entries.map((e) => '${e.key}=${e.value}').join('\n');
    await _storage.write(key: _key, value: raw);
  }

  /// Wipe to defaults (called on logout). The persona, onboarded/personaSetup
  /// flags, and settings of the previous account must NOT survive into the next
  /// one on the same device — otherwise a new account inherits the old name and
  /// skips onboarding. Persona then re-hydrates from the next account's room.
  Future<void> reset() async {
    await _storage.delete(key: _key);
    final detected =
        ui.PlatformDispatcher.instance.locale.languageCode == 'th' ? 'th' : 'en';
    value = PinPrefs(lang: detected);
  }
}
