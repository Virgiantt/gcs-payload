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
    // Buang titik NaN (sensor error) supaya batas sumbu & garis tidak rusak
    final finite = spots.where((s) => s.x.isFinite && s.y.isFinite).toList();
    final windowed = finite.length > maxPoints;
    final view = windowed ? finite.sublist(finite.length - maxPoints) : finite;

    double minY = 0, maxY = 1;
    if (view.isNotEmpty) {
      minY = view.map((s) => s.y).reduce((a, b) => a < b ? a : b);
      maxY = view.map((s) => s.y).reduce((a, b) => a > b ? a : b);
      final pad = (maxY - minY).abs() * 0.15 + 1;
      minY -= pad;
      maxY += pad;
    }

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
                      minX: view.first.x,
                      maxX: view.last.x == view.first.x
                          ? view.first.x + 10
                          : view.last.x,
                      minY: minY,
                      maxY: maxY,
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        horizontalInterval:
                            (maxY - minY) / 4 <= 0 ? 1 : (maxY - minY) / 4,
                        verticalInterval: (view.length / 6).clamp(1, 999),
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
                            reservedSize: 44,
                            getTitlesWidget: (v, _) => Text(
                              v.toStringAsFixed(1),
                              style: TextStyle(
                                color: palette.textDim,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            getTitlesWidget: (v, _) => Text(
                              v.toInt().toString(),
                              style: TextStyle(
                                color: palette.textDim,
                                fontSize: 10,
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
