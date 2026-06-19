import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A task ปิ่น is tracking for the user.
class PinTask {
  final String group; // รอคุณ / รอเขา / เดดไลน์ / เงินค้าง
  final String text;
  final String? sub;
  final String? due;
  final bool today;
  final bool overdue;
  const PinTask(this.group, this.text,
      {this.sub, this.due, this.today = false, this.overdue = false});
}

/// Live task list, fed by the bot's io.tokens2.tasks payloads. Starts empty —
/// no mock data: no real tasks means an empty screen, not fake ones.
class TasksController extends ValueNotifier<List<PinTask>> {
  TasksController._() : super(const []);
  static final TasksController instance = TasksController._();

  /// Replace the list from a bot tasks payload (JSON array of {group,text,due}).
  void updateFromJson(String? json) {
    if (json == null || json.isEmpty) return;
    try {
      final list = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
      value = [
        for (final t in list)
          PinTask(
            '${t['group'] ?? 'รอคุณ'}',
            '${t['text'] ?? ''}',
            due: (t['due'] as String?)?.isNotEmpty == true
                ? t['due'] as String
                : null,
          ),
      ];
    } catch (_) {/* ignore malformed */}
  }
}
