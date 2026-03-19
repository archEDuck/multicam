import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/entities/app_settings.dart';
import '../../domain/repositories/app_settings_repository.dart';

class JsonAppSettingsRepository implements AppSettingsRepository {
  JsonAppSettingsRepository();

  static const String _fileName = 'app_settings.json';

  @override
  Future<AppSettings> load() async {
    try {
      final file = await _resolveFile();
      if (!await file.exists()) {
        return AppSettings.defaults();
      }

      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return AppSettings.defaults();
      }

      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AppSettings.fromJson(decoded);
      }
      if (decoded is Map) {
        return AppSettings.fromJson(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
      return AppSettings.defaults();
    } catch (_) {
      return AppSettings.defaults();
    }
  }

  @override
  Future<void> save(AppSettings settings) async {
    final file = await _resolveFile();
    final prettyJson = const JsonEncoder.withIndent(
      '  ',
    ).convert(settings.toJson());
    await file.writeAsString(prettyJson, flush: true);
  }

  Future<File> _resolveFile() async {
    final baseDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${baseDir.path}${Platform.pathSeparator}settings');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }
}
