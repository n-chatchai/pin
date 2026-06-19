import 'package:flutter/material.dart';

import '../models/chat_view_message.dart';
import '../widgets/pin_toast.dart';
import 'chat_screen.dart';

/// Dev-only harness to view the chat UI with mock data (no login/bot needed).
/// Enabled by `--dart-define=PIN_PREVIEW=1`.
class ChatPreview extends StatefulWidget {
  const ChatPreview({super.key});

  @override
  State<ChatPreview> createState() => _ChatPreviewState();
}

class _ChatPreviewState extends State<ChatPreview> {
  final _scroll = ScrollController();
  late final List<ChatViewMessage> _messages;
  ChatViewMessage? _replyTo;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    DateTime t(int minAgo) => now.subtract(Duration(minutes: minAgo));
    _messages = [
      ChatViewMessage(
        eventId: '1',
        sender: '@pin-bot:pin-chat.tokens2.io',
        body: 'สวัสดีครับ ผมปิ่น ผู้ช่วยส่วนตัวของคุณ 🪮\nวันนี้ให้ช่วยอะไรดี?',
        time: t(42),
        isMe: false,
      ),
      ChatViewMessage(
        eventId: '2',
        sender: '@test:pin-chat.tokens2.io',
        body: 'พรุ่งนี้อากาศเป็นไง',
        time: t(40),
        isMe: true,
      ),
      ChatViewMessage(
        eventId: '3',
        sender: '@pin-bot:pin-chat.tokens2.io',
        body: 'พรุ่งนี้กรุงเทพฯ ฝน 80% ช่วงบ่าย อุณหภูมิ 24–31°C เอาร่มไปด้วยนะครับ ☔',
        time: t(39),
        isMe: false,
        reactions: {'👍': 1},
      ),
      ChatViewMessage(
        eventId: '4',
        sender: '@test:pin-chat.tokens2.io',
        body: 'เตือนกินยา 9 โมงทุกวันด้วย',
        time: t(20),
        isMe: true,
      ),
      ChatViewMessage(
        eventId: '5',
        sender: '@pin-bot:pin-chat.tokens2.io',
        body: 'ตั้งให้แล้วครับ ⏰ เตือนกินยาทุกวัน 09:00 น.',
        time: t(19),
        isMe: false,
        replyToSender: 'test',
        replyToBody: 'เตือนกินยา 9 โมงทุกวันด้วย',
        reactions: {'❤️': 1, '🙏': 1},
      ),
      ChatViewMessage(
        eventId: '6',
        sender: '@test:pin-chat.tokens2.io',
        body: 'งานค้างมีอะไรบ้าง',
        time: t(8),
        isMe: true,
      ),
      ChatViewMessage(
        eventId: '7',
        sender: '@pin-bot:pin-chat.tokens2.io',
        body: 'งานค้าง 4 รายการ',
        time: t(7),
        isMe: false,
        flex: {
          'header': {'icon': 'tasks', 'title': 'งานค้าง', 'trailing': '4 รายการ'},
          'body': [
            {'type': 'progress', 'value': 0.33, 'label': 'ปิดวันนี้ 2 · เหลือ 4'},
            {'type': 'task', 'tag': 'รอคุณ', 'text': 'ส่งงานลูกค้า A', 'due': 'บ่ายสี่'},
            {'type': 'task', 'tag': 'รอเขา', 'text': 'ดีล X ตอบกลับ', 'due': '5 วัน'},
            {'type': 'task', 'tag': 'เดดไลน์', 'text': 'พรีเซนต์ B', 'due': 'พฤหัส'},
            {'type': 'task', 'tag': 'เงินค้าง', 'text': 'งวด 2 ลูกค้า C', 'due': '฿45k'},
          ],
          'footer': {'icon': 'clock', 'text': 'อัปเดต 8:02'},
        },
      ),
      ChatViewMessage(
        eventId: '8',
        sender: '@pin-bot:pin-chat.tokens2.io',
        body: 'เงินค้าง ฿45,000',
        time: t(6),
        isMe: false,
        flex: {
          'header': {'icon': 'money', 'title': 'เงินค้าง', 'trailing': 'เลย 7 วัน'},
          'body': [
            {'type': 'bignum', 'value': '฿45,000', 'sub': 'ลูกค้า C · งวด 2 · ครบกำหนด 5 มิ.ย.'},
            {'type': 'button', 'label': 'ร่างข้อความทวงให้ไหม', 'action': {'type': 'postback', 'data': 'draft:invoice:C'}},
          ],
          'footer': {'icon': 'clock', 'text': 'ปิ่นไม่ส่งให้เอง — ก๊อปไปวาง'},
        },
      ),
      ChatViewMessage(
        eventId: '9',
        sender: '@pin-bot:pin-chat.tokens2.io',
        body: 'พอร์ตวันนี้ ฿128,400',
        time: t(5),
        isMe: false,
        flex: {
          'header': {'icon': 'chart', 'title': 'พอร์ตวันนี้', 'trailing': 'ปิดตลาด 16:30'},
          'body': [
            {'type': 'bignum', 'value': '฿128,400', 'delta': '+1.8%'},
            {'type': 'line', 'points': [120, 118, 122, 121, 125, 124, 128]},
            {'type': 'kv', 'k': 'ตัวเด่น · DELTA', 'v': '+4.2%', 'color': 'pos'},
            {'type': 'kv', 'k': 'ตัวร่วง · KBANK', 'v': '−1.1%', 'color': 'neg'},
          ],
          'footer': {'icon': 'chart', 'text': 'ปิ่นบอกเลขเฉยๆ ไม่ใช่คำแนะนำลงทุน'},
        },
      ),
      ChatViewMessage(
        eventId: '10',
        sender: '@pin-bot:pin-chat.tokens2.io',
        body: 'ฝุ่นวันนี้ AQI 78',
        time: t(4),
        isMe: false,
        flex: {
          'header': {'icon': 'air', 'title': 'ฝุ่นวันนี้', 'trailing': 'เขตของคุณ · 09:00'},
          'body': [
            {'type': 'gauge', 'value': 78, 'max': 300, 'label': 'AQI 78'},
            {'type': 'text', 'text': 'เริ่มมีผลกับคนแพ้ฝุ่น', 'style': 'muted'},
          ],
          'footer': {'icon': 'heart', 'text': 'ถ้าออกไปนัด พกแมสก์หน่อย'},
        },
      ),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _send(String text) {
    setState(() {
      _messages.add(ChatViewMessage(
        eventId: 'local-${_messages.length}',
        sender: '@test:pin-chat.tokens2.io',
        body: text,
        time: DateTime.now(),
        isMe: true,
        replyToSender: _replyTo?.senderName,
        replyToBody: _replyTo?.body,
      ));
      _replyTo = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChatScaffold(
      title: 'ปิ่น AI',
      encrypted: true,
      messages: _messages,
      scroll: _scroll,
      replyTo: _replyTo,
      onSend: _send,
      onFlexAction: (data) => PinToast.show(context, 'postback → $data'),
      onMedia: (id) => PinToast.show(context, 'media → $id'),
      onReply: (m) => setState(() => _replyTo = m),
      onCancelReply: () => setState(() => _replyTo = null),
      onReact: (m, e) => setState(() {
        final i = _messages.indexOf(m);
        if (i == -1) return;
        final r = Map<String, int>.from(m.reactions)..update(e, (v) => v + 1, ifAbsent: () => 1);
        _messages[i] = ChatViewMessage(
          eventId: m.eventId,
          sender: m.sender,
          body: m.body,
          time: m.time,
          isMe: m.isMe,
          reactions: r,
          replyToSender: m.replyToSender,
          replyToBody: m.replyToBody,
        );
      }),
    );
  }
}
