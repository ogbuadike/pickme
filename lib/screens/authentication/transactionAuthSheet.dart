import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../../api/api_client.dart';
import '../../api/url.dart';
import '../../utility/notification.dart';
import '../../themes/app_theme.dart';

class TransactionPinBottomSheet extends StatefulWidget {
  static const int _maxAttempts = 5;
  static const int _lockDurationMinutes = 5;
  static const int _pinLength = 4;

  final Function(bool) onAuthenticationComplete;
  final ApiClient apiClient;

  const TransactionPinBottomSheet({
    Key? key,
    required this.onAuthenticationComplete,
    required this.apiClient,
  }) : super(key: key);

  static Future<bool> show(BuildContext context, ApiClient apiClient) async {
    return await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TransactionPinBottomSheet(
        onAuthenticationComplete: (success) => Navigator.pop(context, success),
        apiClient: apiClient,
      ),
    ) ?? false;
  }

  @override
  State<TransactionPinBottomSheet> createState() => _TransactionPinBottomSheetState();
}

class _TransactionPinBottomSheetState extends State<TransactionPinBottomSheet> {
  final TextEditingController _pinController = TextEditingController();
  final FocusNode _pinFocusNode = FocusNode();
  final LocalAuthentication _localAuth = LocalAuthentication();
  late SharedPreferences _prefs;
  DateTime? _lockTime;

  bool _isBiometricAvailable = false;
  bool _isLoading = false;
  bool _isLocked = false;
  int _failedAttempts = 0;

  @override
  void initState() {
    super.initState();
    _initializePrefs();
    _checkBiometricAvailability();
    _pinController.addListener(_onPinChanged);
  }

  @override
  void dispose() {
    _pinController.dispose();
    _pinFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initializePrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _loadStoredData();
  }

  void _loadStoredData() {
    setState(() {
      _failedAttempts = _prefs.getInt('failed_attempts') ?? 0;
      final lockTimeStr = _prefs.getString('lock_time');
      if (lockTimeStr != null) {
        _lockTime = DateTime.parse(lockTimeStr);
        _checkLockStatus();
      }
    });
  }

  Future<void> _checkBiometricAvailability() async {
    try {
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;
      final hasBiometrics = await _localAuth.isDeviceSupported();
      final availableBiometrics = await _localAuth.getAvailableBiometrics();

      setState(() {
        _isBiometricAvailable = canCheckBiometrics &&
            hasBiometrics &&
            availableBiometrics.isNotEmpty;
      });
    } catch (e) {
      print('Error checking biometrics: $e');
      setState(() {
        _isBiometricAvailable = false;
      });
    }
  }

  void _checkLockStatus() {
    if (_lockTime == null) return;

    final lockDuration = DateTime.now().difference(_lockTime!);
    if (lockDuration.inMinutes < TransactionPinBottomSheet._lockDurationMinutes) {
      setState(() => _isLocked = true);
      Future.delayed(
        Duration(minutes: TransactionPinBottomSheet._lockDurationMinutes - lockDuration.inMinutes),
        _resetLockState,
      );
    } else {
      _resetLockState();
    }
  }

  void _resetLockState() {
    _prefs.remove('lock_time');
    _prefs.setInt('failed_attempts', 0);
    setState(() {
      _isLocked = false;
      _failedAttempts = 0;
    });
  }

  void _onPinChanged() {
    if (_pinController.text.length >= TransactionPinBottomSheet._pinLength) {
      if (_pinController.text.length > TransactionPinBottomSheet._pinLength) {
        _pinController.text = _pinController.text.substring(
          0,
          TransactionPinBottomSheet._pinLength,
        );
        _pinController.selection = TextSelection.fromPosition(
          TextPosition(offset: TransactionPinBottomSheet._pinLength),
        );
      }
      FocusScope.of(context).unfocus();
    }
    setState(() {});
  }

  Future<void> _handleAuthentication() async {
    if (_isLocked) {
      showToastNotification(
        context: context,
        title: 'Account Locked',
        message: 'Too many failed attempts. Please try again later.',
        isSuccess: false,
      );
      Navigator.pop(context);
      return;
    }

    final pin = _pinController.text;
    if (pin.length != TransactionPinBottomSheet._pinLength) {
      showToastNotification(
        context: context,
        title: 'Invalid PIN',
        message: 'Please enter a 4-digit PIN',
        isSuccess: false,
      );
      Navigator.pop(context);
      return;
    }

    await _verifyPin(pin);
  }

