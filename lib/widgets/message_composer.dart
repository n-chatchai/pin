import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../theme/pin_theme.dart';
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

  const MessageComposer({
    super.key,
    required this.onSend,
    this.onMedia,
    this.onSendAudio,
    this.replyToSender,
    this.replyToBody,
    this.onCancelReply,
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

  bool get _hasText => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (_controller.text.isEmpty) _expanded = false;
      setState(() {});
    });
    // Focus collapses the icons too; blurring an empty field restores them.
    _focus.addListener(() {
      if (!_focus.hasFocus && !_hasText) _expanded = false;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _recorder.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
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
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottomInset.clamp(0, 80) + 10),
      // Solid lifted card (Claude-style): white surface, hairline edge, soft
      // drop shadow so it floats above the tinted screen instead of sinking in.
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: PinPalette.line),
          boxShadow: const [
            BoxShadow(
                color: Color(0x14282822), blurRadius: 24, offset: Offset(0, 8)),
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
                _roundBtn(PhosphorIconsLight.plus, 'เพิ่ม', _plusMenu, scheme),
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

  /// Curated capabilities shown in the "+" sheet. Tapping one sends a starter
  /// message so ปิ่น kicks off that task (and asks for any details it needs).
  /// (icon, label, starter prompt). See design/chat-compose/plus-capabilities.html.
  static const _caps = <(IconData, String, String)>[
    (PhosphorIconsRegular.sparkle, 'ดูดวง', 'ขอดูดวงหน่อย'),
    (PhosphorIconsRegular.newspaper, 'ข่าวเช้า', 'สรุปข่าวเช้าให้หน่อย'),
    (PhosphorIconsRegular.magnifyingGlass, 'ค้นเชิงลึก',
        'ช่วยค้นข้อมูลเชิงลึกให้หน่อย'),
    (PhosphorIconsRegular.cloudSun, 'อากาศ', 'ขอดูพยากรณ์อากาศ'),
    (PhosphorIconsRegular.bell, 'ตั้งเตือน', 'ช่วยตั้งเตือนหน่อย'),
    (PhosphorIconsRegular.imageSquare, 'วาดรูป', 'ช่วยวาดรูปให้หน่อย'),
    (PhosphorIconsRegular.link, 'ย่อลิงก์', 'ช่วยย่อลิงก์นี้ให้หน่อย'),
  ];

  /// "+" button → capabilities grid + attachments (design variant A).
  void _plusMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: PinPalette.cream,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheet) {
        // 4 tiles per row: (sheet width − outer padding − 3 gaps) / 4.
        final tileW = (MediaQuery.of(sheet).size.width - 28 - 24) / 4;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sheetHead('ความสามารถ'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (icon, label, prompt) in _caps)
                      _CapTile(
                          icon: icon,
                          label: label,
                          width: tileW,
                          onTap: () {
                            Navigator.pop(sheet);
                            widget.onSend(prompt);
                          }),
                  ],
                ),
                const SizedBox(height: 18),
                _sheetHead('แนบไฟล์'),
                Row(children: [
                  _AttachTile(
                      icon: PhosphorIconsLight.camera,
                      label: 'กล้อง',
                      onTap: () => _pickMedia(sheet, 'camera')),
                  const SizedBox(width: 10),
                  _AttachTile(
                      icon: PhosphorIconsLight.image,
                      label: 'รูปภาพ',
                      onTap: () => _pickMedia(sheet, 'image')),
                  const SizedBox(width: 10),
                  _AttachTile(
                      icon: PhosphorIconsLight.videoCamera,
                      label: 'วิดีโอ',
                      onTap: () => _pickMedia(sheet, 'video')),
                ]),
                const SizedBox(height: 12),
                _AttachGroup(children: [
                  _AttachRow(
                      icon: PhosphorIconsLight.paperclip,
                      label: 'เพิ่มไฟล์',
                      onTap: () => _pickMedia(sheet, 'file')),
                  _AttachRow(
                      icon: PhosphorIconsLight.scan,
                      label: 'สแกนเอกสาร',
                      onTap: () => _pickMedia(sheet, 'scan')),
                  _AttachRow(
                      icon: PhosphorIconsLight.mapPin,
                      label: 'แชร์ตำแหน่ง',
                      onTap: () => _pickMedia(sheet, 'location')),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }

  void _pickMedia(BuildContext sheet, String id) {
    Navigator.pop(sheet);
    widget.onMedia?.call(id);
  }

  Widget _sheetHead(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: .5,
                color: PinPalette.ink3)),
      );

  /// Soft pale-grey circle with a dark glyph (Claude-style) — visible but quiet.
  static const _btnBg = Color(0xFFF1EEE7);
  Widget _roundBtn(
      IconData icon, String tip, VoidCallback? onTap, ColorScheme scheme,
      {Key? key}) {
    return Material(
      key: key,
      color: _btnBg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, size: 19, color: PinPalette.ink),
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

/// A capability tile in the "+" sheet: rounded green icon + Thai label.
class _CapTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final double width;
  final VoidCallback onTap;
  const _CapTile(
      {required this.icon,
      required this.label,
      required this.width,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF34B06A).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 21, color: const Color(0xFF1C7A48)),
                ),
                const SizedBox(height: 7),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: PinPalette.ink)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AttachTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _AttachTile(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: SizedBox(
            height: 92,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 26, color: PinPalette.ink),
                const SizedBox(height: 8),
                Text(label,
                    style: const TextStyle(fontSize: 13, color: PinPalette.ink)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AttachGroup extends StatelessWidget {
  final List<Widget> children;
  const _AttachGroup({required this.children});
  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(const Divider(height: 1, indent: 52, color: PinPalette.line));
      }
      rows.add(children[i]);
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: rows),
    );
  }
}

class _AttachRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _AttachRow(
      {required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: PinPalette.ink),
      title: Text(label, style: const TextStyle(color: PinPalette.ink)),
      onTap: onTap,
    );
  }
}
