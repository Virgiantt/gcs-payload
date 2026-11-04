import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, ServerSocket, Socket, exit;
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';

import 'models/telemetry.dart';
import 'services/alert_service.dart';
import 'services/command_service.dart';
import 'services/system_monitor.dart';
import 'services/telemetry_logger.dart';
import 'services/telemetry_service.dart';
import 'theme/app_theme.dart';
import 'widgets/alert_bar.dart';
import 'widgets/battery_panel.dart';
import 'widgets/command_panel.dart';
import 'widgets/connection_indicator.dart';
import 'widgets/flight_progress_bar.dart';
import 'widgets/gps_panel.dart';
import 'widgets/live_chart.dart';
import 'widgets/map_3d_view.dart';
import 'widgets/telemetry_log_table.dart';

const bool kUseEmbeddedSimulator = true;

/// Laju paket simulator. Payload asli 1 Hz. Naikkan ke 2 sampai 5
/// kalau ingin melihat gerakan lebih rapat saat uji tampilan.
const double kSimPacketHz = 1;

/// true: setelah mendarat 15 detik, simulator terbang ulang otomatis
/// dengan arah angin dan arah condong roket yang baru.
const bool kSimLoop = true;

const String kReceiverHost = '127.0.0.1';

const int kTelemetryPort = 9999;
const int kCommandPort = 9998;

const String kLaunchCmd = 'LAUNCH';
const double kSimPacketLossRate = 0.0;
const String kLogoAsset = 'assets/icons/eepisat.png';
const String kSimTeamId = '1064';
const double kSimBaseLat = -7.275764;
const double kSimBaseLon = 112.794317;
const String kSimCsvHeader =
    'TEAM_ID,MISSION_TIME,PACKET_COUNT,ALTITUDE,PRESSURE,TEMPERATURE,'
    'VOLTAGE,ROLL,PITCH,YAW,GPS_LAT,GPS_LON,GPS_ALT,STATE\r\n';

// =========================================================
// DETEKSI PLATFORM
// =========================================================

/// True hanya di Windows/macOS desktop (yang punya window_manager plugin).
/// RPi (flutter-pi) dan Linux headless → false.
/// Web → false.
bool get _isDesktopWindowManager {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isMacOS;
}

// =========================================================
// FLIGHT PROFILE (untuk simulator embedded — mode dev)
// =========================================================
class FlightProfile {
  final math.Random _rng = math.Random();
  late DateTime _start;
  int packetCount = 0;

  bool launched = false;
  DateTime? _launchAt;

  // ---- Parameter penerbangan dummy ----
  static const double _padHold = 5; // detik di pad setelah LAUNCH
  static const double _ascentDur = 14; // detik naik sampai apogee
  static const double _apogeeAlt = 700; // m
  static const double _apogeeDur = 3; // detik payload terlepas dan berguling
  static const double _fastRate = 15; // m/s, turun sebelum parasut utama
  static const double _mainAlt = 100; // m, parasut utama terbuka
  static const double _slowRate = 5; // m/s, turun setelah parasut utama
  static const double _landedHold = 15; // detik diam sebelum terbang ulang
  static const double _leanDeg = 6; // kemiringan roket saat naik

  static const double _tApogee = _padHold + _ascentDur;
  static const double _tDescent = _tApogee + _apogeeDur;
  static const double _tMain =
      _tDescent + (_apogeeAlt - _mainAlt) / _fastRate;
  static const double _tLanded = _tMain + _mainAlt / _slowRate;

  // Diacak setiap peluncuran supaya lintasan tiap terbang berbeda.
  double _windDir = 60; // derajat, arah angin bertiup
  double _windSpeed = 4; // m/s
  double _launchAz = 30; // derajat, arah condong roket

  FlightProfile() {
    reset();
  }

  void reset() {
    _start = DateTime.now();
    packetCount = 0;
    launched = false;
    _launchAt = null;
  }

  void launch() {
    launched = true;
    _launchAt = DateTime.now();
    _windDir = _u(0, 360);
    _windSpeed = _u(2.5, 6);
    _launchAz = _u(0, 360);
  }

  /// Detik sejak perintah LAUNCH. -1 kalau belum diluncurkan.
  double get _t => (!launched || _launchAt == null)
      ? -1.0
      : DateTime.now().difference(_launchAt!).inMilliseconds / 1000.0;

  bool get inFlight => launched && _t >= 0 && _t < _tLanded;

  /// Pergeseran horizontal (timur, utara) dalam meter selama turun.
  (double, double) _descentOffset(double td) {
    final az = _launchAz * math.pi / 180;
    final wd = _windDir * math.pi / 180;
    final apH = _apogeeAlt * math.tan(_leanDeg * math.pi / 180);
    final drift = _windSpeed * td;
    final sway = 6 * math.sin(td * 0.4);
    return (
      apH * math.sin(az) + drift * math.sin(wd) + sway * math.cos(wd),
      apH * math.cos(az) + drift * math.cos(wd) - sway * math.sin(wd),
    );
  }

