import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../agent/agent_config.dart';
import '../agent/agent_store.dart';
import '../services/android_job_alarm.dart';
import '../services/files_store.dart';
import '../services/matrix_service.dart';
import '../widgets/pin_toast.dart';
import '../services/now_controllers.dart';
import '../services/tasks_controller.dart';
import '../services/prefs.dart';
import '../theme/pin_theme.dart';

// Pull straight from the app theme (now warm "Pi") so the panel can't drift.
const _line = PinPalette.line;
const _ink = PinPalette.ink;
const _ink2 = PinPalette.ink2;
const _ink3 = PinPalette.ink3;
const _neg = PinPalette.neg;

/// "ตอนนี้" content (fab-now) — a Pi-style glance: warm greeting in ปิ่น's
/// voice, today's tasks/events/reminders merged into one card, what ปิ่น is
/// watching, and a link to files. Used as the left slide-in panel + full screen.
class NowView extends StatelessWidget {
  const NowView({super.key});

  static const _todayHints = ['วันนี้', 'พรุ่งนี้', 'เช้า', 'บ่าย', 'เย็น', 'คืนนี้'];

  static bool _isNow(PinTask t) {
    if (t.overdue || t.today || t.group == 'เดดไลน์') return true;
    final due = t.due ?? '';
    return _todayHints.any(due.contains);
  }

  static TextStyle _serif(double size,
          {Color color = _ink, FontWeight weight = FontWeight.w600}) =>
      GoogleFonts.trirong(fontSize: size, fontWeight: weight, color: color);

  /// Warm greeting in ปิ่น's voice: time of day + how ปิ่น calls the user.
  static String _greet() {
    final h = DateTime.now().hour;
    final call = PrefsController.instance.value.userCall.trim();
    final base = h < 11
        ? 'สวัสดีตอนเช้า'
        : h < 16
            ? 'สวัสดีตอนบ่าย'
            : h < 19
                ? 'สวัสดีตอนเย็น'
                : 'สวัสดีตอนค่ำ';
    return call.isEmpty ? base : '$base, $call';
  }

