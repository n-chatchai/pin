import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'matrix_service.dart';

/// One artifact ปิ่น handled or made (uploaded doc, scan, photo, voice, gen
/// image). The record lives in the ปิ่น DM room state (`io.tokens2.files`) — the
/// single source of truth. Raw bytes ride the DM as an E2EE attachment ([eventId]);
/// the local [uri] copy is a disposable cache for fast re-open, rebuilt on demand.
class FileItem {
  final int id;
  final String name;
  final String type; // pdf / docx / รูป / เสียง …
  final String summary; // ปิ่น's short summary (may be empty)
  final String uri; // local file path OR remote url ('' = nothing to open)
  final int createdAt; // ms since epoch
  final String? eventId; // ปิ่น DM attachment event id (resolve bytes via downloadMedia)

  const FileItem({
    required this.id,
    required this.name,
    required this.type,
    required this.summary,
    required this.uri,
    required this.createdAt,
    this.eventId,
  });

  bool get isImage => type == 'รูป' && uri.isNotEmpty;
  bool get isAudio => type == 'เสียง';
  bool get isRemote => uri.startsWith('http');

  /// True when the local bytes aren't on THIS device (only metadata synced from
  /// another device) but can be fetched from the DM attachment.
  bool get needsDownload => !isRemote && eventId != null;

  static FileItem fromRoomMap(Map<String, dynamic> m) => FileItem(
        id: (m['id'] as num?)?.toInt() ?? 0,
        name: '${m['name'] ?? ''}',
        type: '${m['type'] ?? ''}',
        summary: '${m['summary'] ?? ''}',
        uri: '${m['uri'] ?? ''}',
        createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
        eventId: (m['event_id'] as String?)?.isEmpty == true
            ? null
            : m['event_id'] as String?,
      );

  /// Row map for mirroring metadata to the ปิ่น DM room state.
  Map<String, dynamic> toRoomMap() => {
        'id': id,
        'name': name,
        'type': type,
        'summary': summary,
        'uri': uri,
        'created_at': createdAt,
        if (eventId != null) 'event_id': eventId,
      };

  /// True when this item's text matches a search [q] (name + summary).
  bool matches(String q) {
    final t = q.toLowerCase();
    return name.toLowerCase().contains(t) || summary.toLowerCase().contains(t);
  }

  /// True when this item belongs to the given filter bucket.
  /// null = all, 'image' / 'audio' / 'doc' (everything else).
  bool inFilter(String? filter) => switch (filter) {
        'image' => type == 'รูป',
        'audio' => type == 'เสียง',
        'doc' => type != 'รูป' && type != 'เสียง',
        _ => true,
      };
}

/// In-memory list of processed files, sourced from the ปิ่น DM room state (the
/// single source of truth). No local database — the list is seeded once from the
/// room ([loadFromRoom]) and filtered/paged in memory for the "ไฟล์" tab. Bytes
/// live in the room as E2EE attachments; the on-device [uri] copies under
/// `media/<acct>/` are a disposable cache that [resolveBytes] re-downloads.
///
/// ponytail: whole list lives in one state event (~64KB → ~300 files). Past that,
/// move records to timeline events + Matrix /search.
class FilesStore {
  FilesStore._();
  static final FilesStore instance = FilesStore._();

  final List<FileItem> _items = []; // newest-first
  String? _loadedAccount; // which account [_items] belongs to

  /// Sanitized account key for per-account media isolation.
  /// Null account → legacy shared name so pre-upgrade installs keep working.
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

  /// Drop the in-memory list so the next account reloads its own. On logout.
  Future<void> reset() async {
    _items.clear();
    _loadedAccount = null;
  }

  /// Seed the in-memory list from the ปิ่น DM room (the single source of truth),
  /// newest-first. Re-reads when the logged-in account changed under us.
  Future<void> _ensureLoaded() async {
    final acct = _acct;
    if (_loadedAccount == acct) return;
    _items.clear();
    _loadedAccount = acct;
    final rid = await MatrixService.instance.pinRoomId();
    if (rid == null) return;
    try {
      final maps = await MatrixService.instance
          .loadListFromRoom(rid, 'io.tokens2.files');
      _items
        ..clear()
        ..addAll(maps.map(FileItem.fromRoomMap))
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {/* best-effort — empty list until the room syncs */}
  }

  /// Public seed/refresh used on boot & resume. Re-reads the room list.
  Future<void> loadFromRoom() async {
    _loadedAccount = null; // force re-read
    await _ensureLoaded();
    FilesController.instance.bump();
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
  ///
  /// If [uri] is a LOCAL file, its bytes are uploaded to the ปิ่น DM as an E2EE
  /// attachment (the single source of truth) and the returned event id is stored
  /// so the ไฟล์ tab can re-download them later via [resolveBytes]. The room
  /// metadata list is then rewritten — there is no local database.
  Future<void> add({
    required String name,
    required String type,
    String summary = '',
    String uri = '',
    int? when,
    String? eventId,
  }) async {
    await _ensureLoaded();
    final rid = await MatrixService.instance.pinRoomId();

    // Upload local bytes to the ปิ่น DM so they survive reinstall/restore. Remote
    // urls and empty uris carry no bytes — nothing to upload. If the caller
    // already posted the bytes as a room attachment (the chat does), it passes
    // the [eventId] so we DON'T upload a second copy.
    if (eventId == null && rid != null && uri.isNotEmpty && !uri.startsWith('http')) {
      try {
        final local = await absPath(uri);
        if (await File(local).exists()) {
          eventId = await MatrixService.instance
              .sendUserAttachment(rid, local, _mimeFor(local));
        }
      } catch (_) {/* best-effort — keep the metadata-only record */}
    }

    final ts = when ?? DateTime.now().millisecondsSinceEpoch;
    // id = creation timestamp; bump on the rare same-ms collision so remove()
    // can address a single record unambiguously.
    var id = ts;
    while (_items.any((f) => f.id == id)) {
      id++;
    }
    _items.insert(
      0,
      FileItem(
        id: id,
        name: name,
        type: type,
        summary: summary,
        uri: uri,
        createdAt: ts,
        eventId: eventId,
      ),
    );

    if (rid != null) await _persistMetadata(rid);
    FilesController.instance.bump();
  }

  /// Write the whole metadata list (newest-first) to the ปิ่น DM room state so
  /// it syncs cross-device. Best-effort.
  Future<void> _persistMetadata(String roomId) async {
    try {
      await MatrixService.instance.saveListToRoom(
        roomId,
        'io.tokens2.files',
        [for (final f in _items) f.toRoomMap()],
      );
    } catch (_) {/* best-effort */}
  }

  /// Local path to a file's bytes for display/open. Returns the local copy if
  /// present; otherwise (uploaded on ANOTHER device — only metadata synced)
  /// downloads it from the ปิ่น DM attachment by event id. Null if neither is
  /// available.
  Future<String?> resolveBytes(FileItem f) async {
    if (f.isRemote) return f.uri;
    if (f.uri.isNotEmpty) {
      final local = await absPath(f.uri);
      if (await File(local).exists()) return local;
    }
    final eid = f.eventId;
    if (eid != null && eid.isNotEmpty) {
      final rid = await MatrixService.instance.pinRoomId();
      if (rid != null) {
        try {
          return await MatrixService.instance.downloadMedia(rid, eid);
        } catch (_) {/* offline / not yet synced */}
      }
    }
    return null;
  }

  /// Best-effort mime type from a file extension (no `mime` package on board).
  static String _mimeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.heic':
        return 'image/heic';
      case '.m4a':
        return 'audio/mp4';
      case '.mp3':
        return 'audio/mpeg';
      case '.wav':
        return 'audio/wav';
      case '.aac':
        return 'audio/aac';
      case '.ogg':
        return 'audio/ogg';
      case '.pdf':
        return 'application/pdf';
      case '.txt':
        return 'text/plain';
      case '.html':
      case '.htm':
        return 'text/html';
      default:
        return 'application/octet-stream';
    }
  }

  /// A page of files, newest first. Used by the infinite-scroll list.
  /// [filter]: null = all, 'image'/'audio' = that type, 'doc' = everything else.
  /// [query]: optional text match over name + summary.
  /// Filtering/search/paging all run over the in-memory room list.
  Future<List<FileItem>> page(
      {required int offset, int limit = 20, String? filter, String? query}) async {
    await _ensureLoaded();
    final q = query?.trim() ?? '';
    final view = [
      for (final f in _items)
        if (f.inFilter(filter) && (q.isEmpty || f.matches(q))) f,
    ];
    final slice = view.skip(offset).take(limit);
    // Resolve stored (relative) uris to absolute paths for the UI to open.
    return Future.wait(slice.map((f) async {
      if (f.uri.isEmpty || f.isRemote) return f;
      return FileItem(
        id: f.id,
        name: f.name,
        type: f.type,
        summary: f.summary,
        uri: await absPath(f.uri),
        createdAt: f.createdAt,
        eventId: f.eventId,
      );
    }));
  }

  Future<int> count() async {
    await _ensureLoaded();
    return _items.length;
  }

  Future<void> remove(int id) async {
    await _ensureLoaded();
    final idx = _items.indexWhere((f) => f.id == id);
    if (idx < 0) return;
    final uri = _items[idx].uri;
    _items.removeAt(idx);
    if (uri.isNotEmpty && !uri.startsWith('http')) {
      try {
        final f = File(await absPath(uri));
        if (await f.exists()) await f.delete();
      } catch (_) {/* best effort */}
    }
    // Rewrite the room metadata list without this id (room is the source).
    final rid = await MatrixService.instance.pinRoomId();
    if (rid != null) await _persistMetadata(rid);
    FilesController.instance.bump();
  }
}

/// Pings the "ไฟล์" tab to reload its first page when a new file lands.
class FilesController extends ChangeNotifier {
  FilesController._();
  static final FilesController instance = FilesController._();
  void bump() => notifyListeners();
}
