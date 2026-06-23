import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config.dart';
import '../models/chat_view_message.dart';
import '../services/prefs.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_composer.dart';
import '../widgets/liquid_glass.dart';
import '../widgets/onboard_card.dart';
import '../theme/pin_theme.dart';
import 'now_screen.dart';
import '../services/now_controllers.dart';
import 'api_log_screen.dart';
import 'settings_screen.dart';

/// Pure-presentation chat scaffold, used by [LocalChatScreen] and the preview
/// harness so the UI can be rendered with mock data.
class ChatScaffold extends StatefulWidget {
  final String title;
  final bool encrypted;
  final List<ChatViewMessage> messages;
  final bool botTyping;
  final int readUpToIndex;
  final ScrollController scroll;
  final ChatViewMessage? replyTo;
  final ValueChanged<String> onSend;
  final ValueChanged<String>? onMedia;
  final ValueChanged<String>? onSendAudio;
  final ValueChanged<ChatViewMessage> onReply;
  final VoidCallback onCancelReply;
  final void Function(ChatViewMessage, String) onReact;
  final ValueChanged<String>? onFlexAction;
  // Tapped an inline onboarding option (chip/tone/pill rendered in the feed).
  final ValueChanged<Map<String, String>>? onOnboardAction;

  const ChatScaffold({
    super.key,
    required this.title,
    required this.encrypted,
    required this.messages,
    this.botTyping = false,
    this.readUpToIndex = -1,
    required this.scroll,
    required this.replyTo,
    required this.onSend,
    this.onMedia,
    this.onSendAudio,
    required this.onReply,
    required this.onCancelReply,
    required this.onReact,
    this.onFlexAction,
    this.onOnboardAction,
  });

  @override
  State<ChatScaffold> createState() => _ChatScaffoldState();
}

class _ChatScaffoldState extends State<ChatScaffold> {
  bool _composerPanelOpen = false;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    final botTyping = widget.botTyping;
    final readUpToIndex = widget.readUpToIndex;
    final scroll = widget.scroll;
    final replyTo = widget.replyTo;
    final onSend = widget.onSend;
    final onMedia = widget.onMedia;
    final onSendAudio = widget.onSendAudio;
    final onReply = widget.onReply;
    final onCancelReply = widget.onCancelReply;
    final onReact = widget.onReact;
    // A card footer with action `open:now` opens the "ตอนนี้" drawer (e.g. the
    // confirmation after ปิ่น adds a reminder/task); everything else goes up.
    void onFlexAction(String data) {
      if (data == 'open:now') {
        _scaffoldKey.currentState?.openDrawer();
        return;
      }
      widget.onFlexAction?.call(data);
    }

