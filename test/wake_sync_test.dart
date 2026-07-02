import 'package:flutter_test/flutter_test.dart';
import 'package:pin/agent/wake_sync.dart';

void main() {
  group('buildWakeJobs', () {
    test('watch tier -> interval job with tier seconds', () {
      final jobs = buildWakeJobs([
        {'id': 'w1', 'topic': 'oil', 'interval': 'hourly'},
      ], []);
      expect(jobs, hasLength(1));
      expect(jobs.first['job_id'], 'w1');
      expect(jobs.first['repeat'], 'interval');
      expect(jobs.first['interval_sec'], watchTierSec['hourly']);
    });

    test('daily watch -> daily job, no interval_sec', () {
      final jobs = buildWakeJobs([
        {'id': 'w2', 'interval': 'daily', 'time': '08:00'},
      ], []);
      expect(jobs.first['repeat'], 'daily');
      expect(jobs.first.containsKey('interval_sec'), isFalse);
    });

    test('reminders: agentic included, plain excluded', () {
      final jobs = buildWakeJobs([], [
        {'id': 'r1', 'kind': 'agentic', 'repeat': 'daily', 'time': '09:00'},
        {'id': 'r2', 'kind': 'reminder', 'repeat': 'daily', 'time': '09:00'},
      ]);
      expect(jobs.map((j) => j['job_id']), ['r1']);
    });

    test('empty id skipped; unknown tier falls back to daily interval', () {
      final jobs = buildWakeJobs([
        {'id': '', 'interval': 'hourly'},
        {'id': 'w3', 'interval': 'bogus'},
      ], []);
      expect(jobs, hasLength(1));
      expect(jobs.first['job_id'], 'w3');
      expect(jobs.first['interval_sec'], watchTierSec['daily']);
    });
  });
}
