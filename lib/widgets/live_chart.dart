import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class LiveChart extends StatelessWidget {
  final AppPalette palette;
  final String title;
  final String unit;
  final List<FlSpot> spots;
  final Color lineColor;

  /// Jumlah titik maksimum yang ditampilkan. Data lebih lama tetap tersimpan
  /// di CSV, hanya tidak digambar di chart.
  final int maxPoints;

  const LiveChart({
    super.key,
    required this.palette,
    required this.title,
    required this.unit,
    required this.spots,
    required this.lineColor,
    this.maxPoints = 50,
  });

  @override
  Widget build(BuildContext context) {
    // Jendela geser: ambil maxPoints data terbaru saja
    final windowed = spots.length > maxPoints;
    final view = windowed ? spots.sublist(spots.length - maxPoints) : spots;

    double minY = 0, maxY = 1;
    if (view.isNotEmpty) {
      minY = view.map((s) => s.y).reduce((a, b) => a < b ? a : b);
      maxY = view.map((s) => s.y).reduce((a, b) => a > b ? a : b);
      final pad = (maxY - minY).abs() * 0.15 + 1;
      minY -= pad;
      maxY += pad;
    }

    // ---- Interval sumbu dibuat eksplisit supaya label tidak bertumpuk ----
    final minX = view.isEmpty ? 0.0 : view.first.x;
    final maxX = view.isEmpty
        ? 1.0
        : (view.last.x == view.first.x ? view.first.x + 10 : view.last.x);

    // Sumbu Y: 4 interval, desimal menyesuaikan besar interval
    final yInterval = (maxY - minY) / 4 <= 0 ? 1.0 : (maxY - minY) / 4;
    final yDecimals = yInterval >= 10 ? 0 : (yInterval >= 0.1 ? 1 : 2);

    // Sumbu X: nomor paket (bilangan bulat), maksimal ~5 label, interval >= 1
    final xInterval = math.max(1.0, ((maxX - minX) / 5).ceilToDouble());

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (windowed) ...[
                Text(
                  'last $maxPoints',
                  style: TextStyle(color: palette.textDim, fontSize: 10),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                unit,
                style: TextStyle(
                  color: palette.textDim,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: view.isEmpty
                ? Center(
                    child: Text(
                      'Menunggu data...',
                      style: TextStyle(color: palette.textDim, fontSize: 12),
                    ),
                  )
                : LineChart(
                    duration: Duration.zero, // tanpa animasi -> geser mulus
                    LineChartData(
                      minX: minX,
                      maxX: maxX,
                      minY: minY,
                      maxY: maxY,
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        horizontalInterval: yInterval,
                        verticalInterval: xInterval,
                        getDrawingHorizontalLine: (_) => FlLine(
                          color: palette.border.withOpacity(0.3),
                          strokeWidth: 1,
                        ),
                        getDrawingVerticalLine: (_) => FlLine(
                          color: palette.border.withOpacity(0.3),
                          strokeWidth: 1,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 48,
                            interval: yInterval,
                            // jangan paksa label di batas min/max (biang tumpukan)
                            minIncluded: false,
                            maxIncluded: false,
                            getTitlesWidget: (v, meta) => SideTitleWidget(
                              axisSide: meta.axisSide,
                              child: Text(
                                v.toStringAsFixed(yDecimals),
                                style: TextStyle(
                                  color: palette.textDim,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 24,
                            interval: xInterval,
                            minIncluded: false,
                            maxIncluded: false,
                            getTitlesWidget: (v, meta) => SideTitleWidget(
                              axisSide: meta.axisSide,
                              child: Text(
                                v.toInt().toString(),
                                style: TextStyle(
                                  color: palette.textDim,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      lineBarsData: [
                        LineChartBarData(
                          spots: view,
                          isCurved: false,
                          color: lineColor,
                          barWidth: 2,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: lineColor.withOpacity(0.1),
                          ),
                        ),
                      ],
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipColor: (_) => palette.panelAlt,
                          getTooltipItems: (spots) => spots
                              .map((s) => LineTooltipItem(
                                    '${s.y.toStringAsFixed(2)} $unit',
                                    TextStyle(
                                      color: palette.text,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 11,
                                    ),
                                  ))
                              .toList(),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
