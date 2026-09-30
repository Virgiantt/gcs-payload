import 'package:flutter/material.dart';

import '../services/health_service.dart';
import '../theme/app_theme.dart';

/// Isi tab "Payload Health":
///   kiri  = status live 7 subsistem
///   kanan = PRE-LAUNCH CHECK (tombol, checklist, verdict GO / NO-GO, riwayat)
class HealthPanel extends StatelessWidget {
  final AppPalette palette;
  final HealthService service;

  const HealthPanel({super.key, required this.palette, required this.service});

  AppPalette get p => palette;

  Color _levelColor(HealthLevel l) => switch (l) {
        HealthLevel.ok => p.ok,
        HealthLevel.warn => p.warn,
        HealthLevel.fail => p.bad,
        HealthLevel.unknown => p.textDim,
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _title('LIVE SUBSYSTEM STATUS'),
                  Expanded(child: _liveCard()),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _title('PRE-LAUNCH CHECK'),
                  Expanded(child: _checkCard()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _title(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        child: Text(
          text,
          style: TextStyle(
            color: p.textDim,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
      );

  BoxDecoration get _box => BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(12),
      );

  // =========================================================
  // KIRI: STATUS LIVE
  // =========================================================
  Widget _liveCard() {
    final items = service.items;
    return Container(
      decoration: _box,
      clipBehavior: Clip.hardEdge,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        itemCount: items.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: p.border),
        itemBuilder: (_, i) => _liveRow(items[i]),
      ),
    );
  }

  Widget _liveRow(HealthItem it) {
    final c = _levelColor(it.level);
    return SizedBox(
      height: 60,
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  it.sub.label,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  it.sub.source,
                  style: TextStyle(color: p.textDim, fontSize: 10),
                ),
              ],
            ),
          ),
          Expanded(
            child: Text(
              it.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.textDim,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 130,
            child: Align(
              alignment: Alignment.centerRight,
              child: _badge(it.status, c),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String label, Color c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: c,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================
  // KANAN: PRE-LAUNCH CHECK
  // =========================================================
  Widget _checkCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _box,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _verdictBanner(),
          const SizedBox(height: 12),
          _checkButton(),
          const SizedBox(height: 14),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('CHECKLIST'),
                  for (final s in Subsystem.values) _stepRow(s),
                  const SizedBox(height: 14),
                  _label('LAST CHECKS'),
                  if (service.runs.isEmpty)
                    Text('Belum ada check',
                        style: TextStyle(color: p.textDim, fontSize: 11))
                  else
                    for (final r in service.runs.reversed.take(5))
                      _historyRow(r),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          t,
          style: TextStyle(
            color: p.textDim,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      );

  Widget _verdictBanner() {
    final (String label, Color c, IconData icon) = switch (service.verdict) {
      CheckVerdict.idle => (
          'NOT CHECKED',
          p.textDim,
          Icons.fact_check_outlined
        ),
      CheckVerdict.running => ('CHECKING…', p.accent, Icons.sync),
      CheckVerdict.go => ('GO', p.ok, Icons.check_circle),
      CheckVerdict.caution => ('CAUTION', p.warn, Icons.warning_amber_rounded),
      CheckVerdict.noGo => ('NO-GO', p.bad, Icons.cancel),
    };
    final sub = service.note ??
        (service.running
            ? 'Checking subsystems…'
            : 'Press PRE-LAUNCH CHECK to verify all subsystems');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        border: Border.all(color: c.withOpacity(0.5), width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 32, color: c),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: c,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: TextStyle(color: p.textDim, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _checkButton() {
    final running = service.running;
    return InkWell(
      onTap: running ? null : service.runPreLaunchCheck,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: p.accent.withOpacity(running ? 0.05 : 0.14),
          border: Border.all(color: p.accent.withOpacity(running ? 0.3 : 0.6)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.fact_check_outlined,
                size: 18, color: running ? p.textDim : p.accent),
            const SizedBox(width: 8),
            Text(
              running ? 'CHECKING…' : 'PRE-LAUNCH CHECK',
              style: TextStyle(
                color: running ? p.textDim : p.accent,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepRow(Subsystem sub) {
    final idx = sub.index;
    final HealthItem? done =
        idx < service.stepResults.length ? service.stepResults[idx] : null;
    final current = service.running && service.stepIndex == idx && done == null;

    Widget icon;
    Color c = p.textDim;
    if (done != null) {
      c = _levelColor(done.level);
      icon = Icon(
        switch (done.level) {
          HealthLevel.ok => Icons.check_circle,
          HealthLevel.warn => Icons.warning_amber_rounded,
          HealthLevel.fail => Icons.cancel,
          HealthLevel.unknown => Icons.help_outline,
        },
        size: 18,
        color: c,
      );
    } else if (current) {
      icon = SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
      );
    } else {
      icon = Icon(Icons.radio_button_unchecked,
          size: 18, color: p.textDim.withOpacity(0.6));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          icon,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sub.label,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (done != null)
                  Text(
                    done.detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.textDim, fontSize: 10),
                  ),
              ],
            ),
          ),
          if (done != null)
            Text(
              done.status,
              style: TextStyle(
                color: c,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
        ],
      ),
    );
  }

  Widget _historyRow(CheckRun r) {
    String two(int n) => n.toString().padLeft(2, '0');
    final t = r.time;
    final (String label, Color c) = switch (r.verdict) {
      CheckVerdict.go => ('GO', p.ok),
      CheckVerdict.caution => ('CAUTION', p.warn),
      CheckVerdict.noGo => ('NO-GO', p.bad),
      _ => ('—', p.textDim),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(
            '${two(t.hour)}:${two(t.minute)}:${two(t.second)}',
            style: TextStyle(
                color: p.textDim, fontSize: 10, fontFamily: 'monospace'),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: TextStyle(
                  color: c, fontSize: 11, fontWeight: FontWeight.w800),
            ),
          ),
          Expanded(
            child: Text(
              r.note ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.textDim, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}
