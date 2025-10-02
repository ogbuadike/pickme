import 'package:flutter/material.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import '../../themes/app_theme.dart';


class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  _OnboardingScreenState createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Dynamic background with gradient and custom curved effect
      body: Stack(
        children: [
          // Positioned background container with a gradient that adapts to light/dark theme
          Positioned.fill(
            child: CustomPaint(
              painter: CurvedPainter(
                startColor: Theme.of(context).colorScheme.surface,
                endColor: Theme.of(context).colorScheme.secondary,
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
              child: Column(
                children: [
                  // PageView for onboarding slides
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      onPageChanged: (index) {
                        setState(() {
                          _currentPage = index;
                        });
                      },
                      children: const [
                        OnboardingSlide(
                          image: 'images/simplifiedbillpayments.png',
                          title: 'Simplified Bill Payments',
                          description: 'Effortlessly pay for services like electricity, GOTV, and DSTV subscriptions.',
                        ),
                        OnboardingSlide(
                          image: 'images/quicktransactions.png',
                          title: 'Quick Transactions',
                          description: 'Make everyday payments and transactions quick and hassle-free.',
                        ),
                        OnboardingSlide(
                          image: 'images/buysellgiftcards.png',
                          title: 'Buy & Sell Gift Cards',
                          description: 'A convenient platform to buy and sell gift cards at competitive rates.',
                        ),
                      ],
                    ),
                  ),
                  // Smooth page indicator with dynamic color
                  SmoothPageIndicator(
                    controller: _pageController,
                    count: 3,
                    effect: ExpandingDotsEffect(
                      dotHeight: 8.0,
                      dotWidth: 8.0,
                      activeDotColor: Theme.of(context).colorScheme.surface, // Dynamic color
                      dotColor: Theme.of(context).colorScheme.secondary, // Dynamic color
                    ),
                  ),
                  const SizedBox(height: 24.0),
                  // Navigation buttons: Skip and Next/Get Started
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () {
                          // Navigate to login when skipping the onboarding process
                          Navigator.pushReplacementNamed(context, '/login');
                        },
                        child: Text(
                          'Skip',
                          style: Theme.of(context).textTheme.bodyMedium, // Dynamic text style
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          if (_currentPage == 2) {
                            // Navigate to the login screen when finished with onboarding
                            Navigator.pushReplacementNamed(context, '/login');
                          } else {
                            // Move to the next slide in the onboarding process
                            _pageController.nextPage(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeIn,
                            );
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.secondary, // Dynamic button color
                          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30.0),
                          ),
                        ),
                        child: Text(
                          _currentPage == 2 ? 'Get Started' : 'Next',
                          style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                            color: Theme.of(context).colorScheme.onPrimary, // Dynamic text color on button
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Widget representing each onboarding slide
class OnboardingSlide extends StatelessWidget {
  final String image;
  final String title;
  final String description;

  const OnboardingSlide({super.key, 
    required this.image,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset(
          image, // Use asset image instead of network image
          height: 200.0, // Height of the image
          fit: BoxFit.contain, // Contain to keep image proportions
        ),
        const SizedBox(height: 24.0), // Space between image and title
        Text(
          title,
          style: AppTextStyles.heading.copyWith(
            color: Theme.of(context).colorScheme.onPrimary,
            // Apply the displayLarge text style from the theme
            fontSize: Theme.of(context).textTheme.displayLarge?.fontSize,
            fontWeight: Theme.of(context).textTheme.displayLarge?.fontWeight,
          ),
          textAlign: TextAlign.center, // Center-align the text
        ),
        const SizedBox(height: 16.0), // Space between title and description
        Text(
          description,
          style: Theme.of(context).textTheme.bodyMedium, // Body text style from your theme
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// Custom Painter for the curved background
class CurvedPainter extends CustomPainter {
  final Color startColor;
  final Color endColor;

  CurvedPainter({required this.startColor, required this.endColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [startColor, endColor],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final path = Path()
      ..lineTo(0, size.height * 0.4)
      ..quadraticBezierTo(
        size.width * 0.5, size.height * 0.5, // Control point
        size.width, size.height * 0.3, // End point
      )
      ..lineTo(size.width, 0)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) {
    return false;
  }
}