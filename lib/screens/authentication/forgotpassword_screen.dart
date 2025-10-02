import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../themes/app_theme.dart';
import '../../utility/notification.dart';  // Import the reusable notification function
import '../../api/api_client.dart';
import '../../api/url.dart';
import 'package:http/http.dart' as http;  // Import http for ApiClient
import 'dart:convert';  // Import jsonDecode function





class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  _ForgotPasswordScreenState createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  late ApiClient _apiClient;
  bool _isLoading = false; // Add a loading state variable

  @override
  void initState() {
    super.initState();
    // Initialize ApiClient with context
    _apiClient = ApiClient(http.Client(), context);
  }



  // Handle password reset request
  Future<void> _handlePasswordReset() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      // Show error notification with device info
      showToastNotification(
        context: context,
        title: 'Error',
        message: 'Email cant be empty',
        isSuccess: false,
      );
      return;
    }

    setState(() {
      _isLoading = true; // Set loading state to true
    });

    try {

      // add api logic here
      // Prepare data to be sent to the server
      final data = {
        'email': email,
      };
      // Send the password reset request to the server
      final response = await _apiClient.request(
        ApiConstants.restPwdEndpoint, // API endpoint
        method: 'POST', // HTTP method
        data: data, // Payload
      );

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200) {
        if (responseData['error'] == false) {
          // Success case
          showToastNotification(
            context: context,
            title: 'Success',
            message: responseData['message'],
            isSuccess: true,
          );
          Navigator.pop(context); // Go back to the previous screen
        } else {
          // Error case
          showToastNotification(
            context: context,
            title: 'Error',
            message: responseData['message'], // Use message from the server
            isSuccess: false,
          );
        }
      } else {
        // Handle unexpected status codes
        showToastNotification(
          context: context,
          title: 'Error',
          message: 'Unexpected server response: ${response.statusCode}',
          isSuccess: false,
        );
      }
    } catch (error) {
      //print(error);
      showToastNotification(
        context: context,
        title: 'Error',
        message: error.toString(),
        isSuccess: false,
      );
    }finally {
      setState(() {
        _isLoading = false; // Set loading state to false
      });
    }


  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Custom background painter
          CustomPaint(
            size: MediaQuery.of(context).size,
            painter: CurvedBackgroundPainter(
              topColor: AppColors.darkColor, // Replace with your desired top color
              bottomColor: AppColors.accentColor, // Replace with your desired bottom color
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: SingleChildScrollView(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: MediaQuery.of(context).size.height * 0.2), // Adjust top spacing

                    // App Logo and Forgot Password Heading
                    Center(
                      child: Column(
                        children: [
                          Image.asset('images/logo.png', height: 50), // Placeholder for your logo
                          const SizedBox(height: 16.0),
                          const Text('Forgot Password', style: AppTextStyles.heading),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32.0),

                    // Email Input Field
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.email, color: AppColors.primaryColor),
                      ),
                      style: const TextStyle(color: AppColors.primaryColor),
                    ),
                    const SizedBox(height: 32.0),

                    // Reset Password Button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isLoading
                            ? null // Disable the button when loading
                            : () async {
                          await _handlePasswordReset();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                        ),
                        child: _isLoading
                            ? const CircularProgressIndicator() // Show loader when loading
                            : const Text('Rest Password'),
                      ),
                    ),
                    const SizedBox(height: 16.0),

                    // Back to Login Button
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                          },
                          child: Text(
                            'Back to Login',
                            style: AppTextStyles.bodyText.copyWith(color: AppColors.primaryColor),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16.0), // Add bottom spacing to prevent clipping
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }


}
