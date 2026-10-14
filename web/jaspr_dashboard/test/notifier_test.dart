import 'package:juice/juice.dart';
import 'package:test/test.dart';

void main() {
  test('notifications suppress equal values and observe the current value', () {
    final notifier = ValueNotifier(0);
    final values = <int>[];
    notifier.addListener(() => values.add(notifier.value));
    notifier.value = 0;
    notifier.value = 1;
    notifier.value = 1;
    expect(values, [1]);
    notifier.dispose();
  });

  test(
    'removal during dispatch skips listeners, additions wait for next dispatch',
    () {
      final notifier = ValueNotifier(0);
      final calls = <String>[];
      void removed() => calls.add('removed');
      void added() => calls.add('added');
      notifier.addListener(() {
        calls.add('first');
        notifier.removeListener(removed);
        notifier.addListener(added);
      });
      notifier.addListener(removed);
      notifier.value = 1;
      expect(calls, ['first']);
      calls.clear();
      notifier.value = 2;
      expect(calls, ['first', 'added']);
      notifier.dispose();
    },
  );

  test('reentrant dispatch retains all existing listeners', () {
    final notifier = ValueNotifier(0);
    final values = <int>[];
    notifier.addListener(() {
      if (notifier.value == 1) notifier.value = 2;
    });
    notifier.addListener(() => values.add(notifier.value));
    notifier.value = 1;
    expect(values, [2, 2]);
    notifier.dispose();
  });
}
