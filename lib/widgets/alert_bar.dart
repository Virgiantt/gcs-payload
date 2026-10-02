import 'package:flutter/material.dart';

import '../services/alert_service.dart';
import '../theme/app_theme.dart';

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

  Color _color(AlertLevel l) => switch (l) {
        AlertLevel.normal => p.ok,
        AlertLevel.warning => p.warn,
        AlertLevel.critical => p.bad,
      };

  String _label(AlertLevel l) => switch (l) {
        AlertLevel.normal => 'NORMAL',
        AlertLevel.warning => 'WARNING',
        AlertLevel.critical => 'CRITICAL',
      };

  IconData _icon(AlertLevel l) => switch (l) {
        AlertLevel.normal => Icons.check_circle,
        AlertLevel.warning => Icons.warning_amber_rounded,
        AlertLevel.critical => Icons.error,
      };

  @override
  Widget build(BuildContext context) {
    final level = svc.level;
    final color = _color(level);
    final alerts = svc.active;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final glow = level == AlertLevel.critical ? _pulse.value : 0.0;
        return Container(
          height: 46,
          margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
                color.withOpacity(
                    level == AlertLevel.normal ? 0.04 : 0.06 + 0.12 * glow),
                p.panel),
            border: Border.all(
              color: color.withOpacity(
                  level == AlertLevel.normal ? 0.35 : 0.6 + 0.4 * glow),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              _levelPill(level, color),
              const SizedBox(width: 12),
              Expanded(
                child: alerts.isEmpty
                    ? Text(
                        'All systems nominal',
                        style: TextStyle(
                          color: p.textDim,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: alerts.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) => _chip(alerts[i]),
                      ),
              ),
              const SizedBox(width: 8),
              _logButton(),
            ],
          ),
        );
      },
    );
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
          Icon(_icon(level), size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            _label(level),
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

  Widget _chip(Alert a) {
    final c = _color(a.level);
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        border: Border.all(color: c.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: c),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                a.title,
                style: TextStyle(
                  color: c,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
              Text(
                a.detail,
                style: TextStyle(color: p.textDim, fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _logButton() {
    return InkWell(
      onTap: _showLog,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
              'Alert log (${svc.events.length})',
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
    final items = svc.events.reversed.toList();
    String two(int n) => n.toString().padLeft(2, '0');

    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Alert log'),
        content: SizedBox(
          width: 580,
          height: 380,
          child: items.isEmpty
              ? const Center(child: Text('Belum ada alert'))
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final e = items[i];
                    final col = _color(e.level);
                    final tm = e.time;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Text(
                            '${two(tm.hour)}:${two(tm.minute)}:${two(tm.second)}',
                            style: const TextStyle(
                                fontSize: 11, fontFamily: 'monospace'),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 74,
                            child: Text(
                              e.cleared ? 'CLEARED' : _label(e.level),
                              style: TextStyle(
                                color: col,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              e.title,
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w700),
                            ),
                          ),
                          Flexible(
                            child: Text(
                              e.detail,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Tutup')),
        ],
      ),
    );
  }
}