  // Conversational summary moved to _buildAtAGlance()

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        bottom: false,
        child: AnimatedBuilder(
          animation: Listenable.merge([
            TasksController.instance,
            EventsController.instance,
            JobsController.instance,
            WatchesController.instance,
            PrefsController.instance,
          ]),
          builder: (context, _) {
            final now =
                TasksController.instance.value.where(_isNow).toList();
            final overdue = now.where((t) => t.overdue).toList();
            final pending = now.where((t) => !t.overdue).toList();
            final events = EventsController.instance.value;
            // One-time nudges land in "วันนี้"; recurring/agentic jobs are
            // background routine and stay out of the glance.
            final reminders = JobsController.instance.value
                .where((j) => !j.isAgentic)
                .toList();
            final watches = WatchesController.instance.value;
            // Accent follows the active palette (green/clay/slate/…).
            final accent = Theme.of(context).colorScheme.primary;

            // Timed items = today's events + one-time reminders (count only —
            // the full list lives in the _DayScreen the collapsed row opens).
            final timedCount = events.length + reminders.length;

            return ListView(
              padding: EdgeInsets.fromLTRB(
                  20, 8, 20, 24 + MediaQuery.viewPaddingOf(context).bottom),
              children: [
                Text(_greet(), style: _serif(27)),
                const SizedBox(height: 7),
                _buildAtAGlance(
                    context: context,
                    watches: watches,
                    events: events,
                    overdue: overdue,
                    pending: pending,
                    timedCount: timedCount),
                const SizedBox(height: 20),
                _menuCard([
                  _menuRow(
                    icon: PhosphorIconsRegular.calendarCheck,
                    iconColor: overdue.isNotEmpty ? _neg : accent,
                    label: 'งานและนัดหมาย',
                    hint: (overdue.length + timedCount + pending.length) == 0
                        ? 'ว่าง'
                        : '${overdue.length + timedCount + pending.length}',
                    hintColor: overdue.isNotEmpty ? _neg : _ink3,
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const _DayScreen())),
                  ),
                  _menuRow(
                    icon: PhosphorIconsRegular.eye,
                    iconColor: accent,
                    label: '${botName}เฝ้าให้อยู่',
                    hint: () {
                      final n = watches.where((w) => w.hasNew).length;
                      if (n > 0) return 'ใหม่ $n';
                      return watches.isEmpty ? '' : '${watches.length}';
                    }(),
                    hintColor:
                        watches.any((w) => w.hasNew) ? accent : _ink3,
                    onTap: () {
                      WatchesController.instance.markAllSeen();
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const _WatchScreen()));
                    },
                  ),
                  _menuRow(
                    icon: PhosphorIconsRegular.folder,
                    iconColor: accent,
                    label: 'ไฟล์ที่${botName}เก็บไว้',
                    hint: '',
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const _FilesScreen())),
                  ),
                ]),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Bare section rows, hairline-separated — no card (matches the files row).
  Widget _menuCard(List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i != rows.length - 1) {
        children.add(const Divider(height: 1, thickness: 1, color: _line));
      }
    }
    return Column(children: children);
  }

  Widget _buildAtAGlance({
    required BuildContext context,
    required List<PinWatch> watches,
    required List<PinEvent> events,
    required List<PinTask> overdue,
    required List<PinTask> pending,
    required int timedCount,
  }) {
    final newWatches = watches.where((w) => w.hasNew).toList();

    String msg;
    VoidCallback? onTap;
    Color color = _ink;
    Color bgColor = _ink.withValues(alpha: 0.05);
    IconData? icon;

    if (newWatches.isNotEmpty) {
      msg = 'มีอัปเดตเรื่อง "${newWatches.first.topic}"';
      onTap = () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _WatchScreen()));
      color = Theme.of(context).colorScheme.primary;
      bgColor = color.withValues(alpha: 0.08);
      icon = PhosphorIconsRegular.bellRinging;
    } else if (overdue.isNotEmpty) {
      msg = 'มีงานค้าง ${overdue.length} เรื่องที่เลยกำหนดแล้ว';
      onTap = () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _DayScreen()));
      color = _neg;
      bgColor = color.withValues(alpha: 0.08);
      icon = PhosphorIconsRegular.warning;
    } else if (timedCount > 0) {
      msg = 'มีกำหนดการ/นัดหมาย $timedCount รายการวันนี้';
      onTap = () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _DayScreen()));
      icon = PhosphorIconsRegular.calendarCheck;
    } else if (pending.isNotEmpty) {
      msg = 'มีงานที่ต้องทำ ${pending.length} อย่างวันนี้';
      onTap = () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _DayScreen()));
      icon = PhosphorIconsRegular.checkCircle;
    } else {
      return Column(
        children: [
          const SizedBox(height: 28),
          _emptyState(PhosphorIconsRegular.coffee, 'วันนี้โล่ง ๆ ไม่มีอะไรด่วน', 'พักได้เลย'),
          const SizedBox(height: 28),
        ],
      );
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(msg,
                  style: TextStyle(
                      fontSize: 15,
                      color: color,
                      height: 1.4,
                      fontWeight: FontWeight.w500)),
            ),
            Icon(PhosphorIconsRegular.caretRight,
                size: 16, color: color.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }

  /// A uniform section row — icon · label · optional count hint · chevron. Same
  /// shape for งานวันนี้ / ปิ่นเฝ้า / ไฟล์ so they read as one menu.
  Widget _menuRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String hint,
    Color hintColor = _ink3,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 17),
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 13),
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _ink)),
              ),
              if (hint.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(hint,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: hintColor)),
                ),
              const Icon(PhosphorIconsRegular.caretRight,
                  size: 17, color: _ink3),
            ],
          ),
        ),
      );
}

