/// Pure scheduling logic for ปิ่น's agentic jobs (the `schedule_job` tool,
/// kind == 'agentic'). No I/O here so the "which jobs are due now" decision —
/// the part that used to be a missing function the rest of the code only
/// *referenced* — is unit-testable on its own.
///
/// A job is a reminders-list entry: `{id, time:"HH:MM", text, repeat, kind, at,
/// lastRun?}`. `at` is the absolute fire time (ms) for one-shots; `time` is the
/// daily HH:MM; `lastRun` (ms, added by the runner) dedups daily jobs so they
/// fire once per day even though the runner re-checks on every app open/resume.
library;

/// Today's fire DateTime for a daily "HH:MM", on [now]'s date. Null if [hhmm]
/// isn't "H:MM"/"HH:MM".
DateTime? todayFireTime(String hhmm, DateTime now) {
  final parts = hhmm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return DateTime(now.year, now.month, now.day, h, m);
}

/// An agentic job to wake the device for, and when. Used by the Android
/// alarm path ([AndroidJobAlarm]) to schedule one exact alarm per upcoming job.
class AgenticAlarm {
  final String id;
  final DateTime fireAt;
  const AgenticAlarm(this.id, this.fireAt);

  @override
  bool operator ==(Object other) =>
      other is AgenticAlarm && other.id == id && other.fireAt == fireAt;
  @override
  int get hashCode => Object.hash(id, fireAt);
}

/// The agentic jobs that need an exact alarm armed at [now], with the next time
/// each should fire: future one-shots at their `at`, daily jobs at the next
/// occurrence of their `time` (today if still ahead, else tomorrow). Past
/// one-shots are skipped (they either ran or will be caught by the on-open
/// runner). Pure → unit-tested; the I/O (arming the OS alarm) is in the service.
List<AgenticAlarm> agenticAlarmsToArm(
    List<Map<String, dynamic>> jobs, DateTime now) {
  final out = <AgenticAlarm>[];
  for (final j in jobs) {
    if ('${j['kind']}' != 'agentic') continue;
    final id = '${j['id']}';
    if ('${j['repeat']}' == 'daily') {
      var fire = todayFireTime('${j['time'] ?? ''}', now);
      if (fire == null) continue;
      if (!fire.isAfter(now)) fire = fire.add(const Duration(days: 1));
      out.add(AgenticAlarm(id, fire));
    } else {
      final at = (j['at'] as num?)?.toInt();
      if (at == null) continue;
      final fire = DateTime.fromMillisecondsSinceEpoch(at);
      if (fire.isAfter(now)) out.add(AgenticAlarm(id, fire));
    }
  }
  return out;
}

/// Ids of agentic jobs due to run at [now]. One-shots are due once their `at`
/// has passed (and removed after, so they don't repeat). Daily jobs are due
/// after today's fire time, but only if `lastRun` is before it — so they run
/// once per day, not on every resume. Non-agentic entries (OS reminders) and
/// malformed ones are ignored.
List<String> dueAgenticJobs(List<Map<String, dynamic>> jobs, DateTime now) {
  final due = <String>[];
  for (final j in jobs) {
    if ('${j['kind']}' != 'agentic') continue;
    final lastRun = (j['lastRun'] as num?)?.toInt();
    if ('${j['repeat']}' == 'daily') {
      final fire = todayFireTime('${j['time'] ?? ''}', now);
      if (fire == null || now.isBefore(fire)) continue; // not yet today
      if (lastRun != null &&
          !DateTime.fromMillisecondsSinceEpoch(lastRun).isBefore(fire)) {
        continue; // already ran for today's fire
      }
      due.add('${j['id']}');
    } else {
      final at = (j['at'] as num?)?.toInt();
      if (at == null) continue;
      if (now.isBefore(DateTime.fromMillisecondsSinceEpoch(at))) continue;
      if (lastRun != null) continue; // already ran (one-shots are normally removed)
      due.add('${j['id']}');
    }
  }
  return due;
}
