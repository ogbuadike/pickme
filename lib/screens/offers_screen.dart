import 'package:flutter/material.dart';
import '../themes/app_theme.dart';
import '../widgets/inner_background.dart';

class OffersScreen extends StatelessWidget {
  const OffersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = TextEditingController();
    return Scaffold(
      appBar: AppBar(title: const Text('Offers & Promo')),
      body: Stack(
        children: [
          const BackgroundWidget(intensity: .35, animate: true),
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: ctrl,
                decoration: InputDecoration(
                  hintText: 'Enter promo code',
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderSide: BorderSide(color: AppColors.mintBgLight),
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {},
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Apply'),
              ),
              const SizedBox(height: 16),
              _coupon(),
              const SizedBox(height: 10),
              _coupon(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _coupon() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.mintBgLight),
    ),
    child: const Text('10% off on your next ride • Valid till month end',
        style: TextStyle(fontWeight: FontWeight.w800)),
  );
}
