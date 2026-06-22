import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../agent/agent_store.dart';
import '../services/files_store.dart';
import '../services/matrix_service.dart';
import '../services/notification_service.dart';
import '../widgets/pin_toast.dart';
import '../services/now_controllers.dart';
import '../services/tasks_controller.dart';
import '../theme/pin_theme.dart';

/// "ตอนนี้" content (fab-now) — focused peek at what matters right now:
/// overdue first, then today / deadlines. Used both as a left slide-in panel
/// and as a full screen.
class NowView extends StatelessWidget {
  const NowView({super.key});

  static const _todayHints = ['วันนี้', 'พรุ่งนี้', 'เช้า', 'บ่าย', 'เย็น', 'คืนนี้'];

  static bool _isNow(PinTask t) {
    if (t.overdue || t.today || t.group == 'เดดไลน์') return true;
    final due = t.due ?? '';
    return _todayHints.any(due.contains);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        // bottom:false so the drawer fills to the screen edge (no blank bar
        // under the home indicator); the lists pad their own bottom instead.
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelColor: Color(0xFF34B06A),
                  unselectedLabelColor: PinPalette.ink2,
                  indicatorColor: Color(0xFF34B06A),
                  indicatorWeight: 2.5,
                  // Heading face (IBM Plex Sans Thai) to match the app bar +
                  // section headers — tab titles are headings, not body.
                  labelStyle: PinPalette.brand(size: 16),
                  tabs: const [
                    Tab(text: 'ตอนนี้'),
                    Tab(text: 'ไฟล์'),
                    Tab(text: 'เร็ว ๆ นี้'),
                  ],
                  // (const dropped from parent Padding so labelStyle can use brand)
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [_nowTab(context), const FilesTab(), const SoonTab()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nowTab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
                animation: Listenable.merge([
                  TasksController.instance,
                  EventsController.instance,
                  JobsController.instance,
                  MemoryController.instance,
                ]),
                builder: (context, _) {
                  final now = TasksController.instance.value
                      .where(_isNow)
                      .toList()
                    ..sort((a, b) => (b.overdue ? 1 : 0) - (a.overdue ? 1 : 0));
                  final events = EventsController.instance.value;
                  final jobs = JobsController.instance.value;
                  final reminders = jobs.where((j) => !j.isAgentic).toList();
                  final autoJobs = jobs.where((j) => j.isAgentic).toList();
                  final memory = MemoryController.instance.value;
                  final empty = now.isEmpty &&
                      events.isEmpty &&
                      jobs.isEmpty &&
                      memory.isEmpty;
                  return ListView(
                    padding: EdgeInsets.fromLTRB(
                        16, 0, 16, 24 + MediaQuery.viewPaddingOf(context).bottom),
                    children: [
                      if (empty)
                        _breathe()
                      else ...[
                        if (now.isNotEmpty) ...[
                          _sectionLabel('เรื่องที่กำลังสำคัญ · ${now.length}'),
                          for (final t in now) _row(scheme, t),
                        ],
                        if (events.isNotEmpty) ...[
                          _sectionLabel('วันนี้ · ${events.length}'),
                          for (final e in events) _eventRow(e),
                        ],
                        if (reminders.isNotEmpty) ...[
                          _sectionLabel('การเตือน · ${reminders.length}'),
                          for (final j in reminders) _jobRow(j),
                        ],
                        if (autoJobs.isNotEmpty) ...[
                          _sectionLabel('งานอัตโนมัติ · ${autoJobs.length}'),
                          for (final j in autoJobs) _jobRow(j),
                        ],
                        if (memory.isNotEmpty) ...[
                          _sectionLabel('ความรู้ใหม่ · ${memory.length}'),
                          for (final m in memory.take(8)) _memoryRow(m),
                        ],
                      ],
                    ],
                  );
                },
              );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
        child: Text(text,
            style: const TextStyle(color: PinPalette.ink2, fontSize: 13)),
      );

