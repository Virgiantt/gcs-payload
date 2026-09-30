import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'health_service.dart'; // HealthInputs

enum CheckStatus { pending, checking, pass, fail }

class PreflightItem {
  final String id;
  final String label;
  final IconData icon;

  /// true = tidak ada data telemetri untuk item ini, operator konfirmasi manual
  final bool manual;
  CheckStatus status = CheckStatus.pending;
  String detail = 'Belum dicek';

  PreflightItem(this.id, this.label, this.icon, {this.manual = false});
}

class _R {
  final bool ok;
  final String detail;
  const _R(this.ok, this.detail);
}

class PreflightService extends ChangeNotifier {
  PreflightService({required this.inputs, required this.commandUp});

  final HealthInputs Function() inputs;
  final bool Function() commandUp;

  final Set<String> _manualOk = {};
  bool _ran = false;
  bool _running = false;
  DateTime? ranAt;

  late final List<PreflightItem> items = [
    PreflightItem('mcu', 'Raspberry Pi / MCU', Icons.memory),
    PreflightItem('gps', 'GPS', Icons.gps_fixed),
    PreflightItem('imu', 'IMU', Icons.threed_rotation),
    PreflightItem('baro', 'Barometer', Icons.speed),
    PreflightItem('temp', 'Temperature Sensor', Icons.thermostat),
    PreflightItem('lora', 'LoRa', Icons.cell_tower),
    PreflightItem('cam', 'Camera', Icons.videocam_outlined, manual: true),
    PreflightItem('batt', 'Battery', Icons.battery_full),
    PreflightItem('tlm', 'Telemetry', Icons.podcasts),
    PreflightItem('gcs', 'Ground Station Connection', Icons.link),
  ];

  bool get running => _running;
  bool get hasRun => _ran;
  bool isManualOk(String id) => _manualOk.contains(id);

  /// Launch hanya boleh jika check sudah dijalankan DAN semua item lulus
  /// (dievaluasi ulang tiap detik, jadi kalau ada yang gagal lagi -> blocked).
  bool get launchAllowed =>
      _ran && !_running && items.every((e) => e.status == CheckStatus.pass);

  List<PreflightItem> get failed =>
      items.where((e) => e.status == CheckStatus.fail).toList();

  void setManual(String id, bool v) {
    v ? _manualOk.add(id) : _manualOk.remove(id);
    if (_ran) refresh();
    notifyListeners();
  }