  String step() {
    packetCount++;
    final elapsed = DateTime.now().difference(_start).inMilliseconds / 1000.0;

    var t = _t;
    if (kSimLoop && launched && t > _tLanded + _landedHold) {
      launch();
      t = _t;
    }

    final az = _launchAz * math.pi / 180;
    final lean = _leanDeg * math.pi / 180;

    String state;
    double alt, roll, pitch, yaw;
    double east = 0, north = 0;

    if (t < _padHold) {
      state = 'LAUNCH_PAD';
      alt = _u(0.0, 0.3);
      roll = _n(0.3);
      pitch = _n(0.3);
      yaw = _launchAz + _n(0.3);
    } else if (t < _tApogee) {
      // Naik melambat (parabola), roket condong dan berputar pada sumbunya.
      state = 'ASCENT';
      final p = (t - _padHold) / _ascentDur;
      alt = _apogeeAlt * (1 - (1 - p) * (1 - p)) + _n(1.0);
      final h = math.max(0.0, alt) * math.tan(lean);
      east = h * math.sin(az);
      north = h * math.cos(az);
      roll = 2 * math.sin(t * 9) + _n(0.8);
      pitch = _leanDeg + 1.5 * math.sin(t * 7) + _n(0.8);
      yaw = _launchAz + (t - _padHold) * 90;
    } else if (t < _tDescent) {
      // Payload lepas dari roket dan berguling.
      state = 'APOGEE';
      final p = (t - _tApogee) / _apogeeDur;
      alt = _apogeeAlt - 3 * p * p + _n(0.5);
      final o = _descentOffset(0);
      east = o.$1;
      north = o.$2;
      roll = 70 * math.sin(t * 2.3) + _n(2);
      pitch = 60 * math.sin(t * 1.7 + 0.8) + _n(2);
      yaw = _launchAz + (t - _padHold) * 60;
    } else if (t < _tLanded) {
      // Turun dua tahap, terbawa angin, berayun di bawah parasut.
      state = 'DESCENT';
      final td = t - _tDescent;
      final a = t < _tMain
          ? _apogeeAlt - _fastRate * td
          : _mainAlt - _slowRate * (t - _tMain);
      alt = math.max(0.3, a + _n(0.6));
      final o = _descentOffset(td);
      east = o.$1;
      north = o.$2;
      final amp = t < _tMain ? 18.0 : 10.0;
      roll = amp * 0.7 * math.sin(td * 2.3 + 1) + _n(0.6);
      pitch = amp * math.sin(td * 1.9) + _n(0.6);
      yaw = _windDir + td * 25;
    } else {
      // Mendarat lalu rebah ke samping.
      state = 'LANDED';
      final td = _tLanded - _tDescent;
      final o = _descentOffset(td);
      east = o.$1;
      north = o.$2;
      alt = 0.0;
      roll = _n(0.2);
      pitch = 82 + _n(0.3);
      yaw = _windDir + td * 25;
    }
    yaw = yaw % 360;

    double pressure =
        1013.25 * math.pow(1.0 - (math.max(0.0, alt) / 44330.0), 5.255);
    pressure = _r(pressure + _u(-0.2, 0.2), 1);
    final temp = _r(28.5 - (alt * 0.0065) + _u(-0.3, 0.3), 1);
    final volt =
        _r(4.20 - (math.min(elapsed, 110.0) * 0.002) + _u(-0.02, 0.02), 2);

    final latR = kSimBaseLat * math.pi / 180;
    final gpsLat = _r(kSimBaseLat + north / 110574.0 + _n(0.000004), 6);
    final gpsLon = _r(
        kSimBaseLon + east / (111320.0 * math.cos(latR)) + _n(0.000004), 6);
    final gpsAlt = _r(math.max(0.0, alt) + 5 + _n(1.5), 1);

    final sec = elapsed.floor();
    final mt = '${(sec ~/ 3600).toString().padLeft(2, '0')}:'
        '${((sec % 3600) ~/ 60).toString().padLeft(2, '0')}:'
        '${(sec % 60).toString().padLeft(2, '0')}';

    return '$kSimTeamId,$mt,$packetCount,'
        '${alt.toStringAsFixed(1)},${pressure.toStringAsFixed(1)},'
        '${temp.toStringAsFixed(1)},${volt.toStringAsFixed(2)},'
        '${roll.toStringAsFixed(1)},${pitch.toStringAsFixed(1)},'
        '${yaw.toStringAsFixed(1)},'
        '${gpsLat.toStringAsFixed(6)},${gpsLon.toStringAsFixed(6)},'
        '${gpsAlt.toStringAsFixed(1)},$state\r\n';
  }

  double _u(double a, double b) => a + _rng.nextDouble() * (b - a);
  double _n(double s) => _u(-s, s);
  double _r(double v, int d) {
    final m = math.pow(10, d);
    return (v * m).round() / m;
  }
}

// =========================================================
// EMBEDDED TCP SIMULATOR (mode dev)
// =========================================================
class EmbeddedSimulator {
  final String host;
  final int port;

  EmbeddedSimulator({this.host = '0.0.0.0', this.port = 9999});

  ServerSocket? _server;
  ServerSocket? _cmdServer;
  Socket? _client;
  final FlightProfile _profile = FlightProfile();
  bool _running = false;
  final math.Random _lossRng = math.Random();

  void Function(String msg)? onLog;
  bool Function()? canLaunch;
  void Function()? onLaunched;

  bool requestLaunch() {
    if (_profile.inFlight) {
      _log('[LAUNCH] Ditolak: payload sedang terbang');
      return false;
    }
    if (canLaunch == null || !canLaunch!()) {
      _log('[LAUNCH] BLOCKED — Pre-Flight Check belum lolos');
      return false;
    }
    _profile.launch();
    _log('[LAUNCH] Pre-flight OK -> payload ASCEND');
    onLaunched?.call();
    return true;
  }

  Future<void> start() async {
    _server = await ServerSocket.bind(host, port);
    _running = true;
    _log('================================================');
    _log('CanSat Telemetry Simulator (Dart Embedded)');
    _log('   Listening on : $host:$port');
    _log('   GCS Address  : 127.0.0.1:$port');
    _log('   Status       : Waiting for GCS to connect...');
    _log('================================================');
    _server!.listen(_onClient);

    try {
      _cmdServer = await ServerSocket.bind(host, kCommandPort);
      _cmdServer!.listen(_onCmdClient);
      _log('   Command port : $kCommandPort');
    } catch (e) {
      _log('[CMD] Gagal bind port $kCommandPort: $e');
    }
  }

  void _onCmdClient(Socket s) {
    _log('[CMD] Command link connected');
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        final p = line.trim().split(',');
        if (p.length >= 4 && p[0] == 'CMD') {
          final id = p[2];
          final name = p[3];
          _log('[CMD] Received $name (id $id)');
          if (name.toUpperCase() == kLaunchCmd) {
            if (!requestLaunch()) {
              try {
                s.write('NACK,$id,$name,PREFLIGHT_NOT_PASSED\r\n');
              } catch (_) {}
              return;
            }
          }
          Future.delayed(const Duration(milliseconds: 400), () {
            try {
              s.write('ACK,$id,$name\r\n');
            } catch (_) {}
          });
        }
      },
      onDone: () => _log('[CMD] Command link closed'),
      onError: (_) {},
      cancelOnError: true,
    );
  }

  void _onClient(Socket s) async {
    if (_client != null) {
      s.destroy();
      return;
    }
    _client = s;
    _log('[+] GCS Connected from ${s.remoteAddress.address}:${s.remotePort}');
    s.write(kSimCsvHeader);
    _profile.reset();
    _profile.launch();
    _log('[LAUNCH] Auto launch saat GCS terhubung');

    s.listen(
      (_) {},
      onDone: _onDisconnect,
      onError: (_) => _onDisconnect(),
      cancelOnError: true,
    );

    while (_running && _client == s) {
      try {
        final line = _profile.step();
        final parts = line.split(',');
        if (_lossRng.nextDouble() < kSimPacketLossRate) {
          _log(
              '[${parts[1]}] Pkt #${parts[2].padLeft(3, '0')} -> LOST (simulasi)');
        } else {
          s.write(line);
          _log('[${parts[1]}] Pkt #${parts[2].padLeft(3, '0')} '
              '| Alt: ${parts[3].padLeft(6)} m '
              '| State: ${parts[13].trim().padRight(12)} -> Sent');
        }
      } catch (_) {
        break;
      }
      await Future.delayed(
          Duration(milliseconds: (1000 / kSimPacketHz).round()));
    }
    _onDisconnect();
  }

  void _onDisconnect() {
    if (_client == null) return;
    try {
      _client?.destroy();
    } catch (_) {}
    _client = null;
    _log('[-] GCS Disconnected. Waiting for reconnection...');
  }

  void _log(String m) => onLog?.call(m);

  Future<void> stop() async {
    _running = false;
    _onDisconnect();
    await _server?.close();
    _server = null;
    await _cmdServer?.close();
    _cmdServer = null;
  }
}

