// lib/widgets/suggestion_list.dart
// Fast, simple list (caps at 12). Uses ListView.separated for smoothness.

import 'package:flutter/material.dart';
import '../themes/app_theme.dart';
import '../screens/state/home_models.dart';

class SuggestionList extends StatelessWidget {
  static const int _kMaxShow = 12;

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
    final sliced = suggestions.length > _kMaxShow
        ? suggestions.sublist(0, _kMaxShow)
        : suggestions;

    final items = <_RowItem>[];
    if (showUseCurrent) items.add(const _RowItem.current());
    for (final s in sliced) {
      final isRecent = recents.any((r) => r.placeId == s.placeId);
      items.add(_RowItem.suggestion(s, isRecent));
    }

    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text(
            'Start typing to search streets and places',
            style: TextStyle(color: Color(0xFF7A7A7A)),
          ),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      separatorBuilder: (_, __) => Divider(color: AppColors.mintBgLight, height: 1),
      itemBuilder: (context, i) {
        final it = items[i];
        if (it.isCurrent) {
          return ListTile(
            leading: const Icon(Icons.my_location_rounded, color: AppColors.primary),
            title: const Text('Use current location', style: TextStyle(fontWeight: FontWeight.w700)),
            onTap: onUseCurrentTap,
          );
        }
        final s = it.suggestion!;
        return ListTile(
          dense: true,
          leading: Icon(
            it.isRecent ? Icons.history_rounded : Icons.place_outlined,
            color: AppColors.primary,
          ),
          title: Text(s.mainText, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: s.secondaryText.isNotEmpty
              ? Text(s.secondaryText, maxLines: 1, overflow: TextOverflow.ellipsis)
              : null,
          trailing: s.distanceMeters != null
              ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.mintBgLight,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(fmtDistance(s.distanceMeters!),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          )
              : const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          onTap: () => onTap(s),
        );
      },
    );
  }
}

class _RowItem {
  final bool isCurrent;
  final bool isRecent;
  final Suggestion? suggestion;
  const _RowItem.current()
      : isCurrent = true,
        isRecent = false,
        suggestion = null;
  const _RowItem.suggestion(this.suggestion, this.isRecent) : isCurrent = false;
}
