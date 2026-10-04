import 'dart:async';

import 'package:flutter/material.dart';

import '../services/alert_service.dart';
import '../theme/app_theme.dart';

// ---------- helper bersama (bar + dialog log) ----------
String _two(int n) => n.toString().padLeft(2, '0');
String _clock(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
String _dur(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(sec)}' : '${_two(m)}:${_two(sec)}';
}

Color _levelColor(AppPalette p, AlertLevel l) => switch (l) {
      AlertLevel.normal => p.ok,
      AlertLevel.warning => p.warn,
      AlertLevel.critical => p.bad,
    };

String _levelLabel(AlertLevel l) => switch (l) {
      AlertLevel.normal => 'NORMAL',
      AlertLevel.warning => 'WARNING',
      AlertLevel.critical => 'CRITICAL',
    };

IconData _levelIcon(AlertLevel l) => switch (l) {
      AlertLevel.normal => Icons.check_circle,
      AlertLevel.warning => Icons.warning_amber_rounded,
      AlertLevel.critical => Icons.error,
    };

Widget _tag(String text, Color c, {bool filled = false}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: filled ? c : c.withOpacity(0.12),
        border: Border.all(color: c.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: filled ? Colors.white : c,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );

// =========================================================
// KOTAK PERINGATAN
// =========================================================
class AlertBar extends StatefulWidget {
  final AppPalette palette;
  final AlertService service;

  const AlertBar({super.key, required this.palette, required this.service});

  @override
  State<AlertBar> createState() => _AlertBarState();
}

class _AlertBarState extends State<AlertBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  bool _expanded = true;

  AppPalette get p => widget.palette;
  AlertService get svc => widget.service;

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant AlertBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  // Animasi berkedip hanya berjalan saat CRITICAL (hemat CPU).
  void _syncPulse() {
    final crit = svc.level == AlertLevel.critical;
    if (crit && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!crit && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final level = svc.level;
    final color = _levelColor(p, level);
    final alerts = svc.active;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final glow = level == AlertLevel.critical ? _pulse.value : 0.0;
        return Container(
          margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
                color.withOpacity(
                    level == AlertLevel.normal ? 0.04 : 0.06 + 0.10 * glow),
                p.panel),
            border: Border.all(
              color: color.withOpacity(
                  level == AlertLevel.normal ? 0.35 : 0.6 + 0.4 * glow),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(level, color, alerts),
              if (alerts.isNotEmpty && _expanded) ...[
                const SizedBox(height: 10),
                _cards(alerts),
              ],
            ],
          ),
        );
      },
    );
  }

  // ---------------- header ----------------
  Widget _header(AlertLevel level, Color color, List<Alert> alerts) {
    final crit = alerts.where((a) => a.level == AlertLevel.critical).length;
    final warn = alerts.length - crit;
    final counts = [
      if (crit > 0) '$crit CRITICAL',
      if (warn > 0) '$warn WARNING',
    ].join('  ·  ');

    Widget summary;
    if (alerts.isEmpty) {
      summary = Text(
        'Semua sistem normal${_lastResolvedText()}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: p.textDim, fontSize: 12, fontWeight: FontWeight.w600),
      );
    } else {
      final worst = alerts.first;
      summary = Row(
        children: [
          Text(
            counts,
            style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5),
          ),
          if (!_expanded) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                '${worst.title} — ${worst.detail}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.textDim, fontSize: 11.5),
              ),
            ),
          ],
        ],
      );
    }

    return SizedBox(
      height: 34,
      child: Row(
        children: [
          _levelPill(level, color),
          const SizedBox(width: 12),
          Expanded(child: summary),
          const SizedBox(width: 8),
          _logButton(),
          if (alerts.isNotEmpty) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: _expanded ? 'Ringkas' : 'Tampilkan detail',
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: p.panelAlt,
                    border: Border.all(color: p.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: p.text,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _lastResolvedText() {
    AlertIncident? best;
    for (final i in svc.incidents) {
      if (i.endedAt == null) continue;
      if (best == null || i.endedAt!.isAfter(best.endedAt!)) best = i;
    }
    if (best == null) return '';
    return '  ·  Terakhir: ${best.title} (pulih ${_clock(best.endedAt!)}, '
        'berlangsung ${_dur(best.duration(DateTime.now()))})';
  }

  Widget _levelPill(AlertLevel level, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_levelIcon(level), size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            _levelLabel(level),
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- kartu alert ----------------
  Widget _cards(List<Alert> alerts) {
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 10.0;
        const minW = 360.0;
        final n = alerts.length;
        final even = (c.maxWidth - gap * (n - 1)) / n;
        final w = even < minW ? minW : even;
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 170),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < n; i++) ...[
                    if (i > 0) const SizedBox(width: gap),
                    _card(alerts[i], w),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _card(Alert a, double width) {
    final c = _levelColor(p, a.level);
    final since = a.since;
    return Container(
      width: width,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.withOpacity(0.10),
        border: Border.all(color: c.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.withOpacity(0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(
              a.level == AlertLevel.critical
                  ? Icons.error_outline
                  : Icons.warning_amber_rounded,
              color: c,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        a.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _tag(a.source.label, c),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  a.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.text, fontSize: 11.5),
                ),
                if (a.hint != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lightbulb_outline, size: 13, color: p.textDim),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          a.hint!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.textDim, fontSize: 10.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (since != null)
                Text(
                  'aktif ${_dur(DateTime.now().difference(since))}',
                  style: TextStyle(
                    color: c,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (a.value != null) ...[
                const SizedBox(height: 6),
                Text(
                  a.value!,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
              if (a.limit != null)
                Text(
                  'batas ${a.limit}',
                  style: TextStyle(color: p.textDim, fontSize: 10),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- tombol log ----------------
  Widget _logButton() {
    final total = svc.incidents.length;
    return InkWell(
      onTap: _showLog,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: p.panelAlt,
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 16, color: p.text),
            const SizedBox(width: 6),
            Text(
              'Alert log ($total)',
              style: TextStyle(
                color: p.text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLog() {
    showDialog<void>(
      context: context,
      builder: (_) => _AlertLogDialog(palette: p, service: svc),
    );
  }
}

// =========================================================
// DIALOG ALERT LOG
// =========================================================
enum _Filter { all, active, critical, warning }

class _AlertLogDialog extends StatefulWidget {
  final AppPalette palette;
  final AlertService service;
  const _AlertLogDialog({required this.palette, required this.service});

  @override
  State<_AlertLogDialog> createState() => _AlertLogDialogState();
}

class _AlertLogDialogState extends State<_AlertLogDialog> {
  _Filter _filter = _Filter.all;
  Timer? _tick;
  String? _exportMsg;
  bool _exportFailed = false;

  AppPalette get p => widget.palette;
  AlertService get svc => widget.service;

  @override
  void initState() {
    super.initState();
    // refresh tiap detik supaya durasi kejadian aktif terus berjalan
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _export() {
    final path = svc.exportCsv();
    setState(() {
      _exportFailed = path == null;
      _exportMsg = path == null
          ? 'Gagal ekspor: ${svc.exportError}'
          : 'Tersimpan: $path';
    });
  }

  @override
  Widget build(BuildContext context) {
    final all = svc.incidents.reversed.toList();
    final activeN = all.where((i) => i.active).length;
    final critN = all.where((i) => i.peak == AlertLevel.critical).length;
    final warnN = all.where((i) => i.peak == AlertLevel.warning).length;

    final shown = all.where((i) {
      switch (_filter) {
        case _Filter.all:
          return true;
        case _Filter.active:
          return i.active;
        case _Filter.critical:
          return i.peak == AlertLevel.critical;
        case _Filter.warning:
          return i.peak == AlertLevel.warning;
      }
    }).toList();

    Widget chip(_Filter f, String label) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(label, style: const TextStyle(fontSize: 12)),
            selected: _filter == f,
            onSelected: (_) => setState(() => _filter = f),
          ),
        );

    return AlertDialog(
      title: Row(
        children: [
          const Text('Alert log'),
          const SizedBox(width: 12),
          Text(
            '${all.length} kejadian · $activeN aktif',
            style: TextStyle(color: p.textDim, fontSize: 12),
          ),
        ],
      ),
      content: SizedBox(
        width: 900,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                chip(_Filter.all, 'Semua (${all.length})'),
                chip(_Filter.active, 'Aktif ($activeN)'),
                chip(_Filter.critical, 'Critical ($critN)'),
                chip(_Filter.warning, 'Warning ($warnN)'),
              ],
            ),
            const SizedBox(height: 6),
            const Divider(height: 1),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        all.isEmpty
                            ? 'Belum ada alert — semua normal sejauh ini.'
                            : 'Tidak ada kejadian untuk filter ini.',
                        style: TextStyle(color: p.textDim),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 8),
                      itemCount: shown.length,
                      itemBuilder: (_, i) => _tile(shown[i]),
                    ),
            ),
            if (_exportMsg != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SelectableText(
                  _exportMsg!,
                  style: TextStyle(
                    color: _exportFailed ? p.bad : p.ok,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: all.isEmpty ? null : _export,
          icon: const Icon(Icons.save_alt, size: 18),
          label: const Text('Ekspor CSV'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Tutup'),
        ),
      ],
    );
  }

  Widget _tile(AlertIncident i) {
    final now = DateTime.now();
    final c = _levelColor(p, i.peak);
    final statusColor = i.active ? _levelColor(p, i.level) : p.ok;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.withOpacity(0.06),
        border: Border(left: BorderSide(color: c, width: 4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- waktu ----
          SizedBox(
            width: 128,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _clock(i.startedAt),
                  style: const TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  i.active ? '→ sekarang' : '→ ${_clock(i.endedAt!)}',
                  style: TextStyle(
                      color: p.textDim, fontSize: 11, fontFamily: 'monospace'),
                ),
                const SizedBox(height: 4),
                Text(
                  'durasi ${_dur(i.duration(now))}',
                  style: TextStyle(
                      color: statusColor,
                      fontSize: 11,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // ---- isi ----
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      i.title,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800),
                    ),
                    _tag(i.active ? 'ACTIVE' : 'RESOLVED', statusColor,
                        filled: i.active),
                    _tag('PEAK ${_levelLabel(i.peak)}', c),
                    _tag(i.source.label, p.textDim),
                    if (i.occurrence > 1) _tag('KE-${i.occurrence}', p.textDim),
                  ],
                ),
                const SizedBox(height: 5),
                Text(i.detail, style: const TextStyle(fontSize: 12)),
                if (i.value != null || i.limit != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (i.value != null) 'Nilai: ${i.value}',
                      if (i.limit != null) 'Batas: ${i.limit}',
                    ].join('   ·   '),
                    style: TextStyle(
                        color: p.textDim,
                        fontSize: 11,
                        fontFamily: 'monospace'),
                  ),
                ],
                if (i.hint != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lightbulb_outline, size: 13, color: p.textDim),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(i.hint!,
                            style: TextStyle(color: p.textDim, fontSize: 11)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
