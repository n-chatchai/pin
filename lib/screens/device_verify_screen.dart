import 'dart:async';

import 'package:flutter/material.dart';

import '../services/matrix_service.dart';
import '../src/rust/api/matrix.dart' as rust;
import '../theme/pin_theme.dart';
import '../widgets/pin_button.dart';

/// Verify this device against another device of the SAME account that's still
/// logged in: both compare 7 emoji → cross-sign. Once verified, the other device
/// auto-forwards room keys so encrypted history decrypts WITHOUT the recovery
/// key. Works both ways — open it on either device; whichever taps "เริ่ม" is
/// the initiator, the other picks up the incoming request automatically.
class DeviceVerifyScreen extends StatefulWidget {
  const DeviceVerifyScreen({super.key});
  @override
  State<DeviceVerifyScreen> createState() => _DeviceVerifyScreenState();
}

class _DeviceVerifyScreenState extends State<DeviceVerifyScreen> {
  Timer? _poll;
  String? _flowId;
  String _phase = 'idle'; // idle | connecting | emoji | done | cancelled | error
  String? _error;
  List<rust.SasEmoji> _emoji = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Poll every second: pick up an incoming request, then drive the flow.
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _step());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _step() async {
    if (_busy) return;
    _busy = true;
    try {
      final m = MatrixService.instance;
      if (_flowId == null) {
        // Not started here → see if the other device requested us.
        final inc = await m.verificationPollIncoming();
        if (inc != null) {
          await m.verificationAccept(inc.flowId);
          if (!mounted) return;
          setState(() {
            _flowId = inc.flowId;
            _phase = 'connecting';
          });
        }
        return;
      }
      final t = await m.verificationTick(_flowId!);
      if (!mounted) return;
      setState(() {
        if (t.cancelled) {
          _phase = 'cancelled';
        } else if (t.done) {
          _phase = 'done';
        } else if (t.state == 'sas' && (t.emoji?.isNotEmpty ?? false)) {
          _phase = 'emoji';
          _emoji = t.emoji!;
        } else {
          _phase = 'connecting';
        }
      });
      if (_phase == 'done' || _phase == 'cancelled') _poll?.cancel();
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = 'error';
          _error = '$e';
        });
      }
      _poll?.cancel();
    } finally {
      _busy = false;
    }
  }

  Future<void> _start() async {
    setState(() => _phase = 'connecting');
    try {
      final id = await MatrixService.instance.verificationRequestSelf();
      if (mounted) setState(() => _flowId = id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = 'error';
          _error = '$e';
        });
      }
    }
  }

  Future<void> _confirm() async {
    setState(() => _phase = 'connecting');
    try {
      await MatrixService.instance.verificationConfirm(_flowId!);
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = 'error';
          _error = '$e';
        });
      }
    }
  }

  Future<void> _cancel() async {
    if (_flowId != null) {
      try {
        await MatrixService.instance.verificationCancel(_flowId!);
      } catch (_) {}
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('ยืนยันอุปกรณ์'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _body(),
      ),
    );
  }

  Widget _body() {
    switch (_phase) {
      case 'emoji':
        return _emojiView();
      case 'done':
        return _msg(Icons.check_circle, PinPalette.ink,
            'ยืนยันสำเร็จ', 'อุปกรณ์เชื่อถือกันแล้ว — กำลังดึงแชตเก่ากลับมา '
                'อาจใช้เวลาสักครู่หลังซิงค์');
      case 'cancelled':
        return _msg(Icons.cancel, const Color(0xFFC0392B),
            'ยกเลิกแล้ว', 'การยืนยันถูกยกเลิก ลองใหม่ได้');
      case 'error':
        return _msg(Icons.error_outline, const Color(0xFFC0392B),
            'มีปัญหา', _error ?? '');
      case 'connecting':
        return const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('กำลังเชื่อมกับอีกอุปกรณ์…',
              style: TextStyle(color: PinPalette.ink2)),
        ]));
      default: // idle
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('ยืนยันด้วยอุปกรณ์เก่า', style: PinPalette.brand(size: 24)),
            const SizedBox(height: 14),
            const Text(
                'ถ้ายังมีอุปกรณ์เก่าที่ล็อกอินบัญชีนี้อยู่ ให้เปิดหน้านี้ทั้ง '
                'สองเครื่อง แล้วกด "เริ่มยืนยัน" ที่เครื่องใดเครื่องหนึ่ง '
                'จากนั้นเทียบรูป 7 ตัวให้ตรงกัน เพื่อปลดล็อกแชตเก่าโดยไม่ต้องใช้ '
                'กุญแจกู้คืน',
                style: TextStyle(color: PinPalette.ink2, height: 1.5)),
            const SizedBox(height: 24),
            PinButton('เริ่มยืนยัน', onTap: _start),
            const SizedBox(height: 8),
            const Center(
                child: Text('หรือรอรับคำขอจากอีกเครื่อง…',
                    style: TextStyle(color: PinPalette.ink3, fontSize: 12))),
          ],
        );
    }
  }

  Widget _emojiView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('เทียบรูปให้ตรงกัน', style: PinPalette.brand(size: 24)),
        const SizedBox(height: 6),
        const Text('ทั้งสองเครื่องต้องเห็นรูป 7 ตัวนี้เหมือนกัน',
            style: TextStyle(color: PinPalette.ink2)),
        const SizedBox(height: 20),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 18,
          runSpacing: 18,
          children: [
            for (final e in _emoji)
              SizedBox(
                width: 80,
                child: Column(children: [
                  Text(e.symbol, style: const TextStyle(fontSize: 38)),
                  const SizedBox(height: 4),
                  Text(e.description,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11, color: PinPalette.ink2)),
                ]),
              ),
          ],
        ),
        const SizedBox(height: 28),
        PinButton('ตรงกัน', onTap: _confirm),
        const SizedBox(height: 8),
        PinButton.text('ไม่ตรง — ยกเลิก', onTap: _cancel),
      ],
    );
  }

  Widget _msg(IconData icon, Color color, String title, String sub) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 56),
          const SizedBox(height: 14),
          Text(title,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 8),
          Text(sub,
              textAlign: TextAlign.center,
              style: const TextStyle(color: PinPalette.ink2, height: 1.5)),
          const SizedBox(height: 24),
          PinButton('เสร็จ', onTap: () => Navigator.of(context).pop()),
        ]),
      );
}
