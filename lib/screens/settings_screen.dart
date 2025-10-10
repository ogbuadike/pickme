import 'package:flutter/material.dart';
import '../themes/app_theme.dart';
import '../widgets/inner_background.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notifications = true;
  bool _shareTrip = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Stack(
        children: [
          const BackgroundWidget(intensity: .35, animate: true),
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _switch('Notifications', _notifications, (v) {
                setState(() => _notifications = v);
              }),
              const SizedBox(height: 8),
              _switch('Share live trip with contacts', _shareTrip, (v) {
                setState(() => _shareTrip = v);
              }),
              const SizedBox(height: 8),
              ListTile(
                tileColor: AppColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: AppColors.mintBgLight),
                ),
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('Privacy & Safety',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {},
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _switch(String title, bool value, ValueChanged<bool> onChanged) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.mintBgLight),
      ),
      child: SwitchListTile(
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