/// "ไฟล์" tab — files ปิ่น has processed, newest first, with infinite scroll
/// (pages of 20 fetched from the on-device SQLite store as you reach the end).
class FilesTab extends StatefulWidget {
  const FilesTab({super.key});
  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  static const _pageSize = 20;
  final _scroll = ScrollController();
  final _items = <FileItem>[];
  bool _loading = false;
  bool _hasMore = true;
  String? _filter; // null = all, 'image' / 'audio' / 'doc'

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    FilesController.instance.addListener(_reload);
    _loadMore();
    // Re-pull the file metadata from the ปิ่น room so files uploaded on ANOTHER
    // device show up here too — not only those seeded at boot / via a live chat
    // event. loadFromRoom upserts the cache then bumps → _reload re-queries.
    FilesStore.instance.loadFromRoom();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    FilesController.instance.removeListener(_reload);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 240) {
      _loadMore();
    }
  }

  /// A new file landed → reset to a fresh first page.
  void _reload() {
    _items.clear();
    _hasMore = true;
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    _loading = true;
    final page = await FilesStore.instance
        .page(offset: _items.length, limit: _pageSize, filter: _filter);
    if (!mounted) return;
    setState(() {
      _items.addAll(page);
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _chips(),
        Expanded(child: _body(context)),
      ],
    );
  }

  static const _filters = [
    (null, 'ทั้งหมด'),
    ('image', 'รูปภาพ'),
    ('audio', 'เสียง'),
    ('doc', 'เอกสาร'),
  ];

  Widget _chips() {
    // Same chip style as the capability filter (abilities_screen) — a plain
    // scrollable row, no edge-fade shader, so the leftmost "ทั้งหมด" chip isn't
    // clipped and the two filter bars read identically. Top 14 matches the
    // ตอนนี้ tab's first-content inset (_sectionLabel) so both tabs line up.
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        children: [
          for (final (id, label) in _filters)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(label),
                selected: _filter == id,
                onSelected: (selected) => _setFilter(selected ? id : null),
                showCheckmark: false,
                labelStyle: TextStyle(
                    color: _filter == id ? Colors.white : PinPalette.ink,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5),
                selectedColor: Theme.of(context).colorScheme.primary,
                backgroundColor: Colors.white,
                side: BorderSide(
                    color: _filter == id
                        ? Theme.of(context).colorScheme.primary
                        : PinPalette.line),
                shape: const StadiumBorder(),
              ),
            ),
        ],
        ),
      ),
    );
  }

  void _setFilter(String? id) {
    if (_filter == id) return;
    setState(() => _filter = id);
    _reload();
  }

  Widget _body(BuildContext context) {
    if (_items.isEmpty && !_loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(PhosphorIconsRegular.folderOpen, size: 38, color: PinPalette.ink2),
              const SizedBox(height: 14),
              const Text('ยังไม่มีไฟล์',
                  style: TextStyle(fontSize: 16, color: PinPalette.ink)),
              const SizedBox(height: 6),
              Text('ส่งเอกสารหรือไฟล์เสียงมา ${botName}จะสรุปและเก็บไว้ให้',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: PinPalette.ink2, height: 1.5)),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, 24 + MediaQuery.viewPaddingOf(context).bottom),
      itemCount: _items.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        }
        return _fileRow(_items[i]);
      },
    );
  }

  Widget _fileRow(FileItem f) {
    return Dismissible(
      key: ValueKey(f.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => FilesStore.instance.remove(f.id),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: PinPalette.neg.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(PhosphorIconsRegular.trash, size: 18, color: PinPalette.neg),
      ),
      child: InkWell(
        // Any file is tappable — _openFile resolves the bytes (local copy, or
        // downloads the DM attachment uploaded on another device) before opening.
        onTap: f.isImage ? () => _openImage(f) : () => _openFile(f),
        borderRadius: BorderRadius.circular(12),
        child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(
                color: Color(0x0A282822), blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _leading(f),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: PinPalette.ink)),
                  if (f.summary.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(f.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.3,
                              color: PinPalette.ink2)),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_meta(f),
                        style: const TextStyle(
                            fontSize: 11, color: PinPalette.ink3)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// Thumbnail for images (local file or remote gen url); icon otherwise.
  Widget _leading(FileItem f) {
    if (f.isImage) {
      if (f.isRemote) {
        return ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: Image.network(f.uri,
                width: 44, height: 44, fit: BoxFit.cover,
                loadingBuilder: (_, child, p) => p == null ? child : _spinBox(),
                errorBuilder: (_, __, ___) =>
                    _iconBox(PhosphorIconsRegular.imageBroken)));
      }
      // Local copy, or download from the DM attachment when the bytes came from
      // another device (only metadata synced).
      return ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: FutureBuilder<String?>(
          future: FilesStore.instance.resolveBytes(f),
          builder: (_, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return _spinBox();
            }
            final path = snap.data;
            if (path == null) {
              return _iconBox(PhosphorIconsRegular.imageBroken);
            }
            return Image.file(File(path),
                width: 44, height: 44, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    _iconBox(PhosphorIconsRegular.imageBroken));
          },
        ),
      );
    }
    return _iconBox(f.isAudio ? PhosphorIconsRegular.microphone : PhosphorIconsRegular.fileText);
  }

  Widget _spinBox() => Container(
        width: 44,
        height: 44,
        color: const Color(0xFFF5F1E8),
        child: const Center(
          child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF34B06A))),
        ),
      );

  Widget _iconBox(IconData icon) => Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: const Color(0xFF34B06A).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(icon, size: 16, color: const Color(0xFF34B06A)),
      );

  /// Tap an image file → fullscreen, pinch-zoomable viewer.
  void _openImage(FileItem f) {
    final ctx = context;
    showDialog<void>(
      context: ctx,
      barrierColor: Colors.black,
      builder: (_) => GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        child: InteractiveViewer(
          child: Center(
            child: f.isRemote
                ? Image.network(f.uri,
                    loadingBuilder: (_, child, pr) => pr == null
                        ? child
                        : const SizedBox(
                            width: 40,
                            height: 40,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.4, color: Color(0xFF34B06A))))
                : FutureBuilder<String?>(
                    future: FilesStore.instance.resolveBytes(f),
                    builder: (_, snap) {
                      final path = snap.data;
                      if (path == null) {
                        return snap.connectionState == ConnectionState.waiting
                            ? const SizedBox(
                                width: 40,
                                height: 40,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.4, color: Color(0xFF34B06A)))
                            : const Icon(PhosphorIconsRegular.imageBroken,
                                color: Colors.white, size: 48);
                      }
                      return Image.file(File(path));
                    },
                  ),
          ),
        ),
      ),
    );
  }

  /// Tap a document/audio/video → open with the OS handler: iOS QuickLook
  /// previews PDFs and plays audio/video in an overlay; Android opens the right
  /// app. Resolves the bytes first (local copy, or downloads the DM attachment
  /// from another device) and fixes the extension. Falls back to the share sheet.
  Future<void> _openFile(FileItem f) async {
    final raw = await FilesStore.instance.resolveBytes(f);
    if (raw == null) {
      if (mounted) PinToast.show(context, 'ยังโหลดไฟล์ไม่ได้ ลองอีกครั้งนะ');
      return;
    }
    // Downloaded attachments often land as ".bin" (octet-stream); the OS picks
    // the handler by extension, so give it the real one first.
    final path = await _viewablePath(f, raw);
    final res = await OpenFilex.open(path);
    if (res.type == ResultType.done || !mounted) return;
    // No handler / failed → share sheet so the user can still save or open.
    final box = context.findRenderObject() as RenderBox?;
    await Share.shareXFiles(
      [XFile(path)],
      sharePositionOrigin:
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    );
  }

  /// The real extension for [f] (the viewer is extension-driven). Doc files store
  /// it as the `type` (pdf/docx/xlsx…); otherwise read it off the filename, else
  /// fall back by category (รูป→jpg, เสียง→wav, วิดีโอ→mp4).
  static String _extFor(FileItem f) {
    final t = f.type.toLowerCase();
    if (RegExp(r'^[a-z0-9]{1,5}$').hasMatch(t)) return t;
    final n = f.name.toLowerCase();
    final dot = n.lastIndexOf('.');
    if (dot > 0 && dot < n.length - 1) {
      final e = n.substring(dot + 1);
      if (RegExp(r'^[a-z0-9]{1,5}$').hasMatch(e)) return e;
    }
    return switch (f.type) {
      'รูป' => 'jpg',
      'เสียง' => 'wav',
      'วิดีโอ' => 'mp4',
      _ => '',
    };
  }

  /// Ensure [path] carries the right extension so the viewer detects the type —
  /// copying to a temp file when it doesn't (e.g. a downloaded ".bin").
  Future<String> _viewablePath(FileItem f, String path) async {
    final want = _extFor(f);
    if (want.isEmpty) return path;
    final cur = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    if (cur == want) return path;
    try {
      final dest = '${Directory.systemTemp.path}/pin_view_${f.id}.$want';
      await File(path).copy(dest);
      return dest;
    } catch (_) {
      return path;
    }
  }

  static const _months = [
    'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.',
    'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'
  ];

  static String _meta(FileItem f) {
    final d = DateTime.fromMillisecondsSinceEpoch(f.createdAt);
    final time =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final date = '${d.day} ${_months[d.month - 1]} ${(d.year + 543) % 100}';
    final ext = f.type.isEmpty ? '' : '${f.type.toUpperCase()} · ';
    return '$ext$date · $time';
  }
}

