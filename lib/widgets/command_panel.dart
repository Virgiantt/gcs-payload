import 'package:flutter/material.dart';

import '../services/command_service.dart';
import '../theme/app_theme.dart';

class _Def {
  final String name;
  final String label;
  final IconData icon;
  const _Def(this.name, this.label, this.icon);
}

/// Panel perintah: ARM -> konfirmasi -> kirim -> tunggu ACK.
///
/// [compact] = true -> layout 3 kolom (ARM+kritis | quick+custom | log),
/// cocok ditaruh di samping kartu Flight State.
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
  final TextEditingController _ctrl = TextEditingController();

  // Nama perintah harus sama dengan yang dikenali program di Raspberry Pi.
  static const List<_Def> _critical = [
    _Def('SEPARATE_1', 'Separate Stage 1', Icons.call_split),
    _Def('SEPARATE_2', 'Separate Stage 2', Icons.call_split),
    _Def('PAYLOAD_RELEASE', 'Release Payload', Icons.unarchive_outlined),
  ];
  static const List<_Def> _quick = [
    _Def('PING', 'Ping', Icons.wifi_tethering),
    _Def('CAM_ON', 'Cam ON', Icons.videocam_outlined),
    _Def('CAM_OFF', 'Cam OFF', Icons.videocam_off_outlined),
    _Def('BUZZER_ON', 'Buzzer ON', Icons.volume_up_outlined),
    _Def('BUZZER_OFF', 'Buzzer OFF', Icons.volume_off_outlined),
  ];

  AppPalette get p => widget.palette;
  CommandService get svc => widget.service;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
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
    if (ok == true) svc.send(d.name);
  }

  void _sendCustom() {
    final v = _ctrl.text;
    if (v.trim().isEmpty) return;
    svc.send(v);
    _ctrl.clear();
  }

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
        child: widget.compact ? _compactBody() : _fullBody(),
      ),
    );
  }

  // ---------------- layout penuh (vertikal) ----------------
  Widget _fullBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _armBlock(),
                const SizedBox(height: 10),
                for (final d in _critical) ...[
                  _btn(
                    label: d.label,
                    icon: d.icon,
                    color: p.bad,
                    enabled: svc.armed && svc.connected,
                    onTap: () => _sendCritical(d),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 4),
                _label('QUICK ACTIONS'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final d in _quick)
                      _btn(
                        label: d.label,
                        icon: d.icon,
                        color: p.accent,
                        enabled: svc.connected,
                        dense: true,
                        onTap: () => svc.send(d.name),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _label('CUSTOM COMMAND'),
                _customField(),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: p.border),
        SizedBox(height: 150, child: _logView()),
      ],
    );
  }

  // ---------------- layout compact (3 kolom, semua diawali label) ----------------
  Widget _compactBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Kolom 1: ARM + perintah kritis
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _label('CRITICAL COMMANDS'),
                      _armBlock(compact: true),
                      const SizedBox(height: 8),
                      for (int i = 0; i < _critical.length; i++) ...[
                        _btn(
                          label: _critical[i].label,
                          icon: _critical[i].icon,
                          color: p.bad,
                          enabled: svc.armed && svc.connected,
                          dense: true,
                          height: 32,
                          onTap: () => _sendCritical(_critical[i]),
                        ),
                        if (i != _critical.length - 1)
                          const SizedBox(height: 5),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                // Kolom 2: Quick actions (grid 2 kolom) + custom command
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _label('QUICK ACTIONS'),
                      LayoutBuilder(
                        builder: (context, c) {
                          final w = (c.maxWidth - 6) / 2;
                          return Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final d in _quick)
                                _btn(
                                  label: d.label,
                                  icon: d.icon,
                                  color: p.accent,
                                  enabled: svc.connected,
                                  dense: true,
                                  width: w,
                                  height: 32,
                                  onTap: () => svc.send(d.name),
                                ),
                            ],
                          );
                        },
                      ),
                      const Spacer(),
                      _label('CUSTOM COMMAND'),
                      _customField(),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                // Kolom 3: log
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _label('COMMAND LOG'),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: p.border),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          clipBehavior: Clip.hardEdge,
                          child: _logView(showTitle: false),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _header() {
    final ok = svc.connected;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Row(
        children: [
          Icon(Icons.settings_remote, size: 18, color: p.accent),
          const SizedBox(width: 8),
          Text('COMMAND CENTER',
              style: TextStyle(
                  color: p.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4)),
          const Spacer(),
          Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: ok ? p.ok : p.bad, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(ok ? 'LINK OK' : 'NO LINK',
              style: TextStyle(
                  color: ok ? p.ok : p.bad,
                  fontSize: 10,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _armBlock({bool compact = false}) {
    final armed = svc.armed;
    final c = armed ? p.warn : p.textDim;
    return Container(
      padding: EdgeInsets.all(compact ? 7 : 10),
      decoration: BoxDecoration(
        color: c.withOpacity(0.10),
        border: Border.all(color: c.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(armed ? Icons.lock_open : Icons.lock_outline,
              color: c, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              armed
                  ? 'ARMED · ${svc.armedSecondsLeft}s'
                  : (compact
                      ? 'SAFE · terkunci'
                      : 'SAFE · perintah kritis terkunci'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: c, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          _btn(
            label: armed ? 'DISARM' : 'ARM',
            icon: armed ? Icons.lock : Icons.shield_outlined,
            color: armed ? p.textDim : p.warn,
            enabled: armed || svc.connected,
            dense: true,
            height: compact ? 32 : null,
            onTap: armed ? svc.disarm : svc.arm,
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

  Widget _customField() {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 34,
            child: TextField(
              controller: _ctrl,
              enabled: svc.connected,
              textCapitalization: TextCapitalization.characters,
              onSubmitted: (_) => _sendCustom(),
              style: TextStyle(color: p.text, fontSize: 12),
              decoration: InputDecoration(
                hintText: 'mis. CAM_ON',
                hintStyle: TextStyle(color: p.textDim, fontSize: 12),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: p.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: p.border),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _btn(
          label: 'Send',
          icon: Icons.send,
          color: p.accent,
          enabled: svc.connected,
          dense: true,
          onTap: _sendCustom,
        ),
      ],
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
            Icon(icon, size: 16, color: c),
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

  // ---------------- log ----------------
  Widget _logView({bool showTitle = true}) {
    final items = svc.log;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTitle)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Text('COMMAND LOG',
                style: TextStyle(
                    color: p.textDim,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2)),
          ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text('Belum ada perintah',
                      style: TextStyle(color: p.textDim, fontSize: 11)))
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(14, showTitle ? 0 : 8, 14, 8),
                  itemCount: items.length,
                  itemBuilder: (_, i) => _logRow(items[i]),
                ),
        ),
      ],
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
}
