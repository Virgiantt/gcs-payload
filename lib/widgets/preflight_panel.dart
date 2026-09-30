import 'package:flutter/material.dart';

import '../services/preflight_service.dart';
import '../theme/app_theme.dart';

class PreflightPanel extends StatelessWidget {
  final AppPalette palette;
  final PreflightService service;

  /// Dipanggil saat tombol LAUNCH ditekan (hanya aktif jika lolos check).
  final VoidCallback? onLaunch;

  const PreflightPanel({
    super.key,
    required this.palette,
    required this.service,
    this.onLaunch,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'PRE-FLIGHT CHECK',
                style: TextStyle(
                  color: palette.textDim,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: palette.panel,
                    border: Border.all(color: palette.border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: service.items.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: palette.border),
                    itemBuilder: (_, i) => _row(service.items[i]),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _banner(),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: service.running ? null : service.run,
                      icon: const Icon(Icons.fact_check_outlined, size: 18),
                      label: Text(service.running
                          ? 'CHECKING...'
                          : (service.hasRun
                              ? 'RE-RUN CHECK'
                              : 'RUN PRE-FLIGHT CHECK')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: service.running ? null : service.reset,
                    child: const Text('Reset'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: palette.ok,
                        disabledBackgroundColor: palette.panelAlt,
                      ),
                      onPressed: service.launchAllowed ? onLaunch : null,
                      icon: Icon(
                        service.launchAllowed
                            ? Icons.rocket_launch
                            : Icons.lock,
                        size: 18,
                      ),
                      label: Text(
                          service.launchAllowed ? 'LAUNCH' : 'LAUNCH LOCKED'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(PreflightItem e) {
    Color c;
    Widget lead;
    switch (e.status) {
      case CheckStatus.pass:
        c = palette.ok;
        lead = Icon(Icons.check_box, color: c, size: 22);
        break;
      case CheckStatus.fail:
        c = palette.bad;
        lead = Icon(Icons.cancel, color: c, size: 22);
        break;
      case CheckStatus.checking:
        c = palette.accent;
        lead = SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: c),
        );
        break;
      case CheckStatus.pending:
        c = palette.textDim;
        lead = Icon(Icons.check_box_outline_blank, color: c, size: 22);
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          SizedBox(width: 24, child: Center(child: lead)),
          const SizedBox(width: 12),
          Icon(e.icon, size: 18, color: palette.textDim),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: Text(
              e.label,
              style: TextStyle(
                color: palette.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              e.detail,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c, fontSize: 12),
            ),
          ),
          if (e.manual)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Confirm',
                    style: TextStyle(color: palette.textDim, fontSize: 11)),
                Switch(
                  value: service.isManualOk(e.id),
                  onChanged: (v) => service.setManual(e.id, v),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _banner() {
    late final Color c;
    late final String title;
    String? sub;
    late final IconData icon;

    if (service.running) {
      c = palette.accent;
      title = 'CHECKING...';
      icon = Icons.hourglass_top;
    } else if (!service.hasRun) {
      c = palette.warn;
      title = 'PRE-FLIGHT CHECK BELUM DIJALANKAN';
      sub = 'LAUNCH BLOCKED';
      icon = Icons.lock_outline;
    } else if (service.launchAllowed) {
      c = palette.ok;
      title = 'READY FOR LAUNCH';
      icon = Icons.check_circle;
    } else {
      c = palette.bad;
      final f = service.failed.map((e) => '${e.label} NOT READY').join('  ·  ');
      title = f;
      sub = 'LAUNCH BLOCKED';
      icon = Icons.block;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        border: Border.all(color: c.withOpacity(0.6), width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: c, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: c,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                if (sub != null)
                  Text(
                    '[ $sub ]',
                    style: TextStyle(
                      color: c,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
