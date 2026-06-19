import 'dart:convert';

import '../src/rust/api/matrix.dart';

/// UI-side message model. Wraps the Rust [ChatMessage] and adds presentation
/// fields (reactions, reply context) that the backend will fill in later.
class ChatViewMessage {
  final String roomId;
  final String eventId;
  final String sender;
  final String body;
  final DateTime time;
  final bool isMe;

  /// "text" | "image" | "file" | "audio" | "video"
  final String kind;

  /// mxc:// URL for media kinds.
  final String? mediaUrl;

  /// On-device local file path for an image (E2EE chat — no Matrix download).
  final String? localPath;

  /// ปิ่น Flex card spec (io.tokens2.flex), when this message is a rich card.
  final Map<String, dynamic>? flex;

  /// emoji -> count
  final Map<String, int> reactions;

  /// The event this one replies to (raw id) + resolved snippet.
  final String? replyToEventId;
  final String? replyToSender;
  final String? replyToBody;

  /// "ใช้ความสามารถ" hint under a ปิ่น reply, e.g. "ใช้: พยากรณ์อากาศ".
  final String? hint;

  /// This reply added something to the "ตอนนี้" panel (reminder/job/knowledge).
  final bool addedToNow;

  /// Debug-bot trace (tool calls + results) — shown only when debug is on.
  final List<String>? debug;

  const ChatViewMessage({
    this.roomId = '',
    required this.eventId,
    required this.sender,
    required this.body,
    required this.time,
    required this.isMe,
    this.kind = 'text',
    this.mediaUrl,
    this.localPath,
    this.flex,
    this.reactions = const {},
    this.replyToEventId,
    this.replyToSender,
    this.replyToBody,
    this.hint,
    this.addedToNow = false,
    this.debug,
  });

  factory ChatViewMessage.fromRust(ChatMessage m) => ChatViewMessage(
        roomId: m.roomId,
        eventId: m.eventId,
        sender: m.sender,
        body: m.body,
        time: DateTime.fromMillisecondsSinceEpoch(m.timestampMs.toInt()),
        isMe: m.isMe,
        kind: m.kind,
        mediaUrl: m.mediaUrl,
        flex: _parseFlex(m.flexJson),
        replyToEventId: m.replyToEventId,
      );

  static Map<String, dynamic>? _parseFlex(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final v = jsonDecode(json);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  ChatViewMessage copyWith({
    Map<String, int>? reactions,
    String? replyToSender,
    String? replyToBody,
  }) =>
      ChatViewMessage(
        roomId: roomId,
        eventId: eventId,
        sender: sender,
        body: body,
        time: time,
        isMe: isMe,
        kind: kind,
        mediaUrl: mediaUrl,
        localPath: localPath,
        flex: flex,
        reactions: reactions ?? this.reactions,
        replyToEventId: replyToEventId,
        replyToSender: replyToSender ?? this.replyToSender,
        replyToBody: replyToBody ?? this.replyToBody,
        hint: hint,
        addedToNow: addedToNow,
      );

  /// Short display name from a Matrix id like `@alice:server` -> `alice`.
  String get senderName {
    final s = sender.startsWith('@') ? sender.substring(1) : sender;
    final colon = s.indexOf(':');
    return colon == -1 ? s : s.substring(0, colon);
  }
}
