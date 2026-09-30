import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/telemetry.dart';

/// Menyimpan SEMUA paket telemetri ke file CSV (satu file per sesi).
/// Lokasi: <Documents>/CanSat_GCS_Logs/telemetry_YYYYMMDD_HHMMSS.csv
/// Setiap baris langsung di-flush ke disk, jadi aman kalau aplikasi crash.
class TelemetryLogger {
  static const String header =
      'RX_TIME,TEAM_ID,MISSION_TIME,PACKET_COUNT,ALTITUDE,PRESSURE,'
      'TEMPERATURE,VOLTAGE,ROLL,PITCH,YAW,GPS_LAT,GPS_LON,GPS_ALT,STATE';

  Directory? dir;
  File? file;
  String? error;
  int rows = 0;
  Telemetry? _last;

  String get path => file?.path ?? '-';

  TelemetryLogger() {
    _init();
  }

  void _init() {
    try {
      final sep = Platform.pathSeparator;
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      final docs = Directory('$home${sep}Documents');
      final base = docs.existsSync() ? docs.path : home;

      dir = Directory('$base${sep}CanSat_GCS_Logs')
        ..createSync(recursive: true);

      final n = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp = '${n.year}${two(n.month)}${two(n.day)}_'
          '${two(n.hour)}${two(n.minute)}${two(n.second)}';

      file = File('${dir!.path}${sep}telemetry_$stamp.csv');
      file!.writeAsStringSync('$header\r\n', flush: true);
      debugPrint('[LOG] CSV: ${file!.path}');
    } catch (e) {
      error = '$e';
      debugPrint('[LOG] Gagal membuat file log: $e');
    }
  }

  /// Aman dipanggil berkali-kali dengan paket yang sama (duplikat diabaikan).
  void log(Telemetry t) {
    if (file == null || identical(t, _last)) return;
    _last = t;
    try {
      final row = [
        DateTime.now().toIso8601String(),
        t.teamId,
        t.missionTime,
        t.packetCount,
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
        t.state,
      ].join(',');
      file!.writeAsStringSync('$row\r\n', mode: FileMode.append, flush: true);
      rows++;
    } catch (e) {
      error = '$e';
      debugPrint('[LOG] Gagal menulis: $e');
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
