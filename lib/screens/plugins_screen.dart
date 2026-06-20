import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../theme/pin_theme.dart';
import '../widgets/pin_toast.dart';

/// "ปลั๊กอิน & บริการ" — connect external services ปิ่น can read (design).
/// Connect flows are stubs for now.
class PluginsScreen extends StatelessWidget {
  const PluginsScreen({super.key});

  static const _items = <(IconData, String, String)>[
    (PhosphorIconsRegular.envelope, 'Gmail', 'อ่านอีเมล สรุปงาน/ใบเสร็จ'),
    (PhosphorIconsRegular.calendar, 'ปฏิทิน', 'นัดหมาย เตือนล่วงหน้า'),
    (PhosphorIconsRegular.cloudSun, 'อากาศ', 'พยากรณ์ ฝุ่น แจ้งก่อนออกไปนัด'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('ปลั๊กอิน & บริการ')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewPadding.bottom),
        children: [
          const Text(
            'เชื่อมบริการเพื่อให้ปิ่นช่วยได้มากขึ้น — ปิ่นอ่านเท่าที่จำเป็น ไม่ส่งแทนคุณ',
            style: TextStyle(color: PinPalette.ink2, height: 1.5),
          ),
          const SizedBox(height: 16),
          for (final (icon, name, desc) in _items)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x0F282822), blurRadius: 9, offset: Offset(0, 3)),
                ],
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: scheme.primary.withValues(alpha: 0.12),
                    child: Icon(icon, color: scheme.secondary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        Text(desc,
                            style: const TextStyle(
                                fontSize: 12, color: PinPalette.ink2)),
                      ],
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () =>
                        PinToast.show(context, 'เชื่อม $name — เร็ว ๆ นี้'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.secondary,
                      side: BorderSide(
                          color: scheme.primary.withValues(alpha: 0.4)),
                    ),
                    child: const Text('เชื่อม'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
