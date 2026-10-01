import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/telemetry.dart';
import '../theme/app_theme.dart';
import 'live_chart.dart';

// =========================================================
// KONFIGURASI BATERAI — SESUAIKAN DENGAN BATERAI ASLI
// (diasumsikan Li-ion / LiPo 1S, 4.20 V = penuh)
// =========================================================
const double kBatteryCapacityMah = 2000; // kapasitas baterai (mAh)
const double kBatteryLoadMa = 250; // perkiraan arus rata-rata payload (mA)
const double kBatteryCutoffV = 3.30; // tegangan minimum aman (V)

/// Tab Battery: persentase, sisa kapasitas, estimasi lama bertahan,
/// dan grafik tegangan.
class BatteryPanel extends StatelessWidget {
  final AppPalette palette;
  final Telemetry? latest;
  final List<Telemetry> history;
  final bool signalLost;

  const BatteryPanel({
    super.key,
    required this.palette,
    required this.latest,
    required this.history,
    this.signalLost = false,
  });

  AppPalette get p => palette;

  // Kurva tegangan -> persen untuk Li-ion 1S (tegangan naik).
  static const List<List<double>> _curve = [
    [3.27, 0],
    [3.61, 5],
    [3.69, 10],
    [3.71, 15],
    [3.73, 20],
    [3.75, 25],
    [3.77, 30],
    [3.79, 35],
    [3.80, 40],
    [3.82, 45],
    [3.84, 50],
    [3.85, 55],
    [3.87, 60],
    [3.91, 65],
    [3.95, 70],
    [3.98, 75],
    [4.02, 80],
    [4.08, 85],
    [4.11, 90],
    [4.15, 95],
    [4.20, 100],
  ];

  static double percentFromVoltage(double v) {
    if (v >= _curve.last[0]) return 100;
    if (v <= _curve.first[0]) return 0;
    for (var i = 1; i < _curve.length; i++) {
      final a = _curve[i - 1];
      final b = _curve[i];
      if (v <= b[0]) {
        final f = (v - a[0]) / (b[0] - a[0]);
        return a[1] + f * (b[1] - a[1]);
      }
    }
    return 100;
  }

  static double? _secondsOf(String mt) {
    final parts = mt.split(':');
    if (parts.length != 3) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final s = int.tryParse(parts[2]);
    if (h == null || m == null || s == null) return null;
    return (h * 3600 + m * 60 + s).toDouble();
  }

  /// Kemiringan tegangan (V per detik) dari regresi linear 30 paket terakhir.
  double? _slope() {
    final src =
        history.length > 30 ? history.sublist(history.length - 30) : history;
    final xs = <double>[];
    final ys = <double>[];
    for (final t in src) {
      final s = _secondsOf(t.missionTime);
      if (s == null) continue;
      xs.add(s);
      ys.add(t.voltage);
    }
    if (xs.length < 5) return null;
    final n = xs.length;
    final mx = xs.reduce((a, b) => a + b) / n;
    final my = ys.reduce((a, b) => a + b) / n;
    var num = 0.0;
    var den = 0.0;
    for (var i = 0; i < n; i++) {
      num += (xs[i] - mx) * (ys[i] - my);
      den += (xs[i] - mx) * (xs[i] - mx);
    }
    if (den == 0) return null;
    return num / den;
  }

  String _fmt(Duration d) {
    if (d.inHours > 0) return '${d.inHours}j ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}d';
    return '${d.inSeconds}d';
  }

  @override
  Widget build(BuildContext context) {
    final t = latest;

    String txt(String Function() f) {
      if (t == null) return '—';
      if (signalLost) return 'NA';
      return f();
    }

    final hasData = t != null && !signalLost;
    final v = t?.voltage ?? 0.0;
    final pct = hasData ? percentFromVoltage(v) : 0.0;
    final remainingMah = kBatteryCapacityMah * pct / 100.0;
    final runtime =
        Duration(seconds: (remainingMah / kBatteryLoadMa * 3600).round());

    final slope = _slope();
    String trendText;
    String trendSub;
    if (!hasData) {
      trendText = t == null ? '—' : 'NA';
      trendSub = ' ';
    } else if (slope == null) {
      trendText = 'Menghitung…';
      trendSub = 'butuh ≥ 5 paket';
    } else if (slope > -1e-5) {
      trendText = 'Stabil';
      trendSub = 'tegangan tidak turun';
    } else {
      final secs = v <= kBatteryCutoffV ? 0 : (v - kBatteryCutoffV) / -slope;
      trendText = _fmt(Duration(seconds: secs.round()));
      trendSub = '${(slope * 1000 * 60).toStringAsFixed(1)} mV/menit';
    }

    final Color levelColor =
        !hasData ? p.textDim : (pct > 50 ? p.ok : (pct > 20 ? p.warn : p.bad));

    final spots = history
        .map((e) => FlSpot(e.packetCount.toDouble(), e.voltage))
        .toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 236,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 2,
                  child: _mainCard(
                    pctText: txt(() => '${pct.toStringAsFixed(0)}%'),
                    pct: pct,
                    color: levelColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _tile(
                                'TEGANGAN',
                                txt(() => '${v.toStringAsFixed(2)} V'),
                                'cutoff ${kBatteryCutoffV.toStringAsFixed(2)} V',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _tile(
                                'SISA KAPASITAS',
                                txt(() =>
                                    '${remainingMah.toStringAsFixed(0)} mAh'),
                                'dari ${kBatteryCapacityMah.toStringAsFixed(0)} mAh',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _tile(
                                'ESTIMASI TAHAN (BEBAN)',
                                txt(() => _fmt(runtime)),
                                'beban ±${kBatteryLoadMa.toStringAsFixed(0)} mA',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _tile(
                                'ESTIMASI TAHAN (TREN)',
                                trendText,
                                trendSub,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LiveChart(
              palette: palette,
              title: 'Battery Voltage vs Time',
              unit: 'V',
              lineColor: const Color(0xFF22C55E),
              spots: spots,
            ),
          ),
        ],
      ),
    );
  }

  Widget _mainCard({
    required String pctText,
    required double pct,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        border: Border.all(color: color.withOpacity(0.5), width: 1.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                pct > 20 ? Icons.battery_charging_full : Icons.battery_alert,
                color: color,
                size: 28,
              ),
              const SizedBox(width: 10),
              Text(
                'BATTERY',
                style: TextStyle(
                  color: p.textDim,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
            ],
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              pctText,
              style: TextStyle(
                color: color,
                fontSize: 52,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (pct / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: p.panelAlt,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(String label, String value, String sub) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: p.textDim,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                color: p.text,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.textDim, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
