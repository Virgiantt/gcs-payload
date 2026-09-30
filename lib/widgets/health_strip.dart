import 'package:flutter/material.dart';

import '../services/health_service.dart';
import '../theme/app_theme.dart';

/// Ringkasan mini kesehatan payload: deretan chip  ● MCU  ● GPS  ● IMU ...
/// Diklik -> [onTap] (mis. pindah ke tab Payload Health).
class HealthStrip extends StatelessWidget {
  final AppPalette palette;
  final List<HealthItem> items;
  final VoidCallback? onTap;

  const HealthStrip({
    super.key,
    required this.palette,
    required this.items,
    this.onTap,
  });

  AppPalette get p => palette;

  Color _color(HealthLevel l) => switch (l) {
        HealthLevel.ok => p.ok,
        HealthLevel.warn => p.warn,
        HealthLevel.fail => p.bad,
        HealthLevel.unknown => p.textDim,
      };

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Wrap(
          alignment: WrapAlignment.end,
          runAlignment: WrapAlignment.end,
          spacing: 6,
          runSpacing: 6,
          children: [for (final it in items) _chip(it)],
        ),
      ),
    );
  }

  Widget _chip(HealthItem it) {
    final c = _color(it.level);
    return Tooltip(
      message: '${it.sub.label}: ${it.status} · ${it.detail}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: c.withOpacity(0.12),
          border: Border.all(color: c.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(
              it.sub.shortLabel,
              style: TextStyle(
                color: p.text,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
