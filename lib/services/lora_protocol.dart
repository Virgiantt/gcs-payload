import 'dart:typed_data';

/// Protokol EEPISAT LoRa. Mengikuti protocol.h.
///
/// Frame: [0xAA][TYPE][SEQ][LEN][PAYLOAD x LEN][CRC16_H][CRC16_L]
/// CRC16-CCITT (poly 0x1021, init 0xFFFF) atas TYPE, SEQ, LEN, PAYLOAD.
class LoraProtocol {
  const LoraProtocol._();

  static const int sof = 0xAA;
  static const int maxPayload = 64;

  static const int pktStart = 0x01;
  static const int pktGps = 0x02;
  static const int pktStartAck = 0x81;
  static const int pktGpsAck = 0x82;

  static const List<int> startWord = [0x73, 0x74, 0x61, 0x72, 0x74]; // "start"
  static const List<int> startOk = [0x4F, 0x4B]; // "OK"

  static int crc16(List<int> d) {
    var crc = 0xFFFF;
    for (final b in d) {
      crc ^= (b & 0xFF) << 8;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
        crc &= 0xFFFF;
      }
    }
    return crc;
  }

  static Uint8List build(int type, int seq, List<int> payload) {
    final len = payload.length;
    final out = Uint8List(6 + len);
    out[0] = sof;
    out[1] = type;
    out[2] = seq & 0xFF;
    out[3] = len;
    for (var i = 0; i < len; i++) {
      out[4 + i] = payload[i];
    }
    final crc = crc16(out.sublist(1, 4 + len));
    out[4 + len] = crc >> 8;
    out[5 + len] = crc & 0xFF;
    return out;
  }

  /// ACK untuk PKT_START: payload "OK", seq sama dengan START.
  static Uint8List startAck(int seq) => build(pktStartAck, seq, startOk);

  /// ACK untuk PKT_GPS: payload [status][rxCount_L][rxCount_H].
  static Uint8List gpsAck(int seq, int rxCount, {int status = 0}) =>
      build(pktGpsAck, seq, [status, rxCount & 0xFF, (rxCount >> 8) & 0xFF]);
}

/// Payload PKT_GPS (16 byte, little-endian, packed).
class GpsPayload {
  final double lat;
  final double lon;
  final double altM;
  final double speedKmh;
  final int sats;
  final bool fixValid;

  const GpsPayload(
      this.lat, this.lon, this.altM, this.speedKmh, this.sats, this.fixValid);

  static GpsPayload? parse(Uint8List p) {
    if (p.length != 16) return null;
    final bd = ByteData.sublistView(p);
    return GpsPayload(
      bd.getInt32(0, Endian.little) / 1e6,
      bd.getInt32(4, Endian.little) / 1e6,
      bd.getInt32(8, Endian.little) / 100.0,
      bd.getUint16(12, Endian.little) / 100.0,
      bd.getUint8(14),
      (bd.getUint8(15) & 0x01) != 0,
    );
  }
}

/// Parser frame byte demi byte. [feed] true kalau satu frame valid selesai.
class FrameParser {
  int type = 0;
  int seq = 0;
  int len = 0;
  final Uint8List payload = Uint8List(LoraProtocol.maxPayload);

  /// Jumlah frame lengkap yang CRC-nya salah.
  int crcErrors = 0;

  int _state = 0;
  int _idx = 0;
  int _crcH = 0;
  int _lastMs = 0;
  final Stopwatch _clock = Stopwatch()..start();

  void reset() => _state = 0;

  bool feed(int b) {
    final now = _clock.elapsedMilliseconds;
    if (_state != 0 && now - _lastMs > 300) _state = 0; // frame menggantung
    _lastMs = now;

    switch (_state) {
      case 0:
        if (b == LoraProtocol.sof) _state = 1;
        break;
      case 1:
        type = b;
        _state = 2;
        break;
      case 2:
        seq = b;
        _state = 3;
        break;
      case 3:
        len = b;
        if (len > LoraProtocol.maxPayload) {
          _state = 0;
        } else {
          _idx = 0;
          _state = len > 0 ? 4 : 5;
        }
        break;
      case 4:
        payload[_idx++] = b;
        if (_idx >= len) _state = 5;
        break;
      case 5:
        _crcH = b;
        _state = 6;
        break;
      case 6:
        _state = 0;
        final tmp = <int>[type, seq, len, ...payload.sublist(0, len)];
        final rx = (_crcH << 8) | b;
        if (rx == LoraProtocol.crc16(tmp)) return true;
        crcErrors++;
        return false;
    }
    return false;
  }
}