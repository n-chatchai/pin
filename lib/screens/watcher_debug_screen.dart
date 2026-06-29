import 'package:flutter/material.dart';

import '../agent/agent_config.dart';
import '../agent/agent_session.dart';
import '../agent/agentic_job_service.dart';
import '../agent/job_runner.dart';
import '../services/matrix_service.dart';
import '../services/push_service.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_toast.dart';

/// Developer view of the watcher: every watch (io.tokens2.watches) cross-referenced
/// with its daily agentic job (io.tokens2.reminders, kind=agentic) so you can see
/// the schedule, whether it's DUE now, when it last ran, and the last finding.
/// A "run now" button fires every due job on-device so axis-2 (the scheduled
/// check) can be verified without waiting for the fire time — see
/// [[server-push-trigger-only]]: the work is local, so this is where you watch it.
class WatcherDebugScreen extends StatefulWidget {
  const WatcherDebugScreen({super.key});

  @override
  State<WatcherDebugScreen> createState() => _WatcherDebugScreenState();
}

class _WatcherDebugScreenState extends State<WatcherDebugScreen> {
  List<Map<String, dynamic>> _watches = const [];
  List<Map<String, dynamic>> _jobs = const [];
  Set<String> _due = const {};
  bool _loading = true;
  bool _running = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rid = await MatrixService.instance.pinRoomId();
      if (rid == null) throw 'ยังไม่มีห้องปิ่น';
      final watches = await MatrixService.instance
          .loadListFromRoom(rid, 'io.tokens2.watches');
      final reminders = await MatrixService.instance
          .loadListFromRoom(rid, 'io.tokens2.reminders');
      final jobs = reminders
          .where((j) => '${j['kind']}' == 'agentic')
          .toList(growable: false);
      final due = dueAgenticJobs(jobs, DateTime.now()).toSet();
      if (!mounted) return;
      setState(() {
        _watches = watches;
        _jobs = jobs;
        _due = due;
        _err = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _runNow() async {
    setState(() => _running = true);
    try {
      final rid = await MatrixService.instance.pinRoomId();
      if (rid == null) throw 'ยังไม่มีห้องปิ่น';
      final session = AgentSession(room: rid, proxy: devProxy());
      await runDueAgenticJobs(rid, session);
      if (mounted) PinToast.show(context, 'รันงานที่ถึงเวลาแล้ว — ดูผลในแชต');
    } catch (e) {
      if (mounted) PinToast.show(context, 'รันไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => _running = false);
      await _load();
    }
  }

  static String _fmt(num? ms) {
    if (ms == null || ms == 0) return 'ยังไม่เคย';
    final t = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return sameDay ? 'วันนี้ $hm' : '${t.month}/${t.day} $hm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PinPalette.cream,
      appBar: AppBar(
        backgroundColor: PinPalette.cream,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('ดีบัก Watcher'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'โหลดใหม่',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
              ? Center(
                  child: Text(_err!,
                      style: const TextStyle(color: PinPalette.ink2)))
              : ListView(
                  padding: EdgeInsets.fromLTRB(
                      16, 8, 16, 24 + MediaQuery.of(context).viewPadding.bottom),
                  children: [
                    Text('${_watches.length} watch · ${_due.length} ถึงเวลา',
                        style: const TextStyle(
                            fontSize: 13, color: PinPalette.ink2)),
                    const SizedBox(height: 8),
                    // Push channel diagnostic — a watch only gets a server wake
                    // if this token is non-null (else on-open/AlarmManager only).
                    Builder(builder: (_) {
                      final tok = PushService.instance.deviceToken;
                      final plat = PushService.instance.platform;
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: tok == null
                              ? const Color(0xFFC0392B).withValues(alpha: 0.10)
                              : const Color(0xFF2E9E63).withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          tok == null
                              ? 'push: $plat — ยังไม่มี token (จะใช้ on-open/alarm เท่านั้น)'
                              : 'push: $plat — ${tok.substring(0, tok.length.clamp(0, 22))}…',
                          style: const TextStyle(
                              fontSize: 12, color: PinPalette.ink2),
                        ),
                      );
                    }),
                    const SizedBox(height: 12),
                    if (_watches.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('ยังไม่มี watch',
                            style: TextStyle(color: PinPalette.ink2)),
                      ),
                    for (final w in _watches) _watchCard(w),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _running ? null : _runNow,
                      icon: _running
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.play_arrow),
                      label: Text(_running
                          ? 'กำลังรัน...'
                          : 'รันงานที่ถึงเวลาเดี๋ยวนี้'),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'รันงานเฝ้าที่ถึงเวลาบนเครื่องทันที (ไม่ต้องรอเวลาตั้ง) '
                      'แล้วดูว่าโพสต์ในแชตไหม.',
                      style: TextStyle(fontSize: 12, color: PinPalette.ink3),
                    ),
                  ],
                ),
    );
  }

  Widget _watchCard(Map<String, dynamic> w) {
    final id = '${w['id']}';
    final job = _jobs.cast<Map<String, dynamic>?>().firstWhere(
        (j) => '${j?['id']}' == id,
        orElse: () => null);
    final due = _due.contains(id);
    final hasNew = w['has_new'] == true;
    final lastSeen = '${w['last_seen'] ?? ''}'.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PinPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('${w['topic'] ?? '(ไม่มีหัวข้อ)'}',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: PinPalette.ink)),
              ),
              if (due) _pill('ถึงเวลา', const Color(0xFFE0A100)),
              if (hasNew) _pill('ใหม่', const Color(0xFF2E9E63)),
            ],
          ),
          const SizedBox(height: 6),
          _kv('เวลาเช็ค', job == null ? '— (ไม่มี job!)' : '${job['time']} · ${job['repeat']}'),
          _kv('รันล่าสุด', _fmt(job?['lastRun'] as num?)),
          _kv('เจอล่าสุด', _fmt(w['last_seen_at'] as num?)),
          if (lastSeen.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(lastSeen,
                  style: const TextStyle(fontSize: 13, color: PinPalette.ink2)),
            ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(
                width: 78,
                child: Text(k,
                    style: const TextStyle(
                        fontSize: 12, color: PinPalette.ink3))),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 12, color: PinPalette.ink2))),
          ],
        ),
      );

  Widget _pill(String t, Color c) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(t,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: c)),
      );
}
