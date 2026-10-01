import 'package:flutter/material.dart';

import '../services/command_service.dart';
import '../theme/app_theme.dart';

class _Def {
  final String name;
  final String label;
  final IconData icon;
  const _Def(this.name, this.label, this.icon);
}

/// Panel perintah: ARM -> pilih perintah kritis (dropdown) -> konfirmasi
/// -> kirim -> tunggu ACK.
///
/// Layout: Command Log (persegi panjang) di atas, lalu dropdown perintah
/// kritis, lalu kolom perintah + tombol Send.
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
    if (ok == true) {
      // Panel tidak lagi punya tombol ARM, jadi arm otomatis setelah user
      // mengonfirmasi (CommandService menolak perintah kritis saat SAFE).
      if (!svc.armed) svc.arm();
      svc.send(d.name);
    }
  }

  /// Satu tombol Send: kirim isi kolom perintah.
  /// Jika isinya perintah kritis (dipilih dari dropdown) -> minta konfirmasi dulu.
  void _send() {
    final v = _ctrl.text.trim();
    if (v.isEmpty || !svc.connected) return;
    final crit = _critical.where((d) => d.name == v.toUpperCase());
    if (crit.isNotEmpty) {
      _sendCritical(crit.first).then((_) {
        if (mounted) _ctrl.clear();
        if (mounted) setState(() {});
      });
    } else {
      svc.send(v);
      _ctrl.clear();
      setState(() {});
    }
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
        child: _body(),
      ),
    );
  }

  // ---------------- layout: log (persegi panjang) di atas, kontrol di bawah ----------------
  Widget _body() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
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
                const SizedBox(height: 10),
                _label('CRITICAL COMMANDS'),
                _criticalDropdown(),
                const SizedBox(height: 8),
                // Kolom perintah + satu tombol Send
                Row(
                  children: [
                    Expanded(child: _commandField()),
                    const SizedBox(width: 6),
                    _btn(
                      label: 'Send',
                      icon: Icons.send,
                      color: p.accent,
                      enabled: svc.connected && _ctrl.text.trim().isNotEmpty,
                      dense: true,
                      height: 38,
                      onTap: _send,
                    ),
                  ],
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

  // ---------------- dropdown perintah kritis ----------------
  // Memilih item hanya mengisi kolom perintah; pengiriman lewat tombol Send
  // (perintah kritis tetap minta konfirmasi).
  Widget _criticalDropdown() {
    final enabled = svc.connected;
    final c = enabled ? p.bad : p.textDim.withOpacity(0.5);
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.withOpacity(enabled ? 0.08 : 0.04),
        border: Border.all(color: c.withOpacity(enabled ? 0.6 : 0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_Def>(
          value: null,
          isExpanded: true,
          isDense: true,
          dropdownColor: p.panel,
          icon: Icon(Icons.arrow_drop_down, color: c),
          hint: Text(
            'Pilih perintah kritis',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          onChanged: enabled
              ? (d) {
                  if (d == null) return;
                  setState(() {
                    _ctrl.text = d.name;
                    _ctrl.selection =
                        TextSelection.collapsed(offset: _ctrl.text.length);
                  });
                }
              : null,
          items: [
            for (final d in _critical)
              DropdownMenuItem<_Def>(
                value: d,
                child: Row(
                  children: [
                    Icon(d.icon, size: 16, color: p.bad),
                    const SizedBox(width: 8),
                    Text(d.label,
                        style: TextStyle(
                            color: p.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
          ],
        ),
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

  Widget _commandField() {
    return SizedBox(
      height: 38,
      child: TextField(
        controller: _ctrl,
        enabled: svc.connected,
        textCapitalization: TextCapitalization.characters,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _send(),
        style: TextStyle(color: p.text, fontSize: 12),
        decoration: InputDecoration(
          hintText: 'Ketik perintah, mis. CAM_ON',
          hintStyle: TextStyle(color: p.textDim, fontSize: 12),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
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
