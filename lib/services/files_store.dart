import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'matrix_service.dart';

/// One artifact ปิ่น handled or made (uploaded doc, scan, photo, voice, gen
/// image). We never keep raw bytes of *server-processed* docs — only this
/// record. For media (image/audio) we keep a private on-device copy at [uri]
/// so it can be re-opened; gen images keep their remote URL.
class FileItem {
  final int id;
  final String name;
  final String type; // pdf / docx / รูป / เสียง …
  final String summary; // ปิ่น's short summary (may be empty)
  final String uri; // local file path OR remote url ('' = nothing to open)
  final int createdAt; // ms since epoch

  const FileItem({
    required this.id,
    required this.name,
    required this.type,
    required this.summary,
    required this.uri,
    required this.createdAt,
  });

  bool get isImage => type == 'รูป' && uri.isNotEmpty;
  bool get isAudio => type == 'เสียง';
  bool get isRemote => uri.startsWith('http');

  static FileItem fromRow(Map<String, Object?> r) => FileItem(
        id: r['id'] as int,
        name: '${r['name'] ?? ''}',
        type: '${r['type'] ?? ''}',
        summary: '${r['summary'] ?? ''}',
        uri: '${r['uri'] ?? ''}',
        createdAt: (r['created_at'] as int?) ?? 0,
      );
}

/// On-device SQLite store of processed files, kept newest-first and read in
/// pages for the "ไฟล์" tab's infinite scroll. Lives in the app's private DB
/// dir (encrypted at rest by iOS Data Protection); nothing leaves the phone.
class FilesStore {
  FilesStore._();
  static final FilesStore instance = FilesStore._();

  Database? _db;
  String? _dbAccount; // which account the open _db belongs to

  /// Sanitized account key for per-account file isolation (db + media dir).
  /// Null account → legacy shared names so pre-upgrade installs keep working.
  String get _acct {
    final uid = MatrixService.instance.userId;
    return uid == null
        ? ''
        : uid.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  /// Relative media subdir for this account (`media` legacy, `media/<acct>`).
  String get _mediaRel => _acct.isEmpty ? 'media' : p.join('media', _acct);

  /// This account's media directory (absolute), created if missing.
  Future<Directory> _mediaDir() async {
    final dir = await getApplicationSupportDirectory();
    final media = Directory(p.join(dir.path, _mediaRel));
    if (!await media.exists()) await media.create(recursive: true);
    return media;
  }

  /// Resolve a stored media reference to an absolute path. We persist paths
  /// RELATIVE to the app support dir, because iOS reassigns the data container
  /// (and its absolute prefix) on reinstall/restore — an absolute path saved by
  /// an earlier install points nowhere later ("รูปไม่โชว์"). Remote urls and
  /// legacy absolute paths are returned unchanged.
  Future<String> absPath(String stored) async {
    if (stored.isEmpty || stored.startsWith('http') || stored.startsWith('/')) {
      return stored;
    }
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, stored);
  }

  /// Close the open DB so the next account opens its own. Called on logout.
  Future<void> reset() async {
    await _db?.close();
    _db = null;
    _dbAccount = null;
  }

  Future<Database> _open() async {
    final acct = _acct;
    // Reopen if the logged-in account changed under us (defensive — logout
    // calls reset(), but this guards a missed reset).
    if (_db != null && _dbAccount == acct) return _db!;
    await _db?.close();
    final dir = await getApplicationSupportDirectory();
    final name = acct.isEmpty ? 'pin_files.db' : 'pin_files_$acct.db';
    _dbAccount = acct;
    _db = await openDatabase(
      p.join(dir.path, name),
      version: 2,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE files(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          type TEXT,
          summary TEXT,
          uri TEXT,
          created_at INTEGER NOT NULL
        )'''),
      onUpgrade: (db, old, _) async {
        if (old < 2) await db.execute('ALTER TABLE files ADD COLUMN uri TEXT');
      },
    );
    return _db!;
  }

  /// Copy a media file (image/audio) into the app's private support dir so it
  /// survives temp-dir cleanup and can be re-opened from the "ไฟล์" tab.
  /// Returns the new path; falls back to the source path on any failure.
  Future<String> persistMedia(String srcPath, String ext, {int? when}) async {
    try {
      final media = await _mediaDir();
      final stamp = when ?? DateTime.now().millisecondsSinceEpoch;
      final name = '$stamp.$ext';
      await File(srcPath).copy(p.join(media.path, name));
      // Return a path RELATIVE to the support dir so it survives container
      // reassignment; callers resolve via [absPath] before reading.
      return p.join(_mediaRel, name);
    } catch (_) {
      return srcPath;
    }
  }

  /// Write generated text (e.g. an html card) to a private file so it can be
  /// re-opened from the "ไฟล์" tab. Returns the path ('' on failure).
  Future<String> persistText(String content, String ext, {int? when}) async {
    try {
      final media = await _mediaDir();
      final stamp = when ?? DateTime.now().millisecondsSinceEpoch;
      final name = '$stamp.$ext';
      await File(p.join(media.path, name)).writeAsString(content);
      return p.join(_mediaRel, name); // relative — resolve via [absPath]
    } catch (_) {
      return '';
    }
  }

  /// Record an artifact. [when] lets the caller pass the timestamp; defaults
  /// to now. [uri] is a local path or remote url for re-opening (media only).
  Future<void> add({
    required String name,
    required String type,
    String summary = '',
    String uri = '',
    int? when,
  }) async {
    final db = await _open();
    await db.insert('files', {
      'name': name,
      'type': type,
      'summary': summary,
      'uri': uri,
      'created_at': when ?? DateTime.now().millisecondsSinceEpoch,
    });
    FilesController.instance.bump();
  }

  /// A page of files, newest first. Used by the infinite-scroll list.
  Future<List<FileItem>> page({required int offset, int limit = 20}) async {
    final db = await _open();
    final rows = await db.query('files',
        orderBy: 'created_at DESC', limit: limit, offset: offset);
    // Resolve stored (relative) uris to absolute paths for the UI to open.
    return Future.wait(rows.map((r) async {
      final item = FileItem.fromRow(r);
      if (item.uri.isEmpty || item.isRemote) return item;
      return FileItem.fromRow({...r, 'uri': await absPath(item.uri)});
    }));
  }

  Future<int> count() async {
    final db = await _open();
    return Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM files')) ??
        0;
  }

  Future<void> remove(int id) async {
    final db = await _open();
    final rows =
        await db.query('files', columns: ['uri'], where: 'id = ?', whereArgs: [id]);
    final uri = rows.isEmpty ? '' : '${rows.first['uri'] ?? ''}';
    await db.delete('files', where: 'id = ?', whereArgs: [id]);
    if (uri.isNotEmpty && !uri.startsWith('http')) {
      try {
        final f = File(await absPath(uri));
        if (await f.exists()) await f.delete();
      } catch (_) {/* best effort */}
    }
    FilesController.instance.bump();
  }
}

/// Pings the "ไฟล์" tab to reload its first page when a new file lands.
class FilesController extends ChangeNotifier {
  FilesController._();
  static final FilesController instance = FilesController._();
  void bump() => notifyListeners();
}
