import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../services/tasks_controller.dart';
import '../theme/pin_theme.dart';

/// "งานค้างทั้งหมด" screen (design/pin.html). Tasks grouped by status with
/// filter chips. Live from the bot via [TasksController] (io.tokens2.tasks).
const _groups = ['รอคุณ', 'รอเขา', 'เดดไลน์', 'เงินค้าง'];

IconData _groupIcon(String g) => switch (g) {
      'รอคุณ' => LucideIcons.user,
      'รอเขา' => LucideIcons.clock,
      'เดดไลน์' => LucideIcons.calendar,
      _ => LucideIcons.wallet,
    };

class AllTasksScreen extends StatefulWidget {
  const AllTasksScreen({super.key});

  @override
  State<AllTasksScreen> createState() => _AllTasksScreenState();
}

class _AllTasksScreenState extends State<AllTasksScreen> {
  String _filter = 'all'; // all | today | overdue

  bool _match(PinTask t) => switch (_filter) {
        'today' => t.today,
        'overdue' => t.overdue,
        _ => true,
      };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PinTask>>(
      valueListenable: TasksController.instance,
      builder: (context, tasks, _) => _build(context, tasks),
    );
  }

  Widget _build(BuildContext context, List<PinTask> all) {
    final scheme = Theme.of(context).colorScheme;
    final visible = all.where(_match).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('งานค้าง'),
        actions: [
          IconButton(icon: const Icon(LucideIcons.plus), onPressed: () {}),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Row(
            children: [
              _chip('all', 'ทั้งหมด'),
              const SizedBox(width: 8),
              _chip('today', 'วันนี้'),
              const SizedBox(width: 8),
              _chip('overdue', 'เกินกำหนด'),
            ],
          ),
          const SizedBox(height: 12),
          Text('เหลือ ${visible.length} รายการ · ปิดวันนี้ 2',
              style: const TextStyle(color: PinPalette.ink2, fontSize: 13)),
          const SizedBox(height: 8),
          for (final g in _groups)
            if (visible.any((t) => t.group == g)) ...[
              _groupHeader(scheme, g, visible.where((t) => t.group == g).length),
              for (final t in visible.where((t) => t.group == g)) _row(scheme, t),
            ],
        ],
      ),
    );
  }

  Widget _chip(String id, String label) {
    final scheme = Theme.of(context).colorScheme;
    final on = _filter == id;
    return GestureDetector(
      onTap: () => setState(() => _filter = id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: on ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: on ? scheme.primary : PinPalette.line, width: 1),
        ),
        child: Text(label,
            style: TextStyle(
                color: on ? Colors.white : PinPalette.ink2,
                fontWeight: FontWeight.w600,
                fontSize: 13)),
      ),
    );
  }

  Widget _groupHeader(ColorScheme scheme, String g, int n) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 6),
        child: Row(
          children: [
            Icon(_groupIcon(g), size: 15, color: scheme.secondary),
            const SizedBox(width: 6),
            Text(g,
                style: TextStyle(
                    color: scheme.secondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
            const Spacer(),
            Text('$n', style: const TextStyle(color: PinPalette.ink2, fontSize: 13)),
          ],
        ),
      );

  Widget _row(ColorScheme scheme, PinTask t) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(color: Color(0x0F282822), blurRadius: 9, offset: Offset(0, 3)),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(LucideIcons.circle, size: 20, color: Color(0xFFA0A096)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.text, style: const TextStyle(fontSize: 14, color: PinPalette.ink)),
                  if (t.sub != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(t.sub!,
                          style: const TextStyle(fontSize: 12, color: PinPalette.ink2)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(t.due ?? '',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.overdue ? PinPalette.neg : PinPalette.ink2)),
          ],
        ),
      );
}
