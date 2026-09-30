import 'package:flutter/material.dart';
import '../models/telemetry.dart';
import '../theme/app_theme.dart';

class GpsPanel extends StatelessWidget {
  final AppPalette palette;
  final Telemetry? data;

  const GpsPanel({
    super.key,
    required this.palette,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    final t = data;
    final rows = <List<String>>[
      ['Latitude', t == null ? '—' : '${t.gpsLat.toStringAsFixed(6)}°'],
      ['Longitude', t == null ? '—' : '${t.gpsLon.toStringAsFixed(6)}°'],
      ['GPS Altitude', t == null ? '—' : '${t.gpsAlt.toStringAsFixed(1)} m'],
      ['Mission Time', t?.missionTime ?? '—'],
      ['State', t?.state ?? '—'],
    ];

    return Container(
      padding: const EdgeInsets.all(20),
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
              Icon(Icons.satellite_alt, color: palette.accent, size: 18),
              const SizedBox(width: 8),
              Text(
                'GPS TELEMETRY',
                style: TextStyle(
                  color: palette.textDim,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(
                        rows[i][0],
                        style: TextStyle(
                          color: palette.textDim,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        rows[i][1],
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 13,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
