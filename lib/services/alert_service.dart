import '../models/telemetry.dart';

enum AlertLevel { normal, warning, critical }

class Alert {
  final String id; // kunci unik per jenis alert
  final AlertLevel level;
  final String title;
  final String detail;
  const Alert(this.id, this.level, this.title, this.detail);
}

/// Catatan kejadian: alert muncul / naik level / kembali normal.
class AlertEvent {
  final DateTime time;
  final AlertLevel level; // level saat kejadian (normal = cleared)
  final String title;
  final String detail;
  final bool cleared;
  const AlertEvent(this.time, this.level, this.title, this.detail,
      {this.cleared = false});
}

/// Ambang batas alert. SESUAIKAN dengan hardware CanSat kamu.
class AlertThresholds {
  const AlertThresholds._();

  // Baterai (default: 1S LiPo, 3.0–4.2 V). Untuk 2S mis. warn 7.0 / crit 6.6.
  static const double battWarn = 3.70;
  static const double battCrit = 3.50;

  // Suhu (°C)
  static const double tempWarn = 50;
  static const double tempCrit = 65;

  // Selisih altitude GPS vs barometer (m)
  static const double gpsAltDiffWarn = 50;

  // Keterlambatan paket (detik sejak paket terakhir)
  static const double delayWarnSec = 3;
  static const double delayCritSec = 10;

  // Packet loss: dihitung dari N paket terakhir di history
  static const int lossWindow = 10;

  // Jangan alarm "link down" saat aplikasi baru start
  static const Duration startupGrace = Duration(seconds: 5);
}

/// Menghitung daftar alert aktif dari data telemetri + status koneksi.
/// Panggil [update] tiap ada paket baru DAN tiap ~1 detik (supaya
/// "telemetry delay" tetap naik walaupun tidak ada paket masuk).
class AlertService {
  final DateTime _started = DateTime.now();
  final Map<String, Alert> _prev = {};

  /// Alert aktif, urut dari level tertinggi.
  List<Alert> active = const [];

  /// Riwayat kejadian (terlama -> terbaru), maksimal 200.
  final List<AlertEvent> events = [];

  AlertLevel get level =>
      active.isEmpty ? AlertLevel.normal : active.first.level;

  void update({
    required Telemetry? latest,
    required List<Telemetry> history,
    required DateTime? lastPacketAt,
    required bool telemetryLinkUp,
    required bool commandLinkUp,
    required DateTime now,
  }) {
    final out = <Alert>[];
    final inGrace = now.difference(_started) < AlertThresholds.startupGrace;

    // ---- koneksi ----
    if (!inGrace && !telemetryLinkUp) {
      out.add(const Alert('link', AlertLevel.critical, 'TELEMETRY LINK DOWN',
          'Not connected to telemetry source'));
    }
    if (!inGrace && !commandLinkUp) {
      out.add(const Alert('cmd_link', AlertLevel.warning, 'COMMAND LINK DOWN',
          'Commands cannot be sent'));
    }

    // ---- telemetry delay ----
    if (lastPacketAt != null) {
      final age = now.difference(lastPacketAt).inMilliseconds / 1000.0;
      final detail = 'Last packet: ${age.toStringAsFixed(1)} s ago';
      if (age >= AlertThresholds.delayCritSec) {
        out.add(Alert('delay', AlertLevel.critical, 'TELEMETRY DELAY', detail));
      } else if (age >= AlertThresholds.delayWarnSec) {
        out.add(Alert('delay', AlertLevel.warning, 'TELEMETRY DELAY', detail));
      }
    }

    // ---- berdasarkan isi paket terakhir ----
    final t = latest;
    if (t != null) {
      // Baterai
      final vDetail = 'Voltage: ${t.voltage.toStringAsFixed(2)} V';
      if (t.voltage < AlertThresholds.battCrit) {
        out.add(
            Alert('battery', AlertLevel.critical, 'BATTERY CRITICAL', vDetail));
      } else if (t.voltage < AlertThresholds.battWarn) {
        out.add(Alert('battery', AlertLevel.warning, 'BATTERY LOW', vDetail));
      }

      // Suhu
      final tDetail = 'Temperature: ${t.temperature.toStringAsFixed(1)} °C';
      if (t.temperature > AlertThresholds.tempCrit) {
        out.add(
            Alert('temp', AlertLevel.critical, 'OVER TEMPERATURE', tDetail));
      } else if (t.temperature > AlertThresholds.tempWarn) {
        out.add(Alert('temp', AlertLevel.warning, 'HIGH TEMPERATURE', tDetail));
      }

      // GPS
      final noFix = t.gpsLat == 0 && t.gpsLon == 0;
      if (noFix) {
        out.add(const Alert('gps_nofix', AlertLevel.warning, 'GPS NO FIX',
            'Lat/Lon reported as 0, 0'));
      } else {
        final diff = (t.gpsAlt - t.altitude).abs();
        if (diff > AlertThresholds.gpsAltDiffWarn) {
          out.add(Alert(
              'gps_alt',
              AlertLevel.warning,
              'GPS SIGNAL WEAK',
              'GPS ${t.gpsAlt.toStringAsFixed(0)} m vs baro '
                  '${t.altitude.toStringAsFixed(0)} m'));
        }
      }
    }

    // ---- packet loss (celah nomor paket pada N paket terakhir) ----
    final missed = missedPackets(history);
    if (missed > 0) {
      final n = history.length > AlertThresholds.lossWindow
          ? AlertThresholds.lossWindow
          : history.length;
      out.add(Alert('pkt_loss', AlertLevel.warning, 'PACKET LOSS',
          'Missed $missed in last $n packets'));
    }

    out.sort((a, b) => b.level.index.compareTo(a.level.index));
    _recordEvents(out, now);
    active = out;
  }

  /// Jumlah paket yang hilang (celah nomor paket) pada N paket terakhir.
  static int missedPackets(List<Telemetry> history) {
    if (history.length < 2) return 0;
    final w = history.length > AlertThresholds.lossWindow
        ? history.sublist(history.length - AlertThresholds.lossWindow)
        : history;
    var missed = 0;
    for (var i = 1; i < w.length; i++) {
      final d = (w[i].packetCount - w[i - 1].packetCount).toInt();
      if (d > 1) missed += d - 1; // d <= 0 = counter reset, abaikan
    }
    return missed;
  }

  void _recordEvents(List<Alert> now, DateTime time) {
    final current = {for (final a in now) a.id: a};

    // muncul / naik-turun level
    for (final a in now) {
      final before = _prev[a.id];
      if (before == null || before.level != a.level) {
        events.add(AlertEvent(time, a.level, a.title, a.detail));
      }
    }
    // kembali normal
    for (final old in _prev.values) {
      if (!current.containsKey(old.id)) {
        events.add(AlertEvent(
            time, AlertLevel.normal, old.title, 'Back to normal',
            cleared: true));
      }
    }

    if (events.length > 200) events.removeRange(0, events.length - 200);
    _prev
      ..clear()
      ..addAll(current);
  }
}
