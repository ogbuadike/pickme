import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../api/api_client.dart';
import '../api/url.dart';
import '../themes/app_theme.dart';
import '../utility/notification.dart';

typedef QuickPayButtonCallback = void Function(String name, String code);

class QuickPaySection extends StatefulWidget {
  final QuickPayButtonCallback onQuickPayButtonPressed;

  const QuickPaySection({
    Key? key,
    required this.onQuickPayButtonPressed,
  }) : super(key: key);

  @override
  _QuickPaySectionState createState() => _QuickPaySectionState();
}

class _QuickPaySectionState extends State<QuickPaySection> {
  late ApiClient _apiClient;
  List<Map<String, dynamic>> quickPayOptions = [];
  List<Map<String, dynamic>> allBillOptions = [];
  Map<String, String> iconMappings = {};

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(http.Client(), context);
    _loadQuickPayOptions();
    _fetchBillList();
  }

  Future<void> _loadQuickPayOptions() async {
    final prefs = await SharedPreferences.getInstance();
    final savedOptions = prefs.getStringList('quick_pay_options') ?? [];
    setState(() {
      quickPayOptions = savedOptions.map((option) => Map<String, dynamic>.from(jsonDecode(option))).toList();
      if (quickPayOptions.isEmpty) {
        quickPayOptions = [
          {'name': 'Airtime', 'code': 'AIRTIME'},
          {'name': 'Mobile Data', 'code': 'MOBILEDATA'},
          {'name': 'Internet', 'code': 'INTSERVICE'},
          {'name': 'Cable TV', 'code': 'CABLEBILLS'},
          {'name': 'Electricity', 'code': 'UTILITYBILLS'},
        ];
      }
    });
  }

  Future<void> _fetchBillList() async {
    try {
      final response = await _apiClient.request(ApiConstants.billList, method: 'GET');
      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        if (responseData['status'] == 'success') {
          setState(() {
            allBillOptions = List<Map<String, dynamic>>.from(responseData['data']);
            iconMappings = Map<String, String>.from(responseData['icons'] ?? {});
          });
        }
      }
    } catch (error) {
      print('Error fetching bill list: $error');
    }
  }

  Future<void> _saveQuickPayOptions() async {
    final prefs = await SharedPreferences.getInstance();
    final optionsToSave = quickPayOptions.map((option) => jsonEncode(option)).toList();
    await prefs.setStringList('quick_pay_options', optionsToSave);
  }

  IconData _getIconForBiller(String billerName) {
    final normalizedBillerName = billerName.toLowerCase();
    if (iconMappings.containsKey(normalizedBillerName)) {
      return _getIconDataFromString(iconMappings[normalizedBillerName]!);
    }
    return _matchIconByKeywords(normalizedBillerName);
  }

  IconData _matchIconByKeywords(String billerName) {
    if (billerName.contains('airtime') || billerName.contains('phone') || billerName.contains('call')) {
      return Icons.smartphone_rounded;
    } else if (billerName.contains('data')) {
      return Icons.wifi_tethering_rounded;
    } else if (billerName.contains('internet')) {
      return Icons.storage;
    } else if (billerName.contains('tv') || billerName.contains('cable')) {
      return Icons.tv_rounded;
    } else if (billerName.contains('electricity') || billerName.contains('power')) {
      return Icons.bolt_rounded;
    } else if (billerName.contains('water')) {
      return Icons.water_drop_rounded;
    } else if (billerName.contains('education') || billerName.contains('school')) {
      return Icons.school_rounded;
    } else if (billerName.contains('tax')) {
      return Icons.receipt_long_rounded;
    } else if (billerName.contains('donation')) {
      return Icons.volunteer_activism;
    } else if (billerName.contains('transport') || billerName.contains('bus')) {
      return Icons.directions_bus_filled_rounded;
    } else if (billerName.contains('religious') || billerName.contains('church')) {
      return Icons.church_rounded;
    }
    return Icons.account_balance_wallet_rounded;
  }

  IconData _getIconDataFromString(String iconName) {
    switch (iconName.toLowerCase()) {
      case 'phone': return Icons.smartphone_rounded;
      case 'mobile': return Icons.phone_iphone_rounded;
      case 'data': return Icons.wifi_tethering_rounded;
      case 'wifi': return Icons.wifi_rounded;
      case 'tv': return Icons.tv_rounded;
      case 'electricity': return Icons.bolt_rounded;
      case 'water': return Icons.water_drop_rounded;
      case 'education': return Icons.school_rounded;
      case 'tax': return Icons.receipt_long_rounded;
      case 'donation': return Icons.volunteer_activism;
      case 'transport': return Icons.directions_bus_filled_rounded;
      case 'religious': return Icons.church_rounded;
      default: return Icons.account_balance_wallet_rounded;
    }
  }

  Color _getColorForIcon(IconData icon) {
    if (icon == Icons.smartphone_rounded) return Colors.blue[600]!;
    if (icon == Icons.wifi_tethering_rounded) return Colors.green[600]!;
    if (icon == Icons.tv_rounded) return Colors.red[600]!;
    if (icon == Icons.bolt_rounded) return Colors.yellow[700]!;
    if (icon == Icons.water_drop_rounded) return Colors.lightBlue[500]!;
    if (icon == Icons.school_rounded) return Colors.orange[600]!;
    if (icon == Icons.receipt_long_rounded) return Colors.grey[700]!;
    if (icon == Icons.volunteer_activism) return Colors.pink[400]!;
    if (icon == Icons.directions_bus_filled_rounded) return Colors.indigo[600]!;
    if (icon == Icons.church_rounded) return Colors.purple[600]!;
    if (icon == Icons.phone_iphone_rounded) return Colors.cyan[600]!;
    if (icon == Icons.wifi_rounded) return Colors.lightGreen[600]!;
    if (icon == Icons.storage) return Colors.blue[900]!;
    return Colors.teal[600]!;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80, // Reduced height
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: quickPayOptions.length + 1,
        itemBuilder: (context, index) {
          if (index == quickPayOptions.length) {
            return _buildAddButton();
          }
          final option = quickPayOptions[index];
          return _buildQuickPayButton(option['name'], option['code']);
        },
      ),
    );
  }

  Widget _buildAddButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: InkWell(
        onTap: _showBillOptionsBottomSheet,
        child: Column(
          children: [
            CircleAvatar(
              backgroundColor: AppColors.accentColor,
              radius: 20, // Smaller radius
              child: const Icon(Icons.add, color: AppColors.textOnLightPrimary, size: 16), // Smaller icon
            ),
            const SizedBox(height: 4), // Reduced spacing
            Text('Add', style: AppTextStyles.bodyText.copyWith(fontSize: 12)), // Smaller font
          ],
        ),
      ),
    );
  }

  Widget _buildQuickPayButton(String name, String code) {
    const int maxLength = 10; // Reduced max length
    String truncatedName = name.length > maxLength ? '${name.substring(0, maxLength)}...' : name;
    IconData iconData = _getIconForBiller(name);
    Color iconColor = _getColorForIcon(iconData);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: InkWell(
        onTap: () => widget.onQuickPayButtonPressed(name, code),
        child: Column(
          children: [
            CircleAvatar(
              backgroundColor: AppColors.primaryColor,
              radius: 20, // Smaller radius
              child: Icon(
                iconData,
                color: iconColor,
                size: 16, // Smaller icon
              ),
            ),
            const SizedBox(height: 4), // Reduced spacing
            Container(
              width: 60, // Reduced width
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  truncatedName,
                  style: AppTextStyles.bodyText.copyWith(fontSize: 12), // Smaller font
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showBillOptionsBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.50,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return StatefulBuilder(
              builder: (BuildContext context, StateSetter setModalState) {
                return Container(
                  decoration: BoxDecoration(
                    color: AppColors.backgroundColor,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  child: Column(
                    children: [
                      Center(
                        child: Container(
                          height: 5,
                          width: 40,
                          margin: EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(2.5),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          controller: scrollController,
                          padding: EdgeInsets.all(16), // Reduced padding
                          children: [
                            Text(
                              'Customize Quick Pay Options',
                              style: AppTextStyles.heading2.copyWith(fontSize: 20), // Smaller font
                            ),
                            SizedBox(height: 16), // Reduced spacing
                            ListView.builder(
                              shrinkWrap: true,
                              physics: NeverScrollableScrollPhysics(),
                              itemCount: allBillOptions.length,
                              itemBuilder: (context, index) {
                                final option = allBillOptions[index];
                                final isSelected = quickPayOptions.any((qpo) => qpo['code'] == option['code']);

                                return CheckboxListTile(
                                  title: Text(
                                    option['name'],
                                    style: AppTextStyles.bodyText.copyWith(fontSize: 14), // Smaller font
                                  ),
                                  value: isSelected,
                                  onChanged: (bool? value) {
                                    setModalState(() {
                                      if (value == true && quickPayOptions.length < 5) {
                                        if (!quickPayOptions.any((qpo) => qpo['code'] == option['code'])) {
                                          quickPayOptions.add(option);
                                        }
                                      } else {
                                        if (quickPayOptions.length >= 5 && value == true) {
                                          showAdvancedNotification(
                                            context: context,
                                            title: 'Sorry',
                                            message: 'You can only set a max of 5 options',
                                            isSuccess: false,
                                          );
                                        } else {
                                          quickPayOptions.removeWhere((qpo) => qpo['code'] == option['code']);
                                        }
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                            SizedBox(height: 16), // Reduced spacing
                            ElevatedButton(
                              onPressed: () {
                                _saveQuickPayOptions();
                                Navigator.pop(context);
                                this.setState(() {});
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.accentColor,
                                foregroundColor: Colors.white,
                                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8), // Reduced padding
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: Text('Save', style: AppTextStyles.bodyText.copyWith(fontSize: 14)), // Smaller font
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}