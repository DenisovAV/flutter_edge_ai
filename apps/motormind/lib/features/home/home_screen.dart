import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart';
import '../../app/router.dart';
import '../advisor/advisor_surface.dart';
import '../advisor/stage_view.dart';

/// Home: the stage above, the Motormind surface over it, and the three entry
/// points (captures, models, disclosures).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(appName),
        actions: [
          IconButton(
            key: const Key('open-captures'),
            tooltip: 'Captures and recipes',
            icon: const Icon(Icons.photo_camera_outlined),
            onPressed: () => context.push(Routes.captures),
          ),
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
