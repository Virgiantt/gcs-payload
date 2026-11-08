import '../models/telemetry.dart';

const List<String> kFlightPhases = [
  'LAUNCH_PAD',
  'ASCENT',
  'APOGEE',
  'DESCENT',
  'LANDED',
];

enum FlightEventKind { launch, apogee, separation, descent, landed }

const Map<String, (String, FlightEventKind)> kStateEvents = {
  'ASCENT': ('Launch', FlightEventKind.launch),
  'APOGEE': ('Separation', FlightEventKind.separation),
  'DESCENT': ('Descent', FlightEventKind.descent),
  'LANDED': ('Landed', FlightEventKind.landed),
};
class TrackPoint {
  const TrackPoint({
    required this.lat,
    required this.lon,
    required this.alt,
    required this.state,
    required this.missionTime,
    required this.packet,
  });

  final double lat, lon, alt;
  final String state, missionTime;
  final int packet;
}

class FlightEvent {
  const FlightEvent(this.label, this.index, this.kind);
  final String label;

  /// Indeks ke [FlightTrack.points].
  final int index;
  final FlightEventKind kind;
}

class FlightTrack {
  static const int maxPoints = 20000;

  final List<TrackPoint> points = [];
  final Map<String, String> phaseTimes = {};
  double? maxAlt;

  int version = 0;

  int _lastPacket = -1;
  String? _lastState;

  List<FlightEvent> _events = const [];
  int _eventsVersion = -1;

  void reset() {
    points.clear();
    phaseTimes.clear();
    maxAlt = null;
    version++;
  }

  static bool _validGps(Telemetry t) =>
      t.gpsLat.isFinite &&
      t.gpsLon.isFinite &&
      t.gpsLat.abs() <= 90 &&
      t.gpsLon.abs() <= 180 &&
      (t.gpsLat.abs() > 1e-6 || t.gpsLon.abs() > 1e-6);

  void add(Telemetry t) {
    if (t.packetCount == _lastPacket) return;
    _lastPacket = t.packetCount;

    final st = t.state.trim().toUpperCase();
    if (st == 'LAUNCH_PAD' &&
        _lastState != null &&
        _lastState != 'LAUNCH_PAD') {
      reset();
    }
    _lastState = st;

    if (kFlightPhases.contains(st)) {
      phaseTimes.putIfAbsent(st, () => t.missionTime);
    }
    if (t.altitude.isFinite && (maxAlt == null || t.altitude > maxAlt!)) {
      maxAlt = t.altitude;
    }
    if (_validGps(t)) {
      points.add(TrackPoint(
        lat: t.gpsLat,
        lon: t.gpsLon,
        alt: t.altitude.isFinite ? t.altitude : 0,
        state: st,
        missionTime: t.missionTime,
        packet: t.packetCount,
      ));
      if (points.length > maxPoints) {
        points.removeRange(0, points.length - maxPoints);
      }
    }
    version++;
  }

  /// Event: awal tiap state (lihat [kStateEvents]) dan titik tertinggi.
  List<FlightEvent> get events {
    if (_eventsVersion == version) return _events;
    final out = <FlightEvent>[];
    final seen = <String>{};
    var maxI = -1;
    var maxA = double.negativeInfinity;
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final ev = kStateEvents[p.state];
      if (ev != null && seen.add(p.state)) {
        out.add(FlightEvent(ev.$1, i, ev.$2));
      }
      if (p.alt > maxA) {
        maxA = p.alt;
        maxI = i;
      }
    }
    if (maxI >= 0 && maxA > 5) {
      out.add(FlightEvent(
          'Apogee ${maxA.toStringAsFixed(0)} m', maxI, FlightEventKind.apogee));
    }
    _events = out;
    _eventsVersion = version;
    return out;
  }
}