import 'package:flutter/foundation.dart';

import '../models/telemetry.dart';
import 'alert_service.dart';
import 'command_service.dart';

enum HealthLevel { unknown, ok, warn, fail }

enum Subsystem { mcu, gps, imu, barometer, lora, battery, camera }

extension SubsystemX on Subsystem {
  String get label => switch (this) {
        Subsystem.mcu => 'MCU',
        Subsystem.gps => 'GPS',
        Subsystem.imu => 'IMU',
        Subsystem.barometer => 'BAROMETER',
        Subsystem.lora => 'LoRa',
        Subsystem.battery => 'BATTERY',
        Subsystem.camera => 'CAMERA',
      };

  String get shortLabel => switch (this) {
        Subsystem.mcu => 'MCU',
        Subsystem.gps => 'GPS',
        Subsystem.imu => 'IMU',
        Subsystem.barometer => 'BARO',
        Subsystem.lora => 'LoRa',
        Subsystem.battery => 'BATT',
        Subsystem.camera => 'CAM',
      };

  /// Dari mana status ini disimpulkan (ditampilkan di UI supaya jujur).
  String get source => switch (this) {
        Subsystem.mcu => 'Packet stream',
        Subsystem.gps => 'GPS lat / lon / alt',
        Subsystem.imu => 'Roll / pitch / yaw',
        Subsystem.barometer => 'Pressure / temperature',
        Subsystem.lora => 'Telemetry link + PING',
        Subsystem.battery => 'Voltage',
        Subsystem.camera => 'CAM_ON / CAM_OFF ACK',
      };
}

class HealthItem {
  final Subsystem sub;
  final HealthLevel level;
  final String status; // ONLINE, FIX, NORMAL, OFFLINE, ...
  final String detail;
  const HealthItem(this.sub, this.level, this.status, this.detail);
}

enum CheckVerdict { idle, running, go, caution, noGo }

class CheckRun {
  final DateTime time;
  final CheckVerdict verdict;
  final List<HealthItem> items;
  final String? note;
  const CheckRun(this.time, this.verdict, this.items, this.note);
}

/// Data mentah yang dibutuhkan untuk menilai kesehatan payload.
class HealthInputs {
  final Telemetry? latest;
  final List<Telemetry> history;
  final DateTime? lastPacketAt;
  final bool linkUp;
  const HealthInputs({
    required this.latest,
    required this.history,
    required this.lastPacketAt,
    required this.linkUp,
  });
}

/// Menilai kesehatan tiap subsistem payload + menjalankan PRE-LAUNCH CHECK.
///
/// TAHAP 1 (sekarang): status DISIMPULKAN dari telemetri, link, dan ACK
/// perintah. Belum ada laporan self-test langsung dari Raspberry Pi.
class HealthService extends ChangeNotifier {
  final HealthInputs Function() _inputs;
  final CommandService _cmd;

  HealthService({
    required HealthInputs Function() inputs,
    required CommandService cmd,
  })  : _inputs = inputs,
        _cmd = cmd;

  List<HealthItem> _items = const [];
  bool _disposed = false;

  // ---- state pre-launch check ----
  bool running = false;
  int stepIndex = -1;
  List<HealthItem> stepResults = const [];
  CheckVerdict verdict = CheckVerdict.idle;
  String? note;
  final List<CheckRun> runs = [];

  /// Status live tiap subsistem (urutan = Subsystem.values).
  List<HealthItem> get items {
    if (_items.isEmpty) _items = _compute();
    return _items;
  }

