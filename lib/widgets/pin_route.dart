import 'package:flutter/cupertino.dart';

/// Page push that keeps the iOS interactive edge-swipe-back gesture (so a user
/// is never trapped on a pushed screen) with a clean slide transition and no
/// Material chrome. Built on [CupertinoPageRoute] — Cupertino, not Material —
/// which provides the back-swipe for free. Drop-in for MaterialPageRoute.
Route<T> pinRoute<T>(Widget page) =>
    CupertinoPageRoute<T>(builder: (_) => page);
