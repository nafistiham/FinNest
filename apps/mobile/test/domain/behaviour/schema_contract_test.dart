import 'dart:convert';
import 'dart:io';

import 'package:bhorosha/domain/behaviour/feature_names.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wire order is the trained model's contract: the fixture is
/// `models/ato/artefacts.json` `schema_names`, copied verbatim.
void main() {
  test('FeatureNames.wire equals the model artefact schema_names', () {
    final names = (jsonDecode(
      File('test/fixtures/ato_schema_names.json').readAsStringSync(),
    ) as List<dynamic>).cast<String>();
    expect(names, hasLength(55));
    expect(FeatureNames.count, names.length);
    expect(FeatureNames.wire, orderedEquals(names));
  });
}
