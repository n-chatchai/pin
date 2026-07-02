import '../services/matrix_service.dart';
import '../services/push_service.dart';
import 'agent_config.dart';
import 'when_parse.dart';

/// Poll cadence per watch tier, in seconds. Shared with now_tools (add_watch
/// picks a tier; here we turn it back into an interval for the server wake).
const Map<String, int> watchTierSec = {
  'realtime': 2 * 3600,
  'hourly': 6 * 3600,
  'daily': 24 * 3600,
  'weekly': 7 * 24 * 3600,
  'idle': 30 * 24 * 3600,
};

/// Reconcile the server's wake schedule for THIS device against room state — the
/// single source of truth. Server = dumb waker; it only needs to know *when* to
/// wake the device to run agentic work. We build the full desired job set from
/// the room (watches + agentic reminders) and POST it declaratively, so the
/// server converges (deletes stale, upserts current) and any prior drift heals.
///
/// No-ops without a push token (nothing to wake) — retried on the next call
/// (add_watch, app resume, or token refresh all trigger this).
Future<void> syncWakeSchedule(String rid) async {
  final device = PushService.instance.deviceToken;
  if (device == null || device.isEmpty) return;

  final watches =
      await MatrixService.instance.loadListFromRoom(rid, 'io.tokens2.watches');
  final reminders = await MatrixService.instance
      .loadListFromRoom(rid, 'io.tokens2.reminders');

  final jobs = buildWakeJobs(watches, reminders);
  await devProxy().scheduleSync(
    device: device,
    platform: PushService.instance.platform,
    jobs: jobs,
  );
}

/// Pure: room lists -> the wake-job set the server should hold. Each watch is an
/// agentic checker (job_id == watch id); reminders contribute only their agentic
/// entries (plain reminders fire via the OS locally, no server wake needed).
List<Map<String, dynamic>> buildWakeJobs(
  List<Map<String, dynamic>> watches,
  List<Map<String, dynamic>> reminders,
) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final jobs = <Map<String, dynamic>>[];

  Map<String, dynamic>? job({
    required String id,
    required bool daily,
    String? time,
    int? intervalSec,
    int? at,
  }) {
    if (id.isEmpty) return null;
    if (daily) {
      final when = parseWhen(time ?? '') ?? parseWhen('09:00')!;
      return {
        'job_id': id,
        'next_due': when.millisecondsSinceEpoch / 1000,
        'repeat': 'daily',
      };
    }
    final iv = intervalSec ?? watchTierSec['daily']!;
    return {
      'job_id': id,
      'next_due': ((at ?? now) + iv * 1000) / 1000,
      'repeat': 'interval',
      'interval_sec': iv,
    };
  }

  for (final w in watches) {
    final interval = '${w['interval'] ?? 'daily'}';
    final j = job(
      id: '${w['id'] ?? ''}',
      daily: interval == 'daily',
      time: '${w['time'] ?? ''}',
      intervalSec: watchTierSec[interval],
    );
    if (j != null) jobs.add(j);
  }

  for (final r in reminders) {
    if ('${r['kind'] ?? ''}' != 'agentic') continue; // OS handles plain reminders
    final j = job(
      id: '${r['id'] ?? ''}',
      daily: '${r['repeat'] ?? ''}' == 'daily',
      time: '${r['time'] ?? ''}',
      intervalSec: (r['interval_sec'] as num?)?.toInt(),
      at: (r['at'] as num?)?.toInt(),
    );
    if (j != null) jobs.add(j);
  }

  return jobs;
}
