import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../services/matrix_service.dart';
import 'embed_client.dart';

/// A saved piece of knowledge with its embedding (for on-device semantic recall).
class KnowledgeItem {
  final String title;
  final String summary;
  final String content;
  final List<double>? embedding;
  const KnowledgeItem(this.title, this.summary, this.content, this.embedding);

  Map<String, dynamic> toJson() => {
        'title': title,
        'summary': summary,
        'content': content,
        if (embedding != null) 'embedding': embedding,
      };
  static KnowledgeItem fromJson(Map<String, dynamic> j) => KnowledgeItem(
        '${j['title'] ?? ''}',
        '${j['summary'] ?? ''}',
        '${j['content'] ?? ''}',
        (j['embedding'] as List?)?.map((e) => (e as num).toDouble()).toList(),
      );
}

/// On-device agent memory (history / facts / knowledge / prefs), room-scoped.
/// Persisted as a JSON file in the app support dir — encrypted at rest by iOS
/// Data Protection (tied to the device passcode). The server never holds this.
class AgentStore {
  static const _maxTurns = 20;
  static const _maxFacts = 40;
  static const _maxKnowledge = 50;

  final Map<String, List<Map<String, dynamic>>> _history = {};
  final Map<String, List<String>> _facts = {};
  final Map<String, List<KnowledgeItem>> _knowledge = {};
  final List<Map<String, dynamic>> _reminders = []; // {id,time,text,repeat,kind}
  Map<String, dynamic> prefs = {};
  File? _file;

  /// Per-account store file. Each logged-in account gets its own JSON so one
  /// account's chat history/facts/knowledge can never surface under another
  /// (the store was a single shared `agent_store.json` before — a cross-account
  /// leak). Falls back to the legacy shared name when no account is loaded yet.
  Future<File> _storeFile() async {
    final dir = await getApplicationSupportDirectory();
    final uid = MatrixService.instance.userId;
    if (uid == null) return File('${dir.path}/agent_store.json');
    final safe = uid.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return File('${dir.path}/agent_store_$safe.json');
  }

  Future<void> load() async {
    _file = await _storeFile();
    if (!await _file!.exists()) return;
    try {
      final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
      for (final e in (j['history'] as Map? ?? {}).entries) {
        _history[e.key] = (e.value as List).cast<Map<String, dynamic>>();
      }
      for (final e in (j['facts'] as Map? ?? {}).entries) {
        _facts[e.key] = (e.value as List).map((x) => '$x').toList();
      }
      for (final e in (j['knowledge'] as Map? ?? {}).entries) {
        _knowledge[e.key] = (e.value as List)
            .map((x) => KnowledgeItem.fromJson(x as Map<String, dynamic>))
            .toList();
      }
      _reminders
        ..clear()
        ..addAll((j['reminders'] as List? ?? [])
            .map((x) => (x as Map).cast<String, dynamic>()));
      prefs = (j['prefs'] as Map?)?.cast<String, dynamic>() ?? {};
    } catch (_) {/* ignore corrupt store */}
  }

  Future<void> save() async {
    if (_file == null) return;
    final j = {
      'history': _history,
      'facts': _facts,
      'knowledge': {
        for (final e in _knowledge.entries)
          e.key: e.value.map((k) => k.toJson()).toList()
      },
      'reminders': _reminders,
      'prefs': prefs,
    };
    await _file!.writeAsString(jsonEncode(j));
  }

  // -- history ---------------------------------------------------------------
  List<Map<String, dynamic>> history(String room) =>
      List.of(_history[room] ?? const []);

  Future<void> appendHistory(
      String room, List<Map<String, dynamic>> turns) async {
    final h = _history.putIfAbsent(room, () => []);
    h.addAll(turns);
    if (h.length > _maxTurns) h.removeRange(0, h.length - _maxTurns);
    await save();
  }

  /// Replace a room's model-context window wholesale (last [_maxTurns] kept).
  /// Used when the durable transcript lives in the Matrix DM: each boot seeds
  /// the agent's working history from the room instead of local JSON.
  Future<void> replaceHistory(
      String room, List<Map<String, dynamic>> turns) async {
    final h = _history[room] = List.of(turns);
    if (h.length > _maxTurns) h.removeRange(0, h.length - _maxTurns);
    await save();
  }

