// lib/screens/onboarding_screen.dart
import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../themes/app_theme.dart';
import '../../widgets/inner_background.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final PageController _pageController = PageController(viewportFraction: 0.88);
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
      description: 'Street Rides • Campus Rides\nOrder for yourself or a friend—get from A to B, smarter.',
      icon: Icons.directions_car_rounded,
      gradient: [AppColors.primary, AppColors.secondary],
      features: ['Real-time tracking & reliable ETAs', 'Safe, trained & principled drivers', 'Fair pricing', 'Book for friends'],
      imagePath: 'image/ride_illustration.jpg',
    ),
    OnboardingData(
      title: 'Send Packages with Care',
      subtitle: 'Fast, secure Package Dispatch for your documents and parcels.',
      description: 'Send packages anywhere with our trained dispatch riders. Track your items from pickup to delivery with complete peace of mind.',
      icon: Icons.local_shipping_rounded,
      gradient: [AppColors.secondary, AppColors.primary],
      features: ['Live updates from pickup to drop-off', 'Insured & verified dispatch riders', 'Door-to-door convenience', 'Trained riders'],
      imagePath: 'image/dispatch.jpg',
    ),
    OnboardingData(
      title: 'Move Smarter with “Send Me”',
      subtitle: 'Connect & Transact',
      description: 'Your in-app hub to send, receive and get tasks done.\nRun errands, support your business—get more done.',
      icon: Icons.hub_rounded,
      gradient: [AppColors.primary, AppColors.mintBg],
      features: ['Post requests and get help fast', 'For individuals and small businesses', 'Quick service', 'Built into Pick Me—no extra apps'],
      imagePath: 'image/send_me1.jpg',
    ),
    OnboardingData(
      title: 'Safety • Respect • Kindness',
      subtitle: 'Your Security Matters',
      description: 'Every ride and delivery is protected. Our drivers and riders are well-trained, principled professionals committed to your safety.',
      icon: Icons.shield_rounded,
      gradient: [AppColors.success, AppColors.primary],
      features: ['Emergency button', '24/7 support', 'Trip sharing', 'Background checks'],
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

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _mainController, curve: const Interval(0.0, 0.5, curve: Curves.easeOut)),
    );

    _scaleAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _mainController, curve: Curves.elasticOut),
    );

    _slideAnimation = Tween<double>(begin: 50.0, end: 0.0).animate(
      CurvedAnimation(parent: _mainController, curve: const Interval(0.2, 0.8, curve: Curves.easeOutCubic)),
    );

    _rotateAnimation = Tween<double>(begin: -0.08, end: 0.0).animate(
      CurvedAnimation(parent: _mainController, curve: Curves.easeOutBack),
    );

    _particleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(_particleController);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.12).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _waveAnimation = Tween<double>(begin: 0.0, end: 2 * math.pi).animate(_waveController);

    _shimmerAnimation = Tween<double>(begin: -2.0, end: 2.0).animate(
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
    final size = MediaQuery.of(context).size;
    final isTablet = size.shortestSide > 600;
    final isLandscape = size.width > size.height;

    return Scaffold(
      backgroundColor: AppColors.backgroundColor,
      body: Stack(
        children: [
          const BackgroundWidget(
            style: HoloStyle.flux,
            animate: true,
            intensity: 0.5,
          ),

          AnimatedBuilder(
            animation: _particleAnimation,
            builder: (context, _) => CustomPaint(
              painter: AdvancedParticlePainter(
                progress: _particleAnimation.value,
                color: AppColors.primary,
              ),
              size: Size.infinite,
            ),
          ),

          AnimatedBuilder(
            animation: _waveAnimation,
            builder: (context, _) => CustomPaint(
              painter: WavePainter(
                progress: _waveAnimation.value,
                color: AppColors.secondary.withOpacity(0.1),
              ),
              size: Size.infinite,
            ),
          ),

          SafeArea(
            child: Column(
              children: [
                _buildHeader(context, isTablet),
                Expanded(
                  child: isLandscape
                      ? _buildLandscapeLayout(isTablet)
                      : _buildPortraitLayout(isTablet),
                ),
                _buildFooter(context, isTablet),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isTablet) {
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) => Opacity(
        opacity: _fadeAnimation.value,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: isTablet ? 32 : 24,
            vertical: isTablet ? 20 : 16,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, _) => Transform.scale(
                  scale: _pulseAnimation.value,
                  child: Container(
                    width: isTablet ? 56 : 50,
                    height: isTablet ? 56 : 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [AppColors.primary, AppColors.secondary],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withOpacity(0.5),
                          blurRadius: 24,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: Center(
                      child: Image.asset(
                        'image/pickme.png',
                        width: isTablet ? 32 : 28,
                        height: isTablet ? 32 : 28,
                        color: Colors.white,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),

              TextButton(
                onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(
                    horizontal: isTablet ? 24 : 20,
                    vertical: isTablet ? 14 : 12,
                  ),
                  backgroundColor: AppColors.surface.withOpacity(0.9),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      'Skip',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w700,
                        fontSize: isTablet ? 16 : 14,
                      ),
                    ),
                    SizedBox(width: isTablet ? 6 : 4),
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: isTablet ? 20 : 18,
                      color: AppColors.textSecondary,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitLayout(bool isTablet) {
    return PageView.builder(
      controller: _pageController,
      onPageChanged: (index) {
        setState(() => _currentPage = index);
        _mainController.reset();
        _mainController.forward();
        HapticFeedback.lightImpact();
      },
      itemCount: _pages.length,
      itemBuilder: (context, index) {
        return AnimatedBuilder(
          animation: _pageController,
          builder: (context, child) {
            double value = 1.0;
            if (_pageController.position.haveDimensions) {
              value = (_pageController.page ?? 0) - index;
              value = (1 - (value.abs() * 0.4)).clamp(0.0, 1.0);
            }

            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.002)
                ..rotateY(value * 0.1)
                ..scale(0.85 + (value * 0.15)),
              child: Opacity(
                opacity: 0.3 + (value * 0.7),
                child: child,
              ),
            );
          },
          child: _buildCard(_pages[index], isTablet),
        );
      },
    );
  }

  Widget _buildLandscapeLayout(bool isTablet) {
    final data = _pages[_currentPage];
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: Center(
            child: SizedBox(
              height: 450,
              width: 380,
              child: _buildCard(data, isTablet),
            ),
          ),
        ),
        Expanded(
          flex: 5,
          child: AnimatedBuilder(
            animation: _fadeAnimation,
            builder: (context, child) => Opacity(
              opacity: _fadeAnimation.value,
              child: Padding(
                padding: EdgeInsets.all(isTablet ? 48 : 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.title,
                      style: TextStyle(
                        fontSize: isTablet ? 48 : 36,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                        height: 1.1,
                        letterSpacing: -1,
                      ),
                    ),
                    SizedBox(height: isTablet ? 12 : 8),
                    Text(
                      data.subtitle,
                      style: TextStyle(
                        fontSize: isTablet ? 28 : 22,
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: isTablet ? 32 : 24),
                    Text(
                      data.description,
                      style: TextStyle(
                        fontSize: isTablet ? 20 : 18,
                        color: AppColors.textSecondary,
                        height: 1.6,
                      ),
                    ),
                    SizedBox(height: isTablet ? 40 : 32),
                    ...data.features.map((f) => _buildFeatureBullet(f, isTablet)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCard(OnboardingData data, bool isTablet) {
    return AnimatedBuilder(
      animation: Listenable.merge([_scaleAnimation, _slideAnimation, _rotateAnimation]),
      builder: (context, _) => Transform.translate(
        offset: Offset(0, _slideAnimation.value),
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateZ(_rotateAnimation.value * 0.5)
            ..scale(_scaleAnimation.value),
          child: Container(
            margin: EdgeInsets.symmetric(
              horizontal: isTablet ? 12 : 8,
              vertical: isTablet ? 32 : 24,
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _shimmerAnimation,
                    builder: (context, child) => Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(36),
                        gradient: LinearGradient(
                          begin: Alignment(-1 + _shimmerAnimation.value, -1),
                          end: Alignment(1 + _shimmerAnimation.value, 1),
                          colors: [
                            data.gradient.first.withOpacity(0.3),
                            data.gradient.last.withOpacity(0.1),
                            data.gradient.first.withOpacity(0.3),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                ClipRRect(
                  borderRadius: BorderRadius.circular(36),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            data.gradient.first.withOpacity(0.9),
                            data.gradient.last.withOpacity(0.75),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(36),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.25),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: data.gradient.first.withOpacity(0.4),
                            blurRadius: 40,
                            offset: const Offset(0, 20),
                          ),
                          BoxShadow(
                            color: data.gradient.last.withOpacity(0.3),
                            blurRadius: 60,
                            offset: const Offset(0, 30),
                          ),
                        ],
                      ),
                      padding: EdgeInsets.all(isTablet ? 48 : 36),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              width: double.infinity,
                              height: isTablet ? 180 : 150,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Image.asset(
                                data.imagePath,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => Container(
                                  color: Colors.white.withOpacity(0.1),
                                  child: Icon(
                                    data.icon,
                                    size: isTablet ? 80 : 70,
                                    color: Colors.white.withOpacity(0.6),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          SizedBox(height: isTablet ? 32 : 28),

                          Text(
                            data.title,
                            style: TextStyle(
                              fontSize: isTablet ? 38 : 32,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                              letterSpacing: -0.5,
                              height: 1.1,
                            ),
                            textAlign: TextAlign.center,
                          ),

                          SizedBox(height: isTablet ? 12 : 10),

                          Text(
                            data.subtitle,
                            style: TextStyle(
                              fontSize: isTablet ? 22 : 20,
                              fontWeight: FontWeight.w700,
                              color: Colors.white.withOpacity(0.95),
                            ),
                            textAlign: TextAlign.center,
                          ),

                          SizedBox(height: isTablet ? 24 : 20),

                          Text(
                            data.description,
                            style: TextStyle(
                              fontSize: isTablet ? 17 : 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              height: 1.6,
                            ),
                            textAlign: TextAlign.center,
                          ),

                          SizedBox(height: isTablet ? 28 : 24),

                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: isTablet ? 12 : 10,
                            runSpacing: isTablet ? 12 : 10,
                            children: data.features.map((feature) {
                              return Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: isTablet ? 18 : 16,
                                  vertical: isTablet ? 10 : 9,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.4),
                                    width: 1.5,
                                  ),
                                ),
                                child: Text(
                                  feature,
                                  style: TextStyle(
                                    fontSize: isTablet ? 14 : 13,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),

                          if (data.isSafety) ...[
                            SizedBox(height: isTablet ? 36 : 32),
                            _buildSafetyCard(isTablet),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSafetyCard(bool isTablet) {
    return Container(
      padding: EdgeInsets.all(isTablet ? 24 : 20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withOpacity(0.3),
          width: 2,
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
                size: isTablet ? 26 : 22,
              ),
              SizedBox(width: isTablet ? 12 : 10),
              Text(
                'Our Commitment to You',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: isTablet ? 18 : 16,
                ),
              ),
            ],
          ),
          SizedBox(height: isTablet ? 18 : 16),
          ...[
            'Treat everyone with kindness & respect',
            'Help keep one another safe; follow local laws',
            'Report any abuse or misconduct immediately',
          ].map((text) => Padding(
            padding: EdgeInsets.only(bottom: isTablet ? 10 : 8),
            child: Row(
              children: [
                Container(
                  width: isTablet ? 8 : 7,
                  height: isTablet ? 8 : 7,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
                SizedBox(width: isTablet ? 14 : 12),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: isTablet ? 15 : 14,
                      color: Colors.white.withOpacity(0.95),
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildFeatureBullet(String feature, bool isTablet) {
    return Padding(
      padding: EdgeInsets.only(bottom: isTablet ? 16 : 12),
      child: Row(
        children: [
          Container(
            width: isTablet ? 12 : 10,
            height: isTablet ? 12 : 10,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.primary, AppColors.secondary],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(0.4),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
          SizedBox(width: isTablet ? 16 : 14),
          Expanded(
            child: Text(
              feature,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: isTablet ? 18 : 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context, bool isTablet) {
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) => Opacity(
        opacity: _fadeAnimation.value,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: isTablet ? 32 : 24,
            vertical: isTablet ? 40 : 32,
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
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                      margin: EdgeInsets.symmetric(horizontal: isTablet ? 6 : 5),
                      width: isActive ? (isTablet ? 48 : 40) : (isTablet ? 12 : 10),
                      height: isTablet ? 12 : 10,
                      decoration: BoxDecoration(
                        gradient: isActive
                            ? LinearGradient(
                          colors: [AppColors.primary, AppColors.secondary],
                        )
                            : null,
                        color: isActive ? null : AppColors.mintBgLight,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: isActive
                            ? [
                          BoxShadow(
                            color: AppColors.primary.withOpacity(0.5),
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

              SizedBox(height: isTablet ? 40 : 32),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_currentPage > 0)
                    GestureDetector(
                      onTap: _previousPage,
                      child: Container(
                        width: isTablet ? 60 : 56,
                        height: isTablet ? 60 : 56,
                        margin: EdgeInsets.only(right: isTablet ? 20 : 16),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.mintBgLight,
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.arrow_back_rounded,
                          color: AppColors.primary,
                          size: isTablet ? 28 : 24,
                        ),
                      ),
                    ),

                  GestureDetector(
                    onTap: _nextPage,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: _currentPage == _pages.length - 1
                          ? (isTablet ? 220 : 200)
                          : (isTablet ? 200 : 180),
                      height: isTablet ? 66 : 60,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [AppColors.primary, AppColors.secondary],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                        borderRadius: BorderRadius.circular(35),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withOpacity(0.5),
                            blurRadius: 24,
                            offset: const Offset(0, 12),
                          ),
                          BoxShadow(
                            color: AppColors.secondary.withOpacity(0.3),
                            blurRadius: 32,
                            offset: const Offset(0, 16),
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
                              fontSize: isTablet ? 20 : 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                          SizedBox(width: isTablet ? 10 : 8),
                          Icon(
                            Icons.arrow_forward_rounded,
                            color: Colors.white,
                            size: isTablet ? 26 : 24,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
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

  OnboardingData({
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
  bool shouldRepaint(AdvancedParticlePainter old) => old.progress != progress;
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
  bool shouldRepaint(WavePainter old) => old.progress != progress;
}