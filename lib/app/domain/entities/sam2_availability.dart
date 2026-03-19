class Sam2Availability {
  final bool isReady;
  final String message;
  final String modelDirectory;
  final String encoderPath;
  final String decoderPath;

  const Sam2Availability({
    required this.isReady,
    required this.message,
    required this.modelDirectory,
    required this.encoderPath,
    required this.decoderPath,
  });

  factory Sam2Availability.unavailable(String message) {
    return Sam2Availability(
      isReady: false,
      message: message,
      modelDirectory: '',
      encoderPath: '',
      decoderPath: '',
    );
  }

  factory Sam2Availability.fromMap(Map<dynamic, dynamic> map) {
    final stringKeyed = map.map(
      (key, value) => MapEntry(key.toString(), value),
    );

    return Sam2Availability(
      isReady: stringKeyed['isReady'] == true,
      message: (stringKeyed['message']?.toString() ?? '').trim(),
      modelDirectory: (stringKeyed['modelDirectory']?.toString() ?? '').trim(),
      encoderPath: (stringKeyed['encoderPath']?.toString() ?? '').trim(),
      decoderPath: (stringKeyed['decoderPath']?.toString() ?? '').trim(),
    );
  }
}
