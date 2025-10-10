// lib/screens/home/widgets/suggestion_list.dart
// Reusable list of place suggestions, with optional "Use current location" row.

import 'package:flutter/material.dart';
import '../../../themes/app_theme.dart';
import '../screens/state/home_models.dart';

class SuggestionList extends StatelessWidget {
  final List<Suggestion> suggestions;
  final List<Suggestion> recents;
  final bool showUseCurrent;
  final VoidCallback? onUseCurrentTap;
  final void Function(Suggestion s) onTap;
  final String Function(int meters) fmtDistance;

  const SuggestionList({
    super.key,
    required this.suggestions,
    required this.recents,
    required this.showUseCurrent,
    required this.onUseCurrentTap,
    required this.onTap,
    required this.fmtDistance,
  });

  @override
  Widget build(BuildContext context) {
    final total = suggestions.length + (showUseCurrent ? 1 : 0);

    if (total == 0) {
      return Center(
        child: Text('Start typing to search streets and places',
            style: TextStyle(color: Colors.grey[600])),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: total,
      separatorBuilder: (_, __) =>
          Divider(color: AppColors.mintBgLight, height: 1),
      itemBuilder: (ctx, i) {
        if (showUseCurrent && i == 0) {
          return ListTile(
            leading:
            const Icon(Icons.my_location_rounded, color: AppColors.primary),
            title: const Text('Use current location',
                style: TextStyle(fontWeight: FontWeight.w700)),
            onTap: onUseCurrentTap,
          );
        }
        final s = suggestions[showUseCurrent ? i - 1 : i];
        final isRecent = recents.any((r) => r.placeId == s.placeId);
        return ListTile(
          leading: Icon(
            isRecent ? Icons.history_rounded : Icons.place_outlined,
            color: AppColors.primary,
          ),
          title: Text(s.mainText,
              style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle:
          s.secondaryText.isNotEmpty ? Text(s.secondaryText) : null,
          trailing: s.distanceMeters != null
              ? Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.mintBgLight,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(fmtDistance(s.distanceMeters!),
                  style:
                  const TextStyle(fontWeight: FontWeight.w700)))
              : const Icon(Icons.chevron_right_rounded,
              color: AppColors.textSecondary),
          onTap: () => onTap(s),
        );
      },
    );
  }
}
