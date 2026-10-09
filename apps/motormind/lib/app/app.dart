import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme.dart';

/// The person-facing product name, used wherever the app names itself.
const appName = 'Motormind AI';

/// The root widget: theme, router and the disclosure gate behind it.
class MotormindApp extends ConsumerWidget {
  const MotormindApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: appName,
      theme: motormindTheme(Brightness.light),
      darkTheme: motormindTheme(Brightness.dark),
      routerConfig: router,
    );
  }
}
