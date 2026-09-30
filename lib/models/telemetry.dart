class Telemetry {
  final String teamId;
  final String missionTime;
  final int packetCount;
  final double altitude;
  final double pressure;
  final double temperature;
  final double voltage;
  final double roll;
  final double pitch;
  final double yaw;
  final double gpsLat;
  final double gpsLon;
  final double gpsAlt;
  final String state;
  final DateTime receivedAt;

  Telemetry({
    required this.teamId,
    required this.missionTime,
    required this.packetCount,
    required this.altitude,
    required this.pressure,
    required this.temperature,
    required this.voltage,
    required this.roll,
    required this.pitch,
    required this.yaw,
    required this.gpsLat,
    required this.gpsLon,
    required this.gpsAlt,
    required this.state,
    required this.receivedAt,
  });

  static Telemetry? fromCsv(String line) {
    final parts = line.trim().split(',');
    if (parts.length < 14) return null;
    try {
      return Telemetry(
        teamId: parts[0].trim(),
        missionTime: parts[1].trim(),
        packetCount: int.parse(parts[2].trim()),
        altitude: double.parse(parts[3].trim()),
        pressure: double.parse(parts[4].trim()),
        temperature: double.parse(parts[5].trim()),
        voltage: double.parse(parts[6].trim()),
        roll: double.parse(parts[7].trim()),
        pitch: double.parse(parts[8].trim()),
        yaw: double.parse(parts[9].trim()),
        gpsLat: double.parse(parts[10].trim()),
        gpsLon: double.parse(parts[11].trim()),
        gpsAlt: double.parse(parts[12].trim()),
        state: parts[13].trim(),
        receivedAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}
