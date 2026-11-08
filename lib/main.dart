import 'dart:async';
import 'dart:io' show Platform, exit;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';

import 'models/telemetry.dart';
import 'services/alert_service.dart';
import 'services/command_service.dart';
import 'services/flight_track.dart';
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

/// Modul LoRa E220 di Raspberry Pi: port serial dan pin kontrol (nomor BCM).
const String kSerialPort = '/dev/serial0';
const int kSerialBaud = 9600;
const int kPinM0 = 22;
const int kPinM1 = 27;
const int kPinAux = 17;
const int kGpioChip = 0; // Pi 5 memakai chip lain, cek dengan gpiodetect

/// Command link dinonaktifkan (versi TCP tidak bisa jalan lewat serial).
const String kCommandHost = '127.0.0.1';
const int kCommandPort = 9998;

const String kTeamId = '1064';

/// Lebar panel Command di Dashboard: fraksi lebar baris, dengan batas
/// bawah dan atas (piksel). Naikkan fraksi kalau peta terasa terlalu besar.
const double kCommandPanelFrac = 0.32;
const double kCommandPanelMin = 320;
const double kCommandPanelMax = 560;

const String kLogoAsset = 'assets/icons/eepisat.png';

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

  // ---- TelemetryService (serial LoRa E220) ----
  late final TelemetryService service = TelemetryService(
    portPath: kSerialPort,
    baud: kSerialBaud,
    m0Line: kPinM0,
    m1Line: kPinM1,
    auxLine: kPinAux,
    gpioChip: kGpioChip,
    teamId: kTeamId,
  );

  final SystemMonitor sysmon = SystemMonitor();
  final TelemetryLogger logger = TelemetryLogger();
  final AlertService alerts = AlertService();
  Timer? _alertTimer;
  int _lastTotal = -1;
  DateTime? _lastPacketAt;

  // Lintasan penuh satu penerbangan, waktu fase, dan apogee.
  final FlightTrack track = FlightTrack();

  late final CommandService cmd = CommandService(
      host: kCommandHost, port: kCommandPort, teamId: kTeamId);

  bool _isFullscreen = false;

  /// true setelah command link dijalankan. Selama false, alert
  /// COMMAND LINK DOWN tidak dimunculkan.
  bool _cmdStarted = false;
  int _tab = 0;
  final List<String> _rxLog = [];

  @override
  void initState() {
    super.initState();
    service.onLog = _onLoraLog;
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
    debugPrint('[GCS] LoRa $kSerialPort @ $kSerialBaud');
    _rxLog.add('[GCS] Membuka modul LoRa di $kSerialPort ...');

    await Future.delayed(const Duration(milliseconds: 300));
    service.connect();
    // Command link nonaktif (TCP tidak bisa lewat serial).
    // cmd.start();
    // _cmdStarted = true;
  }

  void _onLoraLog(String m) {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _rxLog.add('${two(n.hour)}:${two(n.minute)}:${two(n.second)}  $m');
    if (_rxLog.length > 200) _rxLog.removeAt(0);
  }

  void _onServiceUpdate() {
    // Logger TIDAK auto-save. User klik tombol "Save CSV" untuk menyimpan.

    if (service.totalReceived > 0 && service.totalReceived != _lastTotal) {
      _lastTotal = service.totalReceived;
      _lastPacketAt = DateTime.now();
      final t = service.latest;
      if (t != null) track.add(t);
    }
    _runAlerts();
    if (mounted) setState(() {});
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
      moduleUp: service.status != ConnectionStatus.disconnected,
      commandLinkUp: !_cmdStarted || cmd.connected,
      now: DateTime.now(),
      telemetryTarget: kSerialPort,
      telemetryStatus: service.statusMessage,
      invalidFields: service.invalidFields,
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
                // Flight state dibuat tetap (tidak ikut scroll) dan tampil
                // di semua halaman.
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                  child: FlightProgressBar(
                    palette: palette,
                    data: service.latest,
                    signalLost: _signalLost,
                    phaseTimes: track.phaseTimes,
                    maxAltitude: track.maxAlt,
                  ),
                ),
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
                  'Team $kTeamId  ·  $kSerialPort @ $kSerialBaud',
                  style: TextStyle(color: palette.textDim, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(width: 20),
            _navTabs(iconOnly: tight),
            const Spacer(),
            AlertStatusPill(
              palette: palette,
              service: alerts,
              iconOnly: tight,
            ),
            const SizedBox(width: 12),
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
    final history = service.history;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Peta di kiri, Command ringkas di kanan. Detail command
          // (servo manual, preset, config, log) dibuka sebagai pop-up.
          SizedBox(
            height: 440,
            child: LayoutBuilder(builder: (context, c) {
              // Lebar panel Command mengikuti layar, dibatasi supaya
              // tidak terlalu sempit di RPi dan tidak terlalu lebar di
              // monitor besar.
              final cmdW = (c.maxWidth * kCommandPanelFrac)
                  .clamp(kCommandPanelMin, kCommandPanelMax)
                  .toDouble();
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Map3DView(
                      key: const ValueKey('map3d-dash'),
                      palette: palette,
                      data: service.latest,
                      track: track,
                      compact: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: cmdW,
                    child: CommandPanel(
                      palette: palette,
                      service: cmd,
                      compact: true,
                    ),
                  ),
                ],
              );
            }),
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

    // Nilai NaN (sensor yang belum dikirim transmitter) dilewati.
    List<FlSpot> spots(double Function(Telemetry) sel) => [
          for (var i = 0; i < h.length; i++)
            if (sel(h[i]).isFinite) FlSpot((offset + i).toDouble(), sel(h[i])),
        ];

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
                    track: track,
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
                _section('LoRa LOG'),
                Expanded(flex: 2, child: _buildRxLog()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRxLog() {
    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.hardEdge,
      child: _rxLog.isEmpty
          ? Center(
              child: Text(
                'Menunggu data LoRa...',
                style: TextStyle(color: palette.textDim, fontSize: 11),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: _rxLog.length,
              itemBuilder: (_, i) {
                final line = _rxLog[_rxLog.length - 1 - i]; // terbaru di atas
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
    // Nilai NaN (belum dikirim transmitter) ditampilkan sebagai strip.
    final valid = value != null && value.isFinite;
    final v = valid ? value : 0.0;
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
              !valid
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
              '${service.statusMessage}  ·  $kSerialPort',
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