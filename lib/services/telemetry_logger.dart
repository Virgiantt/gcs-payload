import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/telemetry.dart';

class _Entry {
  final DateTime rx;
  final Telemetry t;
  final double current;
  const _Entry(this.rx, this.t, this.current);
}

/// Menyimpan telemetri ke CSV SECARA MANUAL.
///
/// - [log] hanya menaruh paket ke buffer di memori (tidak menulis file).
///   Buffer hanya menyimpan [keepRows] paket terbaru.
/// - [save] menulis isi buffer ke file CSV baru (satu file per penekanan
///   tombol): <Documents>/CanSat_GCS_Logs/telemetry_YYYYMMDD_HHMMSS.csv
/// Nilai NaN / sensor error ditulis sebagai "nan".
class TelemetryLogger {
  static const String header =
      'RX_TIME,TEAM_ID,MISSION_TIME,PACKET_COUNT,ALTITUDE,PRESSURE,'
      'TEMPERATURE,VOLTAGE,CURRENT,ROLL,PITCH,YAW,GPS_LAT,GPS_LON,GPS_ALT,STATE';

  /// Jumlah paket terbaru yang ikut tersimpan ke CSV.
  static const int keepRows = 20;

  Directory? dir;

  /// File hasil Save terakhir (null = belum pernah Save).
  File? file;

  /// Pesan error terakhir (gagal membuat folder / menulis file).
  String? error;

  DateTime? lastSavedAt;
  int lastSavedRows = 0;

  final List<_Entry> _buffer = [];
  Telemetry? _last;

  /// Jumlah paket yang siap disimpan (maks. [keepRows]).
  int get rows => _buffer.length;
  bool get hasData => _buffer.isNotEmpty;

  /// Path file Save terakhir, atau '-' kalau belum pernah Save.
  String get path => file?.path ?? '-';

  static String _f(double v, int d) =>
      v.isFinite ? v.toStringAsFixed(d) : 'nan';

  /// Masukkan paket ke buffer (BELUM menulis ke disk).
  /// Aman dipanggil berkali-kali dengan paket yang sama (duplikat diabaikan).
  void log(Telemetry t, {double current = double.nan}) {
    if (identical(t, _last)) return;
    _last = t;
    _buffer.add(_Entry(DateTime.now(), t, current));
    if (_buffer.length > keepRows) {
      _buffer.removeRange(0, _buffer.length - keepRows);
    }
  }

  Directory _ensureDir() {
    final existing = dir;
    if (existing != null && existing.existsSync()) return existing;

    final sep = Platform.pathSeparator;
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    final docs = Directory('$home${sep}Documents');
    final base = docs.existsSync() ? docs.path : home;

    final d = Directory('$base${sep}CanSat_GCS_Logs')
      ..createSync(recursive: true);
    dir = d;
    return d;
  }

  /// Tulis [keepRows] paket terbaru ke file CSV baru (urut lama -> baru).
  /// Return true kalau berhasil. Kalau buffer kosong -> false tanpa error.
  bool save() {
    if (_buffer.isEmpty) return false;
    try {
      final d = _ensureDir();
      final sep = Platform.pathSeparator;

      final n = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp = '${n.year}${two(n.month)}${two(n.day)}_'
          '${two(n.hour)}${two(n.minute)}${two(n.second)}';

      final out = StringBuffer('$header\r\n');
      for (final e in _buffer) {
        final t = e.t;
        out.write([
          e.rx.toIso8601String(),
          t.teamId,
          t.missionTime,
          t.packetCount,
          _f(t.altitude, 1),
          _f(t.pressure, 1),
          _f(t.temperature, 1),
          _f(t.voltage, 2),
          _f(e.current, 2),
          _f(t.roll, 1),
          _f(t.pitch, 1),
          _f(t.yaw, 1),
          _f(t.gpsLat, 6),
          _f(t.gpsLon, 6),
          _f(t.gpsAlt, 1),
          t.state,
        ].join(','));
        out.write('\r\n');
      }

      final f = File('${d.path}${sep}telemetry_$stamp.csv');
      f.writeAsStringSync(out.toString(), flush: true);

      file = f;
      lastSavedAt = n;
      lastSavedRows = _buffer.length;
      error = null;
      debugPrint('[LOG] Saved $lastSavedRows rows -> ${f.path}');
      return true;
    } catch (e) {
      error = '$e';
      debugPrint('[LOG] Gagal menyimpan: $e');
      return false;
    }
  }

  Future<void> openFolder() async {
    try {
      final d = _ensureDir();
      if (Platform.isWindows) {
        await Process.run('explorer', [d.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [d.path]);
      } else {
        await Process.run('xdg-open', [d.path]);
      }
    } catch (e) {
      error = '$e';
      debugPrint('[LOG] Gagal membuka folder: $e');
    }
  }
}
