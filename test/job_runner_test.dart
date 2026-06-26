// Unit tests for the agentic-job due logic. Pure — no Matrix/LLM — so it runs
// with `flutter test test/job_runner_test.dart` (no device).
import 'package:flutter_test/flutter_test.dart';
import 'package:pin/agent/job_runner.dart';

// 2026-06-26 13:00 local.
final _now = DateTime(2026, 6, 26, 13, 0);
int _ms(DateTime d) => d.millisecondsSinceEpoch;

Map<String, dynamic> _once(String id, DateTime at, {int? lastRun}) => {
      'id': id,
      'text': 'do $id',
      'repeat': 'once',
      'kind': 'agentic',
      'at': _ms(at),
      if (lastRun != null) 'lastRun': lastRun,
    };

Map<String, dynamic> _daily(String id, String time, {int? lastRun}) => {
      'id': id,
      'text': 'do $id',
      'repeat': 'daily',
      'kind': 'agentic',
      'time': time,
      if (lastRun != null) 'lastRun': lastRun,
    };

void main() {
  group('dueAgenticJobs', () {
    test('one-shot in the past is due', () {
      final jobs = [_once('a', _now.subtract(const Duration(minutes: 5)))];
      expect(dueAgenticJobs(jobs, _now), ['a']);
    });

    test('one-shot in the future is not due', () {
      final jobs = [_once('a', _now.add(const Duration(minutes: 5)))];
      expect(dueAgenticJobs(jobs, _now), isEmpty);
    });

    test('one-shot already run (lastRun set) is not due', () {
      final jobs = [
        _once('a', _now.subtract(const Duration(hours: 1)), lastRun: _ms(_now))
      ];
      expect(dueAgenticJobs(jobs, _now), isEmpty);
    });

    test('daily past today’s fire, never run, is due', () {
      // fire 09:00, now 13:00, no lastRun.
      expect(dueAgenticJobs([_daily('a', '09:00')], _now), ['a']);
    });

    test('daily already run today is not due', () {
      final ranToday = _ms(DateTime(2026, 6, 26, 9, 0, 30));
      expect(dueAgenticJobs([_daily('a', '09:00', lastRun: ranToday)], _now),
          isEmpty);
    });

    test('daily last run yesterday is due again', () {
      final ranYesterday = _ms(DateTime(2026, 6, 25, 9, 0));
      expect(dueAgenticJobs([_daily('a', '09:00', lastRun: ranYesterday)], _now),
          ['a']);
    });

    test('daily before today’s fire is not due', () {
      // fire 18:00, now 13:00.
      expect(dueAgenticJobs([_daily('a', '18:00')], _now), isEmpty);
    });

    test('plain reminders (kind != agentic) are ignored', () {
      final jobs = [
        {
          'id': 'r',
          'text': 'pill',
          'repeat': 'once',
          'kind': 'reminder',
          'at': _ms(_now.subtract(const Duration(hours: 1))),
        }
      ];
      expect(dueAgenticJobs(jobs, _now), isEmpty);
    });

    test('malformed entries are skipped, not thrown', () {
      final jobs = [
        {'id': 'x', 'kind': 'agentic', 'repeat': 'daily', 'time': 'nope'},
        {'id': 'y', 'kind': 'agentic', 'repeat': 'once'}, // no `at`
        _once('z', _now.subtract(const Duration(minutes: 1))),
      ];
      expect(dueAgenticJobs(jobs, _now), ['z']);
    });
  });

  group('agenticAlarmsToArm', () {
    test('future one-shot armed at its at; past one-shot skipped', () {
      final future = _now.add(const Duration(hours: 1));
      final jobs = [
        _once('a', future),
        _once('b', _now.subtract(const Duration(hours: 1))),
      ];
      expect(agenticAlarmsToArm(jobs, _now), [AgenticAlarm('a', future)]);
    });

    test('daily with fire still ahead today → armed today', () {
      // fire 18:00, now 13:00.
      expect(agenticAlarmsToArm([_daily('a', '18:00')], _now),
          [AgenticAlarm('a', DateTime(2026, 6, 26, 18, 0))]);
    });

    test('daily with fire already passed today → armed tomorrow', () {
      // fire 09:00, now 13:00 → next is tomorrow 09:00.
      expect(agenticAlarmsToArm([_daily('a', '09:00')], _now),
          [AgenticAlarm('a', DateTime(2026, 6, 27, 9, 0))]);
    });

    test('non-agentic + malformed ignored', () {
      final jobs = [
        {'id': 'r', 'kind': 'reminder', 'repeat': 'once', 'at': _ms(_now.add(const Duration(hours: 1)))},
        {'id': 'x', 'kind': 'agentic', 'repeat': 'daily', 'time': 'nope'},
        _once('z', _now.add(const Duration(minutes: 30))),
      ];
      expect(agenticAlarmsToArm(jobs, _now),
          [AgenticAlarm('z', _now.add(const Duration(minutes: 30)))]);
    });
  });
}