/// Full-screen wrapper (kept for any push-route use).
class NowScreen extends StatelessWidget {
  const NowScreen({super.key});
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: NowView());
}

/// ไฟล์ as its own screen, opened from the "ตอนนี้" panel's menu row (was a tab).
class _FilesScreen extends StatelessWidget {
  const _FilesScreen();
  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        surfaceTintColor: bg,
        elevation: 0,
        title: const Text('ไฟล์'),
      ),
      body: const SafeArea(child: FilesTab()),
    );
  }
}

// ── delete helpers (room state = source of truth) ──────────────────────────
Future<void> _removeReminder(String id) async {
  final s = AgentStore();
  await s.load();
  await s.removeReminder(id);
}

Future<bool> _removeRoomItem(String type, bool Function(Map<String, dynamic>) drop,
    void Function(String) refresh) async {
  final rid = await MatrixService.instance.pinRoomId();
  if (rid == null) return false;
  
  final list = await MatrixService.instance.loadListFromRoom(rid, type);
  final before = list.length;
  list.removeWhere(drop);
  if (list.length == before) return true; // already gone
  
  final ok = await MatrixService.instance.saveListToRoom(rid, type, list);
  if (ok) {
    refresh(jsonEncode(list));
    return true;
  } else {
    // Revert refresh so UI restores the item if network failed
    final oldList = await MatrixService.instance.loadListFromRoom(rid, type);
    refresh(jsonEncode(oldList));
    return false;
  }
}

