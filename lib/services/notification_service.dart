import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'matrix_service.dart';

/// Local notifications for incoming ปิ่น messages. Fires while the app is open
/// or backgrounded (not killed). True closed-app delivery needs a push gateway
/// (sygnal) + APNs/FCM credentials — see the architecture notes.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _started = false;

  Future<void> init() async {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Bangkok'));
    const settings = InitializationSettings(
      iOS: DarwinInitializationSettings(),
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(settings: settings);
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
      if (m.isMe || m.kind == 'reaction' || m.kind == 'tasks') return;
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
    await _plugin.zonedSchedule(
      id: id,
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
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: daily ? DateTimeComponents.time : null,
    );
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
  Future<void> cancel(int id) => _plugin.cancel(id: id);

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

  Future<void> _show(String roomId, String body) async {
    await _plugin.show(
      id: roomId.hashCode,
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
