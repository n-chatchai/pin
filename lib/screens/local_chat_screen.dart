import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../agent/agent_config.dart';
import '../agent/agent_reply.dart';
import '../agent/agent_session.dart';
import '../agent/abilities.dart';
import '../models/chat_view_message.dart';
import '../src/rust/api/matrix.dart' as rust;
import '../services/files_store.dart';
import '../services/matrix_service.dart';
import '../services/name_filter.dart';
import '../services/prefs.dart';
import '../theme/theme_controller.dart';
import '../widgets/pin_toast.dart';
import 'chat_screen.dart' show ChatScaffold;

/// The main ปิ่น chat — same polished UI (ChatScaffold) but backed by the
/// on-device agent (LLM proxy + on-device memory + tools), not the Matrix bot.
/// Conversation persists in AgentStore (encrypted at rest); nothing on a server.
class LocalChatScreen extends StatefulWidget {
  const LocalChatScreen({super.key});

  @override
  State<LocalChatScreen> createState() => _LocalChatScreenState();
}

/// Debug hook — the live chat registers its persona-setup starter here so dev
/// tools (Settings) can re-trigger the conversational onboarding without a fresh
/// account. Null when no chat is mounted.
void Function()? debugForcePersonaSetup;

class _LocalChatScreenState extends State<LocalChatScreen>
    with WidgetsBindingObserver {
  static const _room = 'pin';
  /// The encrypted Matrix DM room id (2-account chat). Null until the ปิ่น
  /// session + DM are up; while null the screen behaves as the old local-only
  /// chat (graceful fallback if provisioning fails).
  String? _roomId;
  /// Matrix event ids already rendered (paginated, live, or our own optimistic
  /// sends) — so the live echo of a message we just posted isn't double-shown.
  final _seenEvents = <String>{};
  StreamSubscription<rust.ChatMessage>? _dmSub;
  /// Boot/loading status shown as a pill ('กำลังโหลดข้อความ…' etc), null = done.
  String? _loading;
  final _scroll = ScrollController();
  final _messages = <ChatViewMessage>[];
  List<Map<String, String>> _quickReplies = const []; // first-run quick replies
  AgentSession? _session;
  ChatViewMessage? _replyTo;
  bool _botTyping = false;
  int _seq = 0;
  int _personaStep = -1; // -1 = not in the in-chat onboarding (>=0 = active)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    debugForcePersonaSetup = () {
      if (mounted) _startPersonaSetup();
    };
    _boot();
  }

  @override
  void dispose() {
    _dmSub?.cancel();
    debugForcePersonaSetup = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _boot() async {
    _session = AgentSession(room: _room, proxy: devProxy());
    // The encrypted DM room is the single source of truth for the transcript —
    // no local chat copy that can diverge across devices. The chat stays blank
    // (status pill below) until _loadFromDm paginates the room.
    if (mounted) setState(() => _loading = 'กำลังเตรียม$botName…');
    // Bring up the ปิ่น companion session + encrypted DM (2-account chat).
    // Best-effort: on failure (e.g. registration gated) the chat stays on the
    // local transcript so nothing breaks. The status pill shows each step.
    try {
      await MatrixService.instance.ensurePinSession();
      if (mounted) setState(() => _loading = 'กำลังเชื่อมห้องแชต…');
      _roomId = await MatrixService.instance.getOrCreatePinDm();
    } catch (e) {
      _roomId = null;
      debugPrint('pin DM bring-up failed (local fallback): $e');
    }
    if (_roomId != null) {
      // Persona (a room-state read) is independent of the transcript, so overlap
      // it with pagination instead of paying two sequential round-trips. Awaited
      // before the greeting/quick-replies below, which fill in the persona.
      final personaF = _syncPersonaWithRoom(_roomId!);
      if (mounted) setState(() => _loading = 'กำลังโหลดข้อความ…');
      await _loadFromDm();
      await personaF;
    }
    if (mounted) setState(() => _loading = null);
    // First run (no history): conversational onboarding once (after the
    // account/room exist, so persona syncs to room state); else the greeting.
    if (_messages.isEmpty) {
      if (!PrefsController.instance.value.personaSetup) {
        _startPersonaSetup();
      } else {
        _loadWelcome();
      }
    }
    // Load the catalog in the background — it doesn't block the chat render, and
    // send() refreshes a stale catalog before the first turn anyway.
    unawaited(_session!.loadCatalog());
  }

  /// Persona + theme live in the ปิ่น room state (io.tokens2.prefs) so they're
  /// identical on every device (the room is the source of truth, like the
  /// transcript). Pull and apply on boot; mark personaSetup done so the in-chat
  /// setup is skipped on devices that already have it. If the room has no persona
  /// yet, do nothing — the in-chat setup will write it. State events aren't E2EE.
  Future<void> _syncPersonaWithRoom(String roomId) async {
    try {
      final p = await MatrixService.instance.loadPrefsFromRoom(roomId);
      final hasRoomPersona =
          p != null && (p['pin_ending'] != null || (p['pin_name'] ?? '').isNotEmpty);
      if (!hasRoomPersona) return;
      final cur = PrefsController.instance.value;
      await PrefsController.instance.update(cur.copyWith(
        pinName: p['pin_name'] ?? cur.pinName,
        userName: p['user_name'] ?? cur.userName,
        userCall: p['user_call'] ?? cur.userCall,
        pinSelf: p['pin_self'] ?? cur.pinSelf,
        // Migrate older rooms with no tone stored: derive it from the ending.
        tone: p['tone'] ?? toneFromEnding(p['pin_ending'] ?? cur.pinEnding),
        pinEnding: p['pin_ending'] ?? cur.pinEnding,
        personaSetup: true,
      ));
      final theme = p['theme'];
      if (theme != null && theme.isNotEmpty) {
        ThemeController.instance.select(theme);
      }
    } catch (e) {
      debugPrint('persona sync failed: $e');
    }
  }

  /// Load the transcript from the encrypted DM (source of truth): paginate
  /// backward, render each event by sender, seed the agent's model window, then
  /// subscribe to live events.
  Future<void> _loadFromDm() async {
    // Start the continuous sync loop BEFORE paginating. On a freshly logged-in
    // or key-restored device the encrypted timeline is empty (and historical
    // events are still undecryptable) until the first sync round lands, so an
    // immediate pagination returns nothing and the chat falls back to the
    // greeting even though the DM has history. Touching `messages` starts sync.
    final live = MatrixService.instance.messages;
    try {
      var fresh = <ChatViewMessage>[];
      var seen = <String>{};
      var modelTurns = <Map<String, dynamic>>[];
      // Retry briefly so the first sync round can populate / decrypt the
      // timeline. A genuinely empty DM just stays empty after the retries and
      // correctly falls through to the greeting.
      for (var attempt = 0; attempt < 6; attempt++) {
        final page =
            await MatrixService.instance.roomMessages(_roomId!, limit: 40);
        final chrono = page.messages.reversed.toList(); // oldest→newest
        fresh = <ChatViewMessage>[];
        seen = <String>{};
        modelTurns = <Map<String, dynamic>>[];
        for (final m in chrono) {
          if (m.eventId.isEmpty || seen.contains(m.eventId)) continue;
          seen.add(m.eventId);
          final view = await _dmToView(m);
          if (view != null) fresh.add(view);
          final role = m.sender == MatrixService.instance.pinUserId
              ? 'assistant'
              : 'user';
          if (m.body.isNotEmpty) {
            modelTurns.add({'role': role, 'content': m.body});
          }
        }
        if (fresh.isNotEmpty) break;
        if (!mounted) return;
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      // Only swap in the DM transcript if it actually has messages — otherwise
      // keep the instant local render (handles a fresh/empty room or a transient
      // decrypt miss without flashing the chat empty).
      if (fresh.isNotEmpty && mounted) {
        _seenEvents
          ..clear()
          ..addAll(seen);
        setState(() {
          _messages
            ..clear()
            ..addAll(fresh);
        });
        // Feed the LLM's context from the DM (in memory only — no local copy).
        _session?.seedTurns(modelTurns);
      }
    } catch (e) {
      debugPrint('DM pagination failed, keeping local render: $e');
    }
    // Live events for this room → render (deduped by event id).
    _dmSub ??= live.where((m) => m.roomId == _roomId).listen(_onLiveDmEvent);
  }

  /// Map a DM event to a chat bubble. Sender = role (ปิ่น account → left bubble,
  /// user account → right). Returns null for ephemeral/non-chat events.
  Future<ChatViewMessage?> _dmToView(rust.ChatMessage m) async {
    const skip = {'typing', 'receipt', 'reaction', 'tasks', 'events', 'jobs'};
    if (skip.contains(m.kind)) return null;
    final isPin = m.sender == MatrixService.instance.pinUserId;
    final sender = isPin ? '@pin' : '@me';
    final tsMs = m.timestampMs.toInt();
    final t = DateTime.fromMillisecondsSinceEpoch(
        tsMs == 0 ? DateTime.now().millisecondsSinceEpoch : tsMs);
    String? hint;
    if (m.metaJson != null) {
      try {
        final mm = jsonDecode(m.metaJson!) as Map<String, dynamic>;
        final used = (mm['used'] as List?)?.map((e) => '$e').toList();
        if (used != null && used.isNotEmpty) {
          hint = 'ใช้: ${used.map(abilityLabel).join(', ')}';
        }
      } catch (_) {}
    }
    if (m.kind == 'flex' && m.flexJson != null) {
      Map<String, dynamic>? flex;
      try {
        flex = jsonDecode(m.flexJson!) as Map<String, dynamic>;
      } catch (_) {}
      return ChatViewMessage(
          eventId: m.eventId, sender: sender, body: '', time: t,
          isMe: !isPin, kind: 'flex', flex: flex, hint: hint);
    }
    if (m.kind == 'image' || m.kind == 'file' ||
        m.kind == 'audio' || m.kind == 'video') {
      String? path;
      try {
        path = await MatrixService.instance.downloadMedia(m.roomId, m.eventId);
      } catch (_) {}
      return ChatViewMessage(
          eventId: m.eventId, sender: sender, body: m.body, time: t,
          isMe: !isPin, kind: m.kind, localPath: path);
    }
    final body = isPin ? _splitTag(m.body).$1 : m.body;
    return ChatViewMessage(
        eventId: m.eventId, sender: sender, body: body, time: t,
        isMe: !isPin, hint: hint);
  }

  /// A new live DM event arrived (from this or another device) → render it.
  Future<void> _onLiveDmEvent(rust.ChatMessage m) async {
    if (m.eventId.isEmpty || _seenEvents.contains(m.eventId)) return;
    _seenEvents.add(m.eventId);
    final view = await _dmToView(m);
    if (view != null && mounted) {
      setState(() => _messages.add(view));
      _scrollToEnd();
    }
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  /// Built-in first-run greeting + quick replies, interpolated with the user's
  /// persona and shown when the chat opens empty. This is static UI copy, so it
  /// lives in the app — no /welcome round-trip to the proxy.
  static const _greetingTpl =
      'สวัสดี{userCall} {pinName}เอง{ending} 👋 '
      '{pinName}ช่วยจำ เตือน หาข้อมูล และสรุปให้ได้ — ลองกดดูสักอันก่อนก็ได้{ending}';
  static const _welcomeReplies = <Map<String, String>>[
    {'label': 'ลองให้ปิ่นเตือน', 'send': 'เตือนฉันในอีก 1 นาทีว่า ลองใช้ปิ่นดู'},
    {'label': 'สรุปเอกสาร', 'send': 'ช่วยสรุปเอกสารนี้สั้น ๆ แล้วจำไว้ให้ด้วย'},
    {'label': 'ดูดวง', 'send': 'ดูดวงให้หน่อย'},
    {'label': 'ขอข่าววันนี้', 'send': 'ขอข่าววันนี้'},
    {'label': 'อากาศวันนี้', 'send': 'อากาศวันนี้เป็นไง'},
  ];

  void _loadWelcome() {
    if (!mounted || _messages.isNotEmpty) return;
    final greeting = _fillPersona(_greetingTpl);
    setState(() {
      _messages.add(_text(greeting, me: false));
      _quickReplies = [
        for (final r in _welcomeReplies)
          {'label': _fillPersona(r['label']!), 'send': _fillPersona(r['send']!)},
      ];
    });
  }

  /// Interpolate the user's persona into a template ({userCall}/{pinName}/{ending}).
  String _fillPersona(String s) {
    final p = PrefsController.instance.value;
    return s
        .replaceAll('{userCall}', p.userCall)
        .replaceAll('{pinName}', p.pinName)
        .replaceAll('{ending}', p.pinEnding);
  }

  // ---- First-run conversational onboarding (persona + light demos) --------
  // Order: ask the user's name → name the assistant → reminder demo → tone →
  // how to address you (tone-aware) → file demo → done. pinSelf is derived from
  // the chosen address (พี่X→น้องASST, น้องX→พี่ASST), not asked. Theme lives in
  // Settings now. This replaces the old scripted showcase tour.

  String _personaStage = ''; // which onboarding question the next answer fills
  int _nameTries = 0; // failed name attempts on the current stage (offer skip ≥3)

  void _startPersonaSetup() {
    _personaStep = 0; // >=0 marks onboarding active (typed input = an answer)
    _askUserName();
  }

  /// Post ปิ่น's line for [stage] + its inline options (rendered IN the feed,
  /// design-style — not the quick-reply bar). [kind] = chips | tone | addr.
  void _postStage(String stage, String q, String kind,
      [List<Map<String, String>> options = const []]) {
    _personaStage = stage;
    setState(() {
      _messages.add(_text(q, me: false));
      if (options.isNotEmpty) _messages.add(_optionsMsg(kind, options));
    });
    // reverse:true ListView keeps the newest pinned at the bottom on its own —
    // no manual animate (the old _scrollToEnd fought the pin and jittered).
  }

  ChatViewMessage _optionsMsg(String kind, List<Map<String, String>> options) =>
      ChatViewMessage(
        eventId: 'm${_seq++}',
        sender: '@pin',
        body: '',
        time: DateTime.now(),
        isMe: false,
        onboard: {'type': 'options', 'kind': kind, 'options': options},
      );

  Map<String, String> _pChip(String label, String value) =>
      {'label': label, 'value': value};

  /// Remove the trailing inline-options card once it's been answered (design
  /// removes the buttons after a choice).
  void _consumeOptions() {
    if (_messages.isNotEmpty && _messages.last.onboard?['type'] == 'options') {
      setState(() => _messages.removeLast());
    }
  }

  void _echoUser(String t) {
    setState(() {
      _messages.add(_text(t, me: true));
      _quickReplies = const [];
    });
  }

  void _botSay(String t) {
    setState(() => _messages.add(_text(t, me: false)));
  }

  // ปิ่น's scripted onboarding lines speak in the chosen tone (neutral until the
  // tone step). _pt = statement particle, _ptq = question particle.
  String get _pt => toneParticle(PrefsController.instance.value.tone);
  String get _ptq =>
      toneParticle(PrefsController.instance.value.tone, question: true);

  /// Add a local inline demo card (reminder/news/trip/theme) to the feed.
  void _botCard(Map<String, dynamic> spec) {
    setState(() => _messages.add(ChatViewMessage(
        eventId: 'm${_seq++}',
        sender: '@pin',
        body: '',
        time: DateTime.now(),
        isMe: false,
        onboard: spec)));
  }

  /// Tone-aware address options, built from the user's name.
  List<String> _addrOptions() {
    final p = PrefsController.instance.value;
    final n = p.userName.trim().isEmpty ? 'คุณ' : p.userName.trim();
    switch (p.tone) {
      case 'casual':
        return [n, 'แก', 'นาย', 'เพื่อน'];
      case 'neutral':
        return [n, 'คุณ$n'];
      default:
        return [n, 'คุณ$n', 'พี่$n', 'น้อง$n'];
    }
  }

  /// The address tells the assistant's role: "พี่X" → it's the junior (น้องASST),
  /// "น้องX" → it's the senior (พี่ASST); otherwise it goes by its own name.
  String _deriveSelf(String addr, String asst) {
    if (addr.startsWith('พี่')) return 'น้อง$asst';
    if (addr.startsWith('น้อง')) return 'พี่$asst';
    return asst;
  }

  // ----- stages (each posts a question, _applyPersonaAnswer advances) -----
  // Pre-tone lines stay NEUTRAL (no particle); once the tone is picked the
  // later lines speak in it (via _pt / _ptq).
  void _askUserName() => _postStage(
      'userName',
      'สวัสดี! ฉันคือผู้ช่วยเอไอของคุณ ก่อนเริ่มใช้งาน ขอรู้จักกันสักนิดนะ — '
          'ไม่ทราบว่าคุณชื่ออะไร พิมพ์ชื่อเล่นได้เลย',
      'chips');

  void _askPinName() {
    final u = PrefsController.instance.value.userName;
    _postStage(
        'pinName',
        'ยินดีที่ได้รู้จักนะ$u แล้วอยากเรียกผู้ช่วยว่าอะไรดี — พิมพ์ชื่อ หรือใช้ "ปิ่น" ก็ได้',
        'chips',
        [_pChip('ใช้ "ปิ่น"', 'ปิ่น')]);
  }

  void _reminderDemo() {
    final name = PrefsController.instance.value.pinName;
    _postStage(
        'demo_reminder',
        'เยี่ยมเลย ${name}พร้อมช่วยแล้ว มาลองใช้งานจริงกันนะ — แตะตัวอย่างด้านล่างให้${name}ตั้งเตือนให้ดู',
        'chips',
        [_pChip('เตือนรดน้ำต้นไม้พรุ่งนี้เช้า 7 โมง', 'go')]);
  }

  void _askTone() {
    final name = PrefsController.instance.value.pinName;
    _postStage(
        'tone', 'แล้วอยากให้${name}ตอบแบบไหนดี — แตะเลือกที่ถูกใจเลย', 'tone', [
      {'label': 'ตั้งเตือนให้แล้วครับ', 'sub': 'สุภาพ (ครับ)', 'value': 'male'},
      {'label': 'ตั้งเตือนให้แล้วค่ะ', 'sub': 'สุภาพ (ค่ะ)', 'value': 'female'},
      {'label': 'ตั้งเตือนให้แล้วจ๊ะ', 'sub': 'เป็นกันเอง (จ๊ะ)', 'value': 'casual'},
      {'label': 'ตั้งเตือนให้แล้ว', 'sub': 'เป็นกลาง', 'value': 'neutral'},
    ]);
  }

  void _askAddress() {
    final p = PrefsController.instance.value;
    final opts = [for (final o in _addrOptions()) _pChip(o, o)];
    opts.add(_pChip('กำหนดเอง', '__custom'));
    _postStage(
        'address',
        'แล้วอยากให้${p.pinName}เรียก${p.userName}ว่ายังไงดี$_ptq แตะเลือก หรือพิมพ์เองก็ได้',
        'addr',
        opts);
  }

  void _fileDemo() {
    final self = PrefsController.instance.value;
    _postStage(
        'demo_file',
        'ลองอีกอย่างไหม$_ptq ${self.pinName}รับไฟล์ที่${self.userCall}อัปโหลด แล้วสรุปให้เป็นการ์ดอ่านง่ายได้นะ ลองอัปโหลดไฟล์เอง หรือใช้ไฟล์ตัวอย่างก็ได้',
        'chips',
        [_pChip('อัปโหลดไฟล์', 'upload'), _pChip('ใช้ไฟล์ตัวอย่าง', 'go')]);
  }

  // Voice step: a display-only hint pointing at the composer mic. The real
  // mic-hold drives it (intercepted in _onAudio while _personaStage == 'voice').
  void _voiceStep() {
    _personaStage = 'voice';
    setState(() {
      _messages.add(_text(
          'ปิ่นฟังเสียงก็ได้นะ$_pt กดปุ่มไมค์ในช่องพิมพ์ค้างไว้แล้วลองพูดดูสิ — '
          'จะพูดตามตัวอย่าง หรือพูดอะไรก็ได้',
          me: false));
      _messages.add(ChatViewMessage(
          eventId: 'm${_seq++}',
          sender: '@pin',
          body: '',
          time: DateTime.now(),
          isMe: false,
          onboard: {
            'type': 'voice_hint',
            'examples': ['ตั้งอ่านข่าวทุกวัน 8 โมง', 'พรุ่งนี้อากาศเป็นยังไง'],
          }));
    });
  }

  /// Onboarding "อัปโหลดไฟล์": pick a REAL file, let ปิ่น summarise it (the live
  /// feature), then continue to the voice step.
  Future<void> _uploadFileThenVoice() async {
    await _onMedia('file');
    if (mounted) _voiceStep();
  }

  /// Mic-hold during the voice step → a scripted news/weather demo, then theme.
  void _voiceDemo() {
    if (DateTime.now().millisecondsSinceEpoch % 2 == 0) {
      _echoUser('ตั้งอ่านข่าวทุกวัน 8 โมง');
      _botSay('ตั้งให้แล้ว$_pt ปิ่นจะสรุปข่าวเช้าส่งให้ทุกวัน');
      _botCard({'type': 'news', 'title': 'ข่าวเช้า', 'sub': 'ทุกวัน • 08:00 น.'});
    } else {
      _echoUser('พรุ่งนี้อากาศเป็นยังไง');
      _botSay('พรุ่งนี้กรุงเทพ 32° มีฝนช่วงบ่าย พกร่มไปด้วยนะ$_pt');
      _botCard({
        'type': 'weather',
        'title': 'พรุ่งนี้ • กรุงเทพฯ',
        'sub': '32° · มีฝนช่วงบ่าย · พกร่มไปด้วย'
      });
    }
    _themeStep();
  }

  // Theme is the LAST step: picking a swatch live-applies AND finishes (v2 —
  // no separate "done" button). The swatch tap fires onAction('done').
  void _themeStep() {
    _personaStage = 'theme';
    setState(() {
      _messages.add(_text(
          'สุดท้ายแล้ว$_pt เลือกธีมสีที่ชอบก่อนเริ่มใช้ แตะดูเปลี่ยนสีทันที',
          me: false));
      _messages.add(ChatViewMessage(
          eventId: 'm${_seq++}',
          sender: '@pin',
          body: '',
          time: DateTime.now(),
          isMe: false,
          onboard: {'type': 'theme'}));
    });
  }

  /// Gate a persona name: trusted chips pass straight through; typed names get
  /// the instant local check + an LLM moderation pass (ปิ่น "thinks" meanwhile)
  /// before [onOk]. Rejections re-ask in-character without echoing the bad word.
  Future<void> _acceptName(String value,
      {required bool typed, required void Function(String clean) onOk}) async {
    if (!typed) {
      onOk(value.trim());
      return;
    }
    final local = localNameReason(value);
    if (local != null) {
      _rejectName(value, local);
      return;
    }
    setState(() => _botTyping = true);
    final v = await devProxy().moderateName(value.trim());
    if (!mounted) return;
    setState(() => _botTyping = false);
    if (v['ok'] == false) {
      _rejectName(value, '${v['reason'] ?? 'profane'}');
      return;
    }
    _nameTries = 0;
    onOk(value.trim());
  }

  /// Soft, in-character rejection — mask the word, re-ask, and after a few tries
  /// offer the escape hatch. Stays on the current (typable) stage.
  void _rejectName(String raw, String reason) {
    _nameTries++;
    setState(() {
      _messages.add(_text(maskRejected(raw, reason), me: true));
      _messages
          .add(_text(nameRejectMsg[reason] ?? nameRejectMsg['profane']!, me: false));
    });
    if (_nameTries >= 3) {
      _botSay('ถ้านึกไม่ออก พิมพ์ชื่อจริงสั้น ๆ ก็ได้นะ');
    }
  }

  /// Apply a typed or tapped answer for [_personaStage], echo it, then advance.
  /// [typed] answers only apply on the free-text stages (others are tap-only).
  void _applyPersonaAnswer(String value, {String? label, bool typed = false}) {
    final p = PrefsController.instance.value;
    switch (_personaStage) {
      case 'userName':
        _acceptName(value, typed: typed, onOk: (v) {
          if (v.isEmpty) return;
          _echoUser(v);
          PrefsController.instance
              .update(PrefsController.instance.value.copyWith(userName: v));
          _askPinName();
        });
      case 'pinName':
        _acceptName(value, typed: typed, onOk: (v0) {
          final v = v0.isEmpty ? 'ปิ่น' : v0;
          _echoUser(label ?? v);
          PrefsController.instance
              .update(PrefsController.instance.value.copyWith(pinName: v));
          _reminderDemo();
        });
      case 'demo_reminder':
        if (value == 'go') {
          _echoUser('เตือนรดน้ำต้นไม้พรุ่งนี้เช้า 7 โมง');
          _botSay('จัดให้แล้ว!');
          _botCard({
            'type': 'reminder',
            'title': 'รดน้ำต้นไม้',
            'sub': 'พรุ่งนี้ • 07:00 น.'
          });
        }
        _askTone();
      case 'tone':
        if (typed) return; // tone is tap-only
        _echoUser(label ?? value);
        PrefsController.instance
            .update(p.copyWith(tone: value, pinEnding: toneParticle(value)));
        _askAddress();
      case 'address':
        if (value == '__custom') {
          _botSay('ได้เลย$_pt พิมพ์คำที่อยากให้เรียกมาได้เลย');
          _personaStage = 'address'; // stay; the typed answer lands here next
          setState(() => _quickReplies = const []);
          return;
        }
        _acceptName(value, typed: typed, onOk: (addr) {
          if (addr.isEmpty) return;
          _echoUser(addr);
          final cur = PrefsController.instance.value;
          final self = _deriveSelf(addr, cur.pinName);
          PrefsController.instance
              .update(cur.copyWith(userCall: addr, pinSelf: self));
          _botSay('โอเค$addr! ตั้งแต่นี้${self}จะเรียกแบบนี้ตลอดนะ$_ptq');
          _fileDemo();
        });
      case 'demo_file':
        if (value == 'upload') {
          _uploadFileThenVoice(); // real picker → ปิ่น summarises the actual file
        } else {
          _echoUser('📎 ทริปเชียงใหม่ 3 วัน.pdf · ไฟล์ตัวอย่าง');
          _botSay('สรุปทริปเป็นการ์ดให้แล้ว ปัดดูแต่ละวันได้เลย$_pt');
          _botCard({
            'type': 'trip',
            'days': [
              {'d': 'วันที่ 1', 'items': ['ดอยสุเทพ', 'ย่านนิมมาน', 'ขันโตกมื้อเย็น']},
              {'d': 'วันที่ 2', 'items': ['ปางช้าง', 'ดอยอินทนนท์', 'น้ำตกวชิรธาร']},
              {'d': 'วันที่ 3', 'items': ['ตลาดวโรรส', 'คาเฟ่ในเมือง', 'ซื้อของฝาก']},
            ],
          });
          _voiceStep();
        }
      case 'theme':
        _finishPersonaSetup();
    }
  }

  /// Tapped an inline onboarding option — strip the buttons, then advance.
  void _handleOnboardTap(Map<String, String> r) {
    _consumeOptions();
    _applyPersonaAnswer(r['value'] ?? '', label: r['label']);
  }

  /// Persist persona to the room state (source of truth), mark setup done, post
  /// the closing greeting. Onboarding is the whole intro now — no separate tour.
  Future<void> _finishPersonaSetup() async {
    _personaStep = -1;
    _personaStage = '';
    final p = PrefsController.instance.value;
    await PrefsController.instance.update(p.copyWith(personaSetup: true));
    final rid = _roomId;
    if (rid != null) {
      await MatrixService.instance.savePersonaToRoom(rid, {
        'pin_name': p.pinName,
        'user_name': p.userName,
        'user_call': p.userCall,
        'pin_self': p.pinSelf,
        'tone': p.tone,
        'pin_ending': p.pinEnding,
        'theme': ThemeController.instance.value.key,
      });
    }
    if (!mounted) return;
    setState(() {
      _messages.add(_text(
          'ตั้งค่าเสร็จเรียบร้อย$_pt ${p.pinSelf}พร้อมช่วย${p.userCall}แล้วนะ — '
          'พิมพ์อะไรก็ได้เลย เปลี่ยนชื่อหรือคำเรียกทีหลังแตะ ⋯ ได้ตลอด',
          me: false));
      _quickReplies = const [];
    });
  }

  ChatViewMessage _text(String body, {required bool me}) => ChatViewMessage(
        eventId: 'm${_seq++}',
        sender: me ? '@me' : '@pin',
        body: body,
        time: DateTime.now(),
        isMe: me,
      );

  static const _nowTools = {
    'schedule_reminder', 'schedule_job', 'save_knowledge', 'remember_fact'
  };

  /// Split a leading self-tag like "[ใช้: ค้นข้อมูลเชิงลึก]" / "[ทำการ์ด]" off
  /// ปิ่น's reply. The model is prompted to prefix the capability it used; we
  /// surface it as the ✨ footer, not as literal "[...]" noise in the body.
  static (String, String?) _splitTag(String text) {
    final m = RegExp(r'^\s*\[([^\]\n]{1,60})\]\s*').firstMatch(text);
    if (m == null) return (text, null);
    final rest = text.substring(m.end);
    if (rest.trim().isEmpty) return (text, null); // the bracket WAS the content
    final tag =
        m.group(1)!.replaceFirst(RegExp(r'^\s*ใช้\s*[:：]\s*'), '').trim();
    return (rest, tag.isEmpty ? null : tag);
  }

  String? _hintFor(AgentReply r, String? tag) => r.usedTools.isNotEmpty
      ? 'ใช้: ${r.usedTools.map(abilityLabel).join(', ')}'
      : (tag != null ? 'ใช้: $tag' : null);

  /// Add ปิ่น's reply. When there's both a caption and a card, show the caption
  /// as a text bubble first, then the card — so ปิ่น always says a line.
  void _addReply(AgentReply r) {
    final (clean, tag) = _splitTag(r.text?.trim() ?? '');
    final hint = _hintFor(r, tag);
    if (r.flex != null && clean.isNotEmpty) {
      _messages.add(_text(clean, me: false));
    }
    _messages.add(_botReply(r, clean, hint));
  }

  ChatViewMessage _botReply(AgentReply r, String body, String? hint) {
    return ChatViewMessage(
      eventId: 'm${_seq++}',
      sender: '@pin',
      body: r.flex != null ? '' : body,
      time: DateTime.now(),
      isMe: false,
      kind: r.flex != null ? 'flex' : 'text',
      flex: r.flex,
      hint: hint,
      addedToNow: r.usedTools.any(_nowTools.contains),
      debug: PrefsController.instance.value.debugBot && r.trace.isNotEmpty
          ? r.trace
          : null,
    );
  }

  Future<AgentReply?> _run(ChatViewMessage userMsg, String text,
      {String? imagePath, String? recordText, String? imageRecordPath}) async {
    if (_session == null || _botTyping) return null;
    setState(() {
      _messages.add(userMsg);
      _botTyping = true;
    });
    try {
      final r = await _session!.send(text,
          imagePath: imagePath,
          recordText: recordText,
          imageRecordPath: imageRecordPath);
      setState(() => _addReply(r));
      _maybeDebugLog(text, r);
      await _maybeRecordCreation(r);
      // Mirror the turn into the encrypted DM (durable + cross-device): an image
      // becomes an encrypted attachment; text becomes a message.
      if (imagePath != null) {
        await _mirrorImageToRoom(imagePath, r);
      } else {
        await _mirrorToRoom(recordText ?? text, r);
      }
      return r;
    } catch (e) {
      setState(() => _messages.add(_text('ขอโทษค่ะ มีปัญหา: $e', me: false)));
      return null;
    } finally {
      setState(() => _botTyping = false);
    }
  }

  /// Mirror an image turn into the DM: upload the photo as an encrypted
  /// attachment (the user turn) + post ปิ่น's reply. Event ids are marked seen so
  /// the live echo doesn't double-render the local optimistic bubble.
  Future<void> _mirrorImageToRoom(String imagePath, AgentReply? r) async {
    final rid = _roomId;
    if (rid == null) return;
    try {
      final ue = await MatrixService.instance
          .sendUserAttachment(rid, imagePath, 'image/jpeg');
      _seenEvents.add(ue);
      if (r != null) {
        final body = (r.text?.isNotEmpty ?? false)
            ? r.text!
            : (r.flex != null ? '(ส่งการ์ดให้แล้ว)' : '');
        final pe = await MatrixService.instance.sendText(rid, body,
            role: 'pin',
            flex: r.flex,
            meta: r.usedTools.isEmpty ? null : {'used': r.usedTools});
        _seenEvents.add(pe);
      }
    } catch (e) {
      debugPrint('mirror image to DM failed: $e');
    }
  }

  /// Post a turn into the encrypted DM: the user's message (as the user account)
  /// and ปิ่น's reply (as the ปิ่น account). Best-effort; the local bubbles are
  /// already shown. No-op until the DM is up ([_roomId] null = local fallback).
  Future<void> _mirrorToRoom(String userBody, AgentReply? r) async {
    final rid = _roomId;
    if (rid == null) return;
    try {
      // Mark our own event ids as seen so their live echo isn't double-rendered
      // (the optimistic bubble is already on screen).
      final ue = await MatrixService.instance.sendText(rid, userBody, role: 'user');
      _seenEvents.add(ue);
      if (r != null) {
        final body = (r.text?.isNotEmpty ?? false)
            ? r.text!
            : (r.flex != null ? '(ส่งการ์ดให้แล้ว)' : '');
        final pe = await MatrixService.instance.sendText(rid, body,
            role: 'pin',
            flex: r.flex,
            meta: r.usedTools.isEmpty ? null : {'used': r.usedTools});
        _seenEvents.add(pe);
      }
    } catch (e) {
      debugPrint('mirror to DM failed: $e');
    }
  }

  /// Tools that CREATE content for the user (vs. fetch info like ข่าว/อากาศ).
  /// Their output is saved to the "ไฟล์" tab alongside uploaded files.
  static const _creatorTools = {'generate_image': 'รูป', 'render_html': 'html'};

  /// When ปิ่น made something (gen image / html card), keep a record + an
  /// openable copy in the on-device store so it shows in the "ไฟล์" tab.
  Future<void> _maybeRecordCreation(AgentReply r) async {
    final tool = r.usedTools.firstWhere(
        (t) => _creatorTools.containsKey(t),
        orElse: () => '');
    if (tool.isEmpty) return;
    final caption = r.text?.trim() ?? '';
    final title = '${(r.flex?['header'] as Map?)?['title'] ?? ''}'.trim();
    final html = _htmlBlock(r.flex);
    // Image → keep its remote URL; html card → persist the markup to a file.
    final uri = tool == 'generate_image'
        ? (RegExp(r'src="([^"]+)"').firstMatch(html)?.group(1) ?? '')
        : (html.isEmpty
            ? ''
            : await FilesStore.instance.persistText(html, 'html'));
    await FilesStore.instance.add(
      name: title.isNotEmpty ? title : (caption.isNotEmpty ? caption : 'ผลงานของ$botName'),
      type: _creatorTools[tool]!,
      summary: title.isNotEmpty && caption.isNotEmpty && caption != title
          ? caption
          : '',
      uri: uri,
    );
  }

  /// The html string from a flex card's html block (gen image / render_html).
  static String _htmlBlock(Map<String, dynamic>? flex) {
    final body = flex?['body'];
    if (body is! List) return '';
    for (final b in body) {
      if (b is Map && b['type'] == 'html') return '${b['html']}';
    }
    return '';
  }

  /// When the "ดีบักบอท" opt-in is on, ship this turn (user text + reply +
  /// agent trace) to the proxy debug log so the developer can review + improve.
  void _maybeDebugLog(String userText, AgentReply r) {
    if (!PrefsController.instance.value.debugBot) return;
    devProxy().debugLog({
      'user': userText,
      'reply': r.flex != null ? '[การ์ด]' : (r.text ?? ''),
      'flex': r.flex,
      'used': r.usedTools,
      'trace': r.trace,
    });
  }

  void _onSend(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    // During onboarding, a typed message IS the answer (not a chat turn). Only
    // the free-text stages accept typing; tap-only stages ignore it.
    if (_personaStep >= 0) {
      const typable = {'userName', 'pinName', 'address'};
      if (typable.contains(_personaStage)) {
        _consumeOptions(); // remove the inline buttons for this stage, if any
        _applyPersonaAnswer(t, typed: true);
      }
      return;
    }
    // First message dismisses the quick replies.
    if (_quickReplies.isNotEmpty) setState(() => _quickReplies = const []);
    final reply = _replyTo;
    if (reply != null) setState(() => _replyTo = null);
    // Show the quote on the user's bubble; give the agent the quoted context.
    final userMsg = reply == null
        ? _text(t, me: true)
        : ChatViewMessage(
            eventId: 'm${_seq++}', sender: '@me', body: t,
            time: DateTime.now(), isMe: true,
            replyToSender: reply.isMe ? 'คุณ' : botName,
            replyToBody: _snippet(reply));
    final forAgent =
        reply == null ? t : 'อ้างถึงข้อความก่อนหน้า: "${_snippet(reply)}"\n$t';
    _run(userMsg, forAgent);
  }

  static String _snippet(ChatViewMessage m) {
    final b = m.body.isNotEmpty
        ? m.body
        : (m.kind == 'image' ? '[รูป]' : (m.flex != null ? '[การ์ด]' : ''));
    return b.length > 60 ? '${b.substring(0, 60)}…' : b;
  }

  void _onReact(ChatViewMessage m, String emoji) {
    final i = _messages.indexWhere((x) => x.eventId == m.eventId);
    if (i < 0) return;
    final r = Map<String, int>.from(_messages[i].reactions);
    r.containsKey(emoji) ? r.remove(emoji) : r[emoji] = 1;
    setState(() => _messages[i] = _messages[i].copyWith(reactions: r));
  }

  static const _cameraChannel = MethodChannel('io.tokens2.pin/camera');

  Future<void> _onMedia(String id) async {
    switch (id) {
      case 'camera':
        await _nativeCamera(); // Text scan · Photo · Video tabs (native)
      case 'scan':
        await _scanDoc(); // VisionKit doc scanner → pages as images
      case 'image':
        final x = await ImagePicker().pickImage(source: ImageSource.gallery);
        if (x != null) await _sendImage(x.path);
      case 'file':
        await _pickFile();
      case 'location':
        await _shareLocation();
      case 'video':
      case 'record_video':
        if (mounted) {
          PinToast.show(context,
              'บนเครื่อง${botName}ดูรูป/เอกสารได้ — วิดีโอยังไม่รองรับนะคะ');
        }
      default:
        if (mounted) {
          PinToast.show(context, 'บนเครื่อง${botName}ดูรูปและสแกนเอกสารได้ค่ะ');
        }
    }
  }

  /// Pick a file. Images → ปิ่น sees them directly; documents/audio → converted
  /// to text (markitdown service) → ปิ่น summarises + remembers.
  Future<void> _pickFile() async {
    try {
      final r = await FilePicker.platform.pickFiles(withData: false);
      final f = r?.files.single;
      if (f?.path == null) return;
      const imageExt = {'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp'};
      if (imageExt.contains((f!.extension ?? '').toLowerCase())) {
        await _sendImage(f.path!);
      } else {
        await _convertAndSummarize(f.path!, f.name);
      }
    } catch (e) {
      if (mounted) PinToast.show(context, 'เลือกไฟล์ไม่ได้: $e');
    }
  }

  /// Send a file to the markitdown service → text, then ask ปิ่น to summarise +
  /// remember it. (The file is converted server-side, not stored.)
  Future<void> _convertAndSummarize(String path, String name) async {
    setState(() => _botTyping = true);
    final res = await devProxy().convertFile(path);
    if (!mounted) return;
    setState(() => _botTyping = false);
    final md = (res?['markdown'] as String?)?.trim() ?? '';
    if (md.isEmpty) {
      PinToast.show(context, '${res?['error'] ?? 'อ่านไฟล์นี้ไม่ได้'}');
      return;
    }
    final body = md.length > 8000 ? md.substring(0, 8000) : md;
    final userMsg = _text('📄 $name', me: true);
    final r = await _run(
        userMsg,
        'ช่วยสรุปไฟล์ "$name" นี้สั้น ๆ เข้าใจง่าย แล้วบันทึกความรู้ไว้ให้ด้วย:'
        '\n\n$body',
        // Store only the chip in history, not the whole extracted body (keeps
        // the bubble clean on reload and stops resending the body every turn).
        recordText: '📄 $name');
    // Record the file in the on-device SQLite store (→ "ไฟล์" tab). Keep a
    // private local copy of the original so the user can re-open it later;
    // only the markitdown *conversion* happened server-side, not storage.
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot + 1) : 'bin';
    final saved = await FilesStore.instance.persistMedia(path, ext);
    await FilesStore.instance.add(
      name: name,
      type: dot > 0 ? name.substring(dot + 1) : '',
      summary: r?.text?.trim() ?? '',
      uri: saved,
    );
  }

  /// A recorded voice message → transcribe with Gemini audio (blind) → treat the
  /// transcript as what the user said.
  Future<void> _onAudio(String path) async {
    // Onboarding voice step: the mic-hold is a scripted demo (news/weather),
    // not a real turn — no transcription, then move on to the theme step.
    if (_personaStep >= 0 && _personaStage == 'voice') {
      _voiceDemo();
      return;
    }
    setState(() => _botTyping = true);
    final text = await devProxy().transcribe(path);
    if (!mounted) return;
    setState(() => _botTyping = false);
    if (text.isEmpty) {
      PinToast.show(context, 'ฟังเสียงไม่ออก ลองพิมพ์แทนนะคะ');
      return;
    }
    // Keep the voice note (+ transcript) in the "ไฟล์" tab.
    final dot = path.lastIndexOf('.');
    final ext = dot > 0 ? path.substring(dot + 1) : 'm4a';
    final saved = await FilesStore.instance.persistMedia(path, ext);
    await FilesStore.instance
        .add(name: 'บันทึกเสียง', type: 'เสียง', summary: text, uri: saved);
    _onSend(text);
  }

  /// Get the device GPS fix and hand it to ปิ่น as a turn so it can use it
  /// (e.g. อากาศแถวนี้, ร้านใกล้ฉัน).
  Future<void> _shareLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) PinToast.show(context, 'เปิด Location บนเครื่องก่อนนะคะ');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) PinToast.show(context, 'ขอสิทธิ์ตำแหน่งก่อนนะคะ');
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      final coords =
          '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';
      final userMsg = _text('📍 ตำแหน่งของฉัน ($coords)', me: true);
      await _run(userMsg,
          'นี่คือพิกัดปัจจุบันของฉัน: $coords ใช้ข้อมูลนี้ช่วยได้เลย '
          '(เช่น อากาศแถวนี้ หรือสิ่งที่อยู่ใกล้)');
    } catch (e) {
      if (mounted) PinToast.show(context, 'ดึงตำแหน่งไม่ได้: $e');
    }
  }

  /// Native camera with Text scan / Photo / Video tabs. Photos + scanned pages
  /// go to ปิ่น as images; a captured video isn't understandable on-device.
  Future<void> _nativeCamera() async {
    try {
      final res = await _cameraChannel.invokeMapMethod<String, dynamic>('open');
      if (res == null) return;
      final paths = (res['paths'] as List?)?.cast<String>();
      if (paths != null) {
        for (final p in paths) {
          await _sendImage(p);
        }
        return;
      }
      final path = res['path'] as String?;
      if (path == null) return;
      if (res['isVideo'] == true) {
        if (mounted) {
          PinToast.show(context, 'ถ่ายวิดีโอได้ แต่${botName}ยังดูวิดีโอไม่ได้นะคะ');
        }
        return;
      }
      await _sendImage(path);
    } catch (_) {
      if (mounted) PinToast.show(context, 'เปิดกล้องไม่ได้');
    }
  }

  /// VisionKit document scanner → send each page to ปิ่น as an image. [prompt]
  /// lets a caller (e.g. the "สรุปเอกสาร" chip) ask ปิ่น to summarise + remember.
  Future<void> _scanDoc({String prompt = ''}) async {
    try {
      final res = await _cameraChannel.invokeMapMethod<String, dynamic>('scan');
      final paths = (res?['paths'] as List?)?.cast<String>() ?? const [];
      for (var i = 0; i < paths.length; i++) {
        // Only the first page carries the instruction.
        await _sendImage(paths[i],
            prompt: i == 0 ? prompt : '',
            label: paths.length > 1 ? 'เอกสารสแกน น.${i + 1}' : 'เอกสารสแกน');
      }
    } catch (_) {
      if (mounted) PinToast.show(context, 'สแกนเอกสารไม่ได้');
    }
  }

  /// Compress an image file and send it to the on-device agent (multimodal),
  /// optionally with an instruction (e.g. "ช่วยสรุปเอกสารนี้").
  Future<void> _sendImage(String srcPath,
      {String prompt = '', String label = 'รูปภาพ'}) async {
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/pin_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final c = await FlutterImageCompress.compressAndGetFile(srcPath, out,
        quality: 80, minWidth: 1280, minHeight: 1280);
    final path = c?.path ?? srcPath;
    // Persist a durable copy first (temp dir gets purged by iOS) and use it
    // everywhere — the chat bubble, the agent turn, and the "ไฟล์" tab — so the
    // photo still renders after the app is closed and reopened.
    final saved = await FilesStore.instance.persistMedia(path, 'jpg');
    // [saved] is relative; the live bubble + the model need an absolute path.
    final abs = await FilesStore.instance.absPath(saved);
    final msg = ChatViewMessage(
      eventId: 'm${_seq++}', sender: '@me', body: prompt, time: DateTime.now(),
      isMe: true, kind: 'image', localPath: abs,
    );
    final r =
        await _run(msg, prompt, imagePath: abs, imageRecordPath: saved);
    await FilesStore.instance.add(
      name: label,
      type: 'รูป',
      summary: r?.text?.trim() ?? '',
      uri: saved,
    );
  }

  // Flex button postback. A URL (news "อ่านต่อ →") opens externally; anything
  // else is a plain postback echoed for now.
  Future<void> _onFlexAction(String data) async {
    final uri = Uri.tryParse(data);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (mounted) PinToast.show(context, 'postback → $data');
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ChatScaffold(
          title: botName,
          encrypted: true,
          messages: _messages,
          botTyping: _botTyping,
          scroll: _scroll,
          replyTo: _replyTo,
          onSend: _onSend,
          onMedia: _onMedia,
          onSendAudio: _onAudio,
          onReply: (m) => setState(() => _replyTo = m),
          onCancelReply: () => setState(() => _replyTo = null),
          onReact: _onReact,
          onFlexAction: _onFlexAction,
          quickReplies: _quickReplies,
          onQuickReply: _onQuickReply,
          onOnboardAction: _handleOnboardTap,
        ),
        if (_loading != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _LoadingPill(_loading!),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// A quick-reply chip either sends its text or triggers an action (e.g. scan
  /// a document → ปิ่น summarises it).
  void _onQuickReply(Map<String, String> r) {
    if (_quickReplies.isNotEmpty) setState(() => _quickReplies = const []);
    switch (r['action']) {
      case 'scan':
        _scanDoc(
            prompt: r['send'] ?? 'ช่วยสรุปเอกสารนี้สั้น ๆ แล้วจำไว้ให้ด้วย');
      case 'image':
        _onMedia('image');
      case 'photo':
        _onMedia('camera');
      default:
        _onSend(r['send'] ?? r['label'] ?? '');
    }
  }
}

/// Small rounded status pill (spinner + text) shown at the top of the chat
/// while the DM session is coming up ("กำลังโหลดข้อความ…").
class _LoadingPill extends StatelessWidget {
  const _LoadingPill(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: scheme.primary),
            ),
            const SizedBox(width: 9),
            Text(text,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface)),
          ],
        ),
      ),
    );
  }
}
