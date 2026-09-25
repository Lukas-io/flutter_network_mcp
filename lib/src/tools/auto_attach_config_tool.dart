import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/auto_attach_config.dart';
import 'error_kind.dart';
import 'result.dart';

final autoAttachConfigTool = Tool(
  name: 'auto_attach_config',
  description:
      'Read or persist the auto-attach allowlist at '
      '<data-dir>/auto-attach.json. Lets the agent honor an '
      'autoAttachSuggestion without the user editing shell rc (confirm '
      'first, then action:"add").',
  inputSchema: Schema.object(
    properties: {
      'action': Schema.string(
        description:
            '"list" (default), "add", "remove", "clear", "set" (persist '
            'logBufferSize / nativeLogs for every attach, auto or manual).',
      ),
      'logBufferSize': Schema.int(
        description:
            'With action:"set": log ring capacity for every attach '
            '(50–20000). Default 2000.',
      ),
      'nativeLogs': Schema.bool(
        description:
            'With action:"set": also stream the device\'s native log '
            '(simctl log stream / adb logcat) into every attach.',
      ),
      'app': Schema.string(
        description:
            'Allowlist pattern (case-insensitive substring of the app name, '
            'e.g. "eats_mobile"). Required for add/remove.',
      ),
      'deny': Schema.string(
        description: 'Denylist pattern to add alongside app (rare).',
      ),
    },
  ),
);

FutureOr<CallToolResult> autoAttachConfig(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final action = (args['action'] as String?) ?? 'list';
  final app = args['app'] as String?;
  final deny = args['deny'] as String?;

  switch (action) {
    case 'list':
      return _list();
    case 'add':
      return _add(app: app, deny: deny);
    case 'remove':
      return _remove(app: app);
    case 'clear':
      return _clear();
    case 'set':
      return _set(args);
    default:
      return errorResult(
        'auto_attach_config: unknown action "$action". Expected '
        'list | add | remove | clear | set.',
        kind: ErrorKind.badArgument,
      );
  }
}

CallToolResult _set(Map<String, Object?> args) {
  final size = args['logBufferSize'] as int?;
  final native = args['nativeLogs'] as bool?;
  if (size == null && native == null) {
    return errorResult(
      'auto_attach_config set: pass logBufferSize and/or nativeLogs.',
      kind: ErrorKind.badArgument,
      extra: const {
        'nextSteps': ['auto_attach_config action:"set" logBufferSize:8000'],
      },
    );
  }
  if (size != null && (size < 50 || size > 20000)) {
    return errorResult(
      'logBufferSize must be between 50 and 20000.',
      kind: ErrorKind.badArgument,
    );
  }
  AutoAttachConfig.set(
    allowed: AutoAttachConfig.allowedPatterns,
    denied: AutoAttachConfig.deniedPatterns,
    logBufferSize: size,
    nativeLogs: native,
  );
  final wrote = AutoAttachConfig.writeToFile();
  return jsonResult({
    'action': 'set',
    if (size != null) 'logBufferSize': size,
    if (native != null) 'nativeLogs': native,
    'persisted': wrote,
    'filePath': AutoAttachConfig.filePath(),
    'summary': 'Applies to the next attach (auto or manual); sessions already '
        'attached keep their current buffer.',
    'nextSteps': [
      if (!wrote) 'persistence failed — in memory for this process only',
      'network_status — logBufferCapacity per attached session',
    ],
  });
}

CallToolResult _list() {
  return jsonResult({
    'enabled': AutoAttachConfig.isEnabled,
    'allowed': AutoAttachConfig.allowedPatterns,
    'denied': AutoAttachConfig.deniedPatterns,
    if (AutoAttachConfig.logBufferSize != null)
      'logBufferSize': AutoAttachConfig.logBufferSize,
    if (AutoAttachConfig.nativeLogs) 'nativeLogs': true,
    'filePath': AutoAttachConfig.filePath(),
    'nextSteps': const [
      'auto_attach_config action:"add" app:"<package>" — persist a new '
          'allowlist entry. Confirm with the user before calling.',
    ],
  });
}

CallToolResult _add({required String? app, required String? deny}) {
  if (app == null || app.isEmpty) {
    return errorResult(
      'auto_attach_config add: `app` is required.',
      kind: ErrorKind.badArgument,
      extra: const {
        'nextSteps': [
          'auto_attach_config action:"add" app:"eats_mobile"',
        ],
      },
    );
  }
  final current = AutoAttachConfig.allowedPatterns.toList();
  final alreadyPresent = current.any(
    (p) => p.toLowerCase() == app.toLowerCase(),
  );
  if (!alreadyPresent) current.add(app);

  final currentDeny = AutoAttachConfig.deniedPatterns.toList();
  if (deny != null && deny.isNotEmpty &&
      !currentDeny.any((d) => d.toLowerCase() == deny.toLowerCase())) {
    currentDeny.add(deny);
  }

  AutoAttachConfig.set(allowed: current, denied: currentDeny);
  final wrote = AutoAttachConfig.writeToFile();
  return jsonResult({
    'action': 'add',
    'app': app,
    'alreadyPresent': alreadyPresent,
    'allowed': AutoAttachConfig.allowedPatterns,
    'denied': AutoAttachConfig.deniedPatterns,
    'persisted': wrote,
    'filePath': AutoAttachConfig.filePath(),
    'nextSteps': [
      if (!wrote)
        'persistence failed (filesystem error) — config is in memory '
            'for this session only; check write permissions on filePath',
      if (wrote)
        'Tell the user: "$app" added to auto-attach. Effective on next '
            'MCP-host restart unless an env var or CLI flag overrides.',
      'auto_attach_config action:"list" — verify current state',
    ],
  });
}

CallToolResult _remove({required String? app}) {
  if (app == null || app.isEmpty) {
    return errorResult(
      'auto_attach_config remove: `app` is required.',
      kind: ErrorKind.badArgument,
    );
  }
  final current = AutoAttachConfig.allowedPatterns.toList();
  final lowerApp = app.toLowerCase();
  final before = current.length;
  current.removeWhere((p) => p.toLowerCase() == lowerApp);
  final removed = current.length < before;
  AutoAttachConfig.set(
    allowed: current,
    denied: AutoAttachConfig.deniedPatterns.toList(),
  );
  final wrote = AutoAttachConfig.writeToFile();
  return jsonResult({
    'action': 'remove',
    'app': app,
    'removed': removed,
    'allowed': AutoAttachConfig.allowedPatterns,
    'denied': AutoAttachConfig.deniedPatterns,
    'persisted': wrote,
    'filePath': AutoAttachConfig.filePath(),
    'nextSteps': [
      if (!removed)
        'No matching entry to remove. Existing allowlist: '
            '${current.join(", ")}',
      if (removed)
        'Effective on next MCP-host restart unless overridden by env / flag.',
    ],
  });
}

CallToolResult _clear() {
  AutoAttachConfig.set(allowed: const [], denied: const []);
  final wrote = AutoAttachConfig.writeToFile();
  return jsonResult({
    'action': 'clear',
    'allowed': const <String>[],
    'denied': const <String>[],
    'persisted': wrote,
    'filePath': AutoAttachConfig.filePath(),
    'nextSteps': const [
      'Effective on next MCP-host restart unless overridden by env / flag.',
    ],
  });
}
