// lib/screens/home/widgets/header_bar.dart
// Compact, reusable header (avatar + actions)

import 'package:flutter/material.dart';
import '../../../themes/app_theme.dart';

class HeaderBar extends StatelessWidget {
  final Map<String, dynamic>? user;
  final bool busyProfile;
  final VoidCallback onMenu;
  final VoidCallback onWallet;
  final VoidCallback onNotifications;

  const HeaderBar({
    super.key,
    required this.user,
    required this.busyProfile,
    required this.onMenu,
    required this.onWallet,
    required this.onNotifications,
  });

  @override
  Widget build(BuildContext context) {
    final name = user?['user_lname'] ?? user?['user_name'] ?? 'User';
    final avatar = user?['user_logo'] ??
        'https://icon-library.com/images/icon-avatar/icon-avatar-6.jpg';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          GestureDetector(
            onTap: onMenu,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  )
                ],
              ),
              child: CircleAvatar(radius: 22, backgroundImage: NetworkImage(avatar)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              children: [
                const Text('Hello, ',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                Flexible(
                  child: Text(name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w900)),
                ),
                if (busyProfile) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child:
                    CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          _roundHeaderBtn(
            icon: Icons.notifications_outlined,
            onTap: onNotifications,
          ),
          const SizedBox(width: 10),
          _roundHeaderBtn(
            icon: Icons.account_balance_wallet_outlined,
            onTap: onWallet,
          ),
        ],
      ),
    );
  }

  Widget _roundHeaderBtn({required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 8,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: AppColors.deep, size: 20),
        ),
      ),
    );
  }
}
