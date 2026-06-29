import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'matrix_service.dart';
import 'pin_meta.dart';

/// Local notifications for incoming ปิ่น messages. Fires while the app is open
/// or backgrounded (not killed). True closed-app delivery needs a push gateway
/// (sygnal) + APNs/FCM credentials — see the architecture notes.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _started = false;
  bool _inited = false;

  /// Notification ids must fit a 32-bit int, but reminder ids are
  /// millisecondsSinceEpoch (~13 digits). Mask to 31 bits so schedule/cancel
  /// use the same id and zonedSchedule stops throwing "must fit within 32-bit".
  int _nid(int id) => id & 0x7fffffff;

  /// Initialize the plugin only (tz + channels). Safe in ANY isolate, incl. the
  /// FCM background isolate — does NOT request permission (that needs an Activity
  /// Context and crashes headless). Idempotent per isolate.
  Future<void> _ensure() async {
    if (_inited) return;
    _inited = true;
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Bangkok'));
    const settings = InitializationSettings(
      iOS: DarwinInitializationSettings(),
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(settings: settings);
  }

  /// Foreground init: plugin + permission prompt (needs an Activity).
  Future<void> init() async {
    await _ensure();
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// Subscribe to the message stream and surface bot messages as notifications.
  void start() {
    if (_started) return;
    _started = true;
    MatrixService.instance.messages.listen((m) {
      if (m.kind == 'reaction' || m.kind == 'tasks') return;
      // Self-DM: ปิ่น's turns post under the user's OWN account (isMe=true) but
      // carry meta.pin — those MUST notify (e.g. a watch finding). Only the
      // user's own plain typing (isMe && not pin) is skipped.
      if (m.isMe && !isPinMeta(m.metaJson)) return;
      final body = switch (m.kind) {
        'flex' => 'ส่งการ์ดมาให้',
        'image' => 'ส่งรูปมา',
        'file' => 'ส่งไฟล์มา',
        _ => m.body,
      };
      _show(m.roomId, body);
    });
  }

  /// Schedule a local notification at [when] (Asia/Bangkok). Fires even when the
  /// screen is off / app backgrounded — no APNs needed. `daily` repeats at the
  /// same time each day. This is the on-device reminder used by the agent.
  Future<void> scheduleReminder({
    required int id,
    required String body,
    required DateTime when,
    bool daily = false,
  }) async {
    Future<void> arm(AndroidScheduleMode mode) => _plugin.zonedSchedule(
          id: _nid(id),
          title: 'ปิ่น',
          body: body,
          scheduledDate: tz.TZDateTime.from(when, tz.local),
          notificationDetails: const NotificationDetails(
            iOS: DarwinNotificationDetails(
              presentAlert: true, presentBanner: true, presentSound: true,
            ),
            android: AndroidNotificationDetails(
              'pin_reminders', 'การเตือนจากปิ่น',
              importance: Importance.high, priority: Priority.high,
            ),
          ),
          androidScheduleMode: mode,
          matchDateTimeComponents: daily ? DateTimeComponents.time : null,
        );
    try {
      await arm(AndroidScheduleMode.exactAllowWhileIdle);
    } catch (_) {
      // Exact alarms denied (e.g. user revoked SCHEDULE_EXACT_ALARM) — fall back
      // to inexact so the reminder still fires (Doze may batch it a few minutes).
      await arm(AndroidScheduleMode.inexactAllowWhileIdle);
    }
  }

  /// Debug: fire a test notification [secs] from now + report state, so we can
  /// tell apart "plugin/permission broken" from "agent never called the tool".
  Future<String> debugTest({int secs = 10}) async {
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    final granted =
        await ios?.requestPermissions(alert: true, badge: true, sound: true);
    final when = DateTime.now().add(Duration(seconds: secs));
    await scheduleReminder(
      id: 999999, body: 'ทดสอบแจ้งเตือน ($secs วิ)', when: when);
    final pending = await _plugin.pendingNotificationRequests();
    return 'permission=$granted\n'
        'ตั้งไว้ ${secs}s → ${when.toString().substring(11, 19)}\n'
        'pending=${pending.length}: '
        '${pending.map((p) => p.id).join(", ")}';
  }

  /// Cancel a scheduled reminder by its id (no-op if already fired/gone).
  Future<void> cancel(int id) => _plugin.cancel(id: _nid(id));

  /// (Re)arm OS reminders from the ปิ่น room's `io.tokens2.reminders` state — the
  /// single source of truth. Called on boot + app resume so reminders survive
  /// relaunch and a fresh device. One-shots fire at their absolute `at`; daily
  /// ones repeat at `time`. Past one-shots + agentic jobs are skipped.
  Future<void> rescheduleFromRoom() async {
    final rid = await MatrixService.instance.pinRoomId();
    if (rid == null) return;
    final items =
        await MatrixService.instance.loadListFromRoom(rid, 'io.tokens2.reminders');
    await _plugin.cancelAll();
    final now = DateTime.now();
    for (final r in items) {
      if (r['kind'] == 'agentic') continue; // runs in-app, not an OS notification
      final text = '${r['text'] ?? ''}';
      if (text.isEmpty) continue;
      final id = int.tryParse('${r['id']}') ?? ('${r['id']}'.hashCode & 0x7fffffff);
      final daily = r['repeat'] == 'daily';
      DateTime? when;
      if (daily) {
        final hm = '${r['time'] ?? ''}'.split(':');
        if (hm.length == 2) {
          when = DateTime(now.year, now.month, now.day,
              int.tryParse(hm[0]) ?? 8, int.tryParse(hm[1]) ?? 0);
        }
      } else {
        final at = (r['at'] as num?)?.toInt();
        if (at != null) when = DateTime.fromMillisecondsSinceEpoch(at);
      }
      if (when == null) continue;
      if (!daily && when.isBefore(now)) continue; // past one-shot — skip
      await scheduleReminder(id: id, body: text, when: when, daily: daily);
    }
  }

  /// Public immediate notification for agentic-job output (watch findings,
  /// reminders that fire). Called from runDueAgenticJobs in ANY isolate — incl.
  /// the FCM/APNs background isolate, where the message-stream listener isn't
  /// running — so it lazy-inits the plugin first.
  Future<void> showNow(String roomId, String body) async {
    await _ensure(); // plugin only — no permission prompt (bg-isolate safe)
    await _show(roomId, body);
  }

  Future<void> _show(String roomId, String body) async {
    await _plugin.show(
      id: _nid(roomId.hashCode),
      title: 'ปิ่น',
      body: body,
      notificationDetails: const NotificationDetails(
        iOS: DarwinNotificationDetails(
          presentAlert: true, presentBanner: true, presentSound: true,
        ),
        android: AndroidNotificationDetails(
          'pin_messages',
          'ข้อความจากปิ่น',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }
}
