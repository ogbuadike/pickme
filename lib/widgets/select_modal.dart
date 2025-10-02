import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// AdvancedDropdownModal
/// - Single-select field with modal picker
/// - Works with List<Map<String, dynamic>>
/// - Keys: displayKey (required). Optionals: idKey, subtitleKey, logoKey, descriptionKey
/// - Extras: compact UI, recentItems, clear button, search with highlight & ranking
class AdvancedDropdownModal extends StatelessWidget {
  final String label;
  final Map<String, dynamic>? value;
  final List<Map<String, dynamic>> items;
  final ValueChanged<Map<String, dynamic>?> onChanged;
  final String displayKey;
  final String modalTitle;

  // Optional keys to enrich list rows
  final String idKey;
  final String? subtitleKey;
  final String? descriptionKey;
  final String? logoKey;

  // Extras
  final bool compact;
  final List<Map<String, dynamic>>? recentItems; // Shown as a short section at top if provided
  final bool allowClear; // Show clear (X) inside the field when a value is selected

  const AdvancedDropdownModal({
    Key? key,
    required this.label,
    this.value,
    required this.items,
    required this.onChanged,
    required this.displayKey,
    required this.modalTitle,
    this.idKey = 'id',
    this.subtitleKey,
    this.descriptionKey,
    this.logoKey,
    this.compact = false,
    this.recentItems,
    this.allowClear = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final bool hasValue = value != null && value![displayKey] != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: tt.labelLarge?.copyWith(
            color: cs.onSurfaceVariant,
            fontSize: compact ? 12 : 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Material(
          color: cs.surface,
          shape: StadiumBorder(
            side: BorderSide(color: cs.surfaceVariant),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(100),
            onTap: () => _showSelectionModal(context),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 12 : 14,
                vertical: compact ? 10 : 12,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      hasValue ? '${value![displayKey]}' : 'Select…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodyLarge?.copyWith(
                        color: hasValue ? cs.onSurface : cs.onSurfaceVariant,
                        fontWeight: hasValue ? FontWeight.w600 : FontWeight.w500,
                        fontSize: compact ? 13 : 14,
                      ),
                    ),
                  ),
                  if (hasValue && allowClear) ...[
                    IconButton(
                      tooltip: 'Clear',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onChanged(null),
                      icon: Icon(Icons.close_rounded, size: compact ? 18 : 20, color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Icon(Icons.arrow_drop_down_rounded, color: cs.onSurfaceVariant, size: compact ? 22 : 26),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showSelectionModal(BuildContext context) {
    HapticFeedback.selectionClick();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(.35),
      builder: (_) {
        return _SelectionSheet(
          title: modalTitle,
          items: items,
          recentItems: recentItems,
          onChanged: onChanged,
          displayKey: displayKey,
          idKey: idKey,
          subtitleKey: subtitleKey,
          descriptionKey: descriptionKey,
          logoKey: logoKey,
          compact: compact,
          initialValueId: value == null ? null : value![idKey],
        );
      },
    );
  }
}

/// Draggable, snapping selection sheet with search+highlight.
class _SelectionSheet extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>>? recentItems;
  final ValueChanged<Map<String, dynamic>?> onChanged;

  final String displayKey;
  final String idKey;
  final String? subtitleKey;
  final String? descriptionKey;
  final String? logoKey;

  final bool compact;
  final dynamic initialValueId;

  const _SelectionSheet({
    required this.title,
    required this.items,
    required this.onChanged,
    required this.displayKey,
    required this.idKey,
    this.subtitleKey,
    this.descriptionKey,
    this.logoKey,
    this.recentItems,
    required this.compact,
    this.initialValueId,
  });

  @override
  State<_SelectionSheet> createState() => _SelectionSheetState();
}

class _SelectionSheetState extends State<_SelectionSheet> {
  late List<Map<String, dynamic>> _filtered;
  final TextEditingController _searchCtl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _filtered = List<Map<String, dynamic>>.from(widget.items);
    _sort('', init: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 140), () {
      final query = q.trim().toLowerCase();
      setState(() {
        if (query.isEmpty) {
          _filtered = List<Map<String, dynamic>>.from(widget.items);
          _sort('', init: false);
        } else {
          _filtered = widget.items
              .where((m) => _matches(m, query))
              .toList(growable: false);
          _sort(query, init: false);
        }
      });
    });
  }

  bool _matches(Map<String, dynamic> item, String q) {
    bool hit(dynamic v) => v != null && v.toString().toLowerCase().contains(q);
    return hit(item[widget.displayKey]) ||
        (widget.subtitleKey != null && hit(item[widget.subtitleKey])) ||
        (widget.descriptionKey != null && hit(item[widget.descriptionKey])) ||
        hit(item['biller_name']) ||
        hit(item['name']);
  }

  void _sort(String q, {required bool init}) {
    // Weighted ranking: exact > startsWith > contains > others; then alpha
    int score(Map<String, dynamic> m) {
      final s = '${m[widget.displayKey] ?? ''}'.toLowerCase();
      if (q.isEmpty) return 0;
      if (s == q) return 0;
      if (s.startsWith(q)) return 1;
      if (s.contains(q)) return 2;
      return 3;
    }

    _filtered.sort((a, b) {
      final sa = score(a), sb = score(b);
      if (sa != sb) return sa - sb;
      final ad = '${a[widget.displayKey] ?? ''}'.toLowerCase();
      final bd = '${b[widget.displayKey] ?? ''}'.toLowerCase();
      return ad.compareTo(bd);
    });

    // Keep the current value near top initially
    if (init && widget.initialValueId != null) {
      final idx = _filtered.indexWhere((e) => e[widget.idKey] == widget.initialValueId);
      if (idx > 0) {
        final current = _filtered.removeAt(idx);
        _filtered.insert(0, current);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return SafeArea(
      top: false,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Material(
          color: cs.surface,
          child: DraggableScrollableSheet(
            initialChildSize: 0.6,
            minChildSize: 0.35,
            maxChildSize: 0.95,
            snap: true,
            snapSizes: const [0.4, 0.7, 0.95],
            builder: (context, controller) {
              return Column(
                children: [
                  // Grab handle
                  const SizedBox(height: 8),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Header
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),

                  // Search
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: TextField(
                      controller: _searchCtl,
                      focusNode: _searchFocus,
                      onChanged: _onSearchChanged,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search ${widget.title}…',
                        prefixIcon: Icon(Icons.search_rounded, color: cs.primary, size: widget.compact ? 20 : 22),
                        isDense: true,
                        filled: true,
                        fillColor: cs.surfaceVariant.withOpacity(.35),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderSide: BorderSide(color: cs.surfaceVariant),
                          borderRadius: BorderRadius.circular(28),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: cs.primary, width: 1.4),
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                    ),
                  ),

                  // List
                  Expanded(
                    child: _buildList(controller),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildList(ScrollController controller) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final hasRecents = (widget.recentItems != null && widget.recentItems!.isNotEmpty && _searchCtl.text.trim().isEmpty);

    return CustomScrollView(
      controller: controller,
      slivers: [
        if (hasRecents) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            sliver: SliverToBoxAdapter(
              child: Text('Recent', style: tt.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
            ),
          ),
          SliverList.builder(
            itemCount: widget.recentItems!.length,
            itemBuilder: (context, i) {
              final item = widget.recentItems![i];
              return _tile(item, isRecent: true);
            },
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            sliver: SliverToBoxAdapter(
              child: Text('All', style: tt.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
            ),
          ),
        ],

        if (_filtered.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.search_off_rounded, size: 40, color: cs.onSurfaceVariant),
                  const SizedBox(height: 6),
                  Text('No matches', style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: _filtered.length,
            itemBuilder: (context, i) => _tile(_filtered[i]),
          ),
      ],
    );
  }

  Widget _tile(Map<String, dynamic> item, {bool isRecent = false}) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isCompact = widget.compact;

    final titleRaw = '${item[widget.displayKey] ?? ''}';
    final subRaw = widget.subtitleKey == null ? '' : '${item[widget.subtitleKey] ?? ''}';
    final descRaw = widget.descriptionKey == null ? '' : '${item[widget.descriptionKey] ?? ''}';
    final query = _searchCtl.text.trim();

    final selected = widget.initialValueId != null && item[widget.idKey] == widget.initialValueId;

    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onChanged(item);
        Navigator.of(context).pop();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? cs.primary : cs.surfaceVariant, width: selected ? 1.4 : 1),
          boxShadow: [
            if (selected)
              BoxShadow(color: cs.primary.withOpacity(.12), blurRadius: 12, offset: const Offset(0, 4)),
          ],
        ),
        child: Row(
          children: [
            _leadingAvatar(item),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title with highlight
                  RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: _highlightSpan(context, titleRaw, query, base: tt.bodyLarge!, highlightColor: cs.primary),
                  ),
                  if (subRaw.isNotEmpty || descRaw.isNotEmpty)
                    Text(
                      subRaw.isNotEmpty ? subRaw : descRaw,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant, fontSize: isCompact ? 11 : 12),
                    ),
                  if (isRecent)
                    Text(
                      'Recent',
                      style: tt.labelSmall?.copyWith(color: cs.tertiary),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (selected)
              Icon(Icons.check_circle_rounded, color: cs.primary, size: isCompact ? 18 : 20)
            else
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant, size: isCompact ? 18 : 20),
          ],
        ),
      ),
    );
  }

  Widget _leadingAvatar(Map<String, dynamic> item) {
    final cs = Theme.of(context).colorScheme;
    final isCompact = widget.compact;
    final double r = isCompact ? 14 : 16;

    final logo = widget.logoKey == null ? null : item[widget.logoKey];
    return CircleAvatar(
      radius: r,
      backgroundColor: cs.primary,
      child: ClipOval(
        child: (logo is String && logo.isNotEmpty)
            ? Image.network(
          logo,
          width: r * 2,
          height: r * 2,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Icon(Icons.local_activity_rounded, color: Colors.white, size: r),
        )
            : Icon(Icons.local_activity_rounded, color: Colors.white, size: r),
      ),
    );
  }

  TextSpan _highlightSpan(BuildContext context, String text, String query,
      {required TextStyle base, required Color highlightColor}) {
    if (query.isEmpty) return TextSpan(text: text, style: base);
    final q = query.toLowerCase();
    final t = text;
    final tl = t.toLowerCase();

    final spans = <TextSpan>[];
    int start = 0;
    while (true) {
      final idx = tl.indexOf(q, start);
      if (idx < 0) {
        spans.add(TextSpan(text: t.substring(start), style: base));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: t.substring(start, idx), style: base));
      }
      spans.add(TextSpan(
        text: t.substring(idx, idx + q.length),
        style: base.copyWith(
          color: highlightColor,
          fontWeight: FontWeight.w900,
        ),
      ));
      start = idx + q.length;
    }
    return TextSpan(children: spans);
  }
}
