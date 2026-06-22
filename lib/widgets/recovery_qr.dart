import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Render the combined recovery payload as a PNG with ONE branded QR code (the
/// whole `{v,e,u,p}` JSON, high EC, Pin logo in the centre) plus the account
/// label as a caption, then save it to a local file the user picks (defaults to
/// Downloads). No share sheet, so the key never reaches a cloud target unless the
/// user deliberately moves it. The restore screen decodes the PNG with ZXing,
/// which reads a single dense, logo-overlaid QR reliably.
Future<void> shareRecoveryQr(BuildContext context, String data,
    {String? caption}) async {
  try {
    Map<String, dynamic> j;
    try {
      final d = jsonDecode(data);
      j = d is Map<String, dynamic> ? d : {'u': data};
    } catch (_) {
      j = {'u': data}; // raw key (old QR)
    }
    final label = (caption != null && caption.isNotEmpty)
        ? caption
        : (j['e'] as String?);

    // ONE QR carrying the whole combined payload {v,e,u,p}. The restore screen
    // decodes it with ZXing (robust to a single dense QR), so there's no need to
    // split into two; high EC makes it survive recompression/print.
    const double pad = 56, qr = 600, captionH = 84;
    final width = qr + pad * 2;
    final hasCaption = label != null && label.isNotEmpty;
    final height = pad + qr + (hasCaption ? captionH : 0) + pad;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, width, height), Paint()..color = Colors.white);

    void drawText(String s, double cy, double size, FontWeight w) {
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                color: const Color(0xFF14301F), fontSize: size, fontWeight: w)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: width - 40);
      tp.paint(canvas, Offset((width - tp.width) / 2, cy - tp.height / 2));
    }

    final painter = QrPainter(
      data: data,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.H,
      gapless: true,
      eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square, color: Color(0xFF14301F)),
      dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square, color: Color(0xFF14301F)),
    );
    canvas.save();
    canvas.translate(pad, pad);
    painter.paint(canvas, const Size(qr, qr));
    canvas.restore();

    // Branded centre logo on a white plate. High EC (30%) covers the modules the
    // logo hides, and ZXing reads through it on restore.
    try {
      final logoData = await rootBundle.load('assets/pin-logo.png');
      final codec =
          await ui.instantiateImageCodec(logoData.buffer.asUint8List());
      final logo = (await codec.getNextFrame()).image;
      const double ls = qr * 0.20; // logo side ≈ 20% of the QR
      final double lx = pad + (qr - ls) / 2, ly = pad + (qr - ls) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(lx - 10, ly - 10, ls + 20, ls + 20),
            const Radius.circular(18)),
        Paint()..color = Colors.white,
      );
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(lx, ly, ls, ls), const Radius.circular(12)));
      canvas.drawImageRect(
        logo,
        Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
        Rect.fromLTWH(lx, ly, ls, ls),
        Paint(),
      );
      canvas.restore();
    } catch (_) {/* logo optional — QR still valid without it */}

    if (hasCaption) drawText(label, pad + qr + captionH / 2, 28, FontWeight.w600);

    final img =
        await recorder.endRecording().toImage(width.toInt(), height.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw 'no image bytes';

    final png = bytes.buffer.asUint8List();
    // Let the user pick WHERE to save the key — the system save dialog shows the
    // destination, so it's clear where it lands and they can choose (or cancel).
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'เลือกที่บันทึกกุญแจกู้คืน',
      fileName: 'pin-recovery-qr.png',
      type: FileType.image,
      bytes: png,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(path == null
            ? 'ยังไม่ได้บันทึกกุญแจ'
            : 'บันทึกกุญแจไว้ที่: ${path.split('/').last}\n$path'),
        duration: const Duration(seconds: 5)));
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('บันทึก QR ไม่ได้')));
    }
  }
}

/// Parse the barcodes decoded from a saved recovery image (one or two QRs) into
/// the combined `{v,e,u,p}` payload the restore flow expects. Accepts the new
/// per-QR tagged payloads AND a single legacy combined/raw QR.
String? combineRecoveryQrCodes(List<String> codes) {
  String? u, p, e;
  for (final c in codes) {
    try {
      final d = jsonDecode(c);
      if (d is Map) {
        final t = d['t'];
        if (t == 'u') {
          u = '${d['k'] ?? ''}';
          if (d['e'] is String) e = d['e'] as String;
        } else if (t == 'p') {
          p = '${d['k'] ?? ''}';
        } else if (d['u'] != null) {
          // a whole combined payload in one QR (legacy)
          u = '${d['u']}';
          if (d['p'] != null) p = '${d['p']}';
          if (d['e'] is String) e = d['e'] as String;
        }
        continue;
      }
    } catch (_) {/* not JSON → raw key */}
    u ??= c.trim(); // bare key string (oldest QRs)
  }
  if (u == null) return null;
  return jsonEncode({
    'v': 1,
    if (e != null) 'e': e,
    'u': u,
    if (p != null) 'p': p,
  });
}