  Future<void> run() async {
    if (_running) return;
    _running = true;
    _ran = false;
    for (final e in items) {
      e.status = CheckStatus.pending;
      e.detail = 'Menunggu...';
    }
    notifyListeners();

    for (final e in items) {
      e.status = CheckStatus.checking;
      e.detail = 'Memeriksa...';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 250));
      _apply(e);
      notifyListeners();
    }
    _running = false;
    _ran = true;
    ranAt = DateTime.now();
    notifyListeners();
  }

  void reset() {
    _ran = false;
    _running = false;
    ranAt = null;
    for (final e in items) {
      e.status = CheckStatus.pending;
      e.detail = 'Belum dicek';
    }
    notifyListeners();
  }

  /// Panggil tiap detik (dari _runAlerts) agar status live.
  void refresh() {
    if (!_ran || _running) return;
    var changed = false;
    for (final e in items) {
      final old = e.status;
      _apply(e);
      if (old != e.status) changed = true;
    }
    if (changed) notifyListeners();
  }

  void _apply(PreflightItem e) {
    final r = _eval(e.id);
    e.status = r.ok ? CheckStatus.pass : CheckStatus.fail;
    e.detail = r.detail;
  }

  _R _eval(String id) {
    final i = inputs();
    final t = i.latest;
    final age = i.lastPacketAt == null
        ? null
        : DateTime.now().difference(i.lastPacketAt!).inMilliseconds / 1000.0;
    final fresh = age != null && age <= 3.0;

    switch (id) {
      case 'gcs':
        return i.linkUp && commandUp()
            ? const _R(true, 'Telemetry & command link terhubung')
            : _R(false,
                'Link putus (TLM ${i.linkUp ? 'OK' : 'DOWN'}, CMD ${commandUp() ? 'OK' : 'DOWN'})');

      case 'tlm':
        if (t == null || !fresh) {
          return const _R(false, 'Tidak ada paket terbaru (>3 dtk)');
        }
        return _R(true,
            'Paket #${t.packetCount} · ${age.toStringAsFixed(1)} dtk lalu');

      case 'mcu':
        // Paket harus naik berurutan (MCU hidup & sequence benar)
        final h = i.history;
        if (h.length < 3 || !fresh) {
          return const _R(false, 'Butuh minimal 3 paket berurutan');
        }
        final last = h.sublist(math.max(0, h.length - 5));
        for (var k = 1; k < last.length; k++) {
          if (last[k].packetCount <= last[k - 1].packetCount) {
            return const _R(false, 'Packet counter tidak naik');
          }
        }
        return const _R(true, 'Packet counter naik normal');

      case 'lora':
        // Packet loss dari celah packet counter (10 paket terakhir)
        final h = i.history;
        if (h.length < 5 || !fresh)
          return const _R(false, 'Data link belum cukup');
        final last = h.sublist(math.max(0, h.length - 10));
        final span = last.last.packetCount - last.first.packetCount + 1;
        final loss = span <= 0 ? 100.0 : (1 - last.length / span) * 100;
        return loss <= 10
            ? _R(true, 'Packet loss ${loss.toStringAsFixed(0)}%')
            : _R(false, 'Packet loss ${loss.toStringAsFixed(0)}% (>10%)');

      case 'gps':
        if (t == null || !fresh) return const _R(false, 'Tidak ada data');
        final la = t.gpsLat, lo = t.gpsLon; // sesuaikan nama field di Telemetry
        final valid = la.isFinite &&
            lo.isFinite &&
            la.abs() <= 90 &&
            lo.abs() <= 180 &&
            !(la == 0 && lo == 0);
        return valid
            ? _R(true, '${la.toStringAsFixed(5)}, ${lo.toStringAsFixed(5)}')
            : const _R(false, 'GPS NOT READY (no fix)');

      case 'imu':
        if (t == null || !fresh) return const _R(false, 'Tidak ada data');
        final ok = [t.roll, t.pitch, t.yaw].every((v) => v.isFinite);
        if (!ok) return const _R(false, 'Nilai IMU tidak valid');
        // di launch pad payload harus relatif tegak/stabil
        if (t.roll.abs() > 10 || t.pitch.abs() > 10) {
          return _R(false,
              'Miring: R ${t.roll.toStringAsFixed(1)}° P ${t.pitch.toStringAsFixed(1)}°');
        }
        return _R(true,
            'R ${t.roll.toStringAsFixed(1)}° P ${t.pitch.toStringAsFixed(1)}° Y ${t.yaw.toStringAsFixed(1)}°');

      case 'baro':
        if (t == null || !fresh) return const _R(false, 'Tidak ada data');
        final p = t.pressure;
        return (p.isFinite && p >= 300 && p <= 1100)
            ? _R(true, '${p.toStringAsFixed(1)} hPa')
            : _R(false, 'Tekanan di luar rentang ($p hPa)');

      case 'temp':
        if (t == null || !fresh) return const _R(false, 'Tidak ada data');
        final c = t.temperature;
        return (c.isFinite && c >= -40 && c <= 85)
            ? _R(true, '${c.toStringAsFixed(1)} °C')
            : _R(false, 'Suhu di luar rentang ($c °C)');

      case 'batt':
        if (t == null || !fresh) return const _R(false, 'Tidak ada data');
        final v = t.voltage;
        return v >= 3.7
            ? _R(true, '${v.toStringAsFixed(2)} V')
            : _R(false, '${v.toStringAsFixed(2)} V (min 3.70 V)');

      case 'cam':
        return isManualOk('cam')
            ? const _R(true, 'Dikonfirmasi operator')
            : const _R(false, 'Belum dikonfirmasi operator');
    }
    return const _R(false, 'Unknown');
  }
}
