import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, ServerSocket, Socket;
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
import 'widgets/gps_panel.dart';
import 'widgets/live_chart.dart';
import 'widgets/map_view.dart';
import 'widgets/model_3d_glb.dart';
import 'widgets/model_3d_native.dart';
import 'widgets/telemetry_log_table.dart';

// =========================================================
// KONFIGURASI SIMULATOR (embedded)
// =========================================================
const int kCommandPort = 9998;
// Nama command launch yang dikirim CommandPanel (sesuaikan kalau beda)
const String kLaunchCmd = 'LAUNCH';
// Simulasi packet loss (0.0 = tidak ada, 0.15 = 15% paket dibuang) untuk uji tampilan NA
const double kSimPacketLossRate = 0.0;
// Logo header (ganti path ini kalau lokasi file berbeda)
const String kLogoAsset = 'assets/icons/assets1.jpeg';
const String kSimTeamId = '1064';
const double kSimBaseLat = -7.275764;
const double kSimBaseLon = 112.794317;
const String kSimCsvHeader =
    'TEAM_ID,MISSION_TIME,PACKET_COUNT,ALTITUDE,PRESSURE,TEMPERATURE,'
    'VOLTAGE,ROLL,PITCH,YAW,GPS_LAT,GPS_LON,GPS_ALT,STATE\r\n';

// =========================================================
// DETEKSI PLATFORM
// =========================================================
bool get _isDesktopPlatform {
  if (kIsWeb) return false;
  if (Platform.isWindows || Platform.isMacOS) return true;
  if (Platform.isLinux) {
    return Platform.environment.containsKey('DISPLAY') ||
        Platform.environment.containsKey('WAYLAND_DISPLAY');
  }
  return false;
}

// flutter_inappwebview tidak punya implementasi Linux (termasuk flutter-pi),
// jadi InAppWebView melempar "Null check operator used on a null value".
bool get _webViewSupported {
  if (kIsWeb) return true;
  return Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;
}

// =========================================================
// FLIGHT PROFILE (Dart port dari cansat_simulator.py)
// =========================================================
class FlightProfile {
  final math.Random _rng = math.Random();
  late DateTime _start;
  int packetCount = 0;

  /// Payload TIDAK akan naik (ascend) sebelum launch() dipanggil.
  bool launched = false;
  DateTime? _launchAt;

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
  }

  /// true selama fase ASCENT..DESCENT (belum mendarat)
  bool get inFlight =>
      launched &&
      _launchAt != null &&
      10.0 + DateTime.now().difference(_launchAt!).inMilliseconds / 1000.0 <=
          90.0;

  String step() {
    packetCount++;
    final elapsed = DateTime.now().difference(_start).inMilliseconds / 1000.0;
    // Belum launch -> tetap di LAUNCH_PAD (cycleTime 0).
    // Sudah launch -> mulai dari awal fase ASCENT (10 dtk), lalu berjalan
    // sampai LANDED dan berhenti di sana (tidak looping otomatis).
    final cycleTime = (!launched || _launchAt == null)
        ? 0.0
        : 10.0 + DateTime.now().difference(_launchAt!).inMilliseconds / 1000.0;

    String state;
    double alt, roll, pitch, yaw;

    if (cycleTime <= 10.0) {
      state = 'LAUNCH_PAD';
      alt = _u(0.0, 0.4);
      roll = _u(-0.5, 0.5);
      pitch = _u(-0.5, 0.5);
      yaw = 0.0;
    } else if (cycleTime <= 40.0) {
      state = 'ASCENT';
      final progress = (cycleTime - 10.0) / 30.0;
      alt = 700.0 * math.sin(progress * (math.pi / 2.0)) + _u(-1.5, 1.5);
      roll = _u(-15.0, 15.0);
      pitch = _u(5.0, 20.0);
      yaw = (cycleTime * 12.0) % 360.0;
    } else if (cycleTime <= 50.0) {
      state = 'APOGEE';
      alt = 700.0 + _u(-1.0, 1.0);
      roll = _u(-25.0, 25.0);
      pitch = _u(-10.0, 10.0);
      yaw = (cycleTime * 8.0) % 360.0;
    } else if (cycleTime <= 90.0) {
      state = 'DESCENT';
      final progress = (cycleTime - 50.0) / 40.0;
      alt = math.max(0.5, 700.0 * (1.0 - progress) + _u(-1.0, 1.0));
      roll = _u(-8.0, 8.0);
      pitch = _u(-5.0, 5.0);
      yaw = (cycleTime * 4.0) % 360.0;
    } else {
      state = 'LANDED';
      alt = 0.0;
      roll = _u(-1.0, 1.0);
      pitch = _u(-1.0, 1.0);
      yaw = 180.0;
    }

    double pressure =
        1013.25 * math.pow(1.0 - (math.max(0.0, alt) / 44330.0), 5.255);
    pressure = _r(pressure + _u(-0.2, 0.2), 1);
    final temp = _r(28.5 - (alt * 0.0065) + _u(-0.3, 0.3), 1);
    final volt =
        _r(4.20 - (math.min(elapsed, 110.0) * 0.002) + _u(-0.02, 0.02), 2);

    // GPS bergerak dalam pola melingkar — terlihat di map
    final driftFactor = math.min(cycleTime / 90.0, 1.0) * 0.02;
    final angle = elapsed * 0.35;
    final gpsLat = _r(
        kSimBaseLat + driftFactor * math.sin(angle) + _u(-0.00005, 0.00005), 6);
    final gpsLon = _r(
        kSimBaseLon + driftFactor * math.cos(angle) + _u(-0.00005, 0.00005), 6);
    final gpsAlt = _r(math.max(0.0, alt) + _u(-2.0, 2.0), 1);

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
  double _r(double v, int d) {
    final m = math.pow(10, d);
    return (v * m).round() / m;
  }
}

// =========================================================
// EMBEDDED TCP SIMULATOR
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

  /// Interlock: dipasang GCS -> true jika Pre-Flight Check sudah lolos.
  bool Function()? canLaunch;

  /// Dipanggil setelah launch berhasil (GCS memakainya untuk reset preflight).
  void Function()? onLaunched;

  /// Coba launch. Ditolak jika preflight belum lolos atau sedang terbang.
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

    // Server perintah (menerima CMD dari GCS, membalas ACK)
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
        // CMD,<team>,<id>,<NAMA>
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
    // Langsung launch begitu GCS terhubung (tanpa Pre-Flight)
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
      await Future.delayed(const Duration(seconds: 1));
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

  // Tampilkan error ASLI. Tanpa ini Flutter mem-throttle log menjadi
  // "Another exception was thrown: Instance of 'DiagnosticsProperty<void>'".
  FlutterError.onError = (details) {
    debugPrint('[FLUTTER-ERR] ${details.exceptionAsString()}');
    final st = details.stack;
    if (st != null) {
      debugPrint(st.toString().split('\n').take(10).join('\n'));
    }
  };

  if (_isDesktopPlatform) {
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

  // Maximize SETELAH frame pertama tergambar (hindari jendela putih di Windows)
  if (_isDesktopPlatform) {
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
  final TelemetryService service = TelemetryService();
  final EmbeddedSimulator simulator = EmbeddedSimulator();
  final SystemMonitor sysmon = SystemMonitor();
  final TelemetryLogger logger = TelemetryLogger();
  final AlertService alerts = AlertService();
  Timer? _alertTimer;
  int _lastTotal = -1;
  DateTime? _lastPacketAt;
  late final CommandService cmd = CommandService(
      host: service.host, port: kCommandPort, teamId: kSimTeamId);
  bool _isFullscreen = false;
  final List<String> _simLog = [];

  @override
  void initState() {
    super.initState();
    service.addListener(_onServiceUpdate);
    sysmon.start();
    // Evaluasi alert tiap 1 detik (supaya 'telemetry delay' terus naik
    // walaupun tidak ada paket masuk).
    _alertTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _runAlerts();
      setState(() {});
    });
    _boot();
  }

  Future<void> _boot() async {
    // Pre-Flight Check dinonaktifkan sementara -> LAUNCH langsung diizinkan.
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
  }

  void _onServiceUpdate() {
    final t = service.latest;
    if (t != null) logger.log(t); // simpan setiap paket ke CSV

    // catat waktu paket terakhir diterima (untuk alert TELEMETRY DELAY)
    if (service.totalReceived > 0 && service.totalReceived != _lastTotal) {
      _lastTotal = service.totalReceived;
      _lastPacketAt = DateTime.now();
    }
    _runAlerts();
    if (mounted) setState(() {});
  }

  /// true bila antena tidak menerima data (link putus / >3 dtk tanpa paket).
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

  @override
  void dispose() {
    _alertTimer?.cancel();
    service.removeListener(_onServiceUpdate);
    service.dispose();
    simulator.stop();
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
    if (_isDesktopPlatform) {
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
            // Watermark Indonesia
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
            // Konten utama
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
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          // Logo CanSat
          Container(
            width: 46,
            height: 46,
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
                  size: 28,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),

          // Title + Subtitle + PENS kecil
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Ambaload Ground Control Station',
                style: TextStyle(
                  color: palette.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text(
                    'Team 1064  ·  Target ${service.host}:${service.port}',
                    style: TextStyle(color: palette.textDim, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
          const Spacer(),

          // Connection Indicator
          ConnectionIndicator(palette: palette, status: service.status),
          const SizedBox(width: 16),
          Container(width: 1, height: 32, color: palette.border),
          const SizedBox(width: 16),

          // EEPISAT
          _brandLogo(
            asset: 'assets/icons/eepisat.png',
            tooltip: 'EEPISAT',
            height: 32,
          ),
          const SizedBox(width: 12),

          // Indonesia
          _brandLogo(
            asset: 'assets/icons/indonesia.png',
            tooltip: 'Indonesia',
            height: 26,
            circular: true,
          ),
          const SizedBox(width: 16),
          Container(width: 1, height: 32, color: palette.border),
          const SizedBox(width: 16),

          // Tombol
          _headerButton(
            icon: palette.name == 'dark' ? Icons.light_mode : Icons.dark_mode,
            label: palette.name == 'dark' ? 'Light' : 'Dark',
            onTap: _toggleTheme,
          ),
          const SizedBox(width: 8),
          _headerButton(
            icon: _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            label: _isFullscreen ? 'Exit' : 'Fullscreen',
            onTap: _toggleFullscreen,
          ),
          const SizedBox(width: 8),
          _headerButton(
            icon: Icons.refresh,
            label: 'Reconnect',
            onTap: () => service.reconnect(),
          ),
        ],
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
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: palette.panelAlt,
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: palette.text, size: 16),
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
        ),
      ),
    );
  }

  // =========================================================
  // TABS
  // =========================================================
  Widget _buildTabView() {
    return DefaultTabController(
      length: 4,
      child: Container(
        margin: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: palette.panelAlt,
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorSize: TabBarIndicatorSize.label,
              tabs: const [
                Tab(
                  icon: Icon(Icons.dashboard_outlined, size: 16),
                  text: 'Dashboard',
                  iconMargin: EdgeInsets.only(bottom: 2),
                ),
                Tab(
                  icon: Icon(Icons.map_outlined, size: 16),
                  text: 'Maps',
                  iconMargin: EdgeInsets.only(bottom: 2),
                ),
                Tab(
                  icon: Icon(Icons.view_in_ar_outlined, size: 16),
                  text: '3D Model',
                  iconMargin: EdgeInsets.only(bottom: 2),
                ),
                Tab(
                  icon: Icon(Icons.battery_charging_full, size: 16),
                  text: 'Battery',
                  iconMargin: EdgeInsets.only(bottom: 2),
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildDashboardTab(),
                  _buildMapCameraTab(),
                  _build3DTab(),
                  BatteryPanel(
                    palette: palette,
                    latest: service.latest,
                    history: service.history,
                    signalLost: _signalLost,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =========================================================
  // TAB 1: DASHBOARD
  //   Baris 1: Flight State | Command Center | Maps | 3D Model
  //   Baris 2: Live charts (4 grafik sejajar)
  //   Baris 3: Telemetry table selebar layar
  //   Baris 4: Status simpan CSV
  // =========================================================
  Widget _buildDashboardTab() {
    final t = service.latest;
    final history = service.history;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Baris 1: 4 kotak sejajar
          SizedBox(
            height: 320,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _buildHeroStatus(t)),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: CommandPanel(
                    palette: palette,
                    service: cmd,
                    compact: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child: MapView(
                    palette: palette,
                    data: service.latest,
                    history: service.history,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child: _webViewSupported
                      ? Model3DGlbView(
                          key: const ValueKey('payload3d-dash'),
                          palette: palette,
                          data: service.latest,
                          assetPath: 'assets/models/payload.glb',
                        )
                      : Model3DNativeView(
                          key: const ValueKey('payload3d-dash-native'),
                          palette: palette,
                          data: service.latest,
                          assetPath: 'assets/models/payload.glb',
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Baris 2: Live charts
          SizedBox(
            height: 230,
            child: _liveCharts(),
          ),
          const SizedBox(height: 12),

          // Baris 3: Telemetry table
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

          // Baris 4: status penyimpanan CSV
          _buildLogBar(),
        ],
      ),
    );
  }

  /// 4 grafik live sejajar untuk Dashboard.
  Widget _liveCharts() {
    final h = service.history;
    // Nomor sampel absolut (terus naik) -> label sumbu X ikut bergeser
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

  Widget _buildHeroStatus(Telemetry? t) {
    final lost = _signalLost;
    Color stateColor;
    switch (lost ? '' : (t?.state ?? '')) {
      case 'LAUNCH_PAD':
        stateColor = palette.textDim;
        break;
      case 'ASCENT':
        stateColor = palette.ok;
        break;
      case 'APOGEE':
        stateColor = palette.warn;
        break;
      case 'DESCENT':
        stateColor = palette.accent;
        break;
      case 'LANDED':
        stateColor = palette.accent2;
        break;
      default:
        stateColor = palette.textDim;
    }

    Widget stat(String label, String value, {String? unit}) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: palette.textDim,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    value,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (unit != null) ...[
                    const SizedBox(width: 3),
                    Text(
                      unit,
                      style: TextStyle(
                        color: palette.textDim,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Indikator fase penerbangan: PAD -> ASCENT -> APOGEE -> DESCENT -> LANDED
    Widget phaseBar() {
      const phases = ['LAUNCH_PAD', 'ASCENT', 'APOGEE', 'DESCENT', 'LANDED'];
      const names = ['PAD', 'ASCENT', 'APOGEE', 'DESCENT', 'LANDED'];
      final cur = lost ? -1 : phases.indexOf(t?.state ?? '');
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (var i = 0; i < phases.length; i++)
                Expanded(
                  child: Container(
                    height: 5,
                    margin:
                        EdgeInsets.only(right: i < phases.length - 1 ? 4 : 0),
                    decoration: BoxDecoration(
                      color:
                          i <= cur ? stateColor : stateColor.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var i = 0; i < phases.length; i++)
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      names[i],
                      maxLines: 1,
                      style: TextStyle(
                        color: i == cur ? stateColor : palette.textDim,
                        fontSize: 8,
                        fontWeight:
                            i == cur ? FontWeight.w800 : FontWeight.w600,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            stateColor.withOpacity(0.18),
            stateColor.withOpacity(0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: stateColor.withOpacity(0.4), width: 1.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Ikon + flight state
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: stateColor.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(_stateIcon(lost ? null : t?.state),
                    color: stateColor, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'FLIGHT STATE',
                      style: TextStyle(
                        color: palette.textDim,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        lost ? 'NA' : (t?.state ?? 'WAITING'),
                        style: TextStyle(
                          color: stateColor,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          phaseBar(),
          Divider(height: 1, color: stateColor.withOpacity(0.25)),
          // Statistik
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              stat(
                  'ALTITUDE',
                  lost
                      ? 'NA'
                      : (t == null ? '—' : t.altitude.toStringAsFixed(1)),
                  unit: lost ? null : 'm'),
              const SizedBox(width: 6),
              stat(
                  'MISSION TIME', lost ? 'NA' : (t?.missionTime ?? '--:--:--')),
              const SizedBox(width: 6),
              stat(
                  'PACKET',
                  lost
                      ? 'NA'
                      : (t == null
                          ? '—'
                          : '#${t.packetCount.toString().padLeft(4, '0')}')),
            ],
          ),
        ],
      ),
    );
  }

  IconData _stateIcon(String? state) {
    switch (state) {
      case 'LAUNCH_PAD':
        return Icons.rocket_launch_outlined;
      case 'ASCENT':
        return Icons.arrow_upward;
      case 'APOGEE':
        return Icons.vertical_align_top;
      case 'DESCENT':
        return Icons.paragliding;
      case 'LANDED':
        return Icons.flag;
      default:
        return Icons.hourglass_empty;
    }
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
  // TAB 4: MAPS
  // =========================================================
  Widget _buildMapCameraTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section('PAYLOAD LOCATION'),
                Expanded(
                  child: MapView(
                    palette: palette,
                    data: service.latest,
                    history: service.history,
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
                  child: GpsPanel(palette: palette, data: service.latest),
                ),
                const SizedBox(height: 12),
                _section('SIMULATOR LOG'),
                Expanded(child: _buildSimLog()),
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
      child: ListView.builder(
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

  // =========================================================
  // TAB 5: 3D MODEL (dari payload.glb)
  // =========================================================
  Widget _build3DTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section('PAYLOAD 3D MODEL'),
                Expanded(
                  child: _webViewSupported
                      ? Model3DGlbView(
                          // key tetap supaya WebView tidak dibuat ulang
                          key: const ValueKey('payload3d'),
                          palette: palette,
                          data: service.latest,
                          assetPath: 'assets/models/payload.glb',
                        )
                      : Model3DNativeView(
                          key: const ValueKey('payload3d-native'),
                          palette: palette,
                          data: service.latest,
                          assetPath: 'assets/models/payload.glb',
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
                _section('ATTITUDE DATA'),
                Expanded(child: _buildAttitudeNumericPanel()),
              ],
            ),
          ),
        ],
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

  Widget _buildLogBar() {
    final failed = logger.error != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.save_alt,
            size: 16,
            color: failed ? palette.bad : palette.ok,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              failed
                  ? 'Gagal menyimpan CSV: ${logger.error}'
                  : 'Semua data tersimpan otomatis (${logger.rows} baris)  ·  ${logger.path}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.textDim, fontSize: 11),
            ),
          ),
          const SizedBox(width: 10),
          _headerButton(
            icon: Icons.folder_open,
            label: 'Open folder',
            onTap: logger.openFolder,
          ),
        ],
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
              '${service.statusMessage}  ·  Simulator port ${simulator.port}',
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

  // =========================================================
  // INFO SISTEM (CPU / RAM / dll) di footer
  // =========================================================
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
