import 'dart:typed_data';

/// PCM WAV helpers for FNA's voice. Gemini TTS returns raw
/// 24 kHz 16-bit mono PCM (`audio/L16;codec=pcm;rate=24000`), which
/// `audioplayers` cannot play without a RIFF header; risk-mw's
/// `/v1/apa/why-audio` streams a WAV whose header says "length unknown"
/// (`0xFFFFFFFF`), which some decoders reject once the file is whole.
abstract final class Wav {
  static const int headerBytes = 44;
  static const int geminiRate = 24000;
  static const int unknownLength = 0xFFFFFFFF;

  /// The 44-byte header of a PCM WAV holding [dataBytes] bytes of samples,
  /// byte for byte what risk-mw `app/tts.py` `wav_header` packs.
  static Uint8List header(
    int dataBytes, {
    int rate = geminiRate,
    int channels = 1,
    int bitsPerSample = 16,
  }) {
    final blockAlign = channels * bitsPerSample ~/ 8;
    final b = ByteData(headerBytes);
    void ascii(int at, String s) {
      for (var i = 0; i < 4; i++) {
        b.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    b.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    b.setUint32(16, 16, Endian.little); // fmt chunk size
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, channels, Endian.little);
    b.setUint32(24, rate, Endian.little);
    b.setUint32(28, rate * blockAlign, Endian.little); // byte rate
    b.setUint16(32, blockAlign, Endian.little);
    b.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    b.setUint32(40, dataBytes, Endian.little);
    return b.buffer.asUint8List();
  }

  /// [pcm] (16-bit little-endian mono samples at [rate]) as a whole WAV file.
  static Uint8List wrapPcm(Uint8List pcm, {int rate = geminiRate}) {
    final out = Uint8List(headerBytes + pcm.length)
      ..setAll(0, header(pcm.length, rate: rate))
      ..setAll(headerBytes, pcm);
    return out;
  }

  /// Whether [bytes] start with a canonical RIFF/WAVE header.
  static bool isWav(Uint8List bytes) =>
      bytes.length >= headerBytes &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WAVE';

  /// A buffered stream's WAV with its RIFF and data sizes set to what arrived.
  /// Anything that is not a canonical 44-byte-header WAV is returned as is.
  static Uint8List fixStreamedSizes(Uint8List bytes) {
    if (!isWav(bytes) ||
        String.fromCharCodes(bytes.sublist(36, 40)) != 'data') {
      return bytes;
    }
    final view = ByteData.sublistView(bytes);
    final data = bytes.length - headerBytes;
    if (view.getUint32(40, Endian.little) == data &&
        view.getUint32(4, Endian.little) == 36 + data) {
      return bytes;
    }
    final out = Uint8List.fromList(bytes);
    ByteData.sublistView(out)
      ..setUint32(4, 36 + data, Endian.little)
      ..setUint32(40, data, Endian.little);
    return out;
  }

  /// Playing time of a canonical WAV, or null when [bytes] is not one.
  static Duration? duration(Uint8List bytes) {
    if (!isWav(bytes)) return null;
    final view = ByteData.sublistView(bytes);
    final byteRate = view.getUint32(28, Endian.little);
    if (byteRate == 0) return null;
    final data = bytes.length - headerBytes;
    return Duration(microseconds: data * 1000000 ~/ byteRate);
  }

  /// The sample rate a PCM mime type names (`audio/L16;codec=pcm;rate=24000`),
  /// or [geminiRate].
  static int rateOf(String mimeType) {
    final m = RegExp(r'rate=(\d+)').firstMatch(mimeType);
    return m == null ? geminiRate : int.parse(m.group(1)!);
  }
}
