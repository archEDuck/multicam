class StereoPreprocessResult {
  final bool success;
  final String message;
  final int processedPairs;
  final String outputPath;

  const StereoPreprocessResult({
    required this.success,
    required this.message,
    required this.processedPairs,
    required this.outputPath,
  });

  factory StereoPreprocessResult.empty(String message) {
    return StereoPreprocessResult(
      success: false,
      message: message,
      processedPairs: 0,
      outputPath: '',
    );
  }

  factory StereoPreprocessResult.fromMap(Map<dynamic, dynamic> map) {
    int toInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    return StereoPreprocessResult(
      success: map['success'] == true,
      message: (map['message']?.toString() ?? '').trim(),
      processedPairs: toInt(map['processedPairs']),
      outputPath: (map['outputPath']?.toString() ?? '').trim(),
    );
  }
}