  Widget _eventRow(PinEvent e) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(color: Color(0x0F282822), blurRadius: 9, offset: Offset(0, 3)),
          ],
        ),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: Text(e.time,
                  style: PinPalette.brand(size: 15)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(e.title,
                  style: const TextStyle(fontSize: 14, color: PinPalette.ink)),
            ),
            if (e.remind)
              const Icon(PhosphorIconsRegular.bell, size: 16, color: PinPalette.ink2),
          ],
        ),
      );

  Widget _jobRow(PinJob j) {
    final agentic = j.isAgentic;
    final tint = agentic ? const Color(0xFF8A6516) : PinPalette.ink2;
    return Container(
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
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(agentic ? PhosphorIconsRegular.sparkle : PhosphorIconsRegular.bell,
                size: 17, color: tint),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(j.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.25,
                        color: PinPalette.ink)),
                const SizedBox(height: 2),
                Text(
                    '${j.time} · ${j.repeat == 'daily' ? 'ทุกวัน' : 'ครั้งเดียว'}',
                    style:
                        const TextStyle(fontSize: 11.5, color: PinPalette.ink3)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => _deleteJob(j.id),
            customBorder: const CircleBorder(),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(PhosphorIconsRegular.x, size: 16, color: PinPalette.ink3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _memoryRow(MemoryItem m) {
    final isKnow = m.kind == 'knowledge';
    final tint = isKnow ? const Color(0xFF4F6FA6) : const Color(0xFF34B06A);
    return Container(
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
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(isKnow ? PhosphorIconsRegular.bookOpen : PhosphorIconsRegular.pushPin,
                size: 16, color: tint),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(m.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, height: 1.3, color: PinPalette.ink)),
          ),
        ],
      ),
    );
  }

  /// Cancel a reminder: drop it from on-device store + the OS schedule, then
  /// refresh the "ตั้งเวลา" list.
  Future<void> _deleteJob(String id) async {
    final s = AgentStore();
    await s.load();
    await s.removeReminder(id);
    final nid = int.tryParse(id);
    if (nid != null) await NotificationService.instance.cancel(nid);
    JobsController.instance.updateFromJson(jsonEncode(s.reminders()));
  }

  Widget _breathe() => const Padding(
        padding: EdgeInsets.fromLTRB(8, 40, 8, 24),
        child: Column(
          children: [
            Icon(PhosphorIconsRegular.coffee, size: 38, color: PinPalette.ink2),
            SizedBox(height: 14),
            Text('พอมีเวลาหายใจ',
                style: TextStyle(fontSize: 16, color: PinPalette.ink)),
            SizedBox(height: 6),
            Text('ตอนนี้ยังไม่มีอะไรด่วน',
                textAlign: TextAlign.center,
                style: TextStyle(color: PinPalette.ink2, height: 1.5)),
          ],
        ),
      );

  Widget _row(ColorScheme scheme, PinTask t) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: t.overdue
              ? Border.all(color: PinPalette.neg.withValues(alpha: 0.4))
              : null,
          boxShadow: const [
            BoxShadow(color: Color(0x0F282822), blurRadius: 9, offset: Offset(0, 3)),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(PhosphorIconsRegular.circle,
                size: 20,
                color: t.overdue ? PinPalette.neg : const Color(0xFFA0A096)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.text,
                      style: const TextStyle(fontSize: 14, color: PinPalette.ink)),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(t.sub ?? t.group,
                        style: const TextStyle(fontSize: 12, color: PinPalette.ink2)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(t.due ?? '',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.overdue ? PinPalette.neg : PinPalette.ink2)),
          ],
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
    final page =
        await FilesStore.instance.page(offset: _items.length, limit: _pageSize);
    if (!mounted) return;
    setState(() {
      _items.addAll(page);
      _hasMore = page.length == _pageSize;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty && !_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(PhosphorIconsRegular.folderOpen, size: 38, color: PinPalette.ink2),
              SizedBox(height: 14),
              Text('ยังไม่มีไฟล์',
                  style: TextStyle(fontSize: 16, color: PinPalette.ink)),
              SizedBox(height: 6),
              Text('ส่งเอกสารหรือไฟล์เสียงมา ปิ่นจะสรุปและเก็บไว้ให้',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: PinPalette.ink2, height: 1.5)),
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
        onTap: f.isImage
            ? () => _openImage(f)
            : (!f.isRemote && f.uri.isNotEmpty ? () => _openFile(f) : null),
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

  /// Tap a document/audio → iOS share sheet ("Open in…" / save / play). Resolves
  /// the bytes (local copy, or download the DM attachment from another device).
  Future<void> _openFile(FileItem f) async {
    final box = context.findRenderObject() as RenderBox?;
    final path = await FilesStore.instance.resolveBytes(f);
    if (path == null) {
      if (mounted) {
        PinToast.show(context, 'ยังโหลดไฟล์ไม่ได้ ลองอีกครั้งนะ');
      }
      return;
    }
    await Share.shareXFiles(
      [XFile(path)],
      sharePositionOrigin:
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    );
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

/// "เร็ว ๆ นี้" tab — capabilities the user asked for that ปิ่น can't do yet.
/// Logged by the `request_capability` tool into the ปิ่น room state
/// (`io.tokens2.capability_requests`), so the list syncs across devices.
class SoonTab extends StatefulWidget {
  const SoonTab({super.key});
  @override
  State<SoonTab> createState() => _SoonTabState();
}

class _SoonTabState extends State<SoonTab> {
  List<Map<String, dynamic>>? _items; // null = loading

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rid = await MatrixService.instance.pinRoomId();
    final list = rid == null
        ? <Map<String, dynamic>>[]
        : await MatrixService.instance
            .loadListFromRoom(rid, 'io.tokens2.capability_requests');
    // Newest first.
    list.sort((a, b) =>
        ((b['at'] as num?) ?? 0).compareTo((a['at'] as num?) ?? 0));
    if (mounted) setState(() => _items = list);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: const [
            SizedBox(height: 120),
            Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'ยังไม่มีคำขอความสามารถใหม่\nถ้าขอให้ปิ่นทำอะไรที่ยังทำไม่ได้ '
                  'รายการจะมาโผล่ที่นี่ พร้อมความคืบหน้า',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: PinPalette.ink2, height: 1.5),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: items.length,
        itemBuilder: (_, i) => _row(items[i]),
      ),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final cap = '${r['capability'] ?? ''}';
    final detail = '${r['detail'] ?? ''}';
    final count = (r['count'] as num?)?.toInt() ?? 1;
    final status = '${r['status'] ?? 'requested'}';
    final (label, color) = switch (status) {
      'building' => ('กำลังพัฒนา', const Color(0xFF34B06A)),
      'done' => ('พร้อมใช้แล้ว', const Color(0xFF34B06A)),
      _ => ('รอเพิ่มเร็ว ๆ นี้', PinPalette.ink2),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PinPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(cap,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: PinPalette.ink)),
              ),
              if (count > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('×$count',
                      style: const TextStyle(
                          fontSize: 12, color: PinPalette.ink2)),
                ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        color: color,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(detail,
                  style: const TextStyle(fontSize: 13, color: PinPalette.ink2)),
            ),
        ],
      ),
    );
  }
}

/// Full-screen wrapper (kept for any push-route use).
class NowScreen extends StatelessWidget {
  const NowScreen({super.key});
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: NowView());
}