ThemeData _buildTheme(AppPalette p) {
  final base = AppTheme.from(p);
  return base.copyWith(textTheme: GoogleFonts.interTextTheme(base.textTheme));
}

// =========================================================
// MAIN
// =========================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    debugPrint('[FLUTTER-ERR] ${details.exceptionAsString()}');
    final st = details.stack;
    if (st != null) {
      debugPrint(st.toString().split('\n').take(10).join('\n'));
    }
  };

  // window_manager HANYA untuk Windows/macOS desktop.
  // Di RPi/flutter-pi plugin ini tidak ada -> skip supaya tidak crash.
  if (_isDesktopWindowManager) {
    await windowManager.ensureInitialized();

    const opts = WindowOptions(
      size: Size(1400, 880),
      minimumSize: Size(1000, 640),
      center: true,
      title: 'CanSat GCS — Ground Control Station',
    );

    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const GcsApp());

  if (_isDesktopWindowManager) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 300));
      await windowManager.maximize();
    });
  }
}

class GcsApp extends StatelessWidget {
  const GcsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CanSat GCS',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(AppPalette.light),
      home: const GcsHome(),
    );
  }
}

class GcsHome extends StatefulWidget {
  const GcsHome({super.key});

  @override
  State<GcsHome> createState() => _GcsHomeState();
}

class _GcsHomeState extends State<GcsHome> {
  AppPalette palette = AppPalette.light;
  late ThemeData _theme = _buildTheme(palette);

  // ---- TelemetryService ----
  late final TelemetryService service = TelemetryService(
    host: kUseEmbeddedSimulator ? '127.0.0.1' : kReceiverHost,
    port: kTelemetryPort,
  );

  final EmbeddedSimulator simulator = EmbeddedSimulator();
  final SystemMonitor sysmon = SystemMonitor();
  final TelemetryLogger logger = TelemetryLogger();
  final AlertService alerts = AlertService();
  Timer? _alertTimer;
  int _lastTotal = -1;
  DateTime? _lastPacketAt;

  // Jejak proses misi untuk bar progres di Dashboard.
  final Map<String, String> _phaseTimes = {};
  double? _maxAlt;
  String? _lastState;

  late final CommandService cmd = CommandService(
      host: service.host, port: kCommandPort, teamId: kSimTeamId);

  bool _isFullscreen = false;
  int _tab = 0;
  final List<String> _simLog = [];

  @override
  void initState() {
    super.initState();
    service.addListener(_onServiceUpdate);
    sysmon.start();

    _alertTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _runAlerts();
      setState(() {});
    });

    _boot();
  }

  Future<void> _boot() async {
    if (kUseEmbeddedSimulator) {
      // ============= MODE SIMULATOR =============
      debugPrint('[GCS] Mode SIMULATOR (embedded)');
      simulator.canLaunch = () => true;
      simulator.onLog = (msg) {
        debugPrint('[SIM] $msg');
        if (mounted) {
          setState(() {
            _simLog.add(msg);
            if (_simLog.length > 100) _simLog.removeAt(0);
          });
        }
      };

      try {
        await simulator.start();
      } catch (e) {
        debugPrint('[SIM] Gagal start: $e');
      }

      await Future.delayed(const Duration(milliseconds: 500));
      service.connect();
      cmd.start();
    } else {
      // ============= MODE LORA (hardware) =============
      debugPrint('[GCS] Mode LORA — receiver $kReceiverHost:$kTelemetryPort');
      _simLog.add('[GCS] Menghubungkan ke receiver $kReceiverHost ...');
      _simLog.add('[GCS] Pastikan receiver sudah connect WiFi.');
      _simLog.add('[GCS] Test: Test-NetConnection $kReceiverHost '
          '-Port $kTelemetryPort');

      await Future.delayed(const Duration(milliseconds: 300));
      service.connect();
      // cmd.start();   // ← uncomment kalau receiver sudah support command
    }
  }

  void _onServiceUpdate() {
    // Logger TIDAK auto-save. User klik tombol "Save CSV" untuk menyimpan.

    if (service.totalReceived > 0 && service.totalReceived != _lastTotal) {
      _lastTotal = service.totalReceived;
      _lastPacketAt = DateTime.now();
      final t = service.latest;
      if (t != null) _trackPhase(t);
    }
    _runAlerts();
    if (mounted) setState(() {});
  }

  /// Catat mission time saat tiap fase pertama kali muncul dan
  /// ketinggian tertinggi. Direset saat kembali ke LAUNCH_PAD.
  void _trackPhase(Telemetry t) {
    final st = t.state.trim().toUpperCase();
    if (st == 'LAUNCH_PAD' && _lastState != null && _lastState != 'LAUNCH_PAD') {
      _phaseTimes.clear();
      _maxAlt = null;
    }
    if (kFlightPhases.contains(st)) {
      _phaseTimes.putIfAbsent(st, () => t.missionTime);
    }
    if (t.altitude.isFinite && (_maxAlt == null || t.altitude > _maxAlt!)) {
      _maxAlt = t.altitude;
    }
    _lastState = st;
  }

  bool get _signalLost {
    if (service.latest == null) return false;
    if (service.status != ConnectionStatus.connected) return true;
    final at = _lastPacketAt;
    return at != null &&
        DateTime.now().difference(at) > const Duration(seconds: 3);
  }

  void _runAlerts() {
    alerts.update(
      latest: service.latest,
      history: service.history,
      lastPacketAt: _lastPacketAt,
      telemetryLinkUp: service.status == ConnectionStatus.connected,
      commandLinkUp: cmd.connected,
      now: DateTime.now(),
    );
  }

  void _onSaveCsv() {
    final n = logger.save(service.history);

    if (!mounted) return;

    final msg = n > 0
        ? '✅ Tersimpan $n data terbaru ke CSV'
        : '❌ Gagal menyimpan: ${logger.error ?? "tidak diketahui"}';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        backgroundColor: n > 0 ? palette.ok : palette.bad,
      ),
    );

    setState(() {});
  }

  @override
  void dispose() {
    _alertTimer?.cancel();
    service.removeListener(_onServiceUpdate);
    service.dispose();
    if (kUseEmbeddedSimulator) simulator.stop();
    sysmon.dispose();
    cmd.dispose();
    super.dispose();
  }

  void _toggleTheme() {
    setState(() {
      palette = palette.name == 'dark' ? AppPalette.light : AppPalette.dark;
      _theme = _buildTheme(palette);
    });
  }

  Future<void> _toggleFullscreen() async {
    _isFullscreen = !_isFullscreen;
    if (_isDesktopWindowManager) {
      await windowManager.setFullScreen(_isFullscreen);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _theme,
      child: Scaffold(
        backgroundColor: palette.bg,
        body: Stack(
          children: [
            Positioned(
              right: -80,
              bottom: -80,
              child: Opacity(
                opacity: 0.04,
                child: Image.asset(
                  'assets/icons/indonesia.png',
                  width: 420,
                  height: 420,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
            Column(
              children: [
                _buildHeader(),
                AlertBar(palette: palette, service: alerts),
                Expanded(child: _buildTabView()),
                _buildStatusBar(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // =========================================================
  // HEADER
  // =========================================================
  Widget _buildHeader() {
    return LayoutBuilder(builder: (context, c) {
      // Header menyesuaikan lebar layar supaya tidak meluber.
      final compact = c.maxWidth < 1500; // tombol jadi ikon saja
      final tight = c.maxWidth < 1180; // tab jadi ikon saja

      return Container(
        margin: const EdgeInsets.fromLTRB(14, 14, 14, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: palette.panel,
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: palette.panelAlt,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Image.asset(
                  kLogoAsset,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.satellite_alt,
                    color: palette.accent,
                    size: 26,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  compact ? 'EEPISAT GCS' : 'EEPISAT Ground Control Station',
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Team 1064  ·  Target ${service.host}:${service.port}',
                  style: TextStyle(color: palette.textDim, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(width: 20),
            _navTabs(iconOnly: tight),
            const Spacer(),
            ConnectionIndicator(palette: palette, status: service.status),
            const SizedBox(width: 14),
            if (!compact) ...[
              Container(width: 1, height: 30, color: palette.border),
              const SizedBox(width: 14),
              _brandLogo(
                asset: 'assets/icons/indonesia.png',
                tooltip: 'Indonesia',
                height: 26,
                circular: true,
              ),
              const SizedBox(width: 14),
            ],
            Container(width: 1, height: 30, color: palette.border),
            const SizedBox(width: 14),
            _headerButton(
              icon: palette.name == 'dark' ? Icons.light_mode : Icons.dark_mode,
              label: palette.name == 'dark' ? 'Light' : 'Dark',
              onTap: _toggleTheme,
              iconOnly: compact,
            ),
            const SizedBox(width: 8),
            _headerButton(
              icon: _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              label: _isFullscreen ? 'Exit' : 'Fullscreen',
              onTap: _toggleFullscreen,
              iconOnly: compact,
            ),
            const SizedBox(width: 8),
            _headerButton(
              icon: Icons.refresh,
              label: 'Reconnect',
              onTap: () => service.reconnect(),
              iconOnly: compact,
            ),
            const SizedBox(width: 8),
            _menuButton(),
          ],
        ),
      );
    });
  }

  // =========================================================
  // NAVIGASI TAB (di dalam header)
  // =========================================================
  static const List<(IconData, String)> _tabItems = [
    (Icons.dashboard_outlined, 'Dashboard'),
    (Icons.public, 'Map 3D'),
    (Icons.battery_charging_full, 'Battery'),
  ];

  Widget _navTabs({bool iconOnly = false}) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.panelAlt,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _tabItems.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            _navTab(i, iconOnly),
          ],
        ],
      ),
    );
  }

  Widget _navTab(int i, bool iconOnly) {
    final (icon, label) = _tabItems[i];
    final active = _tab == i;
    final color = active ? palette.accent : palette.textDim;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: () => setState(() => _tab = i),
        borderRadius: BorderRadius.circular(7),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(
              horizontal: iconOnly ? 10 : 14, vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? palette.accent.withValues(alpha: 0.14)
                : Colors.transparent,
            border: Border.all(
              color: active
                  ? palette.accent.withValues(alpha: 0.6)
                  : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              if (!iconOnly) ...[
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _brandLogo({
    required String asset,
    required String tooltip,
    double height = 32,
    bool circular = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Container(
        height: height,
        padding: circular
            ? const EdgeInsets.all(2)
            : const EdgeInsets.symmetric(horizontal: 4),
        decoration: circular
            ? BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: palette.border, width: 1.5),
              )
            : null,
        child: Image.asset(
          asset,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Icon(
            Icons.image_not_supported_outlined,
            size: height * 0.6,
            color: palette.textDim,
          ),
        ),
      ),
    );
  }

  Widget _headerButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool iconOnly = false,
  }) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: iconOnly ? 9 : 12, vertical: 9),
          decoration: BoxDecoration(
            color: palette.panelAlt,
            border: Border.all(color: palette.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: palette.text, size: 16),
              if (!iconOnly) ...[
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================
  // MENU TITIK TIGA (⋮) — QUIT APPLICATION
  // =========================================================
  Widget _menuButton() {
    return PopupMenuButton<String>(
      tooltip: 'Menu',
      offset: const Offset(0, 46),
      color: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: palette.border),
      ),
      onSelected: (v) {
        if (v == 'quit') _confirmQuit();
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          value: 'quit',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.power_settings_new, size: 18, color: palette.bad),
              const SizedBox(width: 10),
              Text(
                'Quit application',
                style: TextStyle(
                  color: palette.bad,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: palette.panelAlt,
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.more_vert, size: 18, color: palette.text),
      ),
    );
  }

  Future<void> _confirmQuit() async {
    final unsaved = service.history.isNotEmpty && !logger.hasSaved;

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => Theme(
        data: _theme,
        child: AlertDialog(
          title: const Text('Quit application?'),
          content: Text(
            unsaved
                ? 'Data telemetri belum pernah disimpan ke CSV '
                    '(tombol "Save CSV"). Data di memori akan hilang.\n\n'
                    'Tetap keluar?'
                : 'Koneksi telemetri dan command akan diputus.\n\n'
                    'Tetap keluar?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: palette.bad),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Quit'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) await _quitApp();
  }

  Future<void> _quitApp() async {
    _alertTimer?.cancel();
    try {
      if (kUseEmbeddedSimulator) await simulator.stop();
    } catch (_) {}

    if (_isDesktopWindowManager) {
      // Windows / macOS desktop
      await windowManager.destroy();
    } else {
      // RPi (flutter-pi) / Linux / platform lain
      exit(0);
    }
  }

  // =========================================================
  // TABS
  // =========================================================
  Widget _buildTabView() {
    // Hanya halaman aktif yang dibangun, jadi tidak ada dua peta 3D
    // yang menggambar bersamaan (penting untuk performa di RPi).
    final Widget page = switch (_tab) {
      1 => _buildMap3DTab(),
      2 => BatteryPanel(
          palette: palette,
          latest: service.latest,
          history: service.history,
          signalLost: _signalLost,
        ),
      _ => _buildDashboardTab(),
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: palette.panelAlt,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.hardEdge,
      child: KeyedSubtree(key: ValueKey('page-$_tab'), child: page),
    );
  }

  // =========================================================
  // TAB 1: DASHBOARD
  // =========================================================
  Widget _buildDashboardTab() {
    final t = service.latest;
    final history = service.history;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FlightProgressBar(
            palette: palette,
            data: t,
            signalLost: _signalLost,
            phaseTimes: _phaseTimes,
            maxAltitude: _maxAlt,
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 380,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 6,
                  child: CommandPanel(
                    palette: palette,
                    service: cmd,
                    compact: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 9,
                  child: Map3DView(
                    key: const ValueKey('map3d-dash'),
                    palette: palette,
                    data: service.latest,
                    history: service.history,
                    compact: true,
                    fallbackLat: kSimBaseLat,
                    fallbackLon: kSimBaseLon,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 230,
            child: _liveCharts(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 300,
            child: TelemetryLogTable(
              palette: palette,
              history: history,
              maxRows: 5,
              signalLost: _signalLost,
            ),
          ),
          const SizedBox(height: 12),
          _buildLogBar(),
        ],
      ),
    );
  }

  Widget _liveCharts() {
    final h = service.history;
    final offset = service.totalReceived - h.length;

    List<FlSpot> spots(double Function(Telemetry) sel) => List.generate(
          h.length,
          (i) => FlSpot((offset + i).toDouble(), sel(h[i])),
        );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: LiveChart(
            palette: palette,
            title: 'Altitude',
            unit: 'm',
            lineColor: palette.accent,
            spots: spots((t) => t.altitude),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: LiveChart(
            palette: palette,
            title: 'Temperature',
            unit: '°C',
            lineColor: const Color(0xFFF59E0B),
            spots: spots((t) => t.temperature),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: LiveChart(
            palette: palette,
            title: 'Pressure',
            unit: 'hPa',
            lineColor: const Color(0xFFEF4444),
            spots: spots((t) => t.pressure),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: LiveChart(
            palette: palette,
            title: 'Battery Voltage',
            unit: 'V',
            lineColor: const Color(0xFF22C55E),
            spots: spots((t) => t.voltage),
          ),
        ),
      ],
    );
  }

  Widget _section(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Text(
        text,
        style: TextStyle(
          color: palette.textDim,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  // =========================================================
  // TAB 2: MAP 3D (peta + model payload digabung)
  // =========================================================
  Widget _buildMap3DTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section('PAYLOAD 3D TRACKING'),
                Expanded(
                  child: Map3DView(
                    key: const ValueKey('map3d-tab'),
                    palette: palette,
                    data: service.latest,
                    history: service.history,
                    fallbackLat: kSimBaseLat,
                    fallbackLon: kSimBaseLon,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section('GPS TELEMETRY'),
                Expanded(
                  flex: 3,
                  child: GpsPanel(palette: palette, data: service.latest),
                ),
                const SizedBox(height: 12),
                _section('ATTITUDE DATA'),
                Expanded(
                  flex: 3,
                  child: SingleChildScrollView(
                    child: _buildAttitudeNumericPanel(),
                  ),
                ),
                const SizedBox(height: 12),
                _section(kUseEmbeddedSimulator ? 'SIMULATOR LOG' : 'LoRa LOG'),
                Expanded(flex: 2, child: _buildSimLog()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimLog() {
    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.hardEdge,
      child: _simLog.isEmpty
          ? Center(
              child: Text(
                kUseEmbeddedSimulator
                    ? 'Menunggu simulator...'
                    : 'Menunggu data LoRa...',
                style: TextStyle(color: palette.textDim, fontSize: 11),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: _simLog.length,
              itemBuilder: (_, i) {
                final line = _simLog[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: SelectableText(
                    line,
                    style: TextStyle(
                      color: palette.textDim,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildAttitudeNumericPanel() {
    final t = service.latest;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _attitudeRow('Roll', t?.roll, palette.accent),
          const Divider(height: 24),
          _attitudeRow('Pitch', t?.pitch, const Color(0xFFF59E0B)),
          const Divider(height: 24),
          _attitudeRow('Yaw', t?.yaw, const Color(0xFF7C3AED)),
          const Divider(height: 24),
          _attitudeRow('Temperature', t?.temperature, const Color(0xFFEF4444),
              unit: '°C'),
          const Divider(height: 24),
          _attitudeRow('Pressure', t?.pressure, const Color(0xFF10B981),
              unit: 'hPa'),
        ],
      ),
    );
  }

  Widget _attitudeRow(String label, double? value, Color color,
      {String unit = '°'}) {
    final v = value ?? 0;
    final norm = (v / 180).clamp(-1.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: palette.textDim,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const Spacer(),
            Text(
              value == null
                  ? '—'
                  : '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}$unit',
              style: TextStyle(
                color: color,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (norm + 1) / 2,
            minHeight: 6,
            backgroundColor: palette.panelAlt,
            color: color,
          ),
        ),
      ],
    );
  }

  // =========================================================
  // LOG BAR — MANUAL SAVE CSV
  // =========================================================
  Widget _buildLogBar() {
    final p = palette;
    final failed = logger.error != null;
    final hasData = service.history.isNotEmpty;
    final savedMsg = logger.hasSaved
        ? 'Tersimpan: ${logger.rows} data terbaru  ·  ${logger.path}'
        : 'Belum ada data tersimpan  ·  Klik "Save CSV" untuk menyimpan';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.save_alt,
            size: 16,
            color: failed ? p.bad : p.ok,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              failed ? 'Gagal menyimpan CSV: ${logger.error}' : savedMsg,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.textDim, fontSize: 11),
            ),
          ),
          const SizedBox(width: 10),
          _saveCsvButton(hasData, p),
          const SizedBox(width: 6),
          _headerButton(
            icon: Icons.folder_open,
            label: 'Open folder',
            onTap: logger.openFolder,
          ),
        ],
      ),
    );
  }

  Widget _saveCsvButton(bool enabled, AppPalette p) {
    return Tooltip(
      message: 'Simpan ${TelemetryLogger.maxSave} data terbaru ke CSV',
      child: InkWell(
        onTap: enabled ? _onSaveCsv : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: enabled ? p.accent.withValues(alpha: 0.15) : p.panelAlt,
            border: Border.all(
              color: enabled ? p.accent : p.border,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.save_alt,
                size: 16,
                color: enabled ? p.accent : p.textDim,
              ),
              const SizedBox(width: 6),
              Text(
                'Save CSV (${TelemetryLogger.maxSave})',
                style: TextStyle(
                  color: enabled ? p.accent : p.textDim,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================
  // STATUS BAR
  // =========================================================
  Widget _buildStatusBar() {
    final t = service.latest;
    final ok = service.status == ConnectionStatus.connected;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.error_outline,
            color: ok ? palette.ok : palette.bad,
            size: 14,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              kUseEmbeddedSimulator
                  ? '${service.statusMessage}  ·  Simulator port ${simulator.port}'
                  : '${service.statusMessage}  ·  Receiver ${service.host}:${service.port}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.textDim, fontSize: 11),
            ),
          ),
          const SizedBox(width: 12),
          _buildSysStats(),
          const SizedBox(width: 16),
          if (t != null)
            Text(
              'Packet #${t.packetCount.toString().padLeft(4, '0')}  ·  ${t.missionTime}  ·  ${t.state}',
              style: TextStyle(
                color: palette.textDim,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          const SizedBox(width: 16),
          Container(width: 1, height: 16, color: palette.border),
          const SizedBox(width: 12),
          _footerLogo('assets/icons/eepisat.png', 'EEPISAT', 16),
          const SizedBox(width: 8),
          _footerLogo('assets/icons/indonesia.png', 'Indonesia', 14,
              circular: true),
        ],
      ),
    );
  }

  Widget _buildSysStats() {
    return ListenableBuilder(
      listenable: sysmon,
      builder: (context, _) {
        final cpu = sysmon.cpuPercent;
        final ramUsed = sysmon.ramUsedMb;
        final ramTotal = sysmon.ramTotalMb;
        final ramPct = sysmon.ramPercent;
        final temp = sysmon.cpuTempC;

        Color level(double? v, {double warn = 60, double bad = 85}) {
          if (v == null) return palette.textDim;
          if (v >= bad) return palette.bad;
          if (v >= warn) return palette.warn;
          return palette.ok;
        }

        String gb(double mb) => (mb / 1024).toStringAsFixed(1);
        final up = sysmon.uptime;
        String two(int n) => n.toString().padLeft(2, '0');

        return Flexible(
          flex: 3,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _sysChip(
                  Icons.memory,
                  cpu == null
                      ? 'CPU ${sysmon.cores} core'
                      : 'CPU ${cpu.toStringAsFixed(0)}% · ${sysmon.cores} core',
                  level(cpu),
                ),
                if (ramUsed != null && ramTotal != null)
                  _sysChip(
                    Icons.sd_storage_outlined,
                    'RAM ${gb(ramUsed)}/${gb(ramTotal)} GB'
                    '${ramPct != null ? ' (${ramPct.toStringAsFixed(0)}%)' : ''}',
                    level(ramPct, warn: 70, bad: 90),
                  ),
                _sysChip(
                  Icons.apps,
                  'App ${sysmon.appRamMb} MB',
                  palette.textDim,
                ),
                if (temp != null)
                  _sysChip(
                    Icons.thermostat,
                    '${temp.toStringAsFixed(0)}°C',
                    level(temp, warn: 65, bad: 80),
                  ),
                _sysChip(
                  Icons.timer_outlined,
                  '${two(up.inHours)}:${two(up.inMinutes % 60)}:${two(up.inSeconds % 60)}',
                  palette.textDim,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sysChip(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(left: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: palette.textDim,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _footerLogo(String asset, String tooltip, double h,
      {bool circular = false}) {
    return Tooltip(
      message: tooltip,
      child: Container(
        height: h,
        padding: circular
            ? const EdgeInsets.all(1)
            : const EdgeInsets.symmetric(horizontal: 2),
        decoration: circular
            ? BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: palette.border, width: 1),
              )
            : null,
        child: Image.asset(
          asset,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}