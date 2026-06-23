import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../agent/agent_config.dart';
import '../agent/abilities.dart';
import '../agent/catalog_client.dart';
import '../theme/pin_theme.dart';
import '../services/matrix_service.dart';
import 'pin_toast.dart';

/// FluffyChat-style message composer:
/// attach (+) • growing multiline field • mic↔send swap • reply preview.
/// Emoji come from the system keyboard (no in-app picker).
class MessageComposer extends StatefulWidget {
  final ValueChanged<String> onSend;

  /// Picks media by id: 'file' | 'camera' | 'record_video' | 'image' | 'location'.
  final ValueChanged<String>? onMedia;

  /// Hold-to-record finished with a file at this path (.m4a) → send as audio.
  final ValueChanged<String>? onSendAudio;

  /// When replying, the snippet shown above the field (null = not replying).
  final String? replyToSender;
  final String? replyToBody;
  final VoidCallback? onCancelReply;
  final ValueChanged<bool>? onPanelToggled;

  const MessageComposer({
    super.key,
    required this.onSend,
    this.onMedia,
    this.onSendAudio,
    this.replyToSender,
    this.replyToBody,
    this.onCancelReply,
    this.onPanelToggled,
  });

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _recorder = AudioRecorder();
  bool _recording = false;
  Duration _recordElapsed = Duration.zero;
  Timer? _recordTimer;
  // While text present, action icons collapse to a "›" chevron; tap to re-expand.
  bool _expanded = false;
  // The "+" capabilities/tools panel above the bar (open on tap).
  bool _panelOpen = false;
  // Enabled catalog capability names — drives which capability badges show.
  Set<String> _catNames = {};

  bool get _hasText => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (_controller.text.isEmpty) _expanded = false;
      setState(() {});
    });
    // Focus collapses the icons too; blurring an empty field restores them.
    // Focusing the field also closes the "+" panel.
    _focus.addListener(() {
      if (!_focus.hasFocus && !_hasText) _expanded = false;
      if (_focus.hasFocus) _panelOpen = false;
      setState(() {});
    });
    _loadCaps();
    // Reload the panel when the user opts a capability in/out, so it stays in
    // sync with what ปิ่น can actually do.
    capabilitiesRevision.addListener(_loadCaps);
  }

  /// Learn which capabilities the catalog has enabled, so the panel only shows
  /// real ones (a disabled/coming-soon capability drops out). Best-effort.
  Future<void> _loadCaps() async {
    try {
      final roomId = await MatrixService.instance.pinRoomId();
      final optedOutRaw = roomId != null
          ? await MatrixService.instance
              .loadListFromRoom(roomId, 'io.tokens2.opted_out_capabilities')
          : [];
      final optedOut = optedOutRaw.map((e) => '${e['name']}').toSet();

      final m = await CatalogClient(devProxy()).fetchManifests();
      if (!mounted) return;
      setState(() {
        // Opt-out: show every catalog capability except the ones the user turned
        // off — matching what ปิ่น can actually do.
        _catNames = {
          for (final e in m)
            if (!optedOut.contains('${e['name']}')) '${e['name']}'
        };
      });
    } catch (_) {/* keep optimistic full list */}
  }

  @override
  void dispose() {
    capabilitiesRevision.removeListener(_loadCaps);
    _recordTimer?.cancel();
    _recorder.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (_panelOpen) setState(() => _panelOpen = false);
    widget.onSend(text);
    _controller.clear();
  }

  Future<void> _startRecord() async {
    if (!await _recorder.hasPermission()) {
      if (mounted) PinToast.show(context, 'ขอสิทธิ์ไมโครโฟนก่อนนะ');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/pin_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
    // WAV (PCM) — Gemini accepts audio/wav reliably for transcription.
    await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.wav), path: path);
    if (!mounted) return;
    setState(() {
      _recording = true;
      _recordElapsed = Duration.zero;
    });
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _recordElapsed += const Duration(seconds: 1));
    });
  }

  Future<void> _stopRecord({required bool send}) async {
    _recordTimer?.cancel();
    final path = await _recorder.stop();
    if (mounted) setState(() => _recording = false);
    if (path == null) return;
    if (send && _recordElapsed.inMilliseconds >= 800) {
      widget.onSendAudio?.call(path);
    } else {
      // Too short or cancelled — drop the temp file.
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Floating liquid-glass card, inset to line up with the chat bubbles and
    // lifted above the home indicator (the chat fills under it, blurring
    // through — no solid bar beneath).
    // Lift the card clear of the system nav bar (Android 3-button bar is a solid
    // ~48px; iOS/gesture pill is thinner) PLUS a small gap so it never touches.
    // viewPadding = the raw inset, never consumed by a SafeArea.
    // Sit at the very bottom: just clear of the system safe-area (home indicator
    // / nav bar) with a minimal gap — no extra float.
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottomInset.clamp(6, 80)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Solid lifted card (Claude-style): white surface, hairline edge, soft
          // drop shadow so it floats above the tinted screen instead of sinking in.
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: PinPalette.line),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x14282822),
                    blurRadius: 24,
                    offset: Offset(0, 8)),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.replyToBody != null) _replyPreview(scheme),
                _recording ? _recordRow(scheme) : _inputRow(scheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _replyPreview(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 6),
      child: Row(
        children: [
          Container(width: 3, height: 34, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'ตอบ ${widget.replyToSender ?? ''}',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                Text(
                  widget.replyToBody ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(PhosphorIconsLight.x, size: 20),
            onPressed: widget.onCancelReply,
          ),
        ],
      ),
    );
  }

  // Single-row composer: action icons • growing field • send/mic.
  // Typing collapses the icons to a "›" chevron; tap it to expand them again.
  Widget _inputRow(ColorScheme scheme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _leadingActions(scheme),
        const SizedBox(width: 6),
        Expanded(
          // Field box ≈ button height (36) so the centred row sits symmetric.
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            minLines: 1,
            maxLines: 6,
            textInputAction: TextInputAction.newline,
            style: const TextStyle(fontSize: 15, height: 1.35),
            decoration: const InputDecoration(
              hintText: 'พิมพ์ข้อความ…',
              border: InputBorder.none,
              isCollapsed: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 2, vertical: 9),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _sendOrMic(scheme),
      ],
    );
  }

  // Collapsed (text present, not expanded) → single "›" chevron.
  // Otherwise → the +/camera/image cluster.
  Widget _leadingActions(ColorScheme scheme) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      transitionBuilder: (child, anim) => SizeTransition(
        sizeFactor: anim,
        axis: Axis.horizontal,
        axisAlignment: -1,
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: ((_focus.hasFocus || _hasText) && !_expanded)
          ? _roundBtn(PhosphorIconsLight.caretRight, 'เพิ่มเติม',
              () => setState(() => _expanded = true), scheme,
              key: const ValueKey('more'))
          : Row(
              key: const ValueKey('icons'),
              mainAxisSize: MainAxisSize.min,
              children: [
                _roundBtn(PhosphorIconsLight.plus, 'เพิ่ม', _openSheet, scheme),
                const SizedBox(width: 6),
                _roundBtn(PhosphorIconsLight.camera, 'กล้อง',
                    () => widget.onMedia?.call('camera'), scheme),
                const SizedBox(width: 6),
                _roundBtn(PhosphorIconsLight.image, 'รูปภาพ',
                    () => widget.onMedia?.call('image'), scheme),
              ],
            ),
    );
  }

  /// Capability badges in the "+" panel. Each: (catalog names, icon, label,
  /// starter prompt). Tapping one sends the starter so ปิ่น begins that task
  /// (and asks for any details). A capability shows only if one of its [names]
  /// is enabled in the catalog; an empty [names] = on-device built-in (always
  /// on). See design/chat-compose/plus-capabilities.html.
  static const _capSpecs = <(List<String>, IconData, String, String)>[
    (['consult_astrologer', 'fortune'], PhosphorIconsLight.sparkle, 'ดูดวง',
        'ขอดูดวงหน่อย'),
    (['news_reporter', 'morning_news'], PhosphorIconsLight.newspaper, 'ข่าว',
        'สรุปข่าวให้หน่อย'),
    (['get_weather'], PhosphorIconsLight.cloudSun, 'อากาศ', 'ขอดูพยากรณ์อากาศ'),
    (['web_search'], PhosphorIconsLight.globe, 'ค้นเว็บ',
        'ช่วยค้นข้อมูลในเว็บให้หน่อย'),
    (['get_currency'], PhosphorIconsLight.coins, 'แลกเงิน',
        'ขอดูอัตราแลกเปลี่ยน'),
    (['generate_image'], PhosphorIconsLight.image, 'วาดรูป',
        'ช่วยวาดรูปให้หน่อย'),
    (<String>[], PhosphorIconsLight.bell, 'ตั้งเวลา',
        'ช่วยตั้งเตือนหรือตั้งตารางเวลาประจำให้หน่อย'),
    (['joke'], PhosphorIconsLight.smiley, 'เล่ามุก', 'เล่ามุกให้ฟังหน่อย'),
  ];

  /// Device tools (always available): (id for onMedia, icon, label).
  static const _toolSpecs = <(String, IconData, String)>[
    ('file', PhosphorIconsLight.paperclip, 'แนบไฟล์'),
    ('location', PhosphorIconsLight.mapPin, 'แชร์โลเคชั่น'),
    ('scan', PhosphorIconsLight.scan, 'สแกนเอกสาร'),
  ];

  /// Visible capabilities: built-ins + any catalog-enabled. Before the catalog
  /// loads (empty set) show all — optimistic, avoids an empty first open.
  List<(List<String>, IconData, String, String)> get _visibleCaps =>
      _catNames.isEmpty
          ? _capSpecs
          : [
              for (final s in _capSpecs)
                if (s.$1.isEmpty || s.$1.any(_catNames.contains)) s
            ];

  void _runCap(String prompt) {
    setState(() => _panelOpen = false);
    widget.onPanelToggled?.call(false);
    widget.onSend(prompt);
  }

  void _runTool(String id) {
    setState(() => _panelOpen = false);
    widget.onPanelToggled?.call(false);
    widget.onMedia?.call(id);
  }

  // ----- "+" sheet ----------------------------------------------------------

  /// The "+" opens a bottom sheet (slides up like the photo picker) with the
  /// capabilities + tools laid out as an icon grid.
  void _openSheet() {
    FocusScope.of(context).unfocus();
    widget.onPanelToggled?.call(true);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _capSheet(),
    ).whenComplete(() => widget.onPanelToggled?.call(false));
  }

  Widget _capSheet() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 34,
                height: 4,
                margin: const EdgeInsets.fromLTRB(0, 11, 0, 20),
                decoration: BoxDecoration(
                    color: const Color(0xFFE6E3DA),
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            _sheetLabel('ความสามารถ'),
            _capScroll([
              for (final (_, icon, label, prompt) in _visibleCaps)
                _pill(icon, label, () {
                  Navigator.pop(context);
                  _runCap(prompt);
                }),
            ]),
            const Padding(
              padding: EdgeInsets.fromLTRB(26, 18, 26, 18),
              child: Divider(height: 1, color: PinPalette.line),
            ),
            _sheetLabel('เครื่องมือ'),
            _capScroll([
              for (final (id, icon, label) in _toolSpecs)
                _pill(icon, label, () {
                  Navigator.pop(context);
                  _runTool(id);
                }),
            ]),
            const SizedBox(height: 22),
          ],
        ),
      ),
    );
  }

  Widget _sheetLabel(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(26, 0, 26, 14),
        child: Text(t,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.2,
                color: PinPalette.ink3)),
      );

  // Horizontal scroll row of pills (design .capgrid). Clip.none so the soft
  // shadow under each pill isn't clipped at the row edge.
  Widget _capScroll(List<Widget> pills) => SizedBox(
        height: 46,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          itemCount: pills.length,
          separatorBuilder: (_, _) => const SizedBox(width: 11),
          itemBuilder: (_, i) => pills[i],
        ),
      );

  /// Design `.cap` pill — soft pale fill + hairline border so it reads as a
  /// distinct chip on the white sheet (pure white blended in), icon + label.
  Widget _pill(IconData icon, String label, VoidCallback onTap) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF7F5EF), // faint warm fill, pops on white
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: PinPalette.line),
          boxShadow: const [
            BoxShadow(
                color: Color(0x14362E20), blurRadius: 8, offset: Offset(0, 3)),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(19),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 11),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 19, color: const Color(0xFF5B5950)),
                  const SizedBox(width: 9),
                  Text(label,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: PinPalette.ink)),
                ],
              ),
            ),
          ),
        ),
      );

  /// Soft pale-grey circle with a dark glyph (Claude-style) — visible but quiet.
  /// [active] fills it with the brand colour + a 45° turn (used by the "+" when
  /// its panel is open, so the glyph reads as a close affordance).
  static const _btnBg = Color(0xFFF1EEE7);
  Widget _roundBtn(
      IconData icon, String tip, VoidCallback? onTap, ColorScheme scheme,
      {Key? key, bool active = false}) {
    return Material(
      key: key,
      color: active ? scheme.primary : _btnBg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 36,
          height: 36,
          child: AnimatedRotation(
            turns: active ? 0.125 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(icon,
                size: 19, color: active ? Colors.white : PinPalette.ink),
          ),
        ),
      ),
    );
  }

  Widget _sendOrMic(ColorScheme scheme) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      transitionBuilder: (child, anim) =>
          ScaleTransition(scale: anim, child: child),
      child: _hasText
          ? _circle(
              key: const ValueKey('send'),
              icon: PhosphorIconsLight.arrowUp,
              bg: scheme.primary,
              fg: Colors.white,
              onTap: _send,
            )
          : GestureDetector(
              key: const ValueKey('mic'),
              onLongPress: () => _startRecord(),
              onLongPressUp: () => _stopRecord(send: true),
              child: _circle(
                icon: PhosphorIconsLight.microphone,
                bg: _btnBg,
                fg: PinPalette.ink,
                onTap: () =>
                    PinToast.show(context, 'กดค้างที่ไมค์เพื่ออัดเสียง'),
              ),
            ),
    );
  }

  Widget _circle(
      {Key? key,
      required IconData icon,
      required Color bg,
      required Color fg,
      required VoidCallback onTap}) {
    return Material(
      key: key,
      color: bg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
            width: 36, height: 36, child: Icon(icon, size: 18, color: fg)),
      ),
    );
  }

  Widget _recordRow(ColorScheme scheme) {
    final m = _recordElapsed.inMinutes.toString().padLeft(2, '0');
    final s = (_recordElapsed.inSeconds % 60).toString().padLeft(2, '0');
    return Row(
      children: [
        const SizedBox(width: 8),
        Icon(PhosphorIconsLight.circle, color: scheme.error, size: 16),
        const SizedBox(width: 8),
        Text('$m:$s'),
        const SizedBox(width: 12),
        const Expanded(child: Text('ปัดเพื่อยกเลิก', style: TextStyle(color: PinPalette.ink2))),
        TextButton(
          onPressed: () => _stopRecord(send: false),
          child: const Text('ยกเลิก'),
        ),
        IconButton.filled(
          icon: const Icon(PhosphorIconsLight.paperPlaneTilt),
          onPressed: () => _stopRecord(send: true),
        ),
      ],
    );
  }
}
