import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/chat_view_message.dart';

/// Export / share whatever ปิ่น produced in a bot message, so the user can save
/// it out of the app (Files, Photos, AirDrop, LINE…).
///
/// - image message      → share the image file as-is
/// - flex with HTML      → write a standalone .html and share it (HTML lives in
///                         a WKWebView, which a Flutter screenshot can't capture)
/// - flex (pure Flutter) → screenshot the rendered card to PNG and share
/// - plain text          → share the text
class PinExport {
  /// One GlobalKey per message id → wraps the on-screen card so we can snapshot
  /// it. The bubble registers the boundary; export reads it back here.
  static final Map<String, GlobalKey> boundaryKeys = {};

  static GlobalKey keyFor(String eventId) =>
      boundaryKeys.putIfAbsent(eventId, () => GlobalKey());

  static Future<void> share(ChatViewMessage msg) async {
    // 1) Image: share the underlying file.
    if (msg.flex == null && msg.kind == 'image' && msg.localPath != null) {
      await Share.shareXFiles([XFile(msg.localPath!)], sharePositionOrigin: const Rect.fromLTWH(0, 0, 100, 100));
      return;
    }

    // 2) Flex card.
    final flex = msg.flex;
    if (flex != null) {
      final htmls = _collectHtml(flex);
      if (htmls.isNotEmpty) {
        final path = await _writeHtml(htmls, msg.eventId);
        await Share.shareXFiles([XFile(path, mimeType: 'text/html')], sharePositionOrigin: const Rect.fromLTWH(0, 0, 100, 100));
        return;
      }
      final png = await _capture(msg.eventId);
      if (png != null) {
        final path = await _writeBytes(png, msg.eventId, 'png');
        await Share.shareXFiles([XFile(path, mimeType: 'image/png')], sharePositionOrigin: const Rect.fromLTWH(0, 0, 100, 100));
        return;
      }
    }

    // 3) Fallback: share text.
    final text = msg.body.trim();
    if (text.isNotEmpty) await Share.share(text);
  }

  /// True when there's something worth offering an export action for.
  static bool canShare(ChatViewMessage msg) =>
      msg.flex != null ||
      (msg.kind == 'image' && msg.localPath != null) ||
      msg.body.trim().isNotEmpty;

  // -- helpers ---------------------------------------------------------------

  /// Pull every `{type:'html', html:'…'}` block out of a flex spec (carousel
  /// cards included), in render order.
  static List<String> _collectHtml(Map<String, dynamic> spec) {
    final out = <String>[];
    void walk(Map<String, dynamic> s) {
      final carousel = s['carousel'] as List?;
      if (carousel != null) {
        for (final c in carousel) {
          if (c is Map) walk(c.cast<String, dynamic>());
        }
      }
      final body = s['body'] as List?;
      if (body != null) {
        for (final b in body) {
          if (b is Map && b['type'] == 'html' && b['html'] is String) {
            out.add(b['html'] as String);
          }
        }
      }
    }

    walk(spec);
    return out;
  }

  static Future<String> _writeHtml(List<String> htmls, String id) async {
    final doc = StringBuffer()
      ..writeln('<!doctype html><html><head><meta charset="utf-8">')
      ..writeln('<meta name="viewport" content="width=device-width,'
          'initial-scale=1">')
      ..writeln('<style>body{font-family:-apple-system,system-ui,sans-serif;'
          'margin:16px;color:#282822;line-height:1.5}'
          'img{max-width:100%;border-radius:10px}</style></head><body>')
      ..writeln(htmls.join('<hr style="border:none;border-top:1px solid #eee;'
          'margin:20px 0">'))
      ..writeln('</body></html>');
    return _writeString(doc.toString(), id, 'html');
  }

  static Future<Uint8List?> _capture(String id) async {
    final ctx = boundaryKeys[id]?.currentContext;
    if (ctx == null) return null;
    final obj = ctx.findRenderObject();
    if (obj is! RenderRepaintBoundary) return null;
    final image = await obj.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  static Future<String> _writeBytes(
      Uint8List bytes, String id, String ext) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/pin_$id.$ext');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  static Future<String> _writeString(
      String content, String id, String ext) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/pin_$id.$ext');
    await f.writeAsString(content);
    return f.path;
  }
}