Future<void> _removeWatch(String id) async {
  final ok = await _removeRoomItem('io.tokens2.watches', (w) => '${w['id']}' == id,
      WatchesController.instance.updateFromJson);
  if (!ok) return; // If Matrix save failed, stop here (UI reverts)
  await _removeReminder(id); // the watch's checker job shares the id
  await devProxy().scheduleCancel(id);
  await AndroidJobAlarm.cancel(id);
}

Widget _swipeBg() => Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: PinPalette.neg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Icon(PhosphorIconsRegular.trash, size: 18, color: PinPalette.neg),
    );

/// Explicit per-item delete (alongside swipe) so it's obvious things can go.
Widget _delBtn(VoidCallback onTap) => IconButton(
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: const Icon(PhosphorIconsRegular.trash, size: 17, color: _ink3),
    );

Widget _listCard({required Widget child}) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Color(0x0A282822), blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: child,
    );

TextStyle _trirong(double s, {Color c = _ink, FontWeight w = FontWeight.w600}) =>
    GoogleFonts.trirong(fontSize: s, fontWeight: w, color: c);

/// Shared empty state — a big centered line icon over a serif line + a soft hint.
Widget _emptyState(IconData icon, String title, String sub) => Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: _ink3),
            const SizedBox(height: 20),
            Text(title, textAlign: TextAlign.center, style: _trirong(18)),
            const SizedBox(height: 8),
            Text(sub,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: _ink2, height: 1.5)),
          ],
        ),
      ),
    );

/// "งานวันนี้" full screen — reminders + schedule + tasks merged, newest-urgent
/// first, each swipe-to-delete. Opened from the collapsed row in "ตอนนี้".
class _DayScreen extends StatelessWidget {
  const _DayScreen();

  static const _hints = ['วันนี้', 'พรุ่งนี้', 'เช้า', 'บ่าย', 'เย็น', 'คืนนี้'];
  static bool _isNow(PinTask t) =>
      t.overdue || t.today || t.group == 'เดดไลน์' ||
      _hints.any((t.due ?? '').contains);

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        surfaceTintColor: bg,
        elevation: 0,
        title: const Text('งานและนัดหมาย'),
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([
            TasksController.instance,
            EventsController.instance,
            JobsController.instance,
          ]),
          builder: (context, _) {
            final now = TasksController.instance.value.where(_isNow).toList();
            final overdue = now.where((t) => t.overdue).toList();
            final pending = now.where((t) => !t.overdue).toList();
            final events = EventsController.instance.value;
            final reminders = JobsController.instance.value
                .where((j) => !j.isAgentic)
                .toList();

            final tiles = <Widget>[
              for (final t in overdue) _taskTile(t, accent),
              for (final e in events) _eventTile(e, accent),
              for (final r in reminders) _reminderTile(r, accent),
              for (final t in pending) _taskTile(t, accent),
            ];

            if (tiles.isEmpty) {
              return _emptyState(PhosphorIconsRegular.coffee,
                  'วันนี้โล่ง ๆ ไม่มีอะไรด่วน', 'พักได้เลย');
            }
            return ListView(
              padding: EdgeInsets.fromLTRB(
                  16, 12, 16, 24 + MediaQuery.viewPaddingOf(context).bottom),
              children: tiles,
            );
          },
        ),
      ),
    );
  }

  Widget _reminderTile(PinJob r, Color accent) => Dismissible(
        key: ValueKey('rem_${r.id}'),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => _removeReminder(r.id),
        background: _swipeBg(),
        child: _listCard(
          child: Row(children: [
            SizedBox(
                width: 52,
                child: Text(r.time,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: accent))),
            Expanded(
                child: Text(r.text,
                    style: const TextStyle(fontSize: 15, color: _ink))),
            const Text('เตือน',
                style: TextStyle(fontSize: 12, color: _ink3)),
            _delBtn(() => _removeReminder(r.id)),
          ]),
        ),
      );

  Widget _eventTile(PinEvent e, Color accent) => Dismissible(
        key: ValueKey('evt_${e.id}'),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => _removeRoomItem('io.tokens2.events',
            (m) => '${m['id']}' == e.id, EventsController.instance.updateFromJson),
        background: _swipeBg(),
        child: _listCard(
          child: Row(children: [
            SizedBox(
                width: 52,
                child: Text(e.time,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: accent))),
            Expanded(
                child: Text(e.title,
                    style: const TextStyle(fontSize: 15, color: _ink))),
            if (e.remind)
              const Icon(PhosphorIconsRegular.bell, size: 15, color: _ink3),
            _delBtn(() => _removeRoomItem('io.tokens2.events',
                (m) => '${m['id']}' == e.id,
                EventsController.instance.updateFromJson)),
          ]),
        ),
      );

  Widget _taskTile(PinTask t, Color accent) => Dismissible(
        key: ValueKey('task_${t.group}_${t.text}'),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => _removeRoomItem(
            'io.tokens2.tasks',
            (m) => '${m['text']}' == t.text && '${m['group']}' == t.group,
            TasksController.instance.updateFromJson),
        background: _swipeBg(),
        child: _listCard(
          child: Row(children: [
            Expanded(
                child: Text(t.text,
                    style: TextStyle(
                        fontSize: 15,
                        color: t.overdue ? _neg : _ink,
                        fontWeight:
                            t.overdue ? FontWeight.w600 : FontWeight.w400))),
            if ((t.due ?? '').isNotEmpty)
              Text(t.due!,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: t.overdue ? _neg : _ink3)),
            _delBtn(() => _removeRoomItem(
                'io.tokens2.tasks',
                (m) => '${m['text']}' == t.text && '${m['group']}' == t.group,
                TasksController.instance.updateFromJson)),
          ]),
        ),
      );
}

