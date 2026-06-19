import 'dart:convert';

import 'package:flutter/foundation.dart';

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
}
