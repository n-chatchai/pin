import 'package:flutter_test/flutter_test.dart';
import 'package:pin/services/shared_inbox.dart';

void main() {
  group('classifyShared', () {
    test('shared URL/text → text kind', () {
      final u = classifyShared(
          typeName: 'url', path: 'https://youtu.be/aqz-KE-bpKQ');
      expect(u.kind, SharedKind.text);
      expect(u.value, 'https://youtu.be/aqz-KE-bpKQ');

      final t = classifyShared(typeName: 'text', path: 'สรุปให้หน่อย');
      expect(t.kind, SharedKind.text);
    });

    test('image type → image kind', () {
      final i = classifyShared(typeName: 'image', path: '/tmp/photo.jpg');
      expect(i.kind, SharedKind.image);
      expect(i.value, '/tmp/photo.jpg');
    });

    test('image shared as generic file → re-routed to image', () {
      final byExt = classifyShared(typeName: 'file', path: '/tmp/pic.PNG');
      expect(byExt.kind, SharedKind.image);

      final byMime = classifyShared(
          typeName: 'file', path: '/tmp/blob', mimeType: 'image/jpeg');
      expect(byMime.kind, SharedKind.image);
    });

    test('document → file kind carries a name', () {
      final f = classifyShared(typeName: 'file', path: '/tmp/docs/report.pdf');
      expect(f.kind, SharedKind.file);
      expect(f.name, 'report.pdf');
    });
  });

  group('SharedInbox', () {
    test('addAll skips blanks, drain empties + is FIFO', () {
      final box = SharedInbox.instance;
      box.drain(); // clean slate
      final before = box.revision.value;

      box.addAll([
        const SharedItem(SharedKind.text, '  '), // blank → skipped
        const SharedItem(SharedKind.text, 'first'),
        const SharedItem(SharedKind.image, '/a.jpg'),
      ]);

      expect(box.hasPending, isTrue);
      expect(box.revision.value, before + 1);

      final drained = box.drain();
      expect(drained.map((e) => e.value), ['first', '/a.jpg']);
      expect(box.hasPending, isFalse);
      expect(box.drain(), isEmpty);
    });

    test('addAll of only-blanks does not bump revision', () {
      final box = SharedInbox.instance;
      box.drain();
      final before = box.revision.value;
      box.addAll([const SharedItem(SharedKind.text, '')]);
      expect(box.revision.value, before);
    });
  });
}
