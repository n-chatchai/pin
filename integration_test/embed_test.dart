// On-device vector embeddings: the bundled e5-small model loads through the Rust
// ort runtime and produces semantically meaningful Thai vectors — a related
// query scores higher cosine than an unrelated one. No network, no login;
// plaintext never leaves the device. (Android only; iOS ships no ort runtime.)
//   flutter test integration_test/embed_test.dart -d <android-device>
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:pin/agent/embedder.dart';
import 'package:pin/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('e5 embeddings rank related text above unrelated', (tester) async {
    await RustLib.init();
    final e = Embedder.instance;

    final passage = await e.embedPassage('แมวเป็นสัตว์เลี้ยงที่น่ารักและขี้อ้อน');
    expect(e.ready, true, reason: 'model must load (arm64 onnxruntime present)');
    expect(passage, isNotNull, reason: 'passage must embed');
    print('DIM=${passage!.length} ready=${e.ready}');

    final related = await e.embedQuery('สัตว์เลี้ยงในบ้าน');
    final unrelated = await e.embedQuery('การเขียนโปรแกรมคอมพิวเตอร์');
    expect(related, isNotNull);
    expect(unrelated, isNotNull);

    final simRel = cosine(passage, related!);
    final simUnrel = cosine(passage, unrelated!);
    print('simRelated=$simRel simUnrelated=$simUnrel');
    expect(simRel, greaterThan(simUnrel),
        reason: 'semantic recall: pet query must beat code query');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
