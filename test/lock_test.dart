import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/lock.dart';

void main() {
  test('PIN hash verifies only the right PIN', () {
    final l = AppLock()
      ..salt = newSalt()
      ..hash = null;
    l.hash = hashPin('123456', l.salt!);
    expect(l.checkPin('123456'), isTrue);
    expect(l.checkPin('654321'), isFalse);
  });

  test('same PIN with different salt gives a different hash', () {
    expect(hashPin('123456', 'a'), isNot(hashPin('123456', 'b')));
  });
}
