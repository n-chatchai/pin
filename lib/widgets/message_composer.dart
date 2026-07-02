import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../theme/pin_theme.dart';
import 'liquid_glass.dart';
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
  // The "+" attach popover above the bar (open on tap).
  bool _panelOpen = false;
  // Live-tracks the "+" button so the popover stays glued above it even while
  // the composer slides (keyboard dismiss) — no manual coordinate maths.
  final _link = LayerLink();
  OverlayEntry? _attachEntry;

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
  }

  @override
  void dispose() {
    _attachEntry?.remove();
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
              // No warm tan hairline — clean white pill, soft shadow only.
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
                CompositedTransformTarget(
                  link: _link,
                  child: _roundBtn(
                      PhosphorIconsLight.plus, 'เพิ่ม', _openAttach, scheme),
                ),
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

  /// Attach options (id for onMedia, icon, label). Ditto-style: a short
  /// vertical list, not a grid. File + Location for now; more added later.
  static const _attachSpecs = <(String, IconData, String)>[
    ('file', PhosphorIconsLight.paperclip, 'แนบไฟล์'),
    ('location', PhosphorIconsLight.mapPin, 'แชร์โลเคชั่น'),
  ];

  // ----- "+" attach popover -------------------------------------------------

  /// The "+" opens a frosted glass popover glued just above the button
  /// (Ditto-style) via a LayerLink follower, so it tracks the button live and
  /// never lands mid-screen or covers the composer.
  void _openAttach() {
    FocusScope.of(context).unfocus();
    setState(() => _panelOpen = true);
    widget.onPanelToggled?.call(true);
    _attachEntry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // Tap outside to dismiss.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeAttach,
            ),
          ),
          // Popover's bottom-left corner sits 6px above the button's top-left —
          // grows up out of the "+", clear of the composer.
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topLeft,
            followerAnchor: Alignment.bottomLeft,
            // dx -8: shift left so the panel edge lines up with the composer
            // card (button sits 8px inside the card). dy -16: lift clear above
            // the composer so it never overlaps.
            offset: const Offset(-8, -16),
            child: _attachPopover(),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_attachEntry!);
  }

  void _closeAttach() {
    _attachEntry?.remove();
    _attachEntry = null;
    if (mounted) setState(() => _panelOpen = false);
    widget.onPanelToggled?.call(false);
  }

  // Anchored to the "+" at its bottom-left: top + right corners round big, the
  // bottom-left stays tight so the panel reads as growing out of the button
  // (iOS context-menu style).
  static const _popRadius = BorderRadius.only(
    topLeft: Radius.circular(22),
    topRight: Radius.circular(22),
    bottomRight: Radius.circular(22),
    bottomLeft: Radius.circular(6),
  );

  Widget _attachPopover() {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 210, maxWidth: 264),
      child: LiquidGlass(
        borderRadius: _popRadius,
        blur: 32,
        // Bright, near-white tint with almost no colour pop: over the flat
        // green/cream chat, vibrancy just muddies to grey — keep it clean.
        opacity: 0.88,
        saturation: 1.0,
        // No tan hairline (Ditto's popover is borderless — soft shadow only).
        borderColor: Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 4),
        // Material gives the rows a proper DefaultTextStyle (without it, Text in
        // a raw OverlayEntry falls back to the yellow-underline debug style) and
        // hosts the InkWell splashes.
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (id, icon, label) in _attachSpecs)
                _attachRow(icon, label, () {
                  _closeAttach();
                  widget.onMedia?.call(id);
                }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attachRow(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 22, color: PinPalette.ink),
            const SizedBox(width: 14),
            Text(label,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                    color: PinPalette.ink)),
          ],
        ),
      ),
    );
  }


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
          width: 40,
          height: 40,
          child: AnimatedRotation(
            turns: active ? 0.125 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(icon,
                size: 22, color: active ? Colors.white : PinPalette.ink),
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
            width: 40, height: 40, child: Icon(icon, size: 21, color: fg)),
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