/// "ปิ่นเฝ้าให้อยู่" full screen — every watch with its last finding + check time,
/// swipe-to-delete (also cancels the checker job). Opened from the watch glance.
class _WatchScreen extends StatelessWidget {
  const _WatchScreen();

  static String _ago(int ms) {
    if (ms == 0) return 'ยังไม่เคยเช็ค';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
    final hm =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return sameDay ? 'เช็คล่าสุดวันนี้ $hm' : 'เช็คล่าสุด ${d.day}/${d.month} $hm';
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        surfaceTintColor: bg,
        elevation: 0,
        title: Text('${botName}เฝ้าให้อยู่'),
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([WatchesController.instance, JobsController.instance]),
          builder: (context, _) {
            final watches = WatchesController.instance.value;
            final jobs = JobsController.instance.value;
            if (watches.isEmpty) {
              return _emptyState(PhosphorIconsRegular.eye, 'ยังไม่มีเรื่องที่เฝ้า',
                  'บอก${botName}ในแชตว่าสนใจเรื่องไหน เดี๋ยวคอยดูให้');
            }
            
            final sortedWatches = watches.toList()..sort((a, b) {
              final ja = jobs.where((j) => j.id == a.id).firstOrNull;
              final jb = jobs.where((j) => j.id == b.id).firstOrNull;
              final ia = (ja == null || ja.intervalSec <= 0) ? 999999999 : ja.intervalSec;
              final ib = (jb == null || jb.intervalSec <= 0) ? 999999999 : jb.intervalSec;
              if (ia != ib) return ia.compareTo(ib);
              if (a.hasNew != b.hasNew) return a.hasNew ? -1 : 1;
              return a.topic.compareTo(b.topic);
            });

            return ListView(
              padding: EdgeInsets.fromLTRB(
                  16, 12, 16, 24 + MediaQuery.viewPaddingOf(context).bottom),
              children: [
                for (final w in sortedWatches)
                  Dismissible(
                    key: ValueKey('watch_${w.id}'),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) => _removeWatch(w.id),
                    background: _swipeBg(),
                    child: _listCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(child: Text(w.topic, style: _trirong(15.5))),
                            if (w.hasNew)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text('ใหม่',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: accent)),
                              ),
                            _delBtn(() => _removeWatch(w.id)),
                          ]),
                          if (w.lastSeen.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Text(w.lastSeen,
                                  style: const TextStyle(
                                      fontSize: 13, color: _ink2, height: 1.4)),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Text(_ago(w.lastSeenAt),
                                style: const TextStyle(
                                    fontSize: 11.5, color: _ink3)),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
