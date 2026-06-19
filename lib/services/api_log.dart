import 'package:flutter/foundation.dart';

/// One recorded API/network call: name, how long it took, and whether it threw.
class ApiLogEntry {
  final String name;
  final int ms;
  final DateTime at;
  final bool ok;
  const ApiLogEntry(this.name, this.ms, this.at, this.ok);
}

/// In-memory ring buffer of recent API calls, shown in the Settings debug panel
/// so we can see which call is slow (e.g. a 30s sync) without a USB log cable.
/// Newest first; capped so it can't grow unbounded.
class ApiLog extends ValueNotifier<List<ApiLogEntry>> {
  ApiLog._() : super(const []);
  static final ApiLog instance = ApiLog._();
  static const _max = 120;

  void add(String name, int ms, bool ok) {
    final next = <ApiLogEntry>[
      ApiLogEntry(name, ms, DateTime.now(), ok),
      ...value,
    ];
    if (next.length > _max) next.removeRange(_max, next.length);
    value = next;
  }

  void clear() => value = const [];
}

/// Time an async call and record it in [ApiLog]. Returns the call's result
/// (rethrows on error after recording it with a ✗ marker).
Future<T> timed<T>(String name, Future<T> Function() body) async {
  final sw = Stopwatch()..start();
  try {
    final r = await body();
    ApiLog.instance.add(name, sw.elapsedMilliseconds, true);
    return r;
  } catch (_) {
    ApiLog.instance.add('$name ✗', sw.elapsedMilliseconds, false);
    rethrow;
  }
}
