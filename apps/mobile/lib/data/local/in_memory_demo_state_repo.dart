import 'dart:async';
import 'dart:convert';

import 'package:bhorosha/core/log.dart';
import 'package:bhorosha/data/repos/repos.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Demo state without Firestore: current value replayed to new listeners,
/// writes broadcast, everything mirrored to SharedPreferences under
/// `demo_state/<uid>` so a restart keeps the simulated world.
class InMemoryDemoStateRepo implements DemoStateRepo {
  InMemoryDemoStateRepo({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance();

  static const _tag = 'demo_state';
  static String keyFor(String uid) => 'demo_state/$uid';

  final Future<SharedPreferences> _prefs;
  final _current = <String, DemoState>{};
  final _controllers = <String, StreamController<DemoState>>{};

  StreamController<DemoState> _controller(String uid) =>
      _controllers.putIfAbsent(uid, StreamController<DemoState>.broadcast);

  @override
  Stream<DemoState> watch(String uid) => Stream.multi((emitter) async {
    final sub = _controller(uid).stream.listen(emitter.add);
    emitter.onCancel = sub.cancel;
    final state = await _load(uid);
    if (!emitter.isClosed) emitter.add(state);
  });

  /// The value a new listener gets first; loads once per uid.
  Future<DemoState> _load(String uid) async {
    final cached = _current[uid];
    if (cached != null) return cached;
    var loaded = DemoState.initial;
    try {
      final raw = (await _prefs).getString(keyFor(uid));
      if (raw != null) {
        loaded = DemoState.fromDoc(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
        );
      }
    } on Object catch (e) {
      Log.w(_tag, 'ignoring unreadable stored state for $uid', e);
    }
    // A write may have landed while we were reading; it wins.
    return _current.putIfAbsent(uid, () => loaded);
  }

  @override
  Future<void> write(String uid, DemoState s) async {
    _current[uid] = s;
    _controller(uid).add(s);
    try {
      await (await _prefs).setString(keyFor(uid), jsonEncode(s.toDoc()));
    } on Object catch (e) {
      Log.w(_tag, 'could not persist state for $uid', e);
    }
  }

  @override
  Future<void> reset(String uid) => write(uid, DemoState.initial);

  Future<void> dispose() async {
    for (final c in _controllers.values) {
      await c.close();
    }
    _controllers.clear();
  }
}
