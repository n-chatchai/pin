import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'matrix_service.dart';

/// A timed event in the "วันนี้" section (bot io.tokens2.events).
class PinEvent {
  final String id;
  final String time; // "HH:MM"
  final String title;
  final bool remind;
  const PinEvent(this.id, this.time, this.title, {this.remind = false});
}

/// A scheduled job in the "ตั้งเวลา" section (bot io.tokens2.jobs).
class PinJob {
  final String id;
  final String time; // "HH:MM"
  final String text;
  final String repeat; // once | daily
  final String kind; // reminder | agentic
  const PinJob(this.id, this.time, this.text,
      {this.repeat = 'once', this.kind = 'reminder'});
  bool get isAgentic => kind == 'agentic';
}

/// Live "วันนี้" events, fed by the bot's io.tokens2.events payloads. Empty
/// until the bot sends real events — no mock data.
class EventsController extends ValueNotifier<List<PinEvent>> {
  EventsController._() : super(const []);
  static final EventsController instance = EventsController._();

  void updateFromJson(String? json) {
    if (json == null || json.isEmpty) return;
    try {
      final list = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
      value = [
        for (final e in list)
          PinEvent(
            '${e['id'] ?? ''}',
            '${e['time'] ?? ''}',
            '${e['title'] ?? ''}',
            remind: e['remind'] == true,
          ),
      ];
    } catch (_) {/* ignore malformed */}
  }

  /// Seed events from the ปิ่น DM room (the single source of truth). Best-effort.
  Future<void> loadFromRoom(String roomId) async {
    try {
      final items = await MatrixService.instance
          .loadListFromRoom(roomId, 'io.tokens2.events');
      if (items.isNotEmpty) updateFromJson(jsonEncode(items));
    } catch (_) {/* best-effort */}
  }
}

/// Lights a dot on the left "ตอนนี้" button when ปิ่น adds something there
/// (reminder/job/knowledge); cleared when the panel is opened.
class NowBadge extends ValueNotifier<bool> {
  NowBadge._() : super(false);
  static final NowBadge instance = NowBadge._();
  void mark() => value = true;
  void clear() => value = false;
}

/// One thing ปิ่น has learned/remembered (on-device memory).
class MemoryItem {
  final String text;
  final String kind; // 'fact' | 'knowledge'
  const MemoryItem(this.text, this.kind);
}

/// Recent on-device memory (facts + saved knowledge), shown in the "ตอนนี้"
/// panel's "ความรู้ใหม่" section. Fed from AgentStore, newest first.
class MemoryController extends ValueNotifier<List<MemoryItem>> {
  MemoryController._() : super(const []);
  static final MemoryController instance = MemoryController._();
  void setItems(List<MemoryItem> items) => value = items;
}

/// Live "ตั้งเวลา" scheduled jobs, fed by the bot's io.tokens2.jobs payloads.
class JobsController extends ValueNotifier<List<PinJob>> {
  JobsController._() : super(const []);
  static final JobsController instance = JobsController._();

  void updateFromJson(String? json) {
    if (json == null || json.isEmpty) return;
    try {
      final list = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
      value = [
        for (final j in list)
          PinJob(
            '${j['id'] ?? ''}',
            '${j['time'] ?? ''}',
            '${j['text'] ?? ''}',
            repeat: '${j['repeat'] ?? 'once'}',
            kind: '${j['kind'] ?? 'reminder'}',
          ),
      ];
    } catch (_) {/* ignore malformed */}
  }

  /// Seed jobs/reminders from the ปิ่น DM room (the single source of truth).
  /// Reuses [updateFromJson], which reads the same `{id,time,text,repeat,kind}`
  /// shape AgentStore writes to `io.tokens2.reminders`. Best-effort.
  Future<void> loadFromRoom(String roomId) async {
    try {
      final items = await MatrixService.instance
          .loadListFromRoom(roomId, 'io.tokens2.reminders');
      if (items.isNotEmpty) updateFromJson(jsonEncode(items));
    } catch (_) {/* best-effort */}
  }
}

/// One topic ปิ่น is keeping an eye on for the user (room state
/// io.tokens2.watches). The drawer shows these as a glance ("ปิ่นเฝ้าให้อยู่");
/// the actual findings land in chat. `lastSeen` is the latest finding text,
/// `hasNew` flags a finding the user hasn't read in chat yet.
class PinWatch {
  final String id;
  final String topic;
  final String lastSeen;
  final int lastSeenAt; // ms epoch
  final bool hasNew;
  const PinWatch(this.id, this.topic,
      {this.lastSeen = '', this.lastSeenAt = 0, this.hasNew = false});
}

/// Live watch list, fed from the ปิ่น DM room state `io.tokens2.watches`.
/// Empty until ปิ่น captures an interest — no mock data.
class WatchesController extends ValueNotifier<List<PinWatch>> {
  WatchesController._() : super(const []);
  static final WatchesController instance = WatchesController._();

  void updateFromJson(String? json) {
    if (json == null || json.isEmpty) return;
    try {
      final list = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
      value = [
        for (final w in list)
          PinWatch(
            '${w['id'] ?? ''}',
            '${w['topic'] ?? ''}',
            lastSeen: '${w['last_seen'] ?? ''}',
            lastSeenAt: (w['last_seen_at'] as num?)?.toInt() ?? 0,
            hasNew: w['has_new'] == true,
          ),
      ];
    } catch (_) {/* ignore malformed */}
  }

  Future<void> loadFromRoom(String roomId) async {
    try {
      final items = await MatrixService.instance
          .loadListFromRoom(roomId, 'io.tokens2.watches');
      if (items.isNotEmpty) updateFromJson(jsonEncode(items));
    } catch (_) {/* best-effort */}
  }

  /// Clear the "เจอใหม่" flags once the user heads to chat to read them.
  /// Best-effort; writes back to the room (single source of truth).
  Future<void> markAllSeen() async {
    if (value.every((w) => !w.hasNew)) return;
    try {
      final rid = await MatrixService.instance.pinRoomId();
      if (rid == null) return;
      final list = await MatrixService.instance
          .loadListFromRoom(rid, 'io.tokens2.watches');
      var changed = false;
      for (final w in list) {
        if (w['has_new'] == true) {
          w['has_new'] = false;
          changed = true;
        }
      }
      if (changed) {
        await MatrixService.instance
            .saveListToRoom(rid, 'io.tokens2.watches', list);
        updateFromJson(jsonEncode(list));
      }
    } catch (_) {/* best-effort */}
  }
}
