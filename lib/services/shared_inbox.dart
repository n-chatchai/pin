import 'package:flutter/foundation.dart';

/// How a shared item routes into the chat: [text] → a normal turn, [image] →
/// ปิ่น sees the photo, [file] → markitdown converter → summary.
enum SharedKind { text, image, file }

@immutable
class SharedItem {
  final SharedKind kind;

  /// For [text]: the shared text/URL. For [image]/[file]: the local file path.
  final String value;

  /// Display/file name (used when converting a document).
  final String name;

  const SharedItem(this.kind, this.value, {this.name = ''});

  @override
  bool operator ==(Object other) =>
      other is SharedItem &&
      other.kind == kind &&
      other.value == value &&
      other.name == name;

  @override
  int get hashCode => Object.hash(kind, value, name);
}

/// Classify a receive_sharing_intent `SharedMediaFile` into a routing [kind].
/// Pure so it's unit-testable without the plugin.
///
/// [typeName] is `SharedMediaType.name` ('text' | 'url' | 'image' | 'video' |
/// 'file'); [path] is the shared text/URL string OR a file path; [mimeType] is
/// optional. Images arriving under the generic 'file' type (a share sheet often
/// tags photos that way) are re-routed to [image] by extension/mime so ปิ่น
/// views them instead of running them through the document converter.
SharedItem classifyShared({
  required String typeName,
  required String path,
  String? mimeType,
}) {
  const imageExt = {'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif', 'bmp'};
  bool looksImage() {
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    return imageExt.contains(ext) || (mimeType ?? '').startsWith('image/');
  }

  switch (typeName) {
    case 'text':
    case 'url':
      return SharedItem(SharedKind.text, path);
    case 'image':
      return SharedItem(SharedKind.image, path);
    default: // 'file' | 'video' | anything else → treat as a document/attachment
      if (looksImage()) return SharedItem(SharedKind.image, path);
      final name = path.contains('/') ? path.split('/').last : path;
      return SharedItem(SharedKind.file, path, name: name);
  }
}

/// A tiny queue between the OS share sheet and the chat screen. A share can land
/// before the chat is mounted (cold start into onboarding) or while it's busy,
/// so items are buffered here and the chat drains them when it's ready. Room/DM
/// is still the source of truth — this only carries the pending *input*.
class SharedInbox {
  SharedInbox._();
  static final SharedInbox instance = SharedInbox._();

  /// Bumps whenever new items are queued, so the chat can react without polling.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final List<SharedItem> _queue = <SharedItem>[];

  void addAll(Iterable<SharedItem> items) {
    final incoming = items.where((i) => i.value.trim().isNotEmpty).toList();
    if (incoming.isEmpty) return;
    _queue.addAll(incoming);
    revision.value++;
  }

  bool get hasPending => _queue.isNotEmpty;

  /// Remove and return everything pending (FIFO). The chat routes each item.
  List<SharedItem> drain() {
    final out = List<SharedItem>.of(_queue);
    _queue.clear();
    return out;
  }
}
