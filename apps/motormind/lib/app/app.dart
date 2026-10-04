import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme.dart';

class MotormindApp extends ConsumerWidget {
  const MotormindApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Motormind AI',
      theme: motormindTheme(Brightness.light),
      darkTheme: motormindTheme(Brightness.dark),
      routerConfig: router,
    );
  }
}