  /// Hitung ulang status live. Dipanggil dari timer/paket baru di main.dart.
  void refresh() => _items = _compute();

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // =========================================================
  // EVALUASI LIVE
  // =========================================================
  List<HealthItem> _compute() {
    final i = _inputs();
    final t = i.latest;
    final now = DateTime.now();
    final age = i.lastPacketAt == null
        ? null
        : now.difference(i.lastPacketAt!).inMilliseconds / 1000.0;
    final fresh = t != null &&
        age != null &&
        i.linkUp &&
        age < AlertThresholds.delayWarnSec;
    final ageTxt = age == null ? '-' : age.toStringAsFixed(1);

    final out = <Subsystem, HealthItem>{};

    // ---- MCU: apakah paket terus masuk ----
    if (t == null || age == null) {
      out[Subsystem.mcu] = const HealthItem(Subsystem.mcu, HealthLevel.unknown,
          'WAITING', 'No packet received yet');
    } else if (!i.linkUp || age >= AlertThresholds.delayCritSec) {
      out[Subsystem.mcu] = HealthItem(Subsystem.mcu, HealthLevel.fail,
          'OFFLINE', 'Last packet $ageTxt s ago');
    } else if (age >= AlertThresholds.delayWarnSec) {
      out[Subsystem.mcu] = HealthItem(Subsystem.mcu, HealthLevel.warn, 'STALE',
          'Last packet $ageTxt s ago');
    } else {
      out[Subsystem.mcu] = HealthItem(Subsystem.mcu, HealthLevel.ok, 'ONLINE',
          'Packet #${t.packetCount} · $ageTxt s ago');
    }

    // ---- GPS / IMU / BARO / BATTERY: butuh telemetri yang masih segar ----
    if (t == null || !fresh) {
      for (final s in [
        Subsystem.gps,
        Subsystem.imu,
        Subsystem.barometer,
        Subsystem.battery,
      ]) {
        out[s] = HealthItem(
            s, HealthLevel.unknown, 'NO DATA', 'Waiting for fresh telemetry');
      }
    } else {
      // GPS
      if (t.gpsLat == 0 && t.gpsLon == 0) {
        out[Subsystem.gps] = const HealthItem(Subsystem.gps, HealthLevel.fail,
            'NO FIX', 'Lat/Lon reported as 0, 0');
      } else if ((t.gpsAlt - t.altitude).abs() >
          AlertThresholds.gpsAltDiffWarn) {
        out[Subsystem.gps] = HealthItem(
            Subsystem.gps,
            HealthLevel.warn,
            'WEAK',
            'GPS alt ${t.gpsAlt.toStringAsFixed(0)} m vs baro '
                '${t.altitude.toStringAsFixed(0)} m');
      } else {
        out[Subsystem.gps] = HealthItem(Subsystem.gps, HealthLevel.ok, 'FIX',
            '${t.gpsLat.toStringAsFixed(5)}, ${t.gpsLon.toStringAsFixed(5)}');
      }

      final last = _lastN(i.history, 8);

      // IMU
      final imuInvalid = !t.roll.isFinite ||
          !t.pitch.isFinite ||
          !t.yaw.isFinite ||
          t.roll.abs() > 180 ||
          t.pitch.abs() > 180 ||
          t.yaw.abs() > 360;
      final imuFrozen = last.length >= 8 &&
          last.every((e) =>
              e.roll == last.first.roll &&
              e.pitch == last.first.pitch &&
              e.yaw == last.first.yaw);
      if (imuInvalid) {
        out[Subsystem.imu] = const HealthItem(
            Subsystem.imu, HealthLevel.fail, 'INVALID', 'Angle out of range');
      } else if (imuFrozen) {
        out[Subsystem.imu] = const HealthItem(
            Subsystem.imu, HealthLevel.warn, 'STALE', 'Values not changing');
      } else {
        out[Subsystem.imu] = HealthItem(
            Subsystem.imu,
            HealthLevel.ok,
            'ONLINE',
            'R ${t.roll.toStringAsFixed(1)}  P ${t.pitch.toStringAsFixed(1)}  '
                'Y ${t.yaw.toStringAsFixed(1)}');
      }

      // Barometer
      final baroInvalid = !t.pressure.isFinite ||
          !t.temperature.isFinite ||
          t.pressure < 300 ||
          t.pressure > 1100 ||
          t.temperature < -40 ||
          t.temperature > 85;
      final baroFrozen = last.length >= 8 &&
          last.every((e) => e.pressure == last.first.pressure);
      if (baroInvalid) {
        out[Subsystem.barometer] = HealthItem(
            Subsystem.barometer,
            HealthLevel.fail,
            'INVALID',
            '${t.pressure.toStringAsFixed(1)} hPa · '
                '${t.temperature.toStringAsFixed(1)} °C');
      } else if (baroFrozen) {
        out[Subsystem.barometer] = const HealthItem(Subsystem.barometer,
            HealthLevel.warn, 'STALE', 'Pressure not changing');
      } else {
        out[Subsystem.barometer] = HealthItem(
            Subsystem.barometer,
            HealthLevel.ok,
            'ONLINE',
            '${t.pressure.toStringAsFixed(1)} hPa · '
                '${t.temperature.toStringAsFixed(1)} °C');
      }

      // Battery
      final v = 'Voltage: ${t.voltage.toStringAsFixed(2)} V';
      if (t.voltage < AlertThresholds.battCrit) {
        out[Subsystem.battery] =
            HealthItem(Subsystem.battery, HealthLevel.fail, 'CRITICAL', v);
      } else if (t.voltage < AlertThresholds.battWarn) {
        out[Subsystem.battery] =
            HealthItem(Subsystem.battery, HealthLevel.warn, 'LOW', v);
      } else {
        out[Subsystem.battery] =
            HealthItem(Subsystem.battery, HealthLevel.ok, 'NORMAL', v);
      }
    }

    // ---- LoRa / radio link: kualitas aliran paket ----
    final missed = AlertService.missedPackets(i.history);
    if (!i.linkUp) {
      out[Subsystem.lora] = const HealthItem(
          Subsystem.lora, HealthLevel.fail, 'OFFLINE', 'No telemetry link');
    } else if (age == null) {
      out[Subsystem.lora] = const HealthItem(
          Subsystem.lora, HealthLevel.unknown, 'WAITING', 'No packet yet');
    } else if (age >= AlertThresholds.delayCritSec) {
      out[Subsystem.lora] = HealthItem(Subsystem.lora, HealthLevel.fail,
          'OFFLINE', 'No packets for $ageTxt s');
    } else if (age >= AlertThresholds.delayWarnSec) {
      out[Subsystem.lora] = HealthItem(Subsystem.lora, HealthLevel.warn,
          'STALE', 'No packets for $ageTxt s');
    } else if (missed > 0) {
      out[Subsystem.lora] = HealthItem(Subsystem.lora, HealthLevel.warn,
          'DEGRADED', 'Missed $missed in last ${_window(i.history)} packets');
    } else {
      out[Subsystem.lora] = HealthItem(Subsystem.lora, HealthLevel.ok, 'ONLINE',
          'No packet loss in last ${_window(i.history)}');
    }

    // ---- Camera: dari ACK perintah CAM_ON / CAM_OFF terakhir ----
    if (!_cmd.connected) {
      out[Subsystem.camera] = const HealthItem(
          Subsystem.camera, HealthLevel.fail, 'NO LINK', 'Command link down');
    } else {
      CmdLogEntry? last;
      for (final e in _cmd.log) {
        if (e.state != CmdState.ack) continue;
        if (e.name != 'CAM_ON' && e.name != 'CAM_OFF') continue;
        if (last == null || e.time.isAfter(last.time)) last = e;
      }
      if (last == null) {
        out[Subsystem.camera] = const HealthItem(Subsystem.camera,
            HealthLevel.unknown, 'NOT CHECKED', 'No camera command ACK yet');
      } else if (last.name == 'CAM_ON') {
        out[Subsystem.camera] = HealthItem(Subsystem.camera, HealthLevel.ok,
            'ONLINE', 'CAM_ON ACK ${_hms(last.time)}');
      } else {
        out[Subsystem.camera] = HealthItem(Subsystem.camera, HealthLevel.warn,
            'OFF', 'CAM_OFF ACK ${_hms(last.time)}');
      }
    }

    return [for (final s in Subsystem.values) out[s]!];
  }

  List<Telemetry> _lastN(List<Telemetry> h, int n) =>
      h.length > n ? h.sublist(h.length - n) : h;

  int _window(List<Telemetry> h) => h.length > AlertThresholds.lossWindow
      ? AlertThresholds.lossWindow
      : h.length;

  String _hms(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // =========================================================
  // PRE-LAUNCH CHECK
  // =========================================================
  /// Mengecek semua subsistem satu per satu.
  /// Catatan: langkah LoRa mengirim PING dan langkah CAMERA mengirim CAM_ON
  /// (aman & bisa dibatalkan dengan CAM_OFF), lalu menunggu ACK maks. 3 detik.
  Future<void> runPreLaunchCheck() async {
    if (running) return;
    running = true;
    verdict = CheckVerdict.running;
    note = null;
    stepResults = const [];
    stepIndex = 0;
    _notify();

    final results = <HealthItem>[];
    for (final s in Subsystem.values) {
      if (_disposed) return;
      stepIndex = s.index;
      _notify();
      await Future.delayed(const Duration(milliseconds: 450));

      refresh();
      var item = items.firstWhere((e) => e.sub == s);
      if (s == Subsystem.lora) {
        item = await _checkRadio(item);
      } else if (s == Subsystem.camera) {
        item = await _checkCamera(item);
      }

      results.add(item);
      stepResults = List.of(results);
      _notify();
    }
    if (_disposed) return;

    final bad = results
        .where((e) =>
            e.level == HealthLevel.fail || e.level == HealthLevel.unknown)
        .toList();
    final warns = results.where((e) => e.level == HealthLevel.warn).toList();
    final state = _inputs().latest?.state;

    CheckVerdict v;
    String n;
    if (bad.isNotEmpty) {
      v = CheckVerdict.noGo;
      n = 'Failed: ${bad.map((e) => e.sub.label).join(', ')}';
    } else if (warns.isNotEmpty) {
      v = CheckVerdict.caution;
      n = 'Check: ${warns.map((e) => e.sub.label).join(', ')}';
    } else if (state != null && state != 'LAUNCH_PAD') {
      v = CheckVerdict.caution;
      n = 'Flight state is $state (expected LAUNCH_PAD)';
    } else {
      v = CheckVerdict.go;
      n = 'All subsystems nominal';
    }

    runs.add(CheckRun(DateTime.now(), v, List.of(results), n));
    if (runs.length > 20) runs.removeAt(0);

    running = false;
    stepIndex = -1;
    verdict = v;
    note = n;
    _notify();
  }

  Future<HealthItem> _checkRadio(HealthItem base) async {
    if (base.level == HealthLevel.fail) return base;
    final rtt = await _roundTrip('PING');
    if (rtt == null) {
      final linked = _cmd.connected;
      return HealthItem(
        base.sub,
        linked ? HealthLevel.warn : HealthLevel.fail,
        linked ? 'NO ACK' : 'NO LINK',
        linked ? 'PING not acknowledged (3 s)' : 'Command link down',
      );
    }
    return HealthItem(
        base.sub, base.level, base.status, '${base.detail} · PING $rtt ms');
  }

  Future<HealthItem> _checkCamera(HealthItem base) async {
    final rtt = await _roundTrip('CAM_ON');
    if (rtt == null) {
      final linked = _cmd.connected;
      return HealthItem(
        base.sub,
        HealthLevel.fail,
        linked ? 'NO ACK' : 'NO LINK',
        linked ? 'CAM_ON not acknowledged (3 s)' : 'Command link down',
      );
    }
    return HealthItem(
        base.sub, HealthLevel.ok, 'ONLINE', 'CAM_ON ACK in $rtt ms');
  }

  /// Kirim perintah lalu tunggu ACK-nya (maks. 3 detik). Return ms atau null.
  Future<int?> _roundTrip(String name) async {
    if (!_cmd.connected) return null;
    final since = DateTime.now();
    _cmd.send(name);
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 3000) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (_disposed) return null;
      final acked = _cmd.log.any((e) =>
          e.name == name && e.state == CmdState.ack && !e.time.isBefore(since));
      if (acked) return sw.elapsedMilliseconds;
    }
    return null;
  }
}
