import 'package:flutter/foundation.dart';

/// One recorded call. For HTTP calls the request/response detail is filled in
/// (Chuck-style); for plain timed (rust/FFI) calls only name/ms/ok are set.
class ApiLogEntry {
  final String name; // "POST /infer" for http, or the rust call name
  final int ms;
  final DateTime at;
  final bool ok;
  final String? method;
  final String? url;
  final int? status;
  final String? reqBody;
  final String? respBody;
  const ApiLogEntry(
    this.name,
    this.ms,
    this.at,
    this.ok, {
    this.method,
    this.url,
    this.status,
    this.reqBody,
    this.respBody,
  });

  bool get isHttp => url != null;
}

/// In-memory ring buffer of recent calls, shown in the Settings "API call log"
/// (a lightweight Chuck-style HTTP inspector). Newest first; capped.
class ApiLog extends ValueNotifier<List<ApiLogEntry>> {
  ApiLog._() : super(const []);
  static final ApiLog instance = ApiLog._();
  static const _max = 120;
  static const _bodyCap = 6000; // keep bodies bounded

  void _push(ApiLogEntry e) {
    final next = <ApiLogEntry>[e, ...value];
    if (next.length > _max) next.removeRange(_max, next.length);
    value = next;
  }

  /// Plain timed (non-HTTP) call.
  void add(String name, int ms, bool ok) =>
      _push(ApiLogEntry(name, ms, DateTime.now(), ok));

  /// A full HTTP round-trip (method + path label, status, request/response).
  void addHttp({
    required String method,
    required String url,
    required int status,
    required int ms,
    String? reqBody,
    String? respBody,
  }) {
    final path = Uri.tryParse(url)?.path ?? url;
    _push(ApiLogEntry(
      '$method $path',
      ms,
      DateTime.now(),
      status >= 200 && status < 400,
      method: method,
      url: url,
      status: status,
      reqBody: _cap(reqBody),
      respBody: _cap(respBody),
    ));
  }

  static String? _cap(String? s) => s == null
      ? null
      : (s.length > _bodyCap ? '${s.substring(0, _bodyCap)}\n…(ตัด)' : s);

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
