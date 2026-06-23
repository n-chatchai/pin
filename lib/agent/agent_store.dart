import 'dart:async';
import 'dart:convert';

import '../services/matrix_service.dart';
import '../services/now_controllers.dart';
import 'embedder.dart';

/// A saved piece of knowledge. Text only — its embedding is a derived cache held
/// in RAM by [AgentStore] (never persisted), so the room stays the single source.
class KnowledgeItem {
  final String title;
  final String summary;
  final String content;
  const KnowledgeItem(this.title, this.summary, this.content);

  /// The text we embed for semantic recall (title + summary + content).
  String get embedText => [title, summary, content]
      .where((s) => s.isNotEmpty)
      .join('\n');

  Map<String, dynamic> toJson() => {
        'title': title,
        'summary': summary,
        'content': content,
      };
  static KnowledgeItem fromJson(Map<String, dynamic> j) => KnowledgeItem(
        '${j['title'] ?? ''}',
        '${j['summary'] ?? ''}',
        '${j['content'] ?? ''}',
      );
}

/// Agent memory (facts / knowledge / reminders), scoped per ปิ่น DM room. The
/// Matrix room IS the store: facts+knowledge ride an E2EE blob (io.tokens2.memory)
/// and reminders ride room state (io.tokens2.reminders). Nothing is written to
/// disk — each tool call builds a fresh store and [load]s straight from the room.
///
/// Knowledge embeddings are recomputed on-device from the room text (via
/// [Embedder]) and memoized in a process-wide RAM cache, so they survive a device
/// move (rebuilt from the room) without ever being persisted or sent to a server.
class AgentStore {
  static const _maxFacts = 40;
  static const _maxKnowledge = 50;

  /// Content → vector. Static so the many short-lived [AgentStore] instances
  /// (one per tool call) reuse embeddings instead of recomputing every recall.
  /// Disposable RAM cache; rebuilt from room text after a wipe/device move.
  static final Map<String, List<double>> _embCache = {};

  final Map<String, List<String>> _facts = {};
  final Map<String, List<KnowledgeItem>> _knowledge = {};
  final List<Map<String, dynamic>> _reminders = []; // {id,time,text,repeat,kind}

  /// Read everything from the ปิ่น DM room (the single source of truth): reminders
  /// from room state, facts+knowledge from the E2EE memory blob. Then prune stale
  /// one-shots and seed the "ตอนนี้" controllers. Best-effort — no room yet or a
  /// network failure leaves an empty store.
  Future<void> load() async {
    final rid = await MatrixService.instance.pinRoomId();
    if (rid != null) {
      try {
        final fromRoom = await MatrixService.instance
            .loadListFromRoom(rid, 'io.tokens2.reminders');
        _reminders
          ..clear()
          ..addAll(fromRoom);
      } catch (_) {/* leave empty */}

      try {
        final blob = await MatrixService.instance
            .loadEncryptedBlob(rid, 'io.tokens2.memory');
        if (blob != null) _restoreMemory(blob);
      } catch (_) {/* leave empty */}
    }

    await pruneReminders(DateTime.now());
    JobsController.instance.updateFromJson(jsonEncode(_reminders));
    _refreshMemoryController();
  }

  /// Repopulate per-room [_facts]/[_knowledge] from the flat memory blob.
  void _restoreMemory(Map<String, dynamic> blob) {
    final facts = blob['facts'];
    if (facts is Map) {
      _facts.clear();
      for (final e in facts.entries) {
        if (e.value is List) {
          _facts['${e.key}'] = (e.value as List).map((x) => '$x').toList();
        }
      }
    }
    final knowledge = blob['knowledge'];
    if (knowledge is Map) {
      _knowledge.clear();
      for (final e in knowledge.entries) {
        if (e.value is List) {
          _knowledge['${e.key}'] = (e.value as List)
              .map((x) => KnowledgeItem.fromJson((x as Map).cast<String, dynamic>()))
              .toList();
        }
      }
    }
  }

  /// Push the WHOLE memory (facts + knowledge across all rooms) to the ปิ่น DM as
  /// an E2EE blob. Embeddings are excluded (derived, recomputed on-device).
  /// Best-effort — no ปิ่น room or a network failure is a silent no-op.
  Future<void> _persistMemory() async {
    final rid = await MatrixService.instance.pinRoomId();
    if (rid == null) return;
    try {
      await MatrixService.instance
          .saveEncryptedBlob(rid, 'io.tokens2.memory', {
        'facts': {for (final e in _facts.entries) e.key: e.value},
        'knowledge': {
          for (final e in _knowledge.entries)
            e.key: [for (final k in e.value) k.toJson()],
        },
      });
    } catch (_) {/* best-effort */}
  }

