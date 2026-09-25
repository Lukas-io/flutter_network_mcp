import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import '../state/log_buffer.dart';
import '../storage/captures_db.dart';
import 'log_stream.dart' show logDedupHash;

/// The device's own log for the attached app — `simctl log stream` on an iOS
/// simulator, `adb logcat` on Android — so native SDK output (analytics,
/// crash reporting) is at least readable next to the Dart log. Records enter
/// the same ring and table as Dart records with `source: "native"`.
class NativeLogSource {
  io.Process? _proc;
  StreamSubscription<String>? _sub;
  StreamSubscription<String>? _errSub;

  /// How it started, or why it could not. Surfaced by attach and status.
  String? detail;

  /// `ios` or `android` once started.
  String? platform;

  bool get isActive => _proc != null;

  /// Starts streaming for the app named [appName] (the DTD name, which
  /// carries `Device:` and `Package:`). Returns false with [detail] set when
  /// the device or tool cannot be found; never throws.
  Future<bool> start({
    required String? appName,
    required LogBuffer buffer,
    required int? Function() sessionIdProvider,
  }) async {
    if (isActive) await stop();
    final parsed = parseAppName(appName);
    final device = parsed.device;
    final package = parsed.package;
    if (device == null) {
      detail = 'the DTD app name carries no "Device:" — cannot pick a device to stream from';
      return false;
    }
    try {
      final List<String> cmd;
      if (looksLikeIos(device)) {
        final udid = await resolveSimulatorUdid(device);
        if (udid == null) {
          detail = 'no booted iOS simulator named "$device"';
          return false;
        }
        platform = 'ios';
        final predicate = package == null
            ? 'process == "Runner"'
            : 'process == "Runner" OR processImagePath CONTAINS[c] "$package"';
        cmd = ['xcrun', 'simctl', 'spawn', udid, 'log', 'stream', '--style', 'compact', '--predicate', predicate];
        detail = 'simctl log stream on $device ($udid), predicate: $predicate';
      } else {
        final serial = await resolveAndroidSerial(device);
        if (serial == null) {
          detail = 'no connected Android device matching "$device"';
          return false;
        }
        platform = 'android';
        final pid = package == null ? null : await resolveAndroidPid(serial, package);
        cmd = ['adb', '-s', serial, 'logcat', '-v', 'time', if (pid != null) '--pid=$pid'];
        detail = pid != null
            ? 'adb logcat on $serial, pid $pid'
            : 'adb logcat on $serial, unfiltered (no process found for "$package")';
      }
      final proc = await io.Process.start(cmd.first, cmd.sublist(1));
      _proc = proc;
      final dao = CapturesDao();
      void handle(String line) {
        final rec = platform == 'ios' ? parseSimctlLine(line) : parseLogcatLine(line);
        if (rec == null) return;
        final ts = DateTime.now().millisecondsSinceEpoch;
        buffer.push(
          source: 'native',
          timestampMs: ts,
          level: rec.level,
          loggerName: rec.logger,
          message: rec.message,
        );
        final sid = sessionIdProvider();
        if (sid == null) return;
        try {
          dao.insertLog(
            sessionId: sid,
            timestampMs: ts,
            source: 'native',
            level: rec.level,
            logger: rec.logger,
            message: rec.message,
            dedupKey: 'native:${logDedupHash(line)}',
          );
        } catch (_) {/* DB may be closing */}
      }

      _sub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(handle, onDone: () => _proc = null);
      _errSub = proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) {
        if (l.trim().isNotEmpty) detail = '$detail; stderr: ${l.trim()}';
      });
      unawaited(proc.exitCode.then((_) => _proc = null));
      return true;
    } on io.ProcessException catch (e) {
      detail = 'cannot run ${e.executable}: ${e.message}';
      return false;
    } on Object catch (e) {
      detail = 'native log stream failed to start: $e';
      return false;
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await _errSub?.cancel();
    _sub = null;
    _errSub = null;
    final p = _proc;
    _proc = null;
    if (p != null) {
      try {
        p.kill();
      } on Object {
        // already gone
      }
    }
  }

  /// `Device:` and `Package:` from a DTD app name.
  static ({String? device, String? package}) parseAppName(String? appName) {
    if (appName == null) return (device: null, package: null);
    final device =
        RegExp(r'Device:\s*(.+?)\s*(?:-\s*\w+:|$)').firstMatch(appName)?.group(1)?.trim();
    final package =
        RegExp(r'Package:\s*(.+?)\s*(?:-\s*\w+:|$)').firstMatch(appName)?.group(1)?.trim();
    return (device: device, package: package);
  }

  static bool looksLikeIos(String device) {
    final d = device.toLowerCase();
    return d.contains('iphone') || d.contains('ipad') || d.contains('ipod') || d.contains('ios') || d.contains('apple');
  }

  /// Booted simulator whose name matches [deviceName] (case-insensitive,
  /// exact first, then prefix).
  static Future<String?> resolveSimulatorUdid(String deviceName) async {
    try {
      final r = await io.Process.run('xcrun', ['simctl', 'list', 'devices', 'booted', '-j']);
      if (r.exitCode != 0) return null;
      return udidFromSimctlJson(r.stdout as String, deviceName);
    } on Object {
      return null;
    }
  }

  static String? udidFromSimctlJson(String json, String deviceName) {
    final want = deviceName.toLowerCase();
    try {
      final decoded = jsonDecode(json);
      final devices = (decoded as Map)['devices'] as Map;
      String? prefix;
      for (final list in devices.values) {
        for (final d in list as List) {
          final m = d as Map;
          if (m['state'] != 'Booted') continue;
          final name = (m['name'] as String? ?? '').toLowerCase();
          if (name == want) return m['udid'] as String?;
          if (prefix == null && name.startsWith(want)) prefix = m['udid'] as String?;
        }
      }
      return prefix;
    } on Object {
      return null;
    }
  }

  /// Serial of the connected Android device whose model matches [deviceName].
  static Future<String?> resolveAndroidSerial(String deviceName) async {
    try {
      final r = await io.Process.run('adb', ['devices', '-l']);
      if (r.exitCode != 0) return null;
      return serialFromAdbDevices(r.stdout as String, deviceName);
    } on Object {
      return null;
    }
  }

  static String? serialFromAdbDevices(String text, String deviceName) {
    final want = deviceName.toLowerCase().replaceAll('_', ' ');
    String? only;
    var count = 0;
    for (final line in text.split('\n').skip(1)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2 || parts[1] != 'device') continue;
      count++;
      only = parts[0];
      for (final p in parts.skip(2)) {
        if (p.startsWith('model:') &&
            p.substring(6).toLowerCase().replaceAll('_', ' ') == want) {
          return parts[0];
        }
      }
    }
    return count == 1 ? only : null;
  }

  /// The running process whose application id contains [package].
  static Future<int?> resolveAndroidPid(String serial, String package) async {
    try {
      final pm = await io.Process.run('adb', ['-s', serial, 'shell', 'pm', 'list', 'packages']);
      final needle = package.toLowerCase().replaceAll('_', '');
      final ids = (pm.stdout as String)
          .split('\n')
          .map((l) => l.trim().replaceFirst('package:', ''))
          .where((id) => id.toLowerCase().replaceAll('_', '').contains(needle))
          .toList();
      for (final id in ids) {
        final r = await io.Process.run('adb', ['-s', serial, 'shell', 'pidof', '-s', id]);
        final pid = int.tryParse((r.stdout as String).trim());
        if (pid != null) return pid;
      }
      return null;
    } on Object {
      return null;
    }
  }

  /// `--style compact` line: `<date> <time> <type> <process>[pid:tid] [sub:cat] msg`.
  static ({int level, String logger, String message})? parseSimctlLine(String line) {
    final m = RegExp(r'^\S+ \S+ (\S+) (\S+?)\[\d+:[0-9a-fA-F]+\] (?:\[([^\]]*)\] )?(.*)$')
        .firstMatch(line);
    if (m == null) return null;
    final type = m.group(1)!;
    final level = switch (type[0]) {
      'F' => 1200,
      'E' => 1000,
      'I' => 800,
      _ => 500,
    };
    final logger = m.group(3) != null ? '${m.group(2)} ${m.group(3)}' : m.group(2)!;
    return (level: level, logger: logger, message: m.group(4) ?? '');
  }

  /// `-v time` line: `MM-DD HH:MM:SS.mmm L/Tag( pid): msg`.
  static ({int level, String logger, String message})? parseLogcatLine(String line) {
    final m = RegExp(r'^\S+ \S+ ([VDIWEF])/([^(]+)\(\s*\d+\): (.*)$').firstMatch(line);
    if (m == null) return null;
    final level = switch (m.group(1)) {
      'F' => 1200,
      'E' => 1000,
      'W' => 900,
      'I' => 800,
      _ => 500,
    };
    return (level: level, logger: m.group(2)!.trim(), message: m.group(3) ?? '');
  }
}