  Future<void> _verifyPin(String pin) async {
    setState(() => _isLoading = true);

    try {
      final userId = _prefs.getString('user_id');
      final data = {
        'uid': userId ?? '',
        'pin': pin,
      };

      final response = await widget.apiClient.request(
        ApiConstants.validatePinEndpoint,
        method: 'POST',
        data: data,
      );

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200) {
        if (responseData['error'] == false) {
          _handleSuccessfulAuthentication();
        } else {
          _handleFailedAttempt();
          showToastNotification(
            context: context,
            title: 'Authentication Failed',
            message: responseData['message'] ?? 'Incorrect PIN. Please try again.',
            isSuccess: false,
          );
          Navigator.pop(context);
        }
      } else {
        _handleFailedAttempt();
        showToastNotification(
          context: context,
          title: 'Server Error',
          message: 'Please try again later.',
          isSuccess: false,
        );
        Navigator.pop(context);
      }
    } catch (error) {
      print('PIN verification error: $error');
      _handleFailedAttempt();
      showToastNotification(
        context: context,
        title: 'Error',
        message: 'Error verifying PIN. Please try again.',
        isSuccess: false,
      );
      Navigator.pop(context);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _handleSuccessfulAuthentication() {
    _pinController.clear();
    _failedAttempts = 0;
    _prefs.setInt('failed_attempts', 0);
    widget.onAuthenticationComplete(true);
  }

  void _handleFailedAttempt() {
    _failedAttempts++;
    _prefs.setInt('failed_attempts', _failedAttempts);
    _pinController.clear();

    if (_failedAttempts >= TransactionPinBottomSheet._maxAttempts) {
      _handleTooManyAttempts();
    }
  }

  void _handleTooManyAttempts() {
    setState(() => _isLocked = true);
    _lockTime = DateTime.now();
    _prefs.setString('lock_time', _lockTime!.toIso8601String());
    showToastNotification(
      context: context,
      title: 'Account Locked',
      message: 'Too many failed attempts. Please try again in 5 minutes.',
      isSuccess: false,
    );
  }

  Future<void> _authenticateWithBiometrics() async {
    if (_isLocked) {
      showToastNotification(
        context: context,
        title: 'Account Locked',
        message: 'Too many failed attempts. Please try again later.',
        isSuccess: false,
      );
      return;
    }

    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Authenticate to complete transaction',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );

      if (authenticated) {
        widget.onAuthenticationComplete(true);
      }
    } on PlatformException catch (e) {
      String message = 'Authentication failed';
      if (e.code == 'NotEnrolled') {
        message = 'No fingerprints are enrolled. Please enroll in your settings.';
      } else if (e.code == 'LockedOut') {
        message = 'Too many failed attempts. Please try again later.';
      }
      showToastNotification(
        context: context,
        title: 'Authentication Failed',
        message: message,
        isSuccess: false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.textOnDarkAccent.withOpacity(0.9),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 10, // Reduced padding
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(screenWidth),
            const SizedBox(height: 12), // Reduced spacing
            _buildPinInput(screenWidth),
            if (_isBiometricAvailable) _buildBiometricButton(),
            const SizedBox(height: 12), // Reduced spacing
            _buildActionButtons(screenWidth),
            const SizedBox(height: 12), // Reduced spacing
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(double screenWidth) {
    return Column(
      children: [
        const SizedBox(height: 16), // Reduced spacing
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.textPrimary.withOpacity(0.5),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 16), // Reduced spacing
        const Icon(
          Icons.lock_outline,
          size: 32, // Reduced icon size
          color: AppColors.textOnLightSecondary,
        ),
        const SizedBox(height: 12), // Reduced spacing
        const Text(
          'Transaction PIN',
          style: TextStyle(
            fontSize: 20, // Reduced font size
            fontWeight: FontWeight.bold,
            color: AppColors.textOnLightSecondary,
          ),
        ),
        const SizedBox(height: 8), // Reduced spacing
        Padding(
          padding: EdgeInsets.symmetric(horizontal: screenWidth * 0.05), // Responsive padding
          child: const Text(
            'To complete this transaction, please enter your 4-Digit transaction PIN',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textOnLightSecondary,
              fontSize: 14, // Reduced font size
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPinInput(double screenWidth) {
    return Column(
      children: [
        GestureDetector(
          onTap: () => FocusScope.of(context).requestFocus(_pinFocusNode),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(TransactionPinBottomSheet._pinLength, (index) {
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 6), // Reduced margin
                width: 40, // Reduced width
                height: 40, // Reduced height
                decoration: BoxDecoration(
                  border: Border.all(
                    color: index < _pinController.text.length
                        ? AppColors.textOnLightSecondary
                        : AppColors.primaryColor,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    index < _pinController.text.length ? '*' : '',
                    style: const TextStyle(
                      fontSize: 20, // Reduced font size
                      color: Colors.white,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12), // Reduced padding
          child: SizedBox(
            width: 0,
            height: 0,
            child: TextField(
              controller: _pinController,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(TransactionPinBottomSheet._pinLength),
              ],
              autofocus: true,
              focusNode: _pinFocusNode,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBiometricButton() {
    return IconButton(
      icon: const Icon(
        Icons.fingerprint,
        color: AppColors.primaryColor,
        size: 30, // Reduced icon size
      ),
      onPressed: _authenticateWithBiometrics,
    );
  }

  Widget _buildActionButtons(double screenWidth) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: screenWidth * 0.05), // Responsive padding
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Close',
                style: TextStyle(
                  color: AppColors.darkBackground,
                  fontSize: 14, // Reduced font size
                ),
              ),
            ),
          ),
          Expanded(
            child: TextButton(
              onPressed: _pinController.text.length == TransactionPinBottomSheet._pinLength
                  ? _handleAuthentication
                  : null,
              child: Text(
                'Confirm',
                style: TextStyle(
                  color: _pinController.text.length == TransactionPinBottomSheet._pinLength
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontSize: 14, // Reduced font size
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}