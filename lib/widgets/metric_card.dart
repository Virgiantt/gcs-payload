import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class MetricCard extends StatelessWidget {
  final AppPalette palette;
  final String title;
  final String unit;
  final String? iconAsset;
  final String value;

  const MetricCard({
    super.key,
    required this.palette,
    required this.title,
    required this.unit,
    required this.value,
    this.iconAsset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              if (iconAsset != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Image.asset(
                    iconAsset!,
                    width: 20,
                    height: 20,
                    color: palette.accent,
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.circle,
                      size: 18,
                      color: palette.accent,
                    ),
                  ),
                ),
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    color: palette.textDim,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  style: TextStyle(
                    color: palette.accent,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (unit.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    unit,
                    style: TextStyle(
                      color: palette.textDim,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
