import 'package:flutter/material.dart';

import '../models/telemetry.dart';
import '../theme/app_theme.dart';

enum _Kind { normal, latest, lost }

class _R {
  final List<String> cells;
  final _Kind kind;
  const _R(this.cells, this.kind);
}

class TelemetryLogTable extends StatelessWidget {
  final AppPalette palette;
  final List<Telemetry> history;
  final int maxRows;

  /// true -> antena tidak menerima data: baris paling atas diisi NA.
  final bool signalLost;

  const TelemetryLogTable({
    super.key,
    required this.palette,
    required this.history,
    this.maxRows = 10,
    this.signalLost = false,
  });

  static const String _na = 'NA';

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

  /// Baris data kosong: semua kolom NA (nomor paket diisi kalau diketahui).
  List<String> _naCells(String teamId, String packet) => [
        teamId,
        packet,
        for (var i = 2; i < _cols.length; i++) _na,
      ];

  /// Susun baris: paket yang hilang (nomor loncat) disisipkan sebagai NA,
  /// lalu kalau sinyal putus ditambah satu baris NA di paling atas.
  List<_R> _buildRows() {
    final src =
        history.length > 200 ? history.sublist(history.length - 200) : history;

    final chrono = <_R>[];
    Telemetry? prev;
    for (final t in src) {
      if (prev != null) {
        final gap = t.packetCount - prev.packetCount - 1;
        if (gap > 0) {
          final n = gap > 20 ? 20 : gap; // batasi supaya tabel tidak banjir
          for (var k = 1; k <= n; k++) {
            chrono.add(_R(
              _naCells('${t.teamId}', '${prev.packetCount + k}'),
              _Kind.lost,
            ));
          }
        }
      }
      chrono.add(_R(_cells(t), _Kind.normal));
      prev = t;
    }

    final rows = chrono.reversed.toList();

    if (signalLost && history.isNotEmpty) {
      rows.insert(0, _R(_naCells('${history.last.teamId}', _na), _Kind.lost));
    } else {
      // baris data asli paling atas = latest
      final i = rows.indexWhere((r) => r.kind == _Kind.normal);
      if (i == 0) rows[0] = _R(rows[0].cells, _Kind.latest);
    }
    return rows.take(maxRows).toList();
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final rows = _buildRows();

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
                          kind: _Kind.normal,
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
                                        _row(rows[i].cells,
                                            kind: rows[i].kind, index: i),
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
    required _Kind kind,
    bool header = false,
    int index = 0,
  }) {
    final p = palette;
    final latest = kind == _Kind.latest;
    final lost = kind == _Kind.lost;

    final Color bg = header
        ? p.panelAlt
        : lost
            ? p.bad.withOpacity(0.08)
            : latest
                ? p.accent.withOpacity(0.10)
                : (index.isOdd
                    ? p.panelAlt.withOpacity(0.5)
                    : Colors.transparent);

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
                  textAlign: _cols[i].right ? TextAlign.right : TextAlign.left,
                  style: TextStyle(
                    color: header
                        ? p.textDim
                        : lost
                            ? p.bad
                            : (latest ? p.accent : p.text),
                    fontSize: header ? 11 : 12,
                    fontWeight: header || latest || lost
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
