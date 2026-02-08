// lib/widgets/ride_market_sheet.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../themes/app_theme.dart';
import '../services/ride_market_service.dart';

/// RideMarketSheet
/// - No drag-to-dismiss
/// - Slide + fade entrance
/// - Verbose prints for debugging
/// - Responsive layout (1 / 2 / 3 columns)
/// - Shows retry when no offers
class RideMarketSheet extends StatefulWidget {
  final double bottomNavHeight;
  final String? originText;
  final String? destinationText;
  final String? distanceText;
  final String? durationText;
  final List<RideOffer> offers;
  final bool loading;
  final VoidCallback onRefresh;
  final void Function(RideOffer offer) onSelect;
  final VoidCallback? onCancel;

  const RideMarketSheet({
    Key? key,
    required this.bottomNavHeight,
    required this.originText,
    required this.destinationText,
    required this.distanceText,
    required this.durationText,
    required this.offers,
    required this.loading,
    required this.onRefresh,
    required this.onSelect,
    this.onCancel,
  }) : super(key: key);

  @override
  State<RideMarketSheet> createState() => _RideMarketSheetState();
}

class _RideMarketSheetState extends State<RideMarketSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    print('[RideMarketSheet] initState');
    _entrance = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic));

    // start entrance after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        print('[RideMarketSheet] starting entrance animation');
        _entrance.forward();
      }
    });
  }

  @override
  void dispose() {
    print('[RideMarketSheet] dispose');
    _entrance.dispose();
    super.dispose();
  }

  double _calcMaxHeight(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return MediaQuery.of(context).orientation == Orientation.portrait
        ? (h * 0.65).clamp(360.0, h)
        : (h * 0.72).clamp(380.0, h);
  }

  int _columnsForWidth(double w) {
    if (w < 520) return 1;
    if (w < 920) return 2;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    print('[RideMarketSheet] build — loading=${widget.loading} offers=${widget.offers.length}');
    final mq = MediaQuery.of(context);
    final maxH = _calcMaxHeight(context);
    final safeBottom = mq.padding.bottom;

    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 920, maxHeight: maxH),
          child: SlideTransition(
            position: _slide,
            child: FadeTransition(
              opacity: _fade,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Material(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    elevation: 18,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Header (no drag handle)
                        _HeaderRow(
                          originText: widget.originText,
                          destinationText: widget.destinationText,
                          distanceText: widget.distanceText,
                          durationText: widget.durationText,
                          onRefresh: () {
                            print('[RideMarketSheet] header onRefresh');
                            widget.onRefresh();
                          },
                        ),

                        // Content: loading / empty / list/grid
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 240),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            child: _buildContent(mq.size.width),
                          ),
                        ),

                        // Payment & CTA + Cancel
                        _BottomActions(
                          safeBottom: safeBottom,
                          offers: widget.offers,
                          loading: widget.loading,
                          onSelect: widget.onSelect,
                          onRefresh: widget.onRefresh,
                          onCancel: () {
                            print('[RideMarketSheet] Cancel tapped');
                            widget.onCancel?.call();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(double width) {
    final cols = _columnsForWidth(width);
    if (widget.loading) {
      return _LoadingState(key: const ValueKey('loading'));
    }

    if (widget.offers.isEmpty) {
      return _EmptyState(onRetry: () {
        print('[RideMarketSheet] Empty state retry pressed -> onRefresh');
        widget.onRefresh();
      }, key: const ValueKey('empty'));
    }

    // offers present
    return _OffersList(
      offers: widget.offers,
      columns: cols,
      onSelect: widget.onSelect,
      key: ValueKey('offers_${widget.offers.length}_cols_$cols'),
    );
  }
}

/// HEADER
class _HeaderRow extends StatelessWidget {
  final String? originText;
  final String? destinationText;
  final String? distanceText;
  final String? durationText;
  final VoidCallback onRefresh;

  const _HeaderRow({
    Key? key,
    this.originText,
    this.destinationText,
    this.distanceText,
    this.durationText,
    required this.onRefresh,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: surface.withOpacity(.98),
        border: Border(bottom: BorderSide(color: AppColors.mintBgLight.withOpacity(.18), width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (originText != null && originText!.isNotEmpty)
                Text(originText!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
              if (destinationText != null && destinationText!.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 6), child: Text(destinationText!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
          ),
          IconButton(
            tooltip: 'Refresh offers',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded),
            splashRadius: 20,
          ),
          const SizedBox(width: 6),
          if (durationText != null) _Badge(text: durationText!, icon: Icons.timelapse_rounded),
          const SizedBox(width: 8),
          if (distanceText != null) _Badge(text: distanceText!, icon: Icons.route_rounded),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final IconData icon;
  const _Badge({Key? key, required this.text, required this.icon}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.mintBgLight.withOpacity(.28),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.mintBgLight.withOpacity(.6)),
      ),
      child: Row(children: [Icon(icon, size: 14, color: AppColors.textPrimary), const SizedBox(width: 6), Text(text, style: const TextStyle(fontWeight: FontWeight.w800))]),
    );
  }
}

/// LOADING STATE
class _LoadingState extends StatelessWidget {
  const _LoadingState({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12),
        const CircularProgressIndicator(strokeWidth: 2.8),
        const SizedBox(height: 12),
        Text('Searching for nearby cars…', style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        Text('This usually takes a few seconds.', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
      ]),
    );
  }
}

/// EMPTY STATE (no offers)
class _EmptyState extends StatelessWidget {
  final VoidCallback onRetry;
  const _EmptyState({Key? key, required this.onRetry}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30.0),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.car_rental_outlined, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text('No cars nearby right now', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('Try expanding your search radius or refresh to try again.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600])),
          const SizedBox(height: 18),
          SizedBox(
            width: 160,
            height: 44,
            child: ElevatedButton(
              onPressed: () {
                print('[RideMarketSheet] EmptyState -> retry pressed');
                onRetry();
              },
              style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: const Text('Try again', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      ),
    );
  }
}

/// OFFERS LIST / GRID
class _OffersList extends StatelessWidget {
  final List<RideOffer> offers;
  final int columns;
  final void Function(RideOffer) onSelect;

  const _OffersList({Key? key, required this.offers, required this.columns, required this.onSelect}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (columns == 1) {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        physics: const BouncingScrollPhysics(),
        itemBuilder: (c, i) => _OfferCard(offer: offers[i], onTap: () => onSelect(offers[i])),
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemCount: offers.length,
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      physics: const BouncingScrollPhysics(),
      itemCount: offers.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 3.2,
      ),
      itemBuilder: (c, i) => _OfferCard(offer: offers[i], onTap: () => onSelect(offers[i])),
    );
  }
}

/// SINGLE OFFER CARD
class _OfferCard extends StatelessWidget {
  final RideOffer offer;
  final VoidCallback onTap;
  const _OfferCard({Key? key, required this.offer, required this.onTap}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final priceText = '₦${offer.price}';
    return InkWell(
      onTap: () {
        print('[RideMarketSheet] offer tapped id=${offer.id} provider=${offer.provider}');
        onTap();
      },
      borderRadius: BorderRadius.circular(14),
      child: Ink(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.mintBgLight.withOpacity(.36), width: 1.2),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(.03), blurRadius: 6, offset: const Offset(0, 4))],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(width: 66, height: 46, decoration: BoxDecoration(color: AppColors.mintBg.withOpacity(.6), borderRadius: BorderRadius.circular(10)), child: Center(child: Icon(Icons.directions_car_rounded, color: AppColors.primary))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(offer.provider, style: const TextStyle(fontWeight: FontWeight.w900)),
                  const SizedBox(width: 8),
                  if (offer.surge)
                    Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.orange.shade600, borderRadius: BorderRadius.circular(8)), child: const Text('Surge', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12))),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), decoration: BoxDecoration(color: AppColors.mintBgLight.withOpacity(.3), borderRadius: BorderRadius.circular(12)), child: Text('${offer.etaToPickupMin} min', style: const TextStyle(fontWeight: FontWeight.w800))),
                  const SizedBox(width: 10),
                  Text('• ${offer.seats ?? 4} seats', style: Theme.of(context).textTheme.bodySmall),
                  const Spacer(),
                  if (offer.driverName != null) Text(offer.driverName!, style: Theme.of(context).textTheme.bodySmall),
                ]),
                const SizedBox(height: 6),
                if (offer.driverName != null || offer.carPlate != null || offer.rating != null)
                  Text('${offer.driverName ?? '—'}  •  ${offer.rating?.toStringAsFixed(1) ?? '—'} ★  •  ${offer.carPlate ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[600])),
              ]),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(priceText, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
              const SizedBox(height: 8),
              SizedBox(width: 92, height: 36, child: OutlinedButton(onPressed: onTap, style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), side: BorderSide(color: AppColors.mintBgLight.withOpacity(.6)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))), child: const Text('Select', style: TextStyle(fontWeight: FontWeight.w800)))),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// BOTTOM ACTIONS: payment row + main CTA + cancel
class _BottomActions extends StatelessWidget {
  final double safeBottom;
  final List<RideOffer> offers;
  final bool loading;
  final void Function(RideOffer) onSelect;
  final VoidCallback onRefresh;
  final VoidCallback? onCancel;

  const _BottomActions({
    Key? key,
    required this.safeBottom,
    required this.offers,
    required this.loading,
    required this.onSelect,
    required this.onRefresh,
    this.onCancel,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final disabled = offers.isEmpty || loading;
    final first = offers.isNotEmpty ? offers.first : null;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + safeBottom),
      decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, border: Border(top: BorderSide(color: AppColors.mintBgLight.withOpacity(.12)))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: const [Icon(Icons.money_rounded, size: 18), SizedBox(width: 8), Text('Cash'), Spacer(), Icon(Icons.expand_more, size: 18)]),
        const SizedBox(height: 10),

        // Primary CTA
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: disabled ? null : () {
              print('[RideMarketSheet] primary CTA pressed -> selecting ${first!.id}');
              onSelect(first!);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32))),
            child: Text(disabled ? 'Searching cars…' : 'Select ${first!.provider}', style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),

        const SizedBox(height: 10),

        // Secondary controls: if no offers show try again, otherwise show cancel
        if (offers.isEmpty)
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              onPressed: () {
                print('[RideMarketSheet] Try again pressed');
                onRefresh();
              },
              style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)), side: BorderSide(color: AppColors.mintBgLight.withOpacity(.6))),
              child: const Text('Try again', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          )
        else
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              onPressed: () {
                print('[RideMarketSheet] Cancel pressed');
                onCancel?.call();
              },
              style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)), side: BorderSide(color: AppColors.mintBgLight.withOpacity(.6))),
              child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
      ]),
    );
  }
}
