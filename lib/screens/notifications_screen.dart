import 'package:flutter/material.dart';
import '../themes/app_theme.dart';
import '../widgets/inner_background.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: Stack(
        children: [
          const BackgroundWidget(intensity: .4, animate: true),
          ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: 8,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => ListTile(
              tileColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: AppColors.mintBgLight),
              ),
              leading: CircleAvatar(
                backgroundColor: AppColors.primary.withOpacity(.12),
                child: const Icon(Icons.notifications),
              ),
              title: Text('Update #${i + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: const Text('Your trip and account updates appear here.'),
              trailing: const Icon(Icons.chevron_right),
            ),
          ),
        ],
      ),
    );
  }
}