  // -- facts -----------------------------------------------------------------
  List<String> facts(String room) => List.of(_facts[room] ?? const []);

  Future<void> addFact(String room, String text) async {
    final f = _facts.putIfAbsent(room, () => []);
    if (!f.contains(text)) {
      f.add(text);
      if (f.length > _maxFacts) f.removeRange(0, f.length - _maxFacts);
      await save();
    }
  }

  // -- knowledge -------------------------------------------------------------
  List<String> knowledgeTitles(String room) =>
      (_knowledge[room] ?? const []).map((k) => k.title).toList();

  Future<void> addKnowledge(String room, KnowledgeItem item) async {
    final k = _knowledge.putIfAbsent(room, () => []);
    k.add(item);
    if (k.length > _maxKnowledge) k.removeRange(0, k.length - _maxKnowledge);
    await save();
  }

  // -- skills ----------------------------------------------------------------
  /// A skill is ON unless the user has explicitly disabled it. Fresh install
  /// (no 'skills_off' key) ⇒ every built-in skill is active.
  bool isSkillOn(String name) {
    final off = (prefs['skills_off'] as List?)?.map((e) => '$e').toSet();
    return off == null || !off.contains(name);
  }

  Future<void> setSkill(String name, bool on) async {
    final off = (prefs['skills_off'] as List?)?.map((e) => '$e').toSet() ?? {};
    on ? off.remove(name) : off.add(name);
    prefs = {...prefs, 'skills_off': off.toList()};
    await save();
  }

  /// Free add-ons the user has switched on (opt-in, default off).
  bool isAdded(String name) =>
      (prefs['abilities_added'] as List?)?.map((e) => '$e').contains(name) ??
      false;

  Future<void> setAdded(String name, bool on) async {
    final s =
        (prefs['abilities_added'] as List?)?.map((e) => '$e').toSet() ?? {};
    on ? s.add(name) : s.remove(name);
    prefs = {...prefs, 'abilities_added': s.toList()};
    await save();
  }

  // -- reminders -------------------------------------------------------------
  /// Scheduled reminders/jobs the agent set (shown in the left "ตอนนี้" panel).
  /// Kept newest-relevant; dropped past one-shots are pruned by [pruneReminders].
  List<Map<String, dynamic>> reminders() => List.of(_reminders);

  Future<void> addReminder(Map<String, dynamic> r) async {
    _reminders.removeWhere((x) => x['id'] == r['id']);
    _reminders.add(r);
    await save();
  }

  Future<void> removeReminder(String id) async {
    _reminders.removeWhere((x) => '${x['id']}' == id);
    await save();
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
    if (_reminders.length != before) await save();
  }

  // -- debug / maintenance --------------------------------------------------
  /// Human-readable dump of everything stored on-device (for the Settings debug
  /// panel). Includes the file path so the user can see where it lives.
  Map<String, dynamic> debugSummary() {
    final rooms = <String, dynamic>{};
    final ids = {..._history.keys, ..._facts.keys, ..._knowledge.keys};
    for (final r in ids) {
      rooms[r] = {
        'history': (_history[r] ?? const []).length,
        'facts': List.of(_facts[r] ?? const []),
        'knowledge': (_knowledge[r] ?? const []).map((k) => k.title).toList(),
      };
    }
    return {
      'path': _file?.path ?? '(not loaded)',
      'prefs': prefs,
      'reminders': _reminders,
      'rooms': rooms,
    };
  }

  /// Wipe all on-device agent data (history/facts/knowledge/prefs) + the file.
  Future<void> clearAll() async {
    _history.clear();
    _facts.clear();
    _knowledge.clear();
    _reminders.clear();
    prefs = {};
    if (_file != null && await _file!.exists()) {
      await _file!.delete();
    }
  }

  List<KnowledgeItem> searchKnowledge(
      String room, List<double>? queryEmb, int k) {
    final items = _knowledge[room] ?? const [];
    if (items.isEmpty) return const [];
    if (queryEmb == null) {
      return items.reversed.take(k).toList();
    }
    final scored = [
      for (final it in items)
        (score: cosine(queryEmb, it.embedding ?? const []), item: it)
    ]..sort((a, b) => b.score.compareTo(a.score));
    return scored.where((s) => s.score > 0.25).take(k).map((s) => s.item).toList();
  }
}