    // Design: no header bar — bubbles/cards fill the screen, two floating
    // buttons sit top-left (ตอนนี้, slides from left) and top-right (menu,
    // slides from right) via the Scaffold's drawer / endDrawer.
    return Scaffold(
      key: _scaffoldKey,
      drawer: const Drawer(width: 320, child: NowView()),
      // bottom:false → chat fills to the screen edge so it blurs through the
      // glass composer all the way down (no solid bar under it). The composer
      // adds its own bottom inset to float above the home indicator.
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            // Chat fills the whole body; the composer floats over it (below) so
            // bubbles blur through the glass card — real Claude-style glass.
            Positioned.fill(
              // Tap anywhere outside the composer → dismiss the keyboard.
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: messages.isEmpty
                      ? _EmptyGreeting()
                      : ListView.builder(
                          controller: scroll,
                          // Reverse: newest pinned at the bottom (offset 0) so the
                          // chat always opens at the latest message regardless of
                          // variable item heights / async images — no jump hack.
                          reverse: true,
                          // Reserve space for the quick-reply bar + the composer,
                          // which itself grows by the nav-bar inset (3-button bar /
                          // gesture pill) — add that inset so the newest bubble
                          // clears the taller composer on edge-to-edge Android.
                          padding: EdgeInsets.fromLTRB(
                              0,
                              62,
                              0,
                              152 + MediaQuery.of(context).viewPadding.bottom),
                          // +1 trailing slot for the typing indicator (bottom).
                          itemCount: messages.length + (botTyping ? 1 : 0),
                          itemBuilder: (context, d) {
                            if (botTyping && d == 0) {
                              return const TypingBubble();
                            }
                            final i = messages.length -
                                1 -
                                (botTyping ? d - 1 : d);
                            final m = messages[i];
                            // Onboarding demo cards render full-width, no bubble.
                            if (m.onboard != null) {
                              return OnboardCard(
                                  spec: m.onboard!,
                                  onAction: widget.onOnboardAction);
                            }
                            final prev = i > 0 ? messages[i - 1] : null;
                            final newDay =
                                prev == null || !_sameDay(prev.time, m.time);
                            final showSender = prev == null ||
                                newDay ||
                                prev.sender != m.sender;
                            // "อ่านแล้ว" under the last of our messages once ปิ่น
                            // has read up to (or past) it.
                            final lastOwn = i == _lastOwnIndex(messages);
                            final showRead =
                                m.isMe && lastOwn && readUpToIndex >= i;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (newDay) DateDivider(date: m.time),
                                MessageBubble(
                                  msg: m,
                                  showSender: showSender,
                                  onReply: onReply,
                                  onReact: onReact,
                                  onFlexAction: onFlexAction,
                                ),
                                if (showRead)
                                  const Padding(
                                    padding:
                                        EdgeInsets.only(right: 16, top: 2, bottom: 2),
                                    child: Text(
                                      'อ่านแล้ว',
                                      textAlign: TextAlign.right,
                                      style: TextStyle(
                                          fontSize: 11, color: PinPalette.ink2),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 250),
                  opacity: _composerPanelOpen ? 1.0 : 0.0,
                  child: Container(color: const Color.fromRGBO(28, 28, 24, 0.14)),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MessageComposer(
                    onSend: onSend,
                    onMedia: onMedia,
                    onSendAudio: onSendAudio,
                    replyToSender: replyTo?.senderName,
                    replyToBody: replyTo?.body,
                    onCancelReply: onCancelReply,
                    onPanelToggled: (open) => setState(() => _composerPanelOpen = open),
                  ),
                ],
              ),
            ),
            // Top scrim: fade scrolled bubbles out under the floating fabs so
            // text never collides with the round buttons mid-scroll.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Container(
                  height: 64,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Theme.of(context).scaffoldBackgroundColor,
                        Theme.of(context)
                            .scaffoldBackgroundColor
                            .withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // fab-now (design): slides "ตอนนี้" in from the left.
            Positioned(
              top: 8,
              left: 12,
              child: Builder(
                builder: (context) =>
                    _FabNow(onTap: () {
                      NowBadge.instance.clear();
                      Scaffold.of(context).openDrawer();
                    }),
              ),
            ),
            // fab-cluster (design): slides in from the right. In debug builds the
            // API-log + ⋯ menu share ONE glass pill; otherwise just the ⋯ circle.
            Positioned(
              top: 8,
              right: 12,
              child: Builder(
                builder: (context) {
                  void openMenu() => Navigator.of(context, rootNavigator: true)
                      .push(MaterialPageRoute(
                          builder: (_) => const SettingsScreen()));
                  if (!kDebugBuild) return _FabTop(onTap: openMenu);
                  return _FabCluster(
                    onLog: () => Navigator.of(context, rootNavigator: true)
                        .push(MaterialPageRoute(
                            builder: (_) => const ApiLogScreen())),
                    onMenu: openMenu,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static int _lastOwnIndex(List<ChatViewMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].isMe) return i;
    }
    return -1;
  }
}

/// Left-aligned "…" bubble shown while ปิ่น is composing a reply.
class TypingBubble extends StatelessWidget {
  const TypingBubble({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 0, 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: const _TypingDots(),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // Each dot fades in/out on a staggered phase.
            final phase = (_c.value - i * 0.2) % 1.0;
            final t = (phase < 0.5 ? phase : 1 - phase) * 2; // 0..1..0
            return Container(
              margin: EdgeInsets.only(right: i < 2 ? 5 : 0),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: PinPalette.ink2.withValues(alpha: 0.35 + 0.5 * t),
              ),
            );
          }),
        );
      },
    );
  }
}

/// Claude-style empty state: a spark + a warm, time-aware serif greeting.
class _EmptyGreeting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final call = PrefsController.instance.value.userCall;
    final h = DateTime.now().hour;
    final part = h < 12
        ? 'สวัสดีตอนเช้า'
        : h < 17
            ? 'สวัสดีตอนบ่าย'
            : h < 20
                ? 'สวัสดีตอนเย็น'
                : 'สวัสดีตอนค่ำ';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset('assets/pin-logo.png',
                width: 60, height: 60, fit: BoxFit.cover),
          ),
          const SizedBox(height: 18),
          Text('$part, $call',
              textAlign: TextAlign.center,
              style: PinPalette.brand(size: 26, color: PinPalette.ink)),
        ],
      ),
    );
  }
}

/// Floating round menu button (design `.fab-top`) — white circle, soft shadow,
/// green ⋯ icon, top-right of the chat.
class _FabTop extends StatelessWidget {
  final VoidCallback onTap;
  const _FabTop({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LiquidGlassCircle(
      onTap: onTap,
      child: Icon(PhosphorIconsRegular.dotsThree, size: 21, color: scheme.secondary),
    );
  }
}

/// Debug-only glass pill holding the API-log + ⋯ menu icons in ONE box.
class _FabCluster extends StatelessWidget {
  final VoidCallback onLog;
  final VoidCallback onMenu;
  const _FabCluster({required this.onLog, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LiquidGlass(
      borderRadius: const BorderRadius.all(Radius.circular(22)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _iconBtn(PhosphorIconsRegular.pulse, 20, onLog, scheme),
          _iconBtn(PhosphorIconsRegular.dotsThree, 21, onMenu, scheme),
        ],
      ),
    );
  }

  Widget _iconBtn(
          IconData icon, double size, VoidCallback onTap, ColorScheme scheme) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Icon(icon, size: size, color: scheme.secondary),
        ),
      );
}

/// Floating round button (design `.fab-now`) — white circle, top-LEFT, agenda
/// icon; quick peek at งานค้าง.
class _FabNow extends StatelessWidget {
  final VoidCallback onTap;
  const _FabNow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LiquidGlassCircle(
      onTap: onTap,
      child: Icon(PhosphorIconsRegular.textAlignLeft, size: 21, color: scheme.secondary),
    );
  }
}
