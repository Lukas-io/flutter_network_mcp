import 'package:flutter_network_mcp/src/vm/vm_uri.dart';
import 'package:test/test.dart';

void main() {
  test('the DTD ws form and the printed http form name the same VM', () {
    const printed = 'http://127.0.0.1:55498/bx6x-q8euTU=/';
    expect(canonicalVmServiceUri('ws://127.0.0.1:55498/bx6x-q8euTU=/ws'), printed);
    expect(canonicalVmServiceUri('http://127.0.0.1:55498/bx6x-q8euTU='), printed);
    expect(canonicalVmServiceUri(printed), printed);
    expect(canonicalVmServiceUri('wss://h:1/t=/ws'), 'https://h:1/t=/');
  });

  test('something that is not a URI comes back trimmed', () {
    expect(canonicalVmServiceUri(' not a uri '), 'not a uri');
  });
}
