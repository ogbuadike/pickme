// lib/screens/help_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../api/url.dart';
// For now, I'll use a string directly in the request, but you should move it to ApiConstants.
import '../themes/app_theme.dart';
import '../ui/ui_scale.dart';
import '../utility/notification.dart';

class HelpScreen extends StatefulWidget {
  const HelpScreen({Key? key}) : super(key: key);

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> with SingleTickerProviderStateMixin {
  late ApiClient _api;

  bool _isLoading = true;
  bool _hasError = false;

  List<dynamic> _categories = [];
  List<dynamic> _allFaqs = [];
  List<dynamic> _filteredFaqs = [];
  Map<String, dynamic> _contacts = {};

  int _selectedCategoryId = 0; // 0 means 'All'
  final TextEditingController _searchCtrl = TextEditingController();

  AnimationController? _shimmerController;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(http.Client(), context);
    _shimmerController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
    _fetchHelpData();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _shimmerController?.dispose();
    super.dispose();
  }

  Future<void> _fetchHelpData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      // Replace with your actual ApiConstants endpoint for the help API
      final res = await _api.request(
        ApiConstants.helpEndpoint,
        method: 'GET',
      );

      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data['error'] == false) {
        setState(() {
          _contacts = data['data']['contacts'];
          _categories = [{'id': 0, 'name': 'All'}, ...data['data']['categories']];
          _allFaqs = data['data']['faqs'];
          _filteredFaqs = _allFaqs;
        });
      } else {
        throw Exception('Failed to load help data');
      }
    } catch (e) {
      if (mounted) setState(() => _hasError = true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _filterFaqs(String query) {
    setState(() {
      _filteredFaqs = _allFaqs.where((faq) {
        final matchesCategory = _selectedCategoryId == 0 || faq['category_id'] == _selectedCategoryId;
        final matchesSearch = faq['question'].toString().toLowerCase().contains(query.toLowerCase()) ||
            faq['answer'].toString().toLowerCase().contains(query.toLowerCase());
        return matchesCategory && matchesSearch;
      }).toList();
    });
  }

  void _selectCategory(int id) {
    HapticFeedback.lightImpact();
    setState(() {
      _selectedCategoryId = id;
    });
    _filterFaqs(_searchCtrl.text);
  }

  Future<void> _launchUrl(String scheme, String path) async {
    final Uri url = Uri(scheme: scheme, path: path);
    try {
      await launchUrl(url);
    } catch (e) {
      showToastNotification(context: context, title: 'Error', message: 'Could not open app.', isSuccess: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = UIScale.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : AppColors.offWhite,
      appBar: AppBar(
        backgroundColor: isDark ? Colors.black : AppColors.offWhite,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'Help Center',
          style: TextStyle(fontSize: ui.font(18), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: ui.icon(20), color: isDark ? cs.onSurface : AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading
          ? _buildSkeleton(ui, isDark)
          : _hasError
          ? _buildError(ui, isDark, cs)
          : _buildContent(ui, isDark, cs),
    );
  }

  Widget _buildContent(UIScale ui, bool isDark, ColorScheme cs) {
    return Column(
      children: [
        // Search Bar
        Padding(
          padding: EdgeInsets.fromLTRB(ui.inset(16), ui.gap(8), ui.inset(16), ui.gap(16)),
          child: TextField(
            controller: _searchCtrl,
            onChanged: _filterFaqs,
            style: TextStyle(color: isDark ? cs.onSurface : AppColors.textPrimary, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: 'How can we help you?',
              hintStyle: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary.withOpacity(0.6)),
              prefixIcon: Icon(Icons.search_rounded, color: isDark ? cs.primary : AppColors.primary),
              filled: true,
              fillColor: isDark ? cs.surfaceVariant.withOpacity(0.5) : AppColors.mintBgLight.withOpacity(0.4),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(ui.radius(16)), borderSide: BorderSide.none),
              contentPadding: EdgeInsets.symmetric(vertical: ui.inset(14)),
            ),
          ),
        ),

        // Categories Chips
        SizedBox(
          height: ui.gap(40),
          child: ListView.separated(
            padding: EdgeInsets.symmetric(horizontal: ui.inset(16)),
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: _categories.length,
            separatorBuilder: (_, __) => SizedBox(width: ui.gap(8)),
            itemBuilder: (context, index) {
              final cat = _categories[index];
              final isSelected = _selectedCategoryId == cat['id'];

              return ChoiceChip(
                label: Text(cat['name'], style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(13))),
                selected: isSelected,
                onSelected: (_) => _selectCategory(cat['id']),
                selectedColor: isDark ? cs.primary.withOpacity(0.15) : AppColors.primary.withOpacity(0.15),
                backgroundColor: isDark ? cs.surfaceVariant.withOpacity(0.4) : AppColors.mintBgLight.withOpacity(0.3),
                labelStyle: TextStyle(
                  color: isSelected
                      ? (isDark ? cs.primary : AppColors.primary)
                      : (isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
                ),
                side: BorderSide(
                  color: isSelected
                      ? (isDark ? cs.primary.withOpacity(0.5) : AppColors.primary.withOpacity(0.3))
                      : Colors.transparent,
                ),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ui.radius(12))),
              );
            },
          ),
        ),

        SizedBox(height: ui.gap(8)),

        // FAQs List
        Expanded(
          child: _filteredFaqs.isEmpty
              ? _buildEmptySearch(ui, isDark, cs)
              : ListView.builder(
            padding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.gap(8)),
            physics: const BouncingScrollPhysics(),
            itemCount: _filteredFaqs.length,
            itemBuilder: (context, index) {
              final faq = _filteredFaqs[index];
              return Container(
                margin: EdgeInsets.only(bottom: ui.gap(12)),
                decoration: BoxDecoration(
                  color: isDark ? cs.surface : Colors.white,
                  borderRadius: BorderRadius.circular(ui.radius(16)),
                  border: Border.all(color: isDark ? cs.outline : AppColors.mintBgLight.withOpacity(0.4)),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(isDark ? 0.3 : 0.03), blurRadius: 10, offset: const Offset(0, 4)),
                  ],
                ),
                child: Theme(
                  // Remove the ugly borders from ExpansionTile
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    iconColor: isDark ? cs.primary : AppColors.primary,
                    collapsedIconColor: isDark ? cs.onSurfaceVariant : AppColors.textSecondary,
                    tilePadding: EdgeInsets.symmetric(horizontal: ui.inset(16), vertical: ui.inset(4)),
                    childrenPadding: EdgeInsets.fromLTRB(ui.inset(16), 0, ui.inset(16), ui.inset(16)),
                    title: Text(
                      faq['question'],
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(14), color: isDark ? cs.onSurface : AppColors.textPrimary),
                    ),
                    children: [
                      Text(
                        faq['answer'],
                        style: TextStyle(height: 1.4, fontSize: ui.font(13), fontWeight: FontWeight.w500, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        // Contact Support Footer
        Container(
          padding: EdgeInsets.fromLTRB(ui.inset(16), ui.inset(16), ui.inset(16), ui.inset(32)),
          decoration: BoxDecoration(
            color: isDark ? cs.surface : Colors.white,
            border: Border(top: BorderSide(color: isDark ? cs.outline : AppColors.mintBgLight.withOpacity(0.4))),
          ),
          child: Column(
            children: [
              Text('Still need help?', style: TextStyle(fontWeight: FontWeight.w900, fontSize: ui.font(15), color: isDark ? cs.onSurface : AppColors.textPrimary)),
              SizedBox(height: ui.gap(4)),
              Text('Our support team is available 24/7.', style: TextStyle(fontWeight: FontWeight.w600, fontSize: ui.font(12), color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
              SizedBox(height: ui.gap(16)),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ContactAction(ui: ui, icon: Icons.email_rounded, label: 'Email', color: const Color(0xFF1E8E3E), isDark: isDark, cs: cs, onTap: () => _launchUrl('mailto', _contacts['email'])),
                  SizedBox(width: ui.gap(12)),
                  _ContactAction(ui: ui, icon: Icons.phone_in_talk_rounded, label: 'Call', color: AppColors.primary, isDark: isDark, cs: cs, onTap: () => _launchUrl('tel', _contacts['phone'])),
                  SizedBox(width: ui.gap(12)),
                  _ContactAction(ui: ui, icon: Icons.chat_bubble_rounded, label: 'WhatsApp', color: const Color(0xFF25D366), isDark: isDark, cs: cs, onTap: () => _launchUrl('https', 'wa.me/${_contacts['whatsapp']}')),
                ],
              )
            ],
          ),
        )
      ],
    );
  }

  Widget _buildEmptySearch(UIScale ui, bool isDark, ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off_rounded, size: ui.icon(48), color: isDark ? cs.onSurfaceVariant.withOpacity(0.5) : AppColors.textSecondary.withOpacity(0.3)),
          SizedBox(height: ui.gap(16)),
          Text('No results found', style: TextStyle(fontWeight: FontWeight.w900, fontSize: ui.font(16), color: isDark ? cs.onSurface : AppColors.textPrimary)),
          SizedBox(height: ui.gap(4)),
          Text('Try searching for something else.', style: TextStyle(fontWeight: FontWeight.w600, color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildSkeleton(UIScale ui, bool isDark) {
    if (_shimmerController == null) return const SizedBox();
    final baseColor = isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05);
    final highlightColor = isDark ? Colors.white.withOpacity(0.15) : Colors.black.withOpacity(0.12);

    return AnimatedBuilder(
      animation: _shimmerController!,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: [baseColor, highlightColor, baseColor],
              stops: const [0.1, 0.5, 0.9],
              transform: _SlideGradientTransform(_shimmerController!.value),
            ).createShader(bounds);
          },
          child: ListView(
            padding: EdgeInsets.all(ui.inset(16)),
            children: [
              Container(height: 50, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16))),
              SizedBox(height: ui.gap(16)),
              Row(
                children: [
                  Container(width: 80, height: 35, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12))),
                  SizedBox(width: ui.gap(8)),
                  Container(width: 100, height: 35, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12))),
                ],
              ),
              SizedBox(height: ui.gap(24)),
              ...List.generate(5, (index) => Container(margin: EdgeInsets.only(bottom: ui.gap(12)), height: 60, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)))),
            ],
          ),
        );
      },
    );
  }

  Widget _buildError(UIScale ui, bool isDark, ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off_rounded, size: ui.icon(60), color: cs.error.withOpacity(0.5)),
          SizedBox(height: ui.gap(16)),
          Text('Connection Error', style: TextStyle(fontSize: ui.font(20), fontWeight: FontWeight.w900, color: isDark ? cs.onSurface : AppColors.textPrimary)),
          SizedBox(height: ui.gap(8)),
          Text('Unable to load Help Center.', style: TextStyle(color: isDark ? cs.onSurfaceVariant : AppColors.textSecondary, fontWeight: FontWeight.w600)),
          SizedBox(height: ui.gap(24)),
          ElevatedButton.icon(
            onPressed: _fetchHelpData,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try Again', style: TextStyle(fontWeight: FontWeight.w800)),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark ? cs.primary : AppColors.primary,
              foregroundColor: isDark ? cs.onPrimary : Colors.white,
              padding: EdgeInsets.symmetric(horizontal: ui.inset(24), vertical: ui.inset(12)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ui.radius(30))),
            ),
          )
        ],
      ),
    );
  }
}

class _ContactAction extends StatelessWidget {
  final UIScale ui;
  final IconData icon;
  final String label;
  final Color color;
  final bool isDark;
  final ColorScheme cs;
  final VoidCallback onTap;

  const _ContactAction({required this.ui, required this.icon, required this.label, required this.color, required this.isDark, required this.cs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        borderRadius: BorderRadius.circular(ui.radius(16)),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: ui.inset(12)),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(ui.radius(16)),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: ui.icon(22)),
              SizedBox(height: ui.gap(4)),
              Text(label, style: TextStyle(fontWeight: FontWeight.w800, fontSize: ui.font(12), color: isDark ? cs.onSurface : AppColors.textPrimary)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlideGradientTransform extends GradientTransform {
  final double percent;
  const _SlideGradientTransform(this.percent);
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (percent * 2 - 1), 0, 0);
  }
}