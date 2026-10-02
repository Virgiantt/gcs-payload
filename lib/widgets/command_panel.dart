import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/command_service.dart';
import '../theme/app_theme.dart';

class _Def {
  final String name;
  final String label;
  final IconData icon;
  const _Def(this.name, this.label, this.icon);
}

/// Preset sudut servo yang disimpan user (hanya selama aplikasi berjalan).
class _Preset {
  final int channel;
  final int angle;
  const _Preset(this.channel, this.angle);
  String get label => 'S$channel: $angle°';
}

/// Command Center dengan 4 tab: Servo, Presets, Manual, Log.
class CommandPanel extends StatefulWidget {
  final AppPalette palette;
  final CommandService service;
  final bool compact; // dipertahankan agar kompatibel dengan main.dart

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
  // Nama perintah harus sama dengan yang dikenali program di Raspberry Pi.
  static const List<_Def> _critical = [
    _Def('SEPARATE_1', 'Separate Stage 1', Icons.call_split),
    _Def('SEPARATE_2', 'Separate Stage 2', Icons.call_split),
    _Def('PAYLOAD_RELEASE', 'Release Payload', Icons.unarchive_outlined),
  ];

  // static -> preset tidak hilang saat pindah tab utama
  static final List<_Preset> _presets = [];

  int _tab = 0; // 0 Servo, 1 Presets, 2 Manual, 3 Log

  // --- Servo ---
  int _channel = 2;
  final TextEditingController _angleCtrl = TextEditingController(text: '90');

  // --- Config lock (Container / Wing) ---
  String _cfgTarget = 'CONTAINER';
  String _cfgState = 'LOCK';
  final TextEditingController _cfgAngleCtrl =
      TextEditingController(text: '100');

  // --- Manual ---
  final TextEditingController _manualCtrl = TextEditingController();

  AppPalette get p => widget.palette;
  CommandService get svc => widget.service;

  @override
  void dispose() {
    _angleCtrl.dispose();
    _cfgAngleCtrl.dispose();
    _manualCtrl.dispose();
    super.dispose();
  }

  // ---------------- aksi ----------------
  int? _angleOf(TextEditingController c) {
    final v = int.tryParse(c.text.trim());
    if (v == null || v < 0 || v > 180) return null;
    return v;
  }

  Future<void> _sendCritical(_Def d) async {
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
      // Panel tidak punya tombol ARM, jadi arm otomatis setelah konfirmasi
      // (CommandService menolak perintah kritis saat SAFE).
      if (!svc.armed) svc.arm();
      svc.send(d.name);
    }
  }

  void _sendServo() {
    final a = _angleOf(_angleCtrl);
    if (a == null || !svc.connected) return;
    svc.send('SERVO $_channel $a');
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
    svc.send('CONFIG $_cfgTarget $_cfgState $a');
  }

  /// Tab Manual: kirim isi kolom. Perintah kritis tetap minta konfirmasi.
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
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) => Container(
        decoration: BoxDecoration(
          color: p.panel,
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
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

  Widget _header() {
    final ok = svc.connected;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Row(
        children: [
          Icon(Icons.settings_remote, size: 20, color: p.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Command Center',
                    style: TextStyle(
                        color: p.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w800)),
                Text('Actuators, flight modes & manual uplink',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.textDim, fontSize: 10)),
              ],
            ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: ok ? p.ok : p.bad, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(ok ? 'LINK OK' : 'Offline',
              style: TextStyle(
                  color: ok ? p.ok : p.bad,
                  fontSize: 10,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
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
                      color: p.border.withOpacity(0.6),
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

  // =========================================================
  // TAB 1: SERVO
  // =========================================================
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
          // ---- Individual servo ----
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
                                  color: p.textDim.withOpacity(0.7),
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

          // ---- Config lock ----
          _card(
            icon: Icons.lock_outline,
            title: 'Container (Servo 2) / Wing (Servo 5) Lock Angle Config',
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
                        items: const {
                          'CONTAINER': 'Container (S2)',
                          'WING': 'Wing (S5)',
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

  // =========================================================
  // TAB 2: PRESETS (perintah misi kritis + preset servo tersimpan)
  // =========================================================
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
        color: p.panelAlt.withOpacity(0.5),
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
            onTap: () => svc.send('SERVO ${pr.channel} ${pr.angle}'),
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

  // =========================================================
  // TAB 3: MANUAL
  // =========================================================
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

  // =========================================================
  // TAB 4: LOG
  // =========================================================
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

  // =========================================================
  // KOMPONEN UI
  // =========================================================
  Widget _card({
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.panelAlt.withOpacity(0.5),
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
    final c = onChanged == null ? p.textDim.withOpacity(0.6) : p.text;
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
    final c = enabled ? color : p.textDim.withOpacity(0.5);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width,
        height: height ?? (dense ? 34 : 42),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: c.withOpacity(enabled ? 0.12 : 0.05),
          border: Border.all(color: c.withOpacity(enabled ? 0.6 : 0.3)),
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
