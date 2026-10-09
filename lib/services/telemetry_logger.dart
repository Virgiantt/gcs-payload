import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/telemetry.dart';

/// Logger CSV MANUAL untuk GCS.
///
/// - Data TIDAK disimpan otomatis. Panggil [save] untuk menyimpan.
/// - Yang disimpan hanya [maxSave] data terbaru (default 20).
/// - Lokasi: <Documents>/CanSat_GCS_Logs/telemetry_YYYYMMDD_HHMMSS.csv
class TelemetryLogger {
  static const String header =
      'RX_TIME,TEAM_ID,MISSION_TIME,PACKET_COUNT,ALTITUDE,PRESSURE,'
      'TEMPERATURE,VOLTAGE,CURRENT,ROLL,PITCH,YAW,GPS_LAT,GPS_LON,'
      'GPS_ALT,STATE';

  /// Jumlah data terbaru yang akan disimpan saat [save] dipanggil.
  static const int maxSave = 20;

  Directory? dir;
  File? file;
  String? error;

  /// Jumlah baris yang terakhir berhasil disimpan.
  int rows = 0;

  /// Waktu penyimpanan terakhir.
  DateTime? lastSavedAt;

  String get path => file?.path ?? '-';

  /// Apakah sudah pernah save minimal 1x.
  bool get hasSaved => file != null;

  TelemetryLogger() {
    _initDir();
  }

  /// Siapkan folder penyimpanan (tapi BELUM buat file).
  void _initDir() {
    try {
      final sep = Platform.pathSeparator;
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      final docs = Directory('$home${sep}Documents');
      final base = docs.existsSync() ? docs.path : home;

      dir = Directory('$base${sep}CanSat_GCS_Logs')
        ..createSync(recursive: true);
    } catch (e) {
      error = '$e';
      debugPrint('[LOG] Gagal membuat folder log: $e');
    }
  }

  static String _f(double v, int d) =>
      v.isFinite ? v.toStringAsFixed(d) : 'nan';

  /// Simpan [maxSave] data terbaru dari [history] ke file CSV baru.
  ///
  /// - [history] diambil dari `service.history` (urutan lama -> baru).
  /// - [currentHistory] opsional, sejajar 1:1 dengan [history].
  ///
  /// Return: jumlah baris yang tersimpan (0 kalau gagal).
  int save(
    List<Telemetry> history, {
    List<double>? currentHistory,
  }) {
    if (dir == null) {
      error = 'Folder log tidak siap';
      return 0;
    }
    if (history.isEmpty) {
      error = 'Tidak ada data untuk disimpan';
      return 0;
    }

    try {
      // ---- Ambil maxSave data TERBARU ----
      final start = history.length > maxSave ? history.length - maxSave : 0;
      final slice = history.sublist(start);
      final curSlice =
          (currentHistory != null && currentHistory.length >= history.length)
              ? currentHistory.sublist(start)
              : <double>[];

      // ---- Buat file baru ----
      final n = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp = '${n.year}${two(n.month)}${two(n.day)}_'
          '${two(n.hour)}${two(n.minute)}${two(n.second)}';

      file = File('${dir!.path}${Platform.pathSeparator}telemetry_$stamp.csv');

      final buf = StringBuffer('$header\r\n');
      for (var i = 0; i < slice.length; i++) {
        final t = slice[i];
        final cur = (i < curSlice.length) ? curSlice[i] : double.nan;
        buf.writeln([
          DateTime.now().toIso8601String(),
          t.teamId,
          t.missionTime,
          t.packetCount,
          _f(t.altitude, 1),
          _f(t.pressure, 1),
          _f(t.temperature, 1),
          _f(t.voltage, 2),
          _f(cur, 2),
          _f(t.roll, 1),
          _f(t.pitch, 1),
          _f(t.yaw, 1),
          _f(t.gpsLat, 6),
          _f(t.gpsLon, 6),
          _f(t.gpsAlt, 1),
          t.state,
        ].join(','));
      }

      file!.writeAsStringSync(buf.toString(), flush: true);
      rows = slice.length;
      lastSavedAt = DateTime.now();
      error = null;
      debugPrint('[LOG] Tersimpan $rows baris: ${file!.path}');
      return rows;
    } catch (e) {
      error = '$e';
      debugPrint('[LOG] Gagal menyimpan: $e');
      return 0;
    }
  }

  Future<void> openFolder() async {
    final d = dir;
    if (d == null) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [d.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [d.path]);
      } else {
        await Process.run('xdg-open', [d.path]);
      }
    } catch (e) {
      debugPrint('[LOG] Gagal membuka folder: $e');
    }
  }
}
