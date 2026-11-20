// lib/screens/offers_screen.dart
//
// Promo codes are not supported by the backend yet (no endpoint). The screen
// validates input and says so honestly instead of a dead "Apply" button and
// fake coupons.
import 'package:flutter/material.dart';

import '../themes/app_theme.dart';
import '../widgets/inner_background.dart';

class OffersScreen extends StatefulWidget {
  const OffersScreen({super.key});

  @override
  State<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends State<OffersScreen> {
  final TextEditingController _ctrl = TextEditingController();
  String? _error;
  String? _info;

  static final RegExp _codeRe = RegExp(r'^[A-Z0-9]{4,16}$');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _apply() {
    FocusScope.of(context).unfocus();
    final String code = _ctrl.text.trim().toUpperCase();
    setState(() {
      if (!_codeRe.hasMatch(code)) {
        _error = 'Promo codes are 4-16 letters or digits.';
        _info = null;
      } else {
        _error = null;
        _info = 'Promo codes are not available yet. "$code" was not applied.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offers & Promo')),
      body: Stack(
        children: <Widget>[
          const BackgroundWidget(intensity: .35, animate: true),
          ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              TextField(
                controller: _ctrl,
                textCapitalization: TextCapitalization.characters,
                maxLength: 16,
                onSubmitted: (_) => _apply(),
                decoration: InputDecoration(
                  hintText: 'Enter promo code',
                  errorText: _error,
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
                onPressed: _apply,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Apply'),
              ),
              if (_info != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(_info!, style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.mintBgLight),
                ),
                child: const Text('No active offers right now. Check back soon.',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
