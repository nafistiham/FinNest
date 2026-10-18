import 'dart:convert';

import 'package:bhorosha/data/contracts/contracts.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:flutter/services.dart';

/// One persona's bundle from `assets/demo/personas.json`.
class PersonaSeed {
  const PersonaSeed({
    required this.profile,
    required this.pinSha256,
    required this.transactions,
    required this.savedPayees,
  });

  factory PersonaSeed.fromJson(Map<String, dynamic> json) {
    final profile = requireObject(json, 'profile', (m) => m);
    final balance = readDouble(json, 'balance_bdt', 0);
    return PersonaSeed(
      profile: UserProfile.fromJson(<String, dynamic>{
        ...profile,
        'balance_bdt': balance,
      }),
      pinSha256: requireString(json, 'pin_sha256'),
      transactions: readList(
        json,
        'transactions',
        objectItem(LedgerTxn.fromJson),
      ),
      savedPayees: readList(json, 'saved_payees', objectItem(Payee.fromJson)),
    );
  }

  final UserProfile profile;

  /// Lowercase hex SHA-256 of the demo PIN; compare with [PinCheck.matches].
  final String pinSha256;

  /// Newest first, as bundled.
  final List<LedgerTxn> transactions;
  final List<Payee> savedPayees;
}

/// Loads and caches the bundled demo data. One instance is shared by the
/// local repos so a persona is read from disk once per process.
class DemoAssets {
  DemoAssets({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  static const personasPath = 'assets/demo/personas.json';
  static const scamScriptPath = 'assets/demo/scam_script.json';
  static const fakeAppsPath = 'assets/demo/fake_apps.json';

  final AssetBundle _bundle;
  Future<Map<String, PersonaSeed>>? _personas;
  Future<List<Turn>>? _scamScript;
  Future<List<InstalledApp>>? _fakeApps;

  Future<PersonaSeed> persona(Persona p) async {
    final all = await personas();
    return all[p.uid] ??
        (throw StateError('$personasPath has no persona "${p.uid}"'));
  }

  /// The seed for [p] if it has already been loaded, else `null`.
  PersonaSeed? personaIfLoaded(Persona p) => _loaded?[p.uid];
  Map<String, PersonaSeed>? _loaded;

  Future<Map<String, PersonaSeed>> personas() => _personas ??= _loadPersonas();

  Future<Map<String, PersonaSeed>> _loadPersonas() async {
    final root = await _readJson(personasPath);
    final raw = requireObject(root, 'personas', (m) => m);
    final out = <String, PersonaSeed>{};
    for (final entry in raw.entries) {
      out[entry.key] = PersonaSeed.fromJson(
        (entry.value as Map).cast<String, dynamic>(),
      );
    }
    return _loaded = Map.unmodifiable(out);
  }

  /// The fake customer-care call the demo panel replays.
  Future<List<Turn>> scamScript() => _scamScript ??= _loadScamScript();

  Future<List<Turn>> _loadScamScript() async {
    final raw = jsonDecode(await _bundle.loadString(scamScriptPath));
    return List.unmodifiable(
      (raw as List)
          .map((t) => Turn.fromJson((t as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  /// The TakaNow entry merged into the app-safety bundle on the emulator.
  Future<List<InstalledApp>> fakeApps() => _fakeApps ??= _loadFakeApps();

  Future<List<InstalledApp>> _loadFakeApps() async {
    final raw = jsonDecode(await _bundle.loadString(fakeAppsPath));
    return List.unmodifiable(
      (raw as List)
          .map((a) => InstalledApp.fromJson((a as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  Future<Map<String, dynamic>> _readJson(String path) async {
    final raw = jsonDecode(await _bundle.loadString(path));
    return (raw as Map).cast<String, dynamic>();
  }
}
