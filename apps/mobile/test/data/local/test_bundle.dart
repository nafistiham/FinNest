import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Serves `assets/demo/*` straight from disk so the loaders are tested
/// against the real bundled files.
class DiskAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final bytes = await File(key).readAsBytes();
    return ByteData.sublistView(bytes);
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) =>
      File(key).readAsString(encoding: utf8);
}
