import 'package:flutter/material.dart';
import '../themes/app_theme.dart';
import '../widgets/inner_background.dart';
import '../widgets/transactionList.dart';
import '../widgets/bottom_navigation_bar.dart';

class TransactionHistoryPage extends StatefulWidget {
  const TransactionHistoryPage({Key? key}) : super(key: key);

  @override
  State<TransactionHistoryPage> createState() => _TransactionHistoryPageState();
}

class _TransactionHistoryPageState extends State<TransactionHistoryPage> {
  // Ride-first filters
  static const List<String> _filters = <String>[
    'All',
    'Completed',
    'Ongoing',
    'Cancelled',
    'Dispatch',
  ];

  String _selectedFilter = 'All';
  DateTime? _startDate;
  DateTime? _endDate;
  int _currentIndex = 1; // History tab

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      body: Stack(
        children: [
          const BackgroundWidget(showGrid: true, intensity: 1.0),
          SafeArea(
            child: CustomScrollView(
              slivers: [
                // Title bar
                SliverAppBar(
                  floating: true,
                  snap: true,
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  centerTitle: false,
                  title: Text(
                    'Ride history',
                    style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  actions: [
                    IconButton(
                      tooltip: 'Pick date range',
                      icon: const Icon(Icons.calendar_today_rounded, size: 20),
                      onPressed: _showDateRangePicker,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),

                // Pinned filter header (chips + date range chip)
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _FiltersHeaderDelegate(
                    minExtent: 64,
                    maxExtent: 96,
                    builder: (context) => Container(
                      color: Theme.of(context).scaffoldBackgroundColor.withOpacity(.96),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildFilterBar(context),
                          if (_startDate != null && _endDate != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: _buildDateRangeChip(context),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),

                // List title
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    child: Row(
                      children: [
                        Text(
                          _selectedFilter == 'All'
                              ? 'All rides'
                              : '${_selectedFilter} rides',
                          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        // small legend dot
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: cs.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text('most recent first', style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),

                // History list (uses your existing TransactionList widget)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate.fixed([
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.75,
                        child: TransactionList(
                          limit: 100,
                          // Pass lowercase filter token to your data source
                          filter: _selectedFilter.toLowerCase(),
                          startDate: _startDate,
                          endDate: _endDate,
                        ),
                      ),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: CustomBottomNavBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
      ),
    );
  }

  // ── UI: Filters ─────────────────────────────────────────────────────────
  Widget _buildFilterBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _filters.map((label) {
          final selected = _selectedFilter == label;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(
                label,
                style: tt.labelLarge?.copyWith(
                  color: selected ? cs.onPrimary : cs.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              selected: selected,
              onSelected: (v) => setState(() => _selectedFilter = v ? label : 'All'),
              selectedColor: cs.primary,
              backgroundColor: cs.surface,
              shape: const StadiumBorder(),
              side: BorderSide(color: cs.surfaceVariant),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildDateRangeChip(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return Chip(
      labelPadding: const EdgeInsets.symmetric(horizontal: 8),
      label: Text(
        '${_fmt(_startDate!)} – ${_fmt(_endDate!)}',
        style: tt.labelLarge?.copyWith(color: cs.onSurface),
      ),
      backgroundColor: cs.surface,
      side: BorderSide(color: cs.surfaceVariant),
      deleteIcon: const Icon(Icons.close_rounded, size: 16),
      onDeleted: () => setState(() {
        _startDate = null;
        _endDate = null;
      }),
    );
  }

  // ── Date helpers ───────────────────────────────────────────────────────
  String _fmt(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yyyy = d.year.toString();
    return '$dd/$mm/$yyyy';
  }

  Future<void> _showDateRangePicker() async {
    final cs = Theme.of(context).colorScheme;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now(),
      initialDateRange: (_startDate != null && _endDate != null)
          ? DateTimeRange(start: _startDate!, end: _endDate!)
          : null,
      builder: (context, child) {
        // Theme the calendar with your scheme
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: cs.primary,
              onPrimary: cs.onPrimary,
              surface: cs.surface,
              onSurface: cs.onSurface,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
    }
  }
}

// ── Sliver header delegate for pinned filters ─────────────────────────────
class _FiltersHeaderDelegate extends SliverPersistentHeaderDelegate {
  _FiltersHeaderDelegate({
    required this.minExtent,
    required this.maxExtent,
    required this.builder,
  });

  @override
  final double minExtent;
  @override
  final double maxExtent;

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      type: MaterialType.transparency,
      child: builder(context),
    );
  }

  @override
  bool shouldRebuild(covariant _FiltersHeaderDelegate oldDelegate) {
    return oldDelegate.maxExtent != maxExtent ||
        oldDelegate.minExtent != minExtent ||
        oldDelegate.builder != builder;
  }
}
