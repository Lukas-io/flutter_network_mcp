import 'dart:async';

import 'package:vm_service/vm_service.dart';

/// Longest a log record waits on the VM to expand one value before settling for its preview.
const instanceTextTimeout = Duration(seconds: 2);

/// The full text of [ref]: a string cut at the VM's 128-char preview is refetched, a non-string object is asked for its toString(); null for a null ref. When the VM cannot expand it, the preview comes back with a note saying how much was cut.
Future<String?> instanceText(
    VmService service, String? isolateId, InstanceRef? ref) async {
  if (ref == null || ref.kind == InstanceKind.kNull) return null;
  final preview = ref.valueAsString;
  final id = ref.id;
  final cut = ref.valueAsStringIsTruncated == true;
  if (isolateId != null && id != null) {
    try {
      if (ref.kind == InstanceKind.kString) {
        if (!cut) return preview;
        final full = await service
            .getObject(isolateId, id, offset: 0, count: ref.length)
            .timeout(instanceTextTimeout);
        if (full is Instance && full.valueAsString != null) {
          return full.valueAsString;
        }
      } else if (preview == null || cut) {
        final text = await service
            .invoke(isolateId, id, 'toString', const [])
            .timeout(instanceTextTimeout);
        if (text is InstanceRef && text.kind == InstanceKind.kString) {
          return await instanceText(service, isolateId, text);
        }
      } else {
        return preview;
      }
    } on Object {
      // collected, timed out, or toString threw: fall back to the preview
    }
  }
  if (preview == null) return ref.classRef?.name;
  if (!cut) return preview;
  final total = ref.length;
  return '$preview… [cut by the VM at ${preview.length}'
      '${total == null ? '' : ' of $total'} chars]';
}
