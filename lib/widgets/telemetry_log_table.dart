import 'package:flutter/material.dart';

import '../models/telemetry.dart';
import '../theme/app_theme.dart';

class TelemetryLogTable extends StatelessWidget {
  final AppPalette palette;
  final List<Telemetry> history; 
  final int maxRows;

  const TelemetryLogTable({
    super.key,
    required this.palette,
    required this.history,
    this.maxRows = 10,
  });

  // (judul, flex, rata kanan?)
  static const List<_Col> _cols = [
    _Col('Team ID', 10, false),
    _Col('Packet', 8, false),
    _Col('Mission time', 12, false),
    _Col('State', 11, false),
    _Col('Alt (m)', 9, true),
    _Col('Press (hPa)', 10, true),
    _Col('Temp (C)', 9, true),
    _Col('Volt (V)', 9, true),
    _Col('Roll', 8, true),
    _Col('Pitch', 8, true),
    _Col('Yaw', 8, true),
    _Col('GPS lat', 11, true),
    _Col('GPS lon', 11, true),
    _Col('GPS alt', 9, true),
  ];

  List<String> _cells(Telemetry t) => [
        '${t.teamId}',
        '${t.packetCount}',
        t.missionTime,
        t.state,
        t.altitude.toStringAsFixed(1),
        t.pressure.toStringAsFixed(1),
        t.temperature.toStringAsFixed(1),
        t.voltage.toStringAsFixed(2),
        t.roll.toStringAsFixed(1),
        t.pitch.toStringAsFixed(1),
        t.yaw.toStringAsFixed(1),
        t.gpsLat.toStringAsFixed(6),
        t.gpsLon.toStringAsFixed(6),
        t.gpsAlt.toStringAsFixed(1),
      ];

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final rows = history.reversed.take(maxRows).toList();

    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'Telemetry table',
                  style: TextStyle(
                    color: p.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  'Last $maxRows packets',
                  style: TextStyle(color: p.textDim, fontSize: 11),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                const minWidth = 1150.0;
                final w = c.maxWidth < minWidth ? minWidth : c.maxWidth;
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: w,
                    child: Column(
                      children: [
                        _row(
                          _cols.map((e) => e.title).toList(),
                          header: true,
                        ),
                        Expanded(
                          child: rows.isEmpty
                              ? Center(
                                  child: Text(
                                    'Waiting for telemetry...',
                                    style: TextStyle(
                                        color: p.textDim, fontSize: 12),
                                  ),
                                )
                              : SingleChildScrollView(
                                  child: Column(
                                    children: [
                                      for (var i = 0; i < rows.length; i++)
                                        _row(_cells(rows[i]),
                                            index: i, latest: i == 0),
                                    ],
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    List<String> cells, {
    bool header = false,
    int index = 0,
    bool latest = false,
  }) {
    final p = palette;
    final Color bg = header
        ? p.panelAlt
        : latest
            ? p.accent.withOpacity(0.10)
            : (index.isOdd ? p.panelAlt.withOpacity(0.5) : Colors.transparent);

    return Container(
      height: header ? 38 : 36,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (var i = 0; i < _cols.length; i++)
            Expanded(
              flex: _cols[i].flex,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  cells[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign:
                      _cols[i].right ? TextAlign.right : TextAlign.left,
                  style: TextStyle(
                    color: header
                        ? p.textDim
                        : (latest ? p.accent : p.text),
                    fontSize: header ? 11 : 12,
                    fontWeight: header || latest
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Col {
  final String title;
  final int flex;
  final bool right;
  const _Col(this.title, this.flex, this.right);
}