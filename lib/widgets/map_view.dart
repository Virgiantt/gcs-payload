import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/telemetry.dart';
import '../theme/app_theme.dart';

class MapView extends StatefulWidget {
  final AppPalette palette;
  final Telemetry? data;
  final List<Telemetry> history;

  const MapView({
    super.key,
    required this.palette,
    required this.data,
    this.history = const [],
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final MapController _mapController = MapController();
  bool _autoFollow = true;
  LatLng? _lastCenter;

  @override
  void didUpdateWidget(covariant MapView oldWidget) {
    super.didUpdateWidget(oldWidget);

    final t = widget.data;
    if (t != null && _autoFollow) {
      final newPos = LatLng(t.gpsLat, t.gpsLon);
      if (_lastCenter == null ||
          _lastCenter!.latitude != newPos.latitude ||
          _lastCenter!.longitude != newPos.longitude) {
        _lastCenter = newPos;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _mapController.move(newPos, _mapController.camera.zoom);
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final t = widget.data;

    final lat = t?.gpsLat ?? -7.275764;
    final lon = t?.gpsLon ?? 112.794317;
    final center = LatLng(lat, lon);

    final trailPoints = <LatLng>[];
    for (final h in widget.history) {
      trailPoints.add(LatLng(h.gpsLat, h.gpsLon));
    }
    if (t != null) {
      trailPoints.add(center);
    }

    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: [
          Transform(
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0015)
              ..rotateX(0.7)
              ..rotateY(-0.06),
            alignment: Alignment.center,
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: center,
                initialZoom: 16,
                minZoom: 3,
                maxZoom: 19,
                backgroundColor: palette.panelAlt,
                onPositionChanged: (position, hasGesture) {
                  if (hasGesture && _autoFollow) {
                    setState(() => _autoFollow = false);
                  }
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.eepisat.gcs',
                ),

                // ============ TRAIL GLOW (bayangan tebal di bawah) ============
                if (trailPoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: trailPoints,
                        strokeWidth: 12,
                        color: palette.accent.withValues(alpha: 0.15),
                      ),
                    ],
                  ),

                // ============ TRAIL UTAMA (garis solid) ============
                if (trailPoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: trailPoints,
                        strokeWidth: 4,
                        color: palette.accent,
                        borderStrokeWidth: 1,
                        borderColor: Colors.white.withValues(alpha: 0.8),
                      ),
                    ],
                  ),

                // ============ START MARKER (titik awal) ============
                if (trailPoints.isNotEmpty)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: trailPoints.first,
                        width: 26,
                        height: 26,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: palette.ok.withValues(alpha: 0.9),
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: const Icon(
                            Icons.flag,
                            color: Colors.white,
                            size: 12,
                          ),
                        ),
                      ),
                    ],
                  ),

                // ============ CIRCLE AREA ============
                if (t != null)
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: center,
                        radius: 30,
                        useRadiusInMeter: true,
                        color: palette.accent.withValues(alpha: 0.12),
                        borderColor: palette.accent.withValues(alpha: 0.5),
                        borderStrokeWidth: 1.5,
                      ),
                    ],
                  ),

                // ============ CURRENT POSITION MARKER ============
                if (t != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: center,
                        width: 72,
                        height: 72,
                        child: _payloadMarker(palette, t),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.10),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.16),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            left: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: palette.panel.withValues(alpha: 0.92),
                border: Border.all(color: palette.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Lat ${lat.toStringAsFixed(6)}  ·  Lon ${lon.toStringAsFixed(6)}',
                style: TextStyle(
                  color: palette.text,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),

          if (t != null)
            Positioned(
              right: 12,
              top: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: palette.panel.withValues(alpha: 0.92),
                  border: Border.all(color: palette.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.height, size: 12, color: palette.accent),
                    const SizedBox(width: 4),
                    Text(
                      '${t.gpsAlt.toStringAsFixed(1)} m',
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ),

          Positioned(
            right: 12,
            bottom: 12,
            child: Column(
              children: [
                _mapButton(
                  icon: _autoFollow ? Icons.gps_fixed : Icons.gps_not_fixed,
                  tooltip: _autoFollow ? 'Auto-follow ON' : 'Auto-follow OFF',
                  active: _autoFollow,
                  onTap: () {
                    setState(() => _autoFollow = !_autoFollow);
                    if (_autoFollow) {
                      final p = LatLng(lat, lon);
                      _mapController.move(p, _mapController.camera.zoom);
                      _lastCenter = p;
                    }
                  },
                  palette: palette,
                ),
                const SizedBox(height: 8),
                _mapButton(
                  icon: Icons.zoom_in,
                  tooltip: 'Zoom in',
                  onTap: () => _mapController.move(
                    _mapController.camera.center,
                    _mapController.camera.zoom + 1,
                  ),
                  palette: palette,
                ),
                const SizedBox(height: 8),
                _mapButton(
                  icon: Icons.zoom_out,
                  tooltip: 'Zoom out',
                  onTap: () => _mapController.move(
                    _mapController.camera.center,
                    _mapController.camera.zoom - 1,
                  ),
                  palette: palette,
                ),
                const SizedBox(height: 8),
                _mapButton(
                  icon: Icons.center_focus_strong,
                  tooltip: 'Fit trail',
                  onTap: _fitTrail,
                  palette: palette,
                ),
              ],
            ),
          ),

          if (trailPoints.length >= 2)
            Positioned(
              left: 12,
              bottom: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: palette.panel.withValues(alpha: 0.92),
                  border: Border.all(color: palette.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.timeline, size: 12, color: palette.accent),
                    const SizedBox(width: 4),
                    Text(
                      '${trailPoints.length} titik trail',
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _fitTrail() {
    if (widget.history.length < 2) return;
    double minLat = double.infinity, maxLat = -double.infinity;
    double minLon = double.infinity, maxLon = -double.infinity;
    for (final h in widget.history) {
      minLat = math.min(minLat, h.gpsLat);
      maxLat = math.max(maxLat, h.gpsLat);
      minLon = math.min(minLon, h.gpsLon);
      maxLon = math.max(maxLon, h.gpsLon);
    }
    final bounds = LatLngBounds(
      LatLng(minLat, minLon),
      LatLng(maxLat, maxLon),
    );
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(40),
      ),
    );
    setState(() => _autoFollow = false);
  }

  Widget _payloadMarker(AppPalette palette, Telemetry t) {
    final yaw = t.yaw * math.pi / 180.0;
    final pitch = t.pitch * math.pi / 180.0;
    final roll = t.roll * math.pi / 180.0;

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0012)
        ..rotateX(pitch)
        ..rotateY(roll)
        ..rotateZ(yaw),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: palette.accent.withValues(alpha: 0.18),
              boxShadow: [
                BoxShadow(
                  color: palette.accent.withValues(alpha: 0.45),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
          Transform.rotate(
            angle: yaw,
            child: Container(
              width: 28,
              height: 74,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white,
                    palette.accent,
                    Colors.black.withValues(alpha: 0.8),
                  ],
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: palette.accent.withValues(alpha: 0.55),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Transform.translate(
                offset: const Offset(0, -20),
                child: const Icon(
                  Icons.navigation,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    required AppPalette palette,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: active ? palette.accent : palette.panel.withValues(alpha: 0.95),
            border: Border.all(
              color: active ? palette.accent : palette.border,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 18,
            color: active ? Colors.white : palette.text,
          ),
        ),
      ),
    );
  }
}
