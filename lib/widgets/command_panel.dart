import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/command_service.dart';
import '../theme/app_theme.dart';

// =========================================================
// KONFIGURASI AKTUATOR
// =========================================================

/// Satu aktuator dua keadaan (lock / unlock) yang tampil sebagai toggle.
class ActuatorDef {
  const ActuatorDef({
    required this.target,
    required this.title,
    required this.channel,
    required this.icon,
    required this.defaultLock,
    required this.defaultUnlock,
  });

  /// Nama target di perintah CONFIG (CONTAINER / WING).
  final String target;
  final String title;
  final int channel;
  final IconData icon;

  /// Sudut awal sebelum diubah lewat Lock Angle Config. SESUAIKAN dengan
  /// mekanik payload. Setelah diubah, sudut disimpan ke disk.
  final int defaultLock;
  final int defaultUnlock;
}

const List<ActuatorDef> kActuators = [
  ActuatorDef(
    target: 'CONTAINER',
    title: 'Container',
    channel: 2,
    icon: Icons.inventory_2_outlined,
    defaultLock: 100,
    defaultUnlock: 0,
  ),
  ActuatorDef(
    target: 'WING',
    title: 'Wing',
    channel: 5,
    icon: Icons.flight_outlined,
    defaultLock: 100,
    defaultUnlock: 0,
  ),
];

/// Lama tombol UNLOCK harus ditahan sebelum perintah dikirim.
const Duration kUnlockHold = Duration(milliseconds: 1000);

/// Perintah yang dikirim saat toggle ditekan. Kalau firmware punya
/// perintah khusus (mis. LOCK CONTAINER), ubah cukup di fungsi ini.
String actuatorCommand(ActuatorDef a, bool lock, int angle) =>
    'SERVO ${a.channel} $angle';

// =========================================================
// MODEL & PENYIMPANAN BERSAMA (panel samping + pop-up)
// =========================================================
class _Def {
  final String name;
  final String label;
  final IconData icon;
  const _Def(this.name, this.label, this.icon);
}

const List<_Def> _kCritical = [
  _Def('SEPARATE_1', 'Separate Stage 1', Icons.call_split),
  _Def('SEPARATE_2', 'Separate Stage 2', Icons.call_split),
  _Def('PAYLOAD_RELEASE', 'Release Payload', Icons.unarchive_outlined),
];

class _Preset {
  final int channel;
  final int angle;
  const _Preset(this.channel, this.angle);
  String get label => 'S$channel: $angle°';
}

/// Perintah yang sedang ditunggu ACK-nya.
class _Track {
  _Track(this.entry, this.target, {this.lock, this.cfgState, this.angle});
  final CmdLogEntry entry;
  final String target;

  /// Untuk perintah gerak: true = lock, false = unlock, null = sudut lain.
  final bool? lock;

  /// Untuk perintah CONFIG: 'LOCK' / 'UNLOCK'.
  final String? cfgState;
  final int? angle;

  bool get isConfig => cfgState != null;
}

/// Data yang dipakai bersama oleh panel samping dan pop-up Advanced.
/// Statis supaya tidak hilang saat pindah halaman atau menutup pop-up.
class _Store {
  _Store._();

  static final List<_Preset> presets = [];
  static final Map<String, Map<String, int>> angles = {
    for (final a in kActuators)
      a.target: {'LOCK': a.defaultLock, 'UNLOCK': a.defaultUnlock},
  };
  static bool _anglesLoaded = false;

  /// Status terakhir yang dikonfirmasi ACK. null = belum diketahui.
  static final Map<String, bool?> confirmed = {};
  static final Map<String, String?> error = {};
  static final Map<int, _Track> tracks = {};

  static File? _file() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) return null;
    return File('$home/.eepisat_gcs/servo_angles.json');
  }

  static Future<void> loadAngles() async {
    if (_anglesLoaded) return;
    _anglesLoaded = true;
    try {
      final f = _file();
      if (f == null || !await f.exists()) return;
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      for (final e in data.entries) {
        final m = angles[e.key];
        if (m == null || e.value is! Map) continue;
        for (final s in (e.value as Map).entries) {
          final v = s.value;
          if (v is int && v >= 0 && v <= 180) m['${s.key}'] = v;
        }
      }
    } catch (_) {}
  }

  static void _saveAngles() {
    try {
      final f = _file();
      if (f == null) return;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(angles));
    } catch (_) {}
  }

  static String stateLabel(CmdState s) => switch (s) {
        CmdState.sent => 'SENT',
        CmdState.ack => 'ACK',
        CmdState.nack => 'NACK',
        CmdState.timeout => 'TIMEOUT',
        CmdState.failed => 'FAILED',
        CmdState.rejected => 'REJECTED',
      };

  /// ACK mengubah status toggle atau menyimpan sudut config.
  /// NACK / TIMEOUT / FAILED memunculkan pesan di kartu.
  static void process() {
    for (final id in tracks.keys.toList()) {
      final t = tracks[id]!;
      final st = t.entry.state;
      if (st == CmdState.sent) continue;
      tracks.remove(id);
      if (st == CmdState.ack) {
        if (t.isConfig) {
          angles[t.target]?[t.cfgState!] = t.angle!;
          _saveAngles();
        } else {
          confirmed[t.target] = t.lock;
          error[t.target] = null;
        }
      } else {
        final what = t.isConfig ? 'Config' : 'Perintah';
        error[t.target] = '$what ${stateLabel(st)}: ${t.entry.detail}'.trim();
      }
    }
  }

  static _Track? pendingMove(String target) {
    for (final t in tracks.values) {
      if (t.target == target && !t.isConfig) return t;
    }
    return null;
  }

  static ActuatorDef? byChannel(int ch) {
    for (final a in kActuators) {
      if (a.channel == ch) return a;
    }
    return null;
  }

  static ActuatorDef? byTarget(String target) {
    for (final a in kActuators) {
      if (a.target == target) return a;
    }
    return null;
  }

  static void setLock(CommandService svc, ActuatorDef a, bool lock) {
    if (!svc.connected) return;
    final ang = angles[a.target]![lock ? 'LOCK' : 'UNLOCK']!;
    error[a.target] = null;
    final e = svc.send(actuatorCommand(a, lock, ang));
    if (e != null) tracks[e.id] = _Track(e, a.target, lock: lock);
    process();
  }

  /// SERVO manual. Kalau kanalnya milik aktuator, toggle ikut diperbarui.
  static void sendServo(CommandService svc, int channel, int angle) {
    if (!svc.connected) return;
    final e = svc.send('SERVO $channel $angle');
    final a = byChannel(channel);
    if (e != null && a != null) {
      final m = angles[a.target]!;
      final lock = angle == m['LOCK']
          ? true
          : (angle == m['UNLOCK'] ? false : null);
      tracks[e.id] = _Track(e, a.target, lock: lock);
    }
    process();
  }

  static void sendConfig(
      CommandService svc, String target, String state, int angle) {
    if (!svc.connected) return;
    final e = svc.send('CONFIG $target $state $angle');
    if (e != null && byTarget(target) != null) {
      tracks[e.id] = _Track(e, target, cfgState: state, angle: angle);
    }
    process();
  }
}

/// Konfirmasi lalu kirim perintah kritis (ARM otomatis satu kali).
Future<void> _sendCriticalCmd(
    BuildContext context, CommandService svc, _Def d) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Konfirmasi: ${d.label}'),
      content: const Text(
        'Perintah ini bersifat fisik dan tidak bisa dibatalkan.\n'
        'Pastikan kondisi sudah aman. Kirim sekarang?',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Batal')),
        FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Kirim')),
      ],
    ),
  );
  if (ok == true) {
    if (!svc.armed) svc.arm();
    svc.send(d.name);
  }
}

/// Membuka pop-up Advanced: servo manual, preset, config, uplink, log.
/// [initialTab]: 0 Servo, 1 Presets, 2 Manual, 3 Log.
Future<void> showCommandAdvanced(
  BuildContext context, {
  required AppPalette palette,
  required CommandService service,
  int initialTab = 0,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AdvancedDialog(
      palette: palette,
      service: service,
      initialTab: initialTab,
    ),
  );
}

// =========================================================
// PANEL SAMPING (ringkas)
// =========================================================
class CommandPanel extends StatefulWidget {
  final AppPalette palette;
  final CommandService service;
  final bool compact;

  const CommandPanel({
    super.key,
    required this.palette,
    required this.service,
    this.compact = false,
  });

  @override
  State<CommandPanel> createState() => _CommandPanelState();
}

class _CommandPanelState extends State<CommandPanel> {
  String? _hint;
  Timer? _hintTimer;

  AppPalette get p => widget.palette;
  CommandService get svc => widget.service;

  @override
  void initState() {
    super.initState();
    svc.addListener(_onSvc);
    _Store.process();
    _Store.loadAngles().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant CommandPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_onSvc);
      widget.service.addListener(_onSvc);
    }
  }

  @override
  void dispose() {
    svc.removeListener(_onSvc);
    _hintTimer?.cancel();
    super.dispose();
  }

  void _onSvc() {
    _Store.process();
    if (mounted) setState(() {});
  }

  void _showHint(String msg) {
    _hintTimer?.cancel();
    setState(() => _hint = msg);
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  void _openAdvanced(int tab) => showCommandAdvanced(
        context,
        palette: p,
        service: svc,
        initialTab: tab,
      ).then((_) {
        if (mounted) setState(() {});
      });

  @override
  Widget build(BuildContext context) {
    final conn = svc.connected;
    return LayoutBuilder(builder: (context, c) {
      // Panel lebar: toggle dan teks lebih besar, tombol misi
      // lebih tinggi supaya mudah ditekan di layar sentuh.
      final wide = c.maxWidth >= 380;
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
          _header(conn),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _label('ACTUATORS'),
                  for (final a in kActuators) _actuatorRow(a, conn, wide),
                  const SizedBox(height: 8),
                  _label('MISSION'),
                  for (final d in _kCritical)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _btn(
                        label: d.label,
                        icon: d.icon,
                        color: p.bad,
                        enabled: conn,
                        dense: true,
                        height: wide ? 40 : 32,
                        onTap: () => _sendCriticalCmd(context, svc, d),
                      ),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    _hint ??
                        (conn
                            ? 'LOCK: tap · UNLOCK: tahan 1 detik'
                            : 'Command link offline'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _hint != null
                          ? p.warn
                          : (conn ? p.textDim : p.bad),
                      fontSize: 10,
                      fontWeight:
                          _hint != null ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    });
  }

  Widget _header(bool ok) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      child: Row(
        children: [
          Icon(Icons.settings_remote, size: 18, color: p.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Command',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: p.text, fontSize: 14, fontWeight: FontWeight.w800)),
          ),
          Tooltip(
            message: ok ? 'Command link terhubung' : 'Command link terputus',
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: ok ? p.ok : p.bad, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 8),
          _iconBtn(Icons.history, 'Log perintah', () => _openAdvanced(3),
              badge: svc.log.length),
          const SizedBox(width: 4),
          _iconBtn(Icons.tune, 'Advanced: servo manual, preset, config, uplink',
              () => _openAdvanced(0)),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap,
      {int? badge}) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: p.panelAlt,
            border: Border.all(color: p.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: p.text),
              if (badge != null && badge > 0) ...[
                const SizedBox(width: 3),
                Text('$badge',
                    style: TextStyle(
                        color: p.textDim,
                        fontSize: 10,
                        fontWeight: FontWeight.w800)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _actuatorRow(ActuatorDef a, bool conn, bool wide) {
    final confirmed = _Store.confirmed[a.target];
    final pend = _Store.pendingMove(a.target);
    final err = _Store.error[a.target];
    final ang = _Store.angles[a.target]!;

    final (String status, Color sc) = err != null
        ? (err, p.bad)
        : pend != null
            ? ('MENGIRIM...', p.accent)
            : confirmed == true
                ? ('LOCKED', p.ok)
                : confirmed == false
                    ? ('UNLOCKED', p.warn)
                    : ('BELUM DIKONFIRMASI', p.textDim);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: wide
          ? const EdgeInsets.fromLTRB(12, 10, 10, 10)
          : const EdgeInsets.fromLTRB(10, 7, 7, 7),
      decoration: BoxDecoration(
        color: p.panelAlt.withValues(alpha: 0.5),
        border: Border.all(color: err != null ? p.bad : p.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: '${err ?? status}\n'
                  'Lock ${ang['LOCK']}°  ·  Unlock ${ang['UNLOCK']}°',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(a.icon, size: 13, color: p.accent),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text('${a.title} · S${a.channel}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: p.text,
                                fontSize: wide ? 13 : 11.5,
                                fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ),
                  SizedBox(height: wide ? 4 : 2),
                  Text(status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: sc,
                          fontSize: wide ? 10.5 : 9.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: wide ? 190 : 128,
            child: _LockToggle(
              palette: p,
              locked: confirmed,
              pending: pend != null,
              pendingLock: pend?.lock,
              enabled: conn,
              dense: !wide,
              onLock: () => setState(() => _Store.setLock(svc, a, true)),
              onUnlock: () => setState(() => _Store.setLock(svc, a, false)),
              onHint: _showHint,
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: TextStyle(
                color: p.textDim,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
      );

  Widget _btn({
    required String label,
    required IconData icon,
    required Color color,
    required bool enabled,
    required VoidCallback onTap,
    bool dense = false,
    double? width,
    double? height,
  }) {
    final c = enabled ? color : p.textDim.withValues(alpha: 0.5);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width,
        height: height ?? (dense ? 34 : 42),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: c.withValues(alpha: enabled ? 0.12 : 0.05),
          border: Border.all(color: c.withValues(alpha: enabled ? 0.6 : 0.3)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize:
              (dense && width == null) ? MainAxisSize.min : MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: c, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================
// POP-UP ADVANCED
// =========================================================
class _AdvancedDialog extends StatefulWidget {
  const _AdvancedDialog({
    required this.palette,
    required this.service,
    required this.initialTab,
  });

  final AppPalette palette;
  final CommandService service;
  final int initialTab;

  @override
  State<_AdvancedDialog> createState() => _AdvancedDialogState();
}

class _AdvancedDialogState extends State<_AdvancedDialog> {
  late int _tab = widget.initialTab;

  int _channel = 2;
  final TextEditingController _angleCtrl = TextEditingController(text: '90');

  String _cfgTarget = 'CONTAINER';
  String _cfgState = 'LOCK';
  final TextEditingController _cfgAngleCtrl =
      TextEditingController(text: '100');

  final TextEditingController _manualCtrl = TextEditingController();

  AppPalette get p => widget.palette;
  CommandService get svc => widget.service;
  List<_Preset> get _presets => _Store.presets;
  List<_Def> get _critical => _kCritical;

  @override
  void initState() {
    super.initState();
    svc.addListener(_onSvc);
  }

  @override
  void dispose() {
    svc.removeListener(_onSvc);
    _angleCtrl.dispose();
    _cfgAngleCtrl.dispose();
    _manualCtrl.dispose();
    super.dispose();
  }

  void _onSvc() {
    _Store.process();
    if (mounted) setState(() {});
  }

  // ---------------- aksi ----------------
  int? _angleOf(TextEditingController c) {
    final v = int.tryParse(c.text.trim());
    if (v == null || v < 0 || v > 180) return null;
    return v;
  }

  Future<void> _sendCritical(_Def d) => _sendCriticalCmd(context, svc, d);

  void _sendServoTo(int channel, int angle) =>
      setState(() => _Store.sendServo(svc, channel, angle));

  void _sendServo() {
    final a = _angleOf(_angleCtrl);
    if (a == null || !svc.connected) return;
    _sendServoTo(_channel, a);
  }

  void _savePreset() {
    final a = _angleOf(_angleCtrl);
    if (a == null) return;
    final exists = _presets.any((e) => e.channel == _channel && e.angle == a);
    if (!exists) setState(() => _presets.add(_Preset(_channel, a)));
  }

  void _sendConfig() {
    final a = _angleOf(_cfgAngleCtrl);
    if (a == null || !svc.connected) return;
    setState(() => _Store.sendConfig(svc, _cfgTarget, _cfgState, a));
  }

  void _sendManual() {
    final v = _manualCtrl.text.trim();
    if (v.isEmpty || !svc.connected) return;
    final crit = _critical.where((d) => d.name == v.toUpperCase());
    if (crit.isNotEmpty) {
      _sendCritical(crit.first).then((_) {
        if (!mounted) return;
        _manualCtrl.clear();
        setState(() {});
      });
    } else {
      svc.send(v);
      _manualCtrl.clear();
      setState(() {});
    }
  }

  // ---------------- build ----------------
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: p.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: size.width < 760 ? size.width - 48 : 680,
        height: size.height < 640 ? size.height - 48 : 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 6, 6),
              child: Row(
                children: [
                  Icon(Icons.settings_remote, size: 18, color: p.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Command Center · Advanced',
                        style: TextStyle(
                            color: p.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w800)),
                  ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                        color: svc.connected ? p.ok : p.bad,
                        shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(svc.connected ? 'LINK OK' : 'Offline',
                      style: TextStyle(
                          color: svc.connected ? p.ok : p.bad,
                          fontSize: 10,
                          fontWeight: FontWeight.w700)),
                  IconButton(
                    tooltip: 'Tutup',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close, size: 20, color: p.text),
                  ),
                ],
              ),
            ),
            _tabBar(),
            Expanded(child: _content()),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    switch (_tab) {
      case 0:
        return _servoTab();
      case 1:
        return _presetsTab();
      case 2:
        return _manualTab();
      default:
        return _logTab();
    }
  }

  Widget _tabBar() {
    Widget tab(int i, IconData icon, String label, {int? badge}) {
      final sel = _tab == i;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _tab = i),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 32,
            decoration: BoxDecoration(
              color: sel ? p.panelAlt : Colors.transparent,
              border: Border.all(color: sel ? p.border : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: sel ? p.accent : p.textDim),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: sel ? p.text : p.textDim,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
                if (badge != null) ...[
                  const SizedBox(width: 5),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: p.border.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('$badge',
                        style: TextStyle(
                            color: p.textDim,
                            fontSize: 9,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Row(
        children: [
          tab(0, Icons.tune, 'Servo'),
          const SizedBox(width: 4),
          tab(1, Icons.layers_outlined, 'Presets'),
          const SizedBox(width: 4),
          tab(2, Icons.terminal, 'Manual'),
          const SizedBox(width: 4),
          tab(3, Icons.history, 'Log', badge: svc.log.length),
        ],
      ),
    );
  }

  // ---------------- TAB: SERVO ----------------
  Widget _servoTab() {
    final conn = svc.connected;
    final a = _angleOf(_angleCtrl);
    final cfgA = _angleOf(_cfgAngleCtrl);
    final servoCmd = 'SERVO $_channel ${a ?? '--'}';
    final cfgCmd = 'CONFIG $_cfgTarget $_cfgState ${cfgA ?? '--'}';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(
            icon: Icons.tune,
            title: 'Individual Servo Angle Control',
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: _labeled(
                      'Select Channel',
                      _dropdown<int>(
                        value: _channel,
                        items: {for (var i = 1; i <= 6; i++) i: 'Servo $i'},
                        onChanged:
                            conn ? (v) => setState(() => _channel = v) : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: _labeled(
                      'Target Angle (0–180°)',
                      _angleField(_angleCtrl, conn),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: _labeled(
                      'Saved Presets',
                      _presets.isEmpty
                          ? Text('Belum ada preset',
                              style: TextStyle(
                                  color: p.textDim.withValues(alpha: 0.7),
                                  fontSize: 11))
                          : Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final pr in _presets) _chip(pr),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _btn(
                    label: 'Save Preset',
                    icon: Icons.add,
                    color: p.accent,
                    enabled: a != null,
                    dense: true,
                    height: 30,
                    onTap: _savePreset,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _preview(servoCmd)),
                  const SizedBox(width: 8),
                  _btn(
                    label: 'Send Servo',
                    icon: Icons.send,
                    color: p.accent,
                    enabled: conn && a != null,
                    dense: true,
                    height: 32,
                    onTap: _sendServo,
                  ),
                ],
              ),
            ],
          ),
          _card(
            icon: Icons.lock_outline,
            title: 'Lock Angle Config (dipakai juga oleh toggle cepat)',
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: _labeled(
                      'Target',
                      _dropdown<String>(
                        value: _cfgTarget,
                        items: {
                          for (final a in kActuators)
                            a.target: '${a.title} (S${a.channel})',
                        },
                        onChanged:
                            conn ? (v) => setState(() => _cfgTarget = v) : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: _labeled(
                      'State',
                      _dropdown<String>(
                        value: _cfgState,
                        items: const {'LOCK': 'Lock', 'UNLOCK': 'Unlock'},
                        onChanged:
                            conn ? (v) => setState(() => _cfgState = v) : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: _labeled(
                      'Angle (0–180°)',
                      _angleField(_cfgAngleCtrl, conn),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _preview(cfgCmd)),
                  const SizedBox(width: 8),
                  _btn(
                    label: 'Send Config',
                    icon: Icons.send,
                    color: p.accent,
                    enabled: conn && cfgA != null,
                    dense: true,
                    height: 32,
                    onTap: _sendConfig,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- TAB: PRESETS ----------------
  Widget _presetsTab() {
    final conn = svc.connected;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('MISSION COMMANDS (KRITIS)'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final d in _critical)
                _btn(
                  label: d.label,
                  icon: d.icon,
                  color: p.bad,
                  enabled: conn,
                  dense: true,
                  height: 34,
                  onTap: () => _sendCritical(d),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _label('SAVED SERVO PRESETS'),
          if (_presets.isEmpty)
            Text('Belum ada preset. Simpan dari tab Servo.',
                style: TextStyle(color: p.textDim, fontSize: 11))
          else
            for (final pr in _presets) _presetRow(pr, conn),
        ],
      ),
    );
  }

  Widget _presetRow(_Preset pr, bool conn) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: BoxDecoration(
        color: p.panelAlt.withValues(alpha: 0.5),
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Text('Servo ${pr.channel}',
              style: TextStyle(
                  color: p.text, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Text('${pr.angle}°',
              style: TextStyle(
                  color: p.accent,
                  fontSize: 12,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          _btn(
            label: 'Send',
            icon: Icons.send,
            color: p.accent,
            enabled: conn,
            dense: true,
            height: 28,
            onTap: () => _sendServoTo(pr.channel, pr.angle),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => setState(() => _presets.remove(pr)),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.delete_outline, size: 18, color: p.textDim),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- TAB: MANUAL ----------------
  Widget _manualTab() {
    final conn = svc.connected;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('MANUAL UPLINK'),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _manualCtrl,
                    enabled: conn,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _sendManual(),
                    style: TextStyle(color: p.text, fontSize: 12),
                    decoration:
                        _inputDecoration(hint: 'Ketik perintah, mis. CAM_ON'),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _btn(
                label: 'Send',
                icon: Icons.send,
                color: p.accent,
                enabled: conn && _manualCtrl.text.trim().isNotEmpty,
                dense: true,
                height: 38,
                onTap: _sendManual,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Perintah kritis (SEPARATE_1, SEPARATE_2, PAYLOAD_RELEASE) '
            'akan meminta konfirmasi sebelum dikirim.',
            style: TextStyle(color: p.textDim, fontSize: 10),
          ),
        ],
      ),
    );
  }

  // ---------------- TAB: LOG ----------------
  Widget _logTab() {
    final items = svc.log;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.hardEdge,
        child: items.isEmpty
            ? Center(
                child: Text('Belum ada perintah',
                    style: TextStyle(color: p.textDim, fontSize: 11)))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                itemCount: items.length,
                itemBuilder: (_, i) => _logRow(items[i]),
              ),
      ),
    );
  }

  Widget _logRow(CmdLogEntry e) {
    String two(int n) => n.toString().padLeft(2, '0');
    final t = e.time;
    final (String label, Color color) = switch (e.state) {
      CmdState.sent => ('SENT', p.textDim),
      CmdState.ack => ('ACK', p.ok),
      CmdState.nack => ('NACK', p.bad),
      CmdState.timeout => ('TIMEOUT', p.warn),
      CmdState.failed => ('FAILED', p.bad),
      CmdState.rejected => ('REJECTED', p.bad),
    };
    return Tooltip(
      message: e.detail,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Text('${two(t.hour)}:${two(t.minute)}:${two(t.second)}',
                style: TextStyle(
                    color: p.textDim, fontSize: 10, fontFamily: 'monospace')),
            const SizedBox(width: 8),
            Expanded(
              child: Text(e.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: p.text,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ),
            Text(label,
                style: TextStyle(
                    color: color, fontSize: 10, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }

  Widget _card({
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.panelAlt.withValues(alpha: 0.5),
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: p.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: p.text,
                        fontSize: 11,
                        fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _labeled(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: p.textDim, fontSize: 10, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        child,
      ],
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: TextStyle(
                color: p.textDim,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
      );

  InputDecoration _inputDecoration(
      {String? hint, String? suffix, bool valid = true}) {
    final bc = valid ? p.border : p.bad;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: p.textDim, fontSize: 12),
      suffixText: suffix,
      suffixStyle: TextStyle(color: p.textDim, fontSize: 11),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: bc),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: bc),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: valid ? p.accent : p.bad),
      ),
    );
  }

  Widget _angleField(TextEditingController c, bool enabled) {
    final valid = c.text.trim().isEmpty || _angleOf(c) != null;
    return SizedBox(
      height: 36,
      child: TextField(
        controller: c,
        enabled: enabled,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(3),
        ],
        onChanged: (_) => setState(() {}),
        style: TextStyle(color: p.text, fontSize: 12),
        decoration: _inputDecoration(suffix: 'deg', valid: valid),
      ),
    );
  }

  Widget _dropdown<T>({
    required T value,
    required Map<T, String> items,
    required ValueChanged<T>? onChanged,
  }) {
    final c = onChanged == null ? p.textDim.withValues(alpha: 0.6) : p.text;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          dropdownColor: p.panel,
          icon: Icon(Icons.arrow_drop_down, color: p.textDim),
          onChanged: onChanged == null
              ? null
              : (v) {
                  if (v != null) onChanged(v);
                },
          items: [
            for (final e in items.entries)
              DropdownMenuItem<T>(
                value: e.key,
                child: Text(e.value,
                    style: TextStyle(
                        color: c, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(_Preset pr) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() {
              _channel = pr.channel;
              _angleCtrl.text = '${pr.angle}';
            }),
            child: Text(pr.label,
                style: TextStyle(
                    color: p.text,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => setState(() => _presets.remove(pr)),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close, size: 14, color: p.textDim),
            ),
          ),
        ],
      ),
    );
  }

  Widget _preview(String cmd) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
              text: 'Command: ',
              style: TextStyle(color: p.textDim, fontSize: 11)),
          TextSpan(
              text: cmd,
              style: TextStyle(
                  color: p.accent,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _btn({
    required String label,
    required IconData icon,
    required Color color,
    required bool enabled,
    required VoidCallback onTap,
    bool dense = false,
    double? width,
    double? height,
  }) {
    final c = enabled ? color : p.textDim.withValues(alpha: 0.5);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width,
        height: height ?? (dense ? 34 : 42),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: c.withValues(alpha: enabled ? 0.12 : 0.05),
          border: Border.all(color: c.withValues(alpha: enabled ? 0.6 : 0.3)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize:
              (dense && width == null) ? MainAxisSize.min : MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: c, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================
// TOGGLE LOCK / UNLOCK
// =========================================================
/// Dua sisi: LOCK (sekali tap) dan UNLOCK (tahan [kUnlockHold]).
/// Sisi yang menyala hanya mengikuti status yang sudah di-ACK payload.
class _LockToggle extends StatefulWidget {
  const _LockToggle({
    required this.palette,
    required this.locked,
    required this.pending,
    required this.pendingLock,
    required this.enabled,
    required this.onLock,
    required this.onUnlock,
    required this.onHint,
    this.dense = false,
  });

  final AppPalette palette;

  /// Versi ringkas untuk panel sempit: lebih pendek, tanpa ikon.
  final bool dense;

  /// true = LOCKED, false = UNLOCKED, null = belum diketahui.
  final bool? locked;
  final bool pending;
  final bool? pendingLock;
  final bool enabled;
  final VoidCallback onLock;
  final VoidCallback onUnlock;
  final ValueChanged<String> onHint;

  @override
  State<_LockToggle> createState() => _LockToggleState();
}

class _LockToggleState extends State<_LockToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold =
      AnimationController(vsync: this, duration: kUnlockHold)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) {
            _hold.value = 0;
            widget.onUnlock();
          }
        });

  bool get _canAct => widget.enabled && !widget.pending;

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _release() {
    if (_hold.isAnimating && _hold.value < 1) {
      _hold.reverse();
      widget.onHint('Tahan tombol UNLOCK selama 1 detik untuk mengirim.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Container(
      height: widget.dense ? 32 : 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Expanded(
            child: _half(
              label: 'LOCK',
              icon: Icons.lock,
              selected: widget.locked == true,
              color: p.ok,
              busy: widget.pending && widget.pendingLock != false,
              onTap:
                  _canAct && widget.locked != true ? widget.onLock : null,
            ),
          ),
          const SizedBox(width: 3),
          Expanded(
            child: GestureDetector(
              onTapDown: (_) {
                if (_canAct && widget.locked != false) {
                  _hold.forward(from: 0);
                }
              },
              onTapUp: (_) => _release(),
              onTapCancel: _release,
              child: AnimatedBuilder(
                animation: _hold,
                builder: (context, _) => _half(
                  label: 'UNLOCK',
                  icon: Icons.lock_open,
                  selected: widget.locked == false,
                  color: p.warn,
                  busy: widget.pending && widget.pendingLock == false,
                  progress: _hold.value,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _half({
    required String label,
    required IconData icon,
    required bool selected,
    required Color color,
    required bool busy,
    double progress = 0,
    VoidCallback? onTap,
  }) {
    final p = widget.palette;
    final fg = selected
        ? Colors.white
        : (widget.enabled ? p.text : p.textDim.withValues(alpha: 0.6));

    final body = ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: selected ? color : Colors.transparent),
          if (progress > 0)
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: progress,
              child: ColoredBox(color: color.withValues(alpha: 0.35)),
            ),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: selected ? Colors.white : color,
                    ),
                  )
                else if (!widget.dense)
                  Icon(icon, size: 14, color: fg),
                if (busy || !widget.dense) const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        color: fg,
                        fontSize: widget.dense ? 10.5 : 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8)),
              ],
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return body;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: body,
    );
  }
}