import 'package:flutter/material.dart';

import '../widgets/inner_background.dart';

/// Notification inbox. Push messages are delivered by the OS / in-app banner;
/// until the backend exposes an inbox endpoint this shows an honest empty
/// state instead of placeholder items (store review rejects fake content).
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: Stack(
        children: [
          const BackgroundWidget(intensity: .4, animate: false),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: cs.primary.withValues(alpha: .12),
                    child: Icon(Icons.notifications_none_rounded, size: 36, color: cs.primary),
                  ),
                  const SizedBox(height: 16),
                  Text("You're all caught up", style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text(
                    'Trip, delivery and wallet updates will appear here.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
