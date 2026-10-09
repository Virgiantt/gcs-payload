import 'package:flutter/material.dart';

import '../models/telemetry.dart';
import '../theme/app_theme.dart';

enum _Kind { normal, latest, lost }

class _R {
  final List<String> cells;
  final _Kind kind;
  const _R(this.cells, this.kind);
}

class TelemetryLogTable extends StatefulWidget {
  final AppPalette palette;
  final List<Telemetry> history;

  final int maxRows;

  final bool signalLost;

  const TelemetryLogTable({
    super.key,
    required this.palette,
    required this.history,
    this.maxRows = 10,
    this.signalLost = false,
  });

  @override
  State<TelemetryLogTable> createState() => _TelemetryLogTableState();
}

class _TelemetryLogTableState extends State<TelemetryLogTable> {
  static const String _na = 'NA';
  static const double _rowH = 36;

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

  final ScrollController _ctrl = ScrollController();
  bool _away = false; // user sedang scroll menjauh dari data terbaru
  String? _anchorPacket; // baris acuan (paket pertama yang bukan NA)
  int _anchorIdx = 0;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      final away = _ctrl.hasClients && _ctrl.offset > 40;
      if (away != _away) setState(() => _away = away);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

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

  /// Susun SEMUA baris (terbaru di atas). Paket yang hilang (nomor loncat)
  /// disisipkan sebagai NA; kalau sinyal putus ditambah satu baris NA di atas.
  List<_R> _buildRows() {
    final src = widget.history;

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

    if (widget.signalLost && src.isNotEmpty) {
      rows.insert(0, _R(_naCells('${src.last.teamId}', _na), _Kind.lost));
    } else if (rows.isNotEmpty && rows[0].kind == _Kind.normal) {
      rows[0] = _R(rows[0].cells, _Kind.latest);
    }
    return rows;
  }

  /// Kalau user sedang membaca data lama, paket baru yang masuk di atas
  /// tidak boleh menggeser tampilan: offset digeser sebanyak baris baru.
  void _keepPosition(List<_R> rows) {
    final idx = rows.indexWhere((r) => r.cells[1] != _na);
    if (idx < 0) {
      _anchorPacket = null;
      _anchorIdx = 0;
      return;
    }

    final old = _anchorPacket;
    if (old != null && _ctrl.hasClients && _ctrl.offset > 1) {
      final now = rows.indexWhere((r) => r.cells[1] == old);
      if (now >= 0 && now != _anchorIdx) {
        final delta = (now - _anchorIdx) * _rowH;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_ctrl.hasClients) return;
          final max = _ctrl.position.maxScrollExtent;
          _ctrl.jumpTo((_ctrl.offset + delta).clamp(0.0, max).toDouble());
        });
      }
    }

    _anchorPacket = rows[idx].cells[1];
    _anchorIdx = idx;
  }

  void _toLatest() {
    if (!_ctrl.hasClients) return;
    _ctrl.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final rows = _buildRows();
    _keepPosition(rows);

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
              crossAxisAlignment: CrossAxisAlignment.center,
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
                if (_away) ...[
                  InkWell(
                    onTap: _toLatest,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: p.accent.withOpacity(0.12),
                        border: Border.all(color: p.accent.withOpacity(0.5)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.vertical_align_top,
                              size: 14, color: p.accent),
                          const SizedBox(width: 4),
                          Text(
                            'Ke data terbaru',
                            style: TextStyle(
                              color: p.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Text(
                  'Latest ${widget.maxRows} · scroll untuk data lama '
                  '(${rows.length} baris)',
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
                              : ListView.builder(
                                  controller: _ctrl,
                                  itemExtent: _rowH,
                                  itemCount: rows.length,
                                  itemBuilder: (_, i) => _row(
                                    rows[i].cells,
                                    kind: rows[i].kind,
                                    index: i,
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
    final p = widget.palette;
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
      height: header ? 38 : _rowH,
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
