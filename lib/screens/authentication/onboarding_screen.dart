import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../themes/app_theme.dart';
import '../../widgets/inner_background.dart';
import '../../ui/ui_scale.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final PageController _pageController = PageController(viewportFraction: 0.92);
  int _currentPage = 0;

  late final AnimationController _mainController;
  late final AnimationController _particleController;
  late final AnimationController _pulseController;
  late final AnimationController _waveController;
  late final AnimationController _shimmerController;

  late final Animation<double> _fadeAnimation;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _slideAnimation;
  late final Animation<double> _rotateAnimation;
  late final Animation<double> _particleAnimation;
  late final Animation<double> _pulseAnimation;
  late final Animation<double> _waveAnimation;
  late final Animation<double> _shimmerAnimation;

  final List<OnboardingData> _pages = [
    OnboardingData(
      title: 'Book Rides, Instantly',
      subtitle: 'Your Journey, Perfected',
      description:
      'Street Rides • Campus Rides\nOrder for yourself or a friend—get from A to B, smarter.',
      icon: Icons.directions_car_rounded,
      gradient: [AppColors.primary, AppColors.secondary],
      features: const [
        'Real-time tracking & reliable ETAs',
        'Safe, trained & principled drivers',
        'Fair pricing',
        'Book for friends',
      ],
      imagePath: 'image/ride_illustration.jpg',
    ),
    OnboardingData(
      title: 'Send Packages with Care',
      subtitle:
      'Fast, secure Package Dispatch for your documents and parcels.',
      description:
      'Send packages anywhere with our trained dispatch riders. Track your items from pickup to delivery with complete peace of mind.',
      icon: Icons.local_shipping_rounded,
      gradient: [AppColors.secondary, AppColors.primary],
      features: const [
        'Live updates from pickup to drop-off',
        'Insured & verified dispatch riders',
        'Door-to-door convenience',
        'Trained riders',
      ],
      imagePath: 'image/dispatch.jpg',
    ),
    OnboardingData(
      title: 'Move Smarter with “Send Me”',
      subtitle: 'Connect & Transact',
      description:
      'Your in-app hub to send, receive and get tasks done.\nRun errands, support your business—get more done.',
      icon: Icons.hub_rounded,
      gradient: [AppColors.primary, AppColors.mintBg],
      features: const [
        'Post requests and get help fast',
        'For individuals and small businesses',
        'Quick service',
        'Built into Pick Me—no extra apps',
      ],
      imagePath: 'image/send_me1.jpg',
    ),
    OnboardingData(
      title: 'Safety • Respect • Kindness',
      subtitle: 'Your Security Matters',
      description:
      'Every ride and delivery is protected. Our drivers and riders are well-trained, principled professionals committed to your safety.',
      icon: Icons.shield_rounded,
      gradient: [AppColors.success, AppColors.primary],
      features: const [
        'Emergency button',
        '24/7 support',
        'Trip sharing',
        'Background checks',
      ],
      imagePath: 'image/safety.jpg',
      isSafety: true,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _startAnimations();
  }

  void _setupAnimations() {
    _mainController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );

    _particleController = AnimationController(
      duration: const Duration(seconds: 20),
      vsync: this,
    );

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    );

    _waveController = AnimationController(
      duration: const Duration(seconds: 4),
      vsync: this,
    );

    _shimmerController = AnimationController(
      duration: const Duration(milliseconds: 2500),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _mainController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );

    _scaleAnimation = Tween<double>(begin: 0.88, end: 1).animate(
      CurvedAnimation(parent: _mainController, curve: Curves.elasticOut),
    );

    _slideAnimation = Tween<double>(begin: 42, end: 0).animate(
      CurvedAnimation(
        parent: _mainController,
        curve: const Interval(0.2, 0.8, curve: Curves.easeOutCubic),
      ),
    );

    _rotateAnimation = Tween<double>(begin: -0.07, end: 0).animate(
      CurvedAnimation(parent: _mainController, curve: Curves.easeOutBack),
    );

    _particleAnimation = Tween<double>(begin: 0, end: 1).animate(_particleController);

    _pulseAnimation = Tween<double>(begin: 1, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _waveAnimation = Tween<double>(begin: 0, end: 2 * math.pi).animate(_waveController);

    _shimmerAnimation = Tween<double>(begin: -2, end: 2).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );
  }

  void _startAnimations() {
    _mainController.forward();
    _particleController.repeat();
    _pulseController.repeat(reverse: true);
    _waveController.repeat();
    _shimmerController.repeat();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _mainController.dispose();
    _particleController.dispose();
    _pulseController.dispose();
    _waveController.dispose();
    _shimmerController.dispose();
    super.dispose();
  }

  void _nextPage() {
    HapticFeedback.mediumImpact();
    if (_currentPage < _pages.length - 1) {
      _pageController.animateToPage(
        _currentPage + 1,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOutCubic,
      );
    } else {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      HapticFeedback.lightImpact();
      _pageController.animateToPage(
        _currentPage - 1,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = UIScale.of(context);

    return Scaffold(
      backgroundColor: AppColors.backgroundColor,
      body: Stack(
        children: [
          const BackgroundWidget(
            style: HoloStyle.flux,
            animate: true,
            intensity: 0.5,
          ),
          if (!ui.reduceFx)
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _particleAnimation,
                builder: (context, _) => CustomPaint(
                  painter: AdvancedParticlePainter(
                    progress: _particleAnimation.value,
                    color: AppColors.primary,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          if (!ui.reduceFx)
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _waveAnimation,
                builder: (context, _) => CustomPaint(
                  painter: WavePainter(
                    progress: _waveAnimation.value,
                    color: AppColors.secondary.withOpacity(0.08),
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(ui),
                Expanded(
                  child: ui.useSplitOnboarding
                      ? _buildLandscapeLayout(ui)
                      : _buildPortraitLayout(ui),
                ),
                _buildFooter(ui),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(UIScale ui) {
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) => Opacity(
        opacity: _fadeAnimation.value,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: ui.inset(ui.tablet ? 28 : 18),
            vertical: ui.inset(ui.compact ? 10 : 14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, _) => Transform.scale(
                  scale: ui.reduceFx ? 1 : _pulseAnimation.value,
                  child: Container(
                    width: ui.compact ? 44 : 52,
                    height: ui.compact ? 44 : 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [AppColors.primary, AppColors.secondary],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withOpacity(
                            ui.reduceFx ? 0.16 : 0.28,
                          ),
                          blurRadius: ui.reduceFx ? 10 : 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(ui.inset(10)),
                      child: Image.asset(
                        'image/pickme.png',
                        fit: BoxFit.contain,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  padding: EdgeInsets.symmetric(
                    horizontal: ui.inset(12),
                    vertical: ui.inset(8),
                  ),
                ),
                child: Text(
                  'Skip',
                  style: TextStyle(
                    fontSize: ui.font(14),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitLayout(UIScale ui) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: ui.inset(ui.tiny ? 6 : 10),
        vertical: ui.inset(6),
      ),
      child: PageView.builder(
        controller: _pageController,
        padEnds: false,
        onPageChanged: (index) {
          setState(() => _currentPage = index);
          _mainController
            ..reset()
            ..forward();
          HapticFeedback.lightImpact();
        },
        itemCount: _pages.length,
        itemBuilder: (context, index) {
          return AnimatedBuilder(
            animation: _pageController,
            builder: (context, child) {
              double value = 1;
              if (_pageController.position.haveDimensions) {
                final page = _pageController.page ?? _currentPage.toDouble();
                value = page - index.toDouble();
                value = (1 - (value.abs() * 0.18)).clamp(0.86, 1.0);
              }
              return Transform.scale(
                scale: value,
                child: Opacity(
                  opacity: (0.55 + (value * 0.45)).clamp(0.0, 1.0),
                  child: child,
                ),
              );
            },
            child: _buildCard(_pages[index], ui),
          );
        },
      ),
    );
  }

  Widget _buildLandscapeLayout(UIScale ui) {
    final data = _pages[_currentPage];
    return Padding(
      padding: ui.screenPadding.copyWith(top: ui.gap(4), bottom: ui.gap(4)),
      child: Row(
        children: [
          Expanded(
            flex: 11,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: ui.compact ? 360 : 460,
                  maxHeight: ui.height * 0.76,
                ),
                child: _buildCard(data, ui),
              ),
            ),
          ),
          SizedBox(width: ui.gap(20)),
          Expanded(
            flex: 10,
            child: SingleChildScrollView(
              padding: EdgeInsets.all(ui.inset(ui.compact ? 10 : 18)),
              child: AnimatedBuilder(
                animation: _fadeAnimation,
                builder: (context, child) => Opacity(
                  opacity: _fadeAnimation.value,
                  child: child,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.title,
                      style: TextStyle(
                        fontSize: ui.font(ui.compact ? 26 : 36),
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                        height: 1.08,
                        letterSpacing: -0.8,
                      ),
                    ),
                    SizedBox(height: ui.gap(8)),
                    Text(
                      data.subtitle,
                      style: TextStyle(
                        fontSize: ui.font(ui.compact ? 16 : 22),
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: ui.gap(16)),
                    Text(
                      data.description,
                      style: TextStyle(
                        fontSize: ui.font(ui.compact ? 13.5 : 16),
                        color: AppColors.textSecondary,
                        height: 1.45,
                      ),
                    ),
                    SizedBox(height: ui.gap(18)),
                    ...data.features.map((f) => _buildFeatureBullet(f, ui)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(OnboardingData data, UIScale ui) {
    final borderRadius = ui.compact ? ui.radius(24) : ui.radius(36);

    return AnimatedBuilder(
      animation: Listenable.merge([
        _scaleAnimation,
        _slideAnimation,
        _rotateAnimation,
      ]),
      builder: (context, _) {
        final double translateY = ui.reduceFx ? 0.0 : _slideAnimation.value;
        final double perspective = ui.reduceFx ? 0.0 : 0.001;
        final double rotationZ = ui.reduceFx ? 0.0 : (_rotateAnimation.value * 0.5);
        final double scale = ui.reduceFx ? 1.0 : _scaleAnimation.value;

        return Transform.translate(
          offset: Offset(0, translateY),
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, perspective)
              ..rotateZ(rotationZ)
              ..scale(scale, scale, 1.0),
            child: Container(
              margin: EdgeInsets.symmetric(
                horizontal: ui.gap(4),
                vertical: ui.gap(8),
              ),
              child: Stack(
                children: [
                  if (!ui.reduceFx)
                    Positioned.fill(
                      child: AnimatedBuilder(
                        animation: _shimmerAnimation,
                        builder: (context, child) => DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(borderRadius),
                            gradient: LinearGradient(
                              begin: Alignment(-1 + _shimmerAnimation.value, -1),
                              end: Alignment(1 + _shimmerAnimation.value, 1),
                              colors: [
                                data.gradient.first.withOpacity(0.22),
                                data.gradient.last.withOpacity(0.08),
                                data.gradient.first.withOpacity(0.22),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(borderRadius),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: ui.blur(20),
                        sigmaY: ui.blur(20),
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              data.gradient.first.withOpacity(0.92),
                              data.gradient.last.withOpacity(0.78),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(borderRadius),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.22),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: data.gradient.first.withOpacity(
                                ui.reduceFx ? 0.16 : 0.35,
                              ),
                              blurRadius: ui.reduceFx ? 14 : 32,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final imageHeight = math.max(
                              110.0,
                              math.min(
                                constraints.maxHeight * 0.26,
                                ui.compact ? 132.0 : 180.0,
                              ),
                            );

                            return SingleChildScrollView(
                              physics: const ClampingScrollPhysics(),
                              padding: EdgeInsets.all(
                                ui.inset(ui.compact ? 18 : 28),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(ui.radius(18)),
                                    child: SizedBox(
                                      width: double.infinity,
                                      height: imageHeight,
                                      child: Image.asset(
                                        data.imagePath,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Container(
                                          color: Colors.white.withOpacity(0.10),
                                          child: Icon(
                                            data.icon,
                                            size: ui.icon(ui.compact ? 56 : 72),
                                            color: Colors.white.withOpacity(0.65),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(height: ui.gap(18)),
                                  Text(
                                    data.title,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: ui.font(ui.compact ? 24 : 32),
                                      fontWeight: FontWeight.w900,
                                      color: Colors.white,
                                      height: 1.08,
                                      letterSpacing: -0.4,
                                    ),
                                  ),
                                  SizedBox(height: ui.gap(8)),
                                  Text(
                                    data.subtitle,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: ui.font(ui.compact ? 15.5 : 20),
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white.withOpacity(0.95),
                                    ),
                                  ),
                                  SizedBox(height: ui.gap(14)),
                                  Text(
                                    data.description,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: ui.font(ui.compact ? 13 : 15),
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                      height: 1.45,
                                    ),
                                  ),
                                  SizedBox(height: ui.gap(16)),
                                  Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: ui.gap(8),
                                    runSpacing: ui.gap(8),
                                    children: data.features.map((feature) {
                                      return Container(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: ui.inset(12),
                                          vertical: ui.inset(7),
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.18),
                                          borderRadius: BorderRadius.circular(
                                            ui.radius(20),
                                          ),
                                          border: Border.all(
                                            color: Colors.white.withOpacity(0.35),
                                            width: 1,
                                          ),
                                        ),
                                        child: Text(
                                          feature,
                                          style: TextStyle(
                                            fontSize: ui.font(12),
                                            color: Colors.white,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                  if (data.isSafety) ...[
                                    SizedBox(height: ui.gap(18)),
                                    _buildSafetyCard(ui),
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSafetyCard(UIScale ui) {
    return Container(
      padding: EdgeInsets.all(ui.inset(ui.compact ? 16 : 20)),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(ui.radius(18)),
        border: Border.all(
          color: Colors.white.withOpacity(0.30),
          width: 1.5,
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.favorite_rounded,
                color: Colors.white,
                size: ui.icon(ui.compact ? 20 : 22),
              ),
              SizedBox(width: ui.gap(10)),
              Text(
                'Our Commitment to You',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: ui.font(ui.compact ? 15 : 16),
                ),
              ),
            ],
          ),
          SizedBox(height: ui.gap(14)),
          ...const [
            'Treat everyone with kindness & respect',
            'Help keep one another safe; follow local laws',
            'Report any abuse or misconduct immediately',
          ].map(
                (text) => Padding(
              padding: EdgeInsets.only(bottom: ui.gap(8)),
              child: Row(
                children: [
                  Container(
                    width: ui.icon(7),
                    height: ui.icon(7),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: ui.gap(12)),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        fontSize: ui.font(13),
                        color: Colors.white.withOpacity(0.95),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureBullet(String feature, UIScale ui) {
    return Padding(
      padding: EdgeInsets.only(bottom: ui.gap(12)),
      child: Row(
        children: [
          Container(
            width: ui.icon(ui.compact ? 9 : 10),
            height: ui.icon(ui.compact ? 9 : 10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.primary, AppColors.secondary],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(0.35),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          SizedBox(width: ui.gap(12)),
          Expanded(
            child: Text(
              feature,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: ui.font(ui.compact ? 14 : 16),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(UIScale ui) {
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) => Opacity(
        opacity: _fadeAnimation.value,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: ui.inset(ui.tablet ? 28 : 18),
            vertical: ui.inset(ui.compact ? 16 : 22),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pages.length, (index) {
                  final isActive = index == _currentPage;
                  return GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      _pageController.animateToPage(
                        index,
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeInOutCubic,
                      );
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      margin: EdgeInsets.symmetric(horizontal: ui.gap(4)),
                      width: isActive ? ui.inset(34) : ui.inset(10),
                      height: ui.inset(9),
                      decoration: BoxDecoration(
                        gradient: isActive
                            ? const LinearGradient(
                          colors: [
                            AppColors.primary,
                            AppColors.secondary,
                          ],
                        )
                            : null,
                        color: isActive ? null : AppColors.mintBgLight,
                        borderRadius: BorderRadius.circular(ui.radius(8)),
                        boxShadow: isActive
                            ? [
                          BoxShadow(
                            color: AppColors.primary.withOpacity(0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ]
                            : null,
                      ),
                    ),
                  );
                }),
              ),
              SizedBox(height: ui.gap(18)),
              LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 320;

                  final nextButton = GestureDetector(
                    onTap: _nextPage,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: _currentPage == _pages.length - 1
                          ? (wide ? ui.inset(180) : double.infinity)
                          : (wide ? ui.inset(160) : double.infinity),
                      height: ui.compact ? 52 : 58,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.primary, AppColors.secondary],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                        borderRadius: BorderRadius.circular(ui.radius(32)),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withOpacity(
                              ui.reduceFx ? 0.20 : 0.40,
                            ),
                            blurRadius: ui.reduceFx ? 14 : 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _currentPage == _pages.length - 1
                                ? 'Get Started'
                                : 'Next',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: ui.font(16),
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                            ),
                          ),
                          SizedBox(width: ui.gap(8)),
                          Icon(
                            Icons.arrow_forward_rounded,
                            color: Colors.white,
                            size: ui.icon(22),
                          ),
                        ],
                      ),
                    ),
                  );

                  if (wide) {
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_currentPage > 0)
                          GestureDetector(
                            onTap: _previousPage,
                            child: Container(
                              width: ui.compact ? 48 : 54,
                              height: ui.compact ? 48 : 54,
                              margin: EdgeInsets.only(right: ui.gap(14)),
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.mintBgLight,
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.06),
                                    blurRadius: 16,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.arrow_back_rounded,
                                color: AppColors.primary,
                                size: ui.icon(22),
                              ),
                            ),
                          ),
                        nextButton,
                      ],
                    );
                  }

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_currentPage > 0)
                        Padding(
                          padding: EdgeInsets.only(bottom: ui.gap(10)),
                          child: GestureDetector(
                            onTap: _previousPage,
                            child: Container(
                              width: ui.compact ? 46 : 50,
                              height: ui.compact ? 46 : 50,
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.mintBgLight,
                                  width: 1.5,
                                ),
                              ),
                              child: Icon(
                                Icons.arrow_back_rounded,
                                color: AppColors.primary,
                                size: ui.icon(22),
                              ),
                            ),
                          ),
                        ),
                      SizedBox(width: double.infinity, child: nextButton),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OnboardingData {
  final String title;
  final String subtitle;
  final String description;
  final IconData icon;
  final List<Color> gradient;
  final List<String> features;
  final String imagePath;
  final bool isSafety;

  const OnboardingData({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.icon,
    required this.gradient,
    required this.features,
    required this.imagePath,
    this.isSafety = false,
  });
}

class AdvancedParticlePainter extends CustomPainter {
  final double progress;
  final Color color;

  AdvancedParticlePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final random = math.Random(123);

    for (int i = 0; i < 50; i++) {
      final x = random.nextDouble() * size.width;
      final phase = (progress + i / 50) % 1.0;
      final y = size.height * (1 - phase) + random.nextDouble() * 100 - 50;
      final radius = random.nextDouble() * 4 + 1;
      final opacity = (math.sin(phase * math.pi) * 0.6).clamp(0.0, 1.0);

      paint.color = color.withOpacity(opacity * 0.4);
      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant AdvancedParticlePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class WavePainter extends CustomPainter {
  final double progress;
  final Color color;

  WavePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    final waveHeight = size.height * 0.08;

    path.moveTo(0, size.height * 0.7);

    for (double i = 0; i <= size.width; i++) {
      final y = size.height * 0.7 +
          math.sin((i / size.width * 4 * math.pi) + (progress * 2 * math.pi)) *
              waveHeight;
      path.lineTo(i, y);
    }

    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant WavePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
