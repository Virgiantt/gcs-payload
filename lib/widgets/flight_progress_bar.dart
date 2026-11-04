import 'package:flutter/material.dart';

import '../models/telemetry.dart';
import '../theme/app_theme.dart';

/// Urutan fase misi sesuai state di telemetri.
const List<String> kFlightPhases = [
  'LAUNCH_PAD',
  'ASCENT',
  'APOGEE',
  'DESCENT',
  'LANDED',
];

const List<String> _phaseNames = ['PAD', 'ASCENT', 'APOGEE', 'DESCENT', 'LANDED'];

const List<IconData> _phaseIcons = [
  Icons.rocket_launch_outlined,
  Icons.arrow_upward,
  Icons.vertical_align_top,
  Icons.paragliding,
  Icons.flag,
];

/// Bar progres misi horizontal: state saat ini, lima fase berurutan
/// beserta jam mulainya, dan angka utama di kanan.
class FlightProgressBar extends StatelessWidget {
  const FlightProgressBar({
    super.key,
    required this.palette,
    required this.data,
    required this.signalLost,
    this.phaseTimes = const {},
    this.maxAltitude,
  });

  final AppPalette palette;
  final Telemetry? data;
  final bool signalLost;

  /// Mission time saat tiap fase pertama kali terlihat, contoh
  /// {'ASCENT': '00:00:15'}.
  final Map<String, String> phaseTimes;

  /// Ketinggian tertinggi yang tercatat (apogee).
  final double? maxAltitude;

  Color _stateColor(String? s) {
    switch (s) {
      case 'ASCENT':
        return palette.ok;
      case 'APOGEE':
        return palette.warn;
      case 'DESCENT':
        return palette.accent;
      case 'LANDED':
        return palette.accent2;
      default:
        return palette.textDim;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = data;
    final st = t?.state.trim().toUpperCase();
    final cur = st == null ? -1 : kFlightPhases.indexOf(st);
    final color = signalLost ? palette.bad : _stateColor(st);

    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 1100;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              color.withValues(alpha: 0.16),
              color.withValues(alpha: 0.03),
            ],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            SizedBox(
              width: narrow ? 170 : 210,
              child: _stateBlock(st, cur, color),
            ),
            _vDivider(color),
            Expanded(
              child: Opacity(
                opacity: signalLost ? 0.45 : 1,
                child: _stepper(cur, color),
              ),
            ),
            _vDivider(color),
            _stats(narrow),
          ],
        ),
      );
    });
  }

  Widget _vDivider(Color color) => Container(
        width: 1,
        height: 56,
        margin: const EdgeInsets.symmetric(horizontal: 18),
        color: color.withValues(alpha: 0.25),
      );

  // ---------------- Kiri: state saat ini ----------------
  Widget _stateBlock(String? st, int cur, Color color) {
    final p = palette;
    final sub = signalLost
        ? 'Sinyal hilang'
        : (cur >= 0 ? 'Fase ${cur + 1} dari ${kFlightPhases.length}' : 'Menunggu data');
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(
            signalLost
                ? Icons.signal_wifi_off
                : (cur >= 0 ? _phaseIcons[cur] : Icons.hourglass_empty),
            color: color,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'FLIGHT STATE',
                style: TextStyle(
                  color: p.textDim,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  signalLost ? 'NA' : (st ?? 'WAITING'),
                  style: TextStyle(
                    color: color,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              Text(
                sub,
                style: TextStyle(
                  color: signalLost ? p.bad : p.textDim,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------- Tengah: proses lima fase ----------------
  Widget _stepper(int cur, Color color) {
    final children = <Widget>[];
    for (var i = 0; i < kFlightPhases.length; i++) {
      children.add(_node(i, cur, color));
      if (i < kFlightPhases.length - 1) {
        children.add(Expanded(
          child: Padding(
            // Sejajar dengan pusat lingkaran (diameter 32).
            padding: const EdgeInsets.only(top: 14),
            child: _connector(i, cur, color),
          ),
        ));
      }
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _connector(int i, int cur, Color color) {
    final p = palette;
    final done = i < cur;
    // Ruas yang sedang berjalan: setengah terisi.
    final running = i == cur && cur < kFlightPhases.length - 1;
    return Container(
      height: 4,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        color: running ? null : (done ? p.ok : p.border),
        gradient: running
            ? LinearGradient(
                colors: [color, color, p.border, p.border],
                stops: const [0, 0.5, 0.5, 1],
              )
            : null,
      ),
    );
  }

  Widget _node(int i, int cur, Color color) {
    final p = palette;
    final done = i < cur;
    final active = i == cur;
    final time = phaseTimes[kFlightPhases[i]];

    final Color fill = done ? p.ok : (active ? color : Colors.transparent);
    final Color border = done ? p.ok : (active ? Colors.white : p.border);

    return SizedBox(
      width: 74,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fill,
              border: Border.all(color: border, width: active ? 2.5 : 1.5),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.55),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              done ? Icons.check : _phaseIcons[i],
              size: 16,
              color: done || active ? Colors.white : p.textDim,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _phaseNames[i],
            maxLines: 1,
            style: TextStyle(
              color: active ? color : (done ? p.text : p.textDim),
              fontSize: 10,
              fontWeight: active ? FontWeight.w800 : FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            time ?? '--:--:--',
            maxLines: 1,
            style: TextStyle(
              color: time == null ? p.textDim.withValues(alpha: 0.6) : p.textDim,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- Kanan: angka utama ----------------
  Widget _stats(bool narrow) {
    final t = data;
    final lost = signalLost;
    String v(String Function(Telemetry) f) =>
        lost ? 'NA' : (t == null ? '—' : f(t));

    final items = <Widget>[
      _stat('ALTITUDE', v((t) => t.altitude.toStringAsFixed(1)),
          unit: lost ? null : 'm'),
      if (!narrow)
        _stat(
          'APOGEE',
          maxAltitude == null ? '—' : maxAltitude!.toStringAsFixed(1),
          unit: maxAltitude == null ? null : 'm',
        ),
      _stat('MISSION TIME', v((t) => t.missionTime)),
      if (!narrow)
        _stat('PACKET',
            v((t) => '#${t.packetCount.toString().padLeft(4, '0')}')),
    ];

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 22),
            items[i],
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, String value, {String? unit}) {
    final p = palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: p.textDim,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: TextStyle(
                color: p.text,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (unit != null) ...[
              const SizedBox(width: 3),
              Text(
                unit,
                style: TextStyle(
                  color: p.textDim,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}