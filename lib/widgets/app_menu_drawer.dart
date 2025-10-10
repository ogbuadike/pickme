// lib/widgets/app_menu_drawer.dart
import 'package:flutter/material.dart';
import '../routes/routes.dart';
import '../themes/app_theme.dart';

class AppMenuDrawer extends StatelessWidget {
  const AppMenuDrawer({super.key, required this.user});
  final Map<String, dynamic>? user;

  @override
  Widget build(BuildContext context) {
    final avatar = (user?['user_logo'] as String?) ??
        'https://icon-library.com/images/icon-avatar/icon-avatar-6.jpg';
    final name = user?['user_lname'] ?? user?['user_name'] ?? 'User';
    final email = (user?['user_email'] as String?) ?? '';

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: CircleAvatar(radius: 28, backgroundImage: NetworkImage(avatar)),
              title: Text(name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
              subtitle: Text(email, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: TextButton(
                onPressed: () => Navigator.pushNamed(context, AppRoutes.profile),
                child: const Text('View'),
              ),
            ),
            const Divider(),
            _item(context, Icons.local_taxi_rounded, 'Rides', AppRoutes.rideHistory),
            _item(context, Icons.payments_rounded, 'Payments', AppRoutes.payments),
            _item(context, Icons.notifications_active_outlined, 'Notifications', AppRoutes.notifications),
            _item(context, Icons.card_giftcard_rounded, 'Offers', AppRoutes.offers),
            _item(context, Icons.receipt_long_rounded, 'Transactions', AppRoutes.transactions),
            _item(context, Icons.settings_rounded, 'Settings', AppRoutes.settings),
            _item(context, Icons.help_outline_rounded, 'Help & FAQ', AppRoutes.help),
            const Spacer(),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: AppColors.error),
              title: const Text('Sign out', style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w700)),
              onTap: () => Navigator.pushReplacementNamed(context, AppRoutes.login),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext c, IconData ic, String label, String route) => ListTile(
    leading: Icon(ic, color: AppColors.primary),
    title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    onTap: () => Navigator.pushNamed(c, route),
  );
}
