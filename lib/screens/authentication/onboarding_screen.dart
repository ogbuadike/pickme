import 'dart:math' as math;
import 'dart:ui' as ui;

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

    _rotateAnimation = Tween<double>(begin: -0.05, end: 0).animate(
      CurvedAnimation(parent: _mainController, curve: Curves.easeOutBack),
    );

    _particleAnimation = Tween<double>(begin: 0, end: 1).animate(_particleController);

    _pulseAnimation = Tween<double>(begin: 1, end: 1.05).animate(
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
    final uiScale = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : AppColors.offWhite,
      body: Stack(
        children: [
          // Background Depth Layer
          BackgroundWidget(
            style: HoloStyle.flux,
            animate: true,
            intensity: isDark ? 0.3 : 0.6,
          ),

          if (!uiScale.reduceFx)
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _particleAnimation,
                builder: (context, _) => CustomPaint(
                  painter: AdvancedParticlePainter(
                    progress: _particleAnimation.value,
                    color: isDark ? cs.primary : AppColors.primary,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),

          if (!uiScale.reduceFx)
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _waveAnimation,
                builder: (context, _) => CustomPaint(
                  painter: WavePainter(
                    progress: _waveAnimation.value,
                    color: (isDark ? cs.secondary : AppColors.secondary).withOpacity(isDark ? 0.05 : 0.08),
                  ),
                  size: Size.infinite,
                ),
              ),
            ),

          SafeArea(
            child: Column(
              children: [
                _buildHeader(uiScale, isDark, cs),
                Expanded(
                  child: uiScale.useSplitOnboarding
                      ? _buildLandscapeLayout(uiScale, isDark, cs)
                      : _buildPortraitLayout(uiScale, isDark, cs),
                ),
                _buildFooter(uiScale, isDark, cs),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(UIScale uiScale, bool isDark, ColorScheme cs) {
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) => Opacity(
        opacity: _fadeAnimation.value,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: uiScale.inset(uiScale.tablet ? 28 : 18),
            vertical: uiScale.inset(uiScale.compact ? 10 : 14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, _) => Transform.scale(
                  scale: uiScale.reduceFx ? 1 : _pulseAnimation.value,
                  child: Container(
                    width: uiScale.compact ? 48 : 56,
                    height: uiScale.compact ? 48 : 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: isDark ? [cs.primary, cs.secondary] : [AppColors.primary, AppColors.secondary],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (isDark ? cs.primary : AppColors.primary).withOpacity(uiScale.reduceFx ? 0.16 : 0.35),
                          blurRadius: uiScale.reduceFx ? 10 : 20,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(uiScale.inset(12)),
                      child: Image.asset(
                        'image/pickme.png',
                        fit: BoxFit.contain,
                        color: isDark ? cs.onPrimary : Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
                style: TextButton.styleFrom(
                  foregroundColor: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                  padding: EdgeInsets.symmetric(
                    horizontal: uiScale.inset(16),
                    vertical: uiScale.inset(8),
                  ),
                ),
                child: Text(
                  'Skip',
                  style: TextStyle(
                    fontSize: uiScale.font(15),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitLayout(UIScale uiScale, bool isDark, ColorScheme cs) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: uiScale.inset(uiScale.tiny ? 4 : 8),
        vertical: uiScale.inset(6),
      ),
      child: PageView.builder(
        controller: _pageController,
        padEnds: true, // Center the card perfectly
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
                value = (1 - (value.abs() * 0.15)).clamp(0.85, 1.0);
              }
              return Transform.scale(
                scale: value,
                child: Opacity(
                  opacity: (0.5 + (value * 0.5)).clamp(0.0, 1.0),
                  child: child,
                ),
              );
            },
            child: _buildPremiumCard(_pages[index], uiScale, isDark, cs),
          );
        },
      ),
    );
  }

  Widget _buildLandscapeLayout(UIScale uiScale, bool isDark, ColorScheme cs) {
    final data = _pages[_currentPage];
    return Padding(
      padding: uiScale.screenPadding.copyWith(top: uiScale.gap(4), bottom: uiScale.gap(4)),
      child: Row(
        children: [
          Expanded(
            flex: 11,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: uiScale.compact ? 360 : 460,
                  maxHeight: uiScale.height * 0.8,
                ),
                child: _buildPremiumCard(data, uiScale, isDark, cs),
              ),
            ),
          ),
          SizedBox(width: uiScale.gap(32)),
          Expanded(
            flex: 10,
            child: SingleChildScrollView(
              padding: EdgeInsets.all(uiScale.inset(uiScale.compact ? 10 : 24)),
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
                        fontSize: uiScale.font(uiScale.compact ? 28 : 40),
                        fontWeight: FontWeight.w900,
                        color: isDark ? cs.onSurface : AppColors.textPrimary,
                        height: 1.08,
                        letterSpacing: -1.0,
                      ),
                    ),
                    SizedBox(height: uiScale.gap(8)),
                    Text(
                      data.subtitle,
                      style: TextStyle(
                        fontSize: uiScale.font(uiScale.compact ? 16 : 22),
                        color: data.gradient.first,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: uiScale.gap(16)),
                    Text(
                      data.description,
                      style: TextStyle(
                        fontSize: uiScale.font(uiScale.compact ? 14 : 16),
                        color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                    SizedBox(height: uiScale.gap(24)),
                    ...data.features.map((f) => _buildFeatureBullet(f, uiScale, data.gradient.first, isDark, cs)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPremiumCard(OnboardingData data, UIScale uiScale, bool isDark, ColorScheme cs) {
    final borderRadius = uiScale.compact ? uiScale.radius(28) : uiScale.radius(40);

    return AnimatedBuilder(
      animation: Listenable.merge([_scaleAnimation, _slideAnimation, _rotateAnimation]),
      builder: (context, _) {
        final double translateY = uiScale.reduceFx ? 0.0 : _slideAnimation.value;
        final double perspective = uiScale.reduceFx ? 0.0 : 0.001;
        final double rotationZ = uiScale.reduceFx ? 0.0 : (_rotateAnimation.value * 0.5);
        final double scale = uiScale.reduceFx ? 1.0 : _scaleAnimation.value;

        return Transform.translate(
          offset: Offset(0, translateY),
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, perspective)
              ..rotateZ(rotationZ)
              ..scale(scale, scale, 1.0),
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: uiScale.gap(8), vertical: uiScale.gap(12)),
              child: Stack(
                children: [
                  // Under-glow shadow layer
                  if (!uiScale.reduceFx)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(borderRadius),
                          boxShadow: [
                            BoxShadow(
                              color: data.gradient.first.withOpacity(isDark ? 0.3 : 0.2),
                              blurRadius: 40,
                              spreadRadius: -10,
                              offset: const Offset(0, 20),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Glassmorphism Card
                  ClipRRect(
                    borderRadius: BorderRadius.circular(borderRadius),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isDark ? cs.surface.withOpacity(0.7) : Colors.white.withOpacity(0.85),
                          borderRadius: BorderRadius.circular(borderRadius),
                          border: Border.all(
                            color: data.gradient.first.withOpacity(isDark ? 0.4 : 0.2),
                            width: 1.5,
                          ),
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final imageHeight = math.max(
                              120.0,
                              math.min(constraints.maxHeight * 0.28, uiScale.compact ? 140.0 : 200.0),
                            );

                            return SingleChildScrollView(
                              physics: const ClampingScrollPhysics(),
                              padding: EdgeInsets.all(uiScale.inset(uiScale.compact ? 20 : 28)),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Image Header
                                  Container(
                                    width: double.infinity,
                                    height: imageHeight,
                                    decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(uiScale.radius(20)),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(isDark ? 0.4 : 0.1),
                                            blurRadius: 20,
                                            offset: const Offset(0, 10),
                                          )
                                        ]
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(uiScale.radius(20)),
                                      child: Image.asset(
                                        data.imagePath,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Container(
                                          color: data.gradient.first.withOpacity(0.1),
                                          child: Icon(
                                            data.icon,
                                            size: uiScale.icon(uiScale.compact ? 56 : 72),
                                            color: data.gradient.first,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                  SizedBox(height: uiScale.gap(24)),

                                  // Typography
                                  Text(
                                    data.title,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: uiScale.font(uiScale.compact ? 24 : 30),
                                      fontWeight: FontWeight.w900,
                                      color: isDark ? cs.onSurface : AppColors.textPrimary,
                                      height: 1.1,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                  SizedBox(height: uiScale.gap(8)),
                                  Text(
                                    data.subtitle,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: uiScale.font(uiScale.compact ? 15 : 18),
                                      fontWeight: FontWeight.w800,
                                      color: data.gradient.first,
                                    ),
                                  ),
                                  SizedBox(height: uiScale.gap(16)),
                                  Text(
                                    data.description,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: uiScale.font(uiScale.compact ? 13.5 : 15),
                                      fontWeight: FontWeight.w600,
                                      color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                                      height: 1.45,
                                    ),
                                  ),
                                  SizedBox(height: uiScale.gap(24)),

                                  // Features Pills
                                  Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: uiScale.gap(10),
                                    runSpacing: uiScale.gap(10),
                                    children: data.features.map((feature) {
                                      return Container(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: uiScale.inset(14),
                                          vertical: uiScale.inset(8),
                                        ),
                                        decoration: BoxDecoration(
                                          color: data.gradient.first.withOpacity(isDark ? 0.15 : 0.1),
                                          borderRadius: BorderRadius.circular(uiScale.radius(24)),
                                          border: Border.all(
                                            color: data.gradient.first.withOpacity(0.3),
                                            width: 1,
                                          ),
                                        ),
                                        child: Text(
                                          feature,
                                          style: TextStyle(
                                            fontSize: uiScale.font(12.5),
                                            color: isDark ? cs.onSurface : AppColors.textPrimary,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),

                                  if (data.isSafety) ...[
                                    SizedBox(height: uiScale.gap(24)),
                                    _buildSafetyCard(uiScale, isDark, cs, data.gradient.first),
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

  Widget _buildSafetyCard(UIScale uiScale, bool isDark, ColorScheme cs, Color accentColor) {
    return Container(
      padding: EdgeInsets.all(uiScale.inset(uiScale.compact ? 16 : 20)),
      decoration: BoxDecoration(
        color: accentColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(uiScale.radius(20)),
        border: Border.all(
          color: accentColor.withOpacity(0.4),
          width: 1.5,
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.favorite_rounded, color: accentColor, size: uiScale.icon(uiScale.compact ? 20 : 24)),
              SizedBox(width: uiScale.gap(10)),
              Text(
                'Our Commitment to You',
                style: TextStyle(
                  color: isDark ? cs.onSurface : AppColors.textPrimary,
                  fontWeight: FontWeight.w900,
                  fontSize: uiScale.font(uiScale.compact ? 15 : 17),
                ),
              ),
            ],
          ),
          SizedBox(height: uiScale.gap(16)),
          ...const [
            'Treat everyone with kindness & respect',
            'Help keep one another safe; follow local laws',
            'Report any abuse or misconduct immediately',
          ].map(
                (text) => Padding(
              padding: EdgeInsets.only(bottom: uiScale.gap(10)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: EdgeInsets.only(top: uiScale.gap(4)),
                    width: uiScale.icon(8),
                    height: uiScale.icon(8),
                    decoration: BoxDecoration(
                      color: accentColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: uiScale.gap(12)),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        fontSize: uiScale.font(13.5),
                        color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
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

  Widget _buildFeatureBullet(String feature, UIScale uiScale, Color accentColor, bool isDark, ColorScheme cs) {
    return Padding(
      padding: EdgeInsets.only(bottom: uiScale.gap(14)),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(uiScale.inset(6)),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.check_rounded, size: uiScale.icon(14), color: accentColor),
          ),
          SizedBox(width: uiScale.gap(14)),
          Expanded(
            child: Text(
              feature,
              style: TextStyle(
                color: isDark ? cs.onSurface : AppColors.textPrimary,
                fontSize: uiScale.font(uiScale.compact ? 15 : 17),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(UIScale uiScale, bool isDark, ColorScheme cs) {
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) => Opacity(
        opacity: _fadeAnimation.value,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: uiScale.inset(uiScale.tablet ? 32 : 24),
            vertical: uiScale.inset(uiScale.compact ? 16 : 24),
          ),
          child: Column(
            children: [
              // Premium Progress Indicators
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pages.length, (index) {
                  final isActive = index == _currentPage;
                  final activeColor = _pages[_currentPage].gradient.first;

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
                      margin: EdgeInsets.symmetric(horizontal: uiScale.gap(6)),
                      width: isActive ? uiScale.inset(36) : uiScale.inset(12),
                      height: uiScale.inset(10),
                      decoration: BoxDecoration(
                        color: isActive ? activeColor : (isDark ? cs.outline.withOpacity(0.3) : AppColors.mintBgLight),
                        borderRadius: BorderRadius.circular(uiScale.radius(10)),
                        boxShadow: isActive
                            ? [
                          BoxShadow(
                            color: activeColor.withOpacity(0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ]
                            : null,
                      ),
                    ),
                  );
                }),
              ),
              SizedBox(height: uiScale.gap(24)),

              // Navigation Buttons
              LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 320;
                  final activeGradient = _pages[_currentPage].gradient;

                  final nextButton = GestureDetector(
                    onTap: _nextPage,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: _currentPage == _pages.length - 1
                          ? (wide ? uiScale.inset(200) : double.infinity)
                          : (wide ? uiScale.inset(160) : double.infinity),
                      height: uiScale.buttonHeight,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: activeGradient,
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                        borderRadius: BorderRadius.circular(uiScale.radius(32)),
                        boxShadow: [
                          BoxShadow(
                            color: activeGradient.first.withOpacity(uiScale.reduceFx ? 0.20 : 0.40),
                            blurRadius: uiScale.reduceFx ? 14 : 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _currentPage == _pages.length - 1 ? 'Get Started' : 'Next',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: uiScale.font(16),
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                          SizedBox(width: uiScale.gap(8)),
                          Icon(Icons.arrow_forward_rounded, color: Colors.white, size: uiScale.icon(22)),
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
                              width: uiScale.buttonHeight,
                              height: uiScale.buttonHeight,
                              margin: EdgeInsets.only(right: uiScale.gap(16)),
                              decoration: BoxDecoration(
                                color: isDark ? cs.surfaceVariant : Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight, width: 1.5),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 16,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: Icon(Icons.arrow_back_rounded, color: isDark ? cs.onSurface : AppColors.textPrimary, size: uiScale.icon(22)),
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
                          padding: EdgeInsets.only(bottom: uiScale.gap(12)),
                          child: GestureDetector(
                            onTap: _previousPage,
                            child: Container(
                              width: uiScale.buttonHeight,
                              height: uiScale.buttonHeight,
                              decoration: BoxDecoration(
                                color: isDark ? cs.surfaceVariant : Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(color: isDark ? cs.outline.withOpacity(0.5) : AppColors.mintBgLight, width: 1.5),
                              ),
                              child: Icon(Icons.arrow_back_rounded, color: isDark ? cs.onSurface : AppColors.textPrimary, size: uiScale.icon(22)),
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