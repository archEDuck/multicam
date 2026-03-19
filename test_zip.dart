import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';

void main() async {
  var d = Directory('testzip');
  d.createSync(recursive: true);
  File('testzip/f1.txt').writeAsStringSync('hello test!!!');

  var encoder = ZipFileEncoder();
  await encoder.zipDirectory(d, filename: 'out_test_final.zip');
  debugPrint('Size: ${File('out_test_final.zip').lengthSync()}');
}
