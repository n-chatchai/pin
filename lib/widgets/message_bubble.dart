import 'dart:io';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:flutter/services.dart';

import '../models/chat_view_message.dart';
import '../services/matrix_service.dart';
import '../services/prefs.dart';
import '../services/pin_export.dart';
import '../theme/pin_theme.dart';
import 'flex_card_view.dart';

/// FluffyChat-style message bubble: tail, reply context, reactions row,
/// swipe-to-reply, and a long-press action menu.
class MessageBubble extends StatelessWidget {
  final ChatViewMessage msg;
  final bool showSender; // first in a group from this sender
  final ValueChanged<ChatViewMessage>? onReply;
  final void Function(ChatViewMessage, String emoji)? onReact;
  final ValueChanged<String>? onFlexAction;

  const MessageBubble({
    super.key,
    required this.msg,
    this.showSender = true,
    this.onReply,
    this.onReact,
    this.onFlexAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = msg.isMe;
    // ปิ่น's replies read cleaner with no box (Claude-style) — they blend into
    // the cream background; only the user's own messages get a coloured bubble.
    final bubbleColor = mine ? scheme.primary : Colors.transparent;
    final textColor = mine ? scheme.onPrimary : scheme.onSurface;
    // Images render bare (no bubble) — a rounded photo, not a photo-in-a-box.
    final isMedia = msg.flex == null && msg.kind == 'image';

    return Dismissible(
      key: ValueKey(msg.eventId),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (_) async {
        onReply?.call(msg);
        return false; // never actually dismiss; swipe = reply gesture
      },
      background: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Icon(PhosphorIconsRegular.arrowBendUpLeft, color: scheme.primary),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
          mainAxisAlignment:
              mine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: GestureDetector(
                onLongPress: () => _showActions(context),
                child: Column(
                  crossAxisAlignment:
                      mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    if (msg.flex != null)
                      // Wrapped so export can snapshot the rendered card to PNG.
                      RepaintBoundary(
                        key: PinExport.keyFor(msg.eventId),
                        child:
                            FlexCardView(spec: msg.flex!, onAction: onFlexAction),
                      )
                    else if (isMedia)
                      // Bare rounded photo — no coloured box around it.
                      Column(
                        crossAxisAlignment: mine
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          if (msg.replyToBody != null)
                            _replyContext(scheme, scheme.onSurface),
                          _imageView(context),
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              _hhmm(msg.time),
                              style: const TextStyle(
                                  fontSize: 10, color: PinPalette.ink2),
                            ),
                          ),
                        ],
                      )
                    else
                    Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width *
                            (mine ? 0.72 : 0.95),
                      ),
                      padding: EdgeInsets.symmetric(
                          horizontal: mine ? 12 : 0, vertical: mine ? 8 : 0),
                      decoration: BoxDecoration(
                        color: bubbleColor,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(16),
                          topRight: const Radius.circular(16),
                          bottomLeft: Radius.circular(mine ? 16 : 4),
                          bottomRight: Radius.circular(mine ? 4 : 16),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 1:1 chat with ปิ่น — no sender name label in bubbles.
                          if (msg.replyToBody != null)
                            _replyContext(scheme, textColor),
                          if (msg.kind == 'text')
                            GptMarkdown(msg.body,
                                style: TextStyle(color: textColor, fontSize: 14))
                          else
                            _mediaChip(textColor),
                          // ปิ่น's time + hint go in the full-width footer below;
                          // the user keeps their time inside their own bubble.
                          if (mine) ...[
                            const SizedBox(height: 2),
                            Text(_hhmm(msg.time),
                                style: TextStyle(
                                    fontSize: 10,
                                    color: textColor.withValues(alpha: 0.6))),
                          ],
                        ],
                      ),
                    ),
                    if (msg.reactions.isNotEmpty) _reactions(context, scheme),
                  ],
                ),
              ),
            ),
          ],
        ),
            if (!mine) _footer(context, scheme),
            if (!mine && msg.debug != null && msg.debug!.isNotEmpty)
              _debugTrace(scheme),
            // Debug: show the Matrix event id under each bubble so we can tell
            // real DM events from optimistic/local renders while diagnosing.
            if (PrefsController.instance.value.debugBot)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Align(
                  alignment:
                      mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: SelectableText(
                    msg.eventId,
                    style: const TextStyle(
                        fontSize: 9,
                        fontFamily: 'monospace',
                        color: PinPalette.ink3),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Debug-bot trace: the agent's tool-call steps, monospace, under the reply.
  Widget _debugTrace(ColorScheme scheme) => Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1F2421),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(PhosphorIconsRegular.bug, size: 13, color: scheme.primary),
              const SizedBox(width: 6),
              const Text('debug',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF9FE6BF))),
            ]),
            const SizedBox(height: 6),
            for (final line in msg.debug!)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: SelectableText(line,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.4,
                        color: Color(0xFFD7E8DE))),
              ),
          ],
        ),
      );

  /// ปิ่น footer: time on the left, capability hint ("✨ ใช้: …") on the right.
  /// ปิ่น footer below the bubble/card: fixed-width row (matches the bubble
  /// area) so time sits left and the capability hint is pinned to the right —
  /// consistent for text and flex.
  Widget _footer(BuildContext context, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(top: 4, left: 2, right: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_hhmm(msg.time),
                  style: const TextStyle(fontSize: 10, color: PinPalette.ink3)),
              if (msg.cost != null) ...[
                const SizedBox(width: 6),
                Icon(PhosphorIconsRegular.coins, size: 11, color: PinPalette.ink3),
                const SizedBox(width: 3),
                Text(msg.cost!,
                    style: const TextStyle(fontSize: 10, color: PinPalette.ink3)),
              ],
            ]),
            if (msg.addedToNow || msg.hint != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (msg.addedToNow) ...[
                    Icon(PhosphorIconsRegular.listPlus, size: 12, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text('เพิ่มใน ตอนนี้',
                        style:
                            TextStyle(fontSize: 11, color: scheme.primary)),
                  ],
                  if (msg.addedToNow && msg.hint != null)
                    const SizedBox(width: 12),
                  if (msg.hint != null) ...[
                    Icon(PhosphorIconsRegular.sparkle, size: 12, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text(msg.hint!,
                        style: const TextStyle(
                            fontSize: 11, color: PinPalette.ink2)),
                  ],
                ],
              ),
          ],
        ),
      );

  Widget _imageView(BuildContext context) {
    // On-device chat: render straight from the local file (no Matrix download).
    if (msg.localPath != null) {
      return _thumb(context, msg.localPath!);
    }
    return FutureBuilder<String>(
      future: MatrixService.instance.downloadMedia(msg.roomId, msg.eventId),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
            width: 180,
            height: 140,
            child: Center(
                child: SizedBox(
                    width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        if (!snap.hasData) return _mediaChip(Colors.white);
        return _thumb(context, snap.data!);
      },
    );
  }

  /// A capped, rounded thumbnail; tap → fullscreen pinch-zoom viewer.
  Widget _thumb(BuildContext context, String path) => GestureDetector(
        onTap: () => _openFull(context, path),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240, maxHeight: 280),
            child: Image.file(File(path), fit: BoxFit.cover),
          ),
        ),
      );

  void _openFull(BuildContext context, String path) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (_) => GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: InteractiveViewer(
          child: Center(child: Image.file(File(path))),
        ),
      ),
    );
  }

  Widget _mediaChip(Color textColor) {
    final icon = switch (msg.kind) {
      'image' => PhosphorIconsRegular.image,
      'video' => PhosphorIconsRegular.videoCamera,
      'audio' => PhosphorIconsRegular.microphone,
      _ => PhosphorIconsRegular.file,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: textColor),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            msg.body.isEmpty ? msg.kind : msg.body,
            style: TextStyle(color: textColor),
            softWrap: true,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _replyContext(ColorScheme scheme, Color textColor) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            msg.replyToSender ?? '',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 11,
              color: textColor,
            ),
          ),
          Text(
            msg.replyToBody ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.8)),
          ),
        ],
      ),
    );
  }

  Widget _reactions(BuildContext context, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        children: [
          for (final entry in msg.reactions.entries)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Text('${entry.key} ${entry.value}',
                  style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  for (final e in ['👍', '❤️', '😂', '😮', '😢', '🙏'])
                    Expanded(
                      child: IconButton(
                        icon: Text(e, style: const TextStyle(fontSize: 24)),
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          onReact?.call(msg, e);
                        },
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(PhosphorIconsRegular.arrowBendUpLeft),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(sheetContext);
                onReply?.call(msg);
              },
            ),
            ListTile(
              leading: const Icon(PhosphorIconsRegular.copy),
              title: const Text('Copy'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: msg.body));
                Navigator.pop(sheetContext);
              },
            ),
            if (PinExport.canShare(msg))
              ListTile(
                leading: const Icon(PhosphorIconsRegular.shareNetwork),
                title: const Text('แชร์ / บันทึก'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  PinExport.share(msg);
                },
              ),
            if (msg.isMe)
              ListTile(
                leading: const Icon(PhosphorIconsRegular.pencilSimple),
                title: const Text('Edit'),
                onTap: () => Navigator.pop(sheetContext),
              ),
            if (msg.isMe)
              ListTile(
                leading: const Icon(PhosphorIconsRegular.trash),
                title: const Text('Delete'),
                textColor: Theme.of(context).colorScheme.error,
                iconColor: Theme.of(context).colorScheme.error,
                onTap: () => Navigator.pop(sheetContext),
              ),
          ],
        ),
      ),
    );
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// A centered day separator chip, FluffyChat-style.
class DateDivider extends StatelessWidget {
  final DateTime date;
  const DateDivider({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
                color: Color(0x14282822), blurRadius: 10, offset: Offset(0, 2)),
          ],
        ),
        child: Text(
          label(date),
          style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: PinPalette.ink2),
        ),
      ),
    );
  }

  static const _months = [
    'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.',
    'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.',
  ];

  static String label(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'วันนี้';
    if (diff == 1) return 'เมื่อวาน';
    return '${d.day} ${_months[d.month - 1]} ${d.year + 543}';
  }
}
