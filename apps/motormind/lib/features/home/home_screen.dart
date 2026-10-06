import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../advisor/advisor_surface.dart';
import '../advisor/stage_view.dart';

/// Placeholder home: the content area above, the advisor surface below.
/// Everything here is replaced as VA-2 and VA-11 land.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Motormind AI'),
        actions: [
          IconButton(
            key: const Key('home-models'),
            tooltip: 'Models',
            icon: const Icon(Icons.memory_outlined),
            onPressed: () => context.push(Routes.models),
          ),
          IconButton(
            key: const Key('home-disclosures'),
            tooltip: 'Disclosures',
            icon: const Icon(Icons.policy_outlined),
            onPressed: () => context.push(Routes.disclosures),
          ),
        ],
      ),
      body: const AdvisorSurfaceHost(content: StageView()),
    );
  }
}
