import 'package:flutter_network_mcp/src/tools/network_attach.dart';
import 'package:test/test.dart';

/// Issue #16: the logical-app identity used to recognise the same app across
/// hot restarts (which rotate the VM service URI). Same package + device =
/// same session, regardless of URI.
void main() {
  group('appSessionIdentity', () {
    test('parses package + device from the DTD app-name shape', () {
      const name =
          'Kind: Flutter - Device: iPhone 16 Pro - Package: roqquapp';
      expect(appSessionIdentity(name), 'roqquapp@iphone 16 pro');
    });

    test('two restarts of the same app share an identity', () {
      const a = 'Kind: Flutter - Device: iPhone 16 Pro - Package: roqquapp';
      const b = 'Kind: Flutter - Device: iPhone 16 Pro - Package: roqquapp';
      expect(appSessionIdentity(a), appSessionIdentity(b));
    });

    test('same package on different devices are different identities', () {
      const pro = 'Kind: Flutter - Device: iPhone 16 Pro - Package: roqquapp';
      const reg = 'Kind: Flutter - Device: iPhone 16 - Package: roqquapp';
      expect(appSessionIdentity(pro), isNot(appSessionIdentity(reg)),
          reason: 'iPhone 16 Pro must not collapse into iPhone 16');
    });

    test('different packages on the same device are different identities', () {
      const a = 'Kind: Flutter - Device: iPhone 16 Pro - Package: roqquapp';
      const b = 'Kind: Flutter - Device: iPhone 16 Pro - Package: otherapp';
      expect(appSessionIdentity(a), isNot(appSessionIdentity(b)));
    });

    test('is case-insensitive', () {
      const a = 'Kind: Flutter - Device: iPhone 16 Pro - Package: RoqquApp';
      const b = 'Kind: Flutter - Device: iphone 16 pro - Package: roqquapp';
      expect(appSessionIdentity(a), appSessionIdentity(b));
    });

    test('falls back to the whole name when the shape does not match', () {
      expect(appSessionIdentity('my custom app'), 'my custom app');
    });

    test('null / empty returns null', () {
      expect(appSessionIdentity(null), isNull);
      expect(appSessionIdentity(''), isNull);
      expect(appSessionIdentity('   '), isNull);
    });
  });
}
