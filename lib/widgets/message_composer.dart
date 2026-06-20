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

  bool get _hasText => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
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
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
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

  // Claude-style two-row composer: text on top, action buttons below.
  Widget _inputRow(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
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
              contentPadding: EdgeInsets.symmetric(vertical: 4),
            ),
          ),
        ),
        Row(
          children: [
            _roundBtn(PhosphorIconsLight.plus, 'เพิ่ม', _plusMenu, scheme),
            const SizedBox(width: 8),
            _roundBtn(PhosphorIconsLight.camera, 'กล้อง',
                () => widget.onMedia?.call('camera'), scheme),
            const SizedBox(width: 8),
            _roundBtn(PhosphorIconsLight.image, 'รูปภาพ',
                () => widget.onMedia?.call('image'), scheme),
            const Spacer(),
            _sendOrMic(scheme),
          ],
        ),
      ],
    );
  }

  /// "+" button → choose a file or share location.
  void _plusMenu() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(PhosphorIconsLight.paperclip),
              title: const Text('เลือกไฟล์'),
              onTap: () {
                Navigator.pop(sheet);
                widget.onMedia?.call('file');
              },
            ),
            ListTile(
              leading: const Icon(PhosphorIconsLight.scan),
              title: const Text('สแกนเอกสาร'),
              onTap: () {
                Navigator.pop(sheet);
                widget.onMedia?.call('scan');
              },
            ),
            ListTile(
              leading: const Icon(PhosphorIconsLight.mapPin),
              title: const Text('แชร์ตำแหน่ง'),
              onTap: () {
                Navigator.pop(sheet);
                widget.onMedia?.call('location');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Soft pale-grey circle with a dark glyph (Claude-style) — visible but quiet.
  static const _btnBg = Color(0xFFF1EEE7);
  Widget _roundBtn(
      IconData icon, String tip, VoidCallback? onTap, ColorScheme scheme) {
    return Material(
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

/// "เพิ่มลงแชต" sheet (Claude-style): a Camera/รูป/วิดีโอ tile row on top, then
/// grouped rounded cards. `onPick` gets the chosen id ('camera'|'image'|'video'|
/// 'record_video'|'file'); the caller wires the real action.
Future<void> showAttachmentSheet(
  BuildContext context, {
  ValueChanged<String>? onPick,
}) {
  void pick(BuildContext c, String id) {
    Navigator.pop(c);
    onPick?.call(id);
  }

  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: PinPalette.cream,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text('เพิ่มลงแชต', style: PinPalette.brand(size: 18)),
            ),
            // Top tile row.
            Row(
              children: [
                _AttachTile(
                    icon: PhosphorIconsLight.camera,
                    label: 'กล้อง',
                    onTap: () => pick(c, 'camera')),
                const SizedBox(width: 10),
                _AttachTile(
                    icon: PhosphorIconsLight.image,
                    label: 'รูปภาพ',
                    onTap: () => pick(c, 'image')),
                const SizedBox(width: 10),
                _AttachTile(
                    icon: PhosphorIconsLight.videoCamera,
                    label: 'วิดีโอ',
                    onTap: () => pick(c, 'video')),
              ],
            ),
            const SizedBox(height: 14),
            // Grouped card.
            _AttachGroup(children: [
              _AttachRow(
                  icon: PhosphorIconsLight.paperclip,
                  label: 'เพิ่มไฟล์',
                  onTap: () => pick(c, 'file')),
              _AttachRow(
                  icon: PhosphorIconsLight.videoCamera,
                  label: 'ถ่ายวิดีโอ',
                  onTap: () => pick(c, 'record_video')),
              _AttachRow(
                  icon: PhosphorIconsLight.mapPin,
                  label: 'แชร์ตำแหน่ง',
                  onTap: () => pick(c, 'location')),
            ]),
          ],
        ),
      ),
    ),
  );
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
