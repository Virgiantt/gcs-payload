import 'package:flutter/material.dart';
import '../services/telemetry_service.dart';
import '../theme/app_theme.dart';

class ConnectionIndicator extends StatelessWidget {
  final AppPalette palette;
  final ConnectionStatus status;

  const ConnectionIndicator({
    super.key,
    required this.palette,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    late Color color;
    late String label;
    late IconData icon;

    switch (status) {
      case ConnectionStatus.connected:
        color = palette.ok;
        label = 'CONNECTED';
        icon = Icons.link;
        break;
      case ConnectionStatus.connecting:
        color = palette.warn;
        label = 'CONNECTING';
        icon = Icons.sync;
        break;
      case ConnectionStatus.disconnected:
        color = palette.bad;
        label = 'DISCONNECTED';
        icon = Icons.link_off;
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 1.4),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
      ],
    );
  }
}