  /// Feed the "ความรู้ใหม่" section: facts then knowledge titles, newest first.
  void _refreshMemoryController() {
    final items = <MemoryItem>[
      for (final list in _facts.values)
        for (final f in list.reversed) MemoryItem(f, 'fact'),
      for (final list in _knowledge.values)
        for (final k in list.reversed) MemoryItem(k.title, 'knowledge'),
    ];
    MemoryController.instance.setItems(items);
  }

  // -- facts -----------------------------------------------------------------
  List<String> facts(String room) => List.of(_facts[room] ?? const []);

  Future<void> addFact(String room, String text) async {
    final f = _facts.putIfAbsent(room, () => []);
    if (!f.contains(text)) {
      f.add(text);
      if (f.length > _maxFacts) f.removeRange(0, f.length - _maxFacts);
      await _persistMemory();
      _refreshMemoryController();
    }
  }

  // -- knowledge -------------------------------------------------------------
  List<String> knowledgeTitles(String room) =>
      (_knowledge[room] ?? const []).map((k) => k.title).toList();

  Future<void> addKnowledge(String room, KnowledgeItem item) async {
    final k = _knowledge.putIfAbsent(room, () => []);
    k.add(item);
    if (k.length > _maxKnowledge) k.removeRange(0, k.length - _maxKnowledge);
    await _persistMemory();
    _refreshMemoryController();
    // Warm the embedding cache so the first recall is fast. Best-effort.
    unawaited(_embed(item.embedText));
  }

  /// Embed [text] on-device, memoized. Null when no model is provisioned.
  Future<List<double>?> _embed(String text) async {
    final cached = _embCache[text];
    if (cached != null) return cached;
    final v = await Embedder.instance.embedPassage(text);
    if (v != null) _embCache[text] = v;
    return v;
  }

  /// Semantic recall over a room's knowledge. Embeds the [query] + each item
  /// on-device and ranks by cosine; falls back to newest-first when no model is
  /// provisioned (or nothing clears the similarity floor). Returns up to [k].
  Future<List<KnowledgeItem>> searchKnowledge(
      String room, String query, int k) async {
    final items = _knowledge[room] ?? const [];
    if (items.isEmpty) return const [];
    final qEmb = await Embedder.instance.embedQuery(query);
    if (qEmb == null) return items.reversed.take(k).toList(); // no model
    final scored = <({double score, KnowledgeItem item})>[];
    for (final it in items) {
      final emb = await _embed(it.embedText);
      if (emb == null) continue;
      scored.add((score: cosine(qEmb, emb), item: it));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    final hits =
        scored.where((s) => s.score > 0.25).take(k).map((s) => s.item).toList();
    return hits.isEmpty ? items.reversed.take(k).toList() : hits;
  }

  // -- reminders -------------------------------------------------------------
  /// Scheduled reminders/jobs the agent set (shown in the left "ตอนนี้" panel).
  List<Map<String, dynamic>> reminders() => List.of(_reminders);

  Future<void> addReminder(Map<String, dynamic> r) async {
    _reminders.removeWhere((x) => x['id'] == r['id']);
    _reminders.add(r);
    await _persistReminders();
  }

  Future<void> removeReminder(String id) async {
    _reminders.removeWhere((x) => '${x['id']}' == id);
    await _persistReminders();
  }

  /// Mirror the whole reminders list to the ปิ่น DM room state (the source of
  /// truth) and refresh the "ตั้งเวลา" list. Best-effort.
  Future<void> _persistReminders() async {
    final rid = await MatrixService.instance.pinRoomId();
    if (rid != null) {
      try {
        await MatrixService.instance
            .saveListToRoom(rid, 'io.tokens2.reminders', _reminders.cast());
      } catch (_) {/* best-effort */}
    }
    JobsController.instance.updateFromJson(jsonEncode(_reminders));
  }

  /// Drop one-shot reminders whose time has already passed (called on load).
  Future<void> pruneReminders(DateTime now) async {
    final before = _reminders.length;
    _reminders.removeWhere((r) {
      if ('${r['repeat']}' == 'daily') return false;
      // Agentic jobs are owned by _runDueJobs — it runs the overdue one, THEN
      // clears it. Pruning here would drop the job before it ever executes
      // (the OS notification still fires → "เตือนมา แต่ไม่มีเนื้อหา").
      if ('${r['kind']}' == 'agentic') return false;
      final ts = r['at'];
      return ts is int &&
          DateTime.fromMillisecondsSinceEpoch(ts).isBefore(now);
    });
    // Persist the pruned list back to the room (the source of truth).
    if (_reminders.length != before) await _persistReminders();
  }
}
