import 'package:flutter/material.dart';
import '../services/alert_service.dart';
import '../theme/app_theme.dart';

/// Pill di header yang menampilkan ringkasan alert aktif (OK / WARN / CRITICAL).
/// Klik → dialog berisi daftar alert aktif + info detail.
class AlertStatusPill extends StatelessWidget {
  final AppPalette palette;
  final AlertService service;
  final bool iconOnly;

  const AlertStatusPill({
    super.key,
    required this.palette,
    required this.service,
    this.iconOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final alerts = service.active; // List<Alert>
    final level = service.level; // AlertLevel (normal/warning/critical)

    int count(AlertLevel l) => alerts.where((a) => a.level == l).length;
    final critical = count(AlertLevel.critical);
    final warn = count(AlertLevel.warning);

    final Color color;
    final IconData icon;
    final String label;
    switch (level) {
      case AlertLevel.critical:
        color = palette.bad;
        icon = Icons.error;
        label = critical > 1 ? '$critical CRITICAL' : 'CRITICAL';
        break;
      case AlertLevel.warning:
        color = palette.warn;
        icon = Icons.warning_amber_rounded;
        label = warn > 1 ? '$warn WARN' : 'WARNING';
        break;
      case AlertLevel.normal:
        color = palette.ok;
        icon = Icons.check_circle;
        label = 'OK';
        break;
    }

    return Tooltip(
      message: alerts.isEmpty
          ? 'Tidak ada alert aktif'
          : '${alerts.length} alert aktif — klik untuk detail',
      child: InkWell(
        onTap: () => _showDialog(context, alerts),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: iconOnly ? 10 : 12,
            vertical: 7,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            border: Border.all(color: color.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              if (!iconOnly) ...[
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showDialog(BuildContext context, List<Alert> alerts) {
    showDialog<void>(
      context: context,
      builder: (c) => Theme(
        data: Theme.of(context),
        child: AlertDialog(
          title: Row(
            children: [
              Icon(
                alerts.isEmpty ? Icons.check_circle : Icons.warning_amber_rounded,
                color: alerts.isEmpty ? palette.ok : palette.warn,
              ),
              const SizedBox(width: 8),
              Text(alerts.isEmpty
                  ? 'No Active Alerts'
                  : '${alerts.length} Active Alert${alerts.length > 1 ? 's' : ''}'),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: alerts.isEmpty
                ? Text(
                    'Semua sistem normal.',
                    style: TextStyle(color: palette.textDim),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: alerts.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 16,
                      color: palette.border,
                    ),
                    itemBuilder: (_, i) => _alertRow(alerts[i]),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Tutup'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _alertRow(Alert a) {
    final Color color;
    final IconData icon;
    switch (a.level) {
      case AlertLevel.critical:
        color = palette.bad;
        icon = Icons.error;
        break;
      case AlertLevel.warning:
        color = palette.warn;
        icon = Icons.warning_amber_rounded;
        break;
      case AlertLevel.normal:
        color = palette.ok;
        icon = Icons.info_outline;
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                a.title,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: palette.panelAlt,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                a.source.label,
                style: TextStyle(
                  color: palette.textDim,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          a.detail,
          style: TextStyle(color: palette.text, fontSize: 12),
        ),
        if (a.value != null || a.limit != null) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              if (a.value != null)
                _chip('VALUE', a.value!, palette.textDim),
              if (a.value != null && a.limit != null)
                const SizedBox(width: 8),
              if (a.limit != null)
                _chip('LIMIT', a.limit!, palette.bad),
            ],
          ),
        ],
        if (a.hint != null) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lightbulb_outline,
                  size: 12, color: palette.accent),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  a.hint!,
                  style: TextStyle(
                    color: palette.textDim,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (a.since != null) ...[
          const SizedBox(height: 4),
          Text(
            'Aktif sejak ${_fmt(a.since!)}',
            style: TextStyle(color: palette.textDim, fontSize: 10),
          ),
        ],
      ],
    );
  }

  Widget _chip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _fmt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}