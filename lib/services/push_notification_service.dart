import 'package:firebase_messaging/firebase_messaging.dart';

class PushNotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  Future<void> initialize() async {
    // Request iOS permissions
    await _requestIOSPermissions();

    // Handle background messages
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Handle foreground messages
    _handleForegroundMessages();

    // Handle messages when the app is opened from a terminated state
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    // Get the device token
    String? token = await _messaging.getToken();
    //print("FCM Token: $token");

    // Get the APNS token
    String? apnsToken = await _messaging.getAPNSToken();
    //print("APNS Token: $apnsToken");

    // You can save both tokens to your backend if needed
  }

  Future<void> _requestIOSPermissions() async {
    NotificationSettings settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      //print('User granted permission');
    } else if (settings.authorizationStatus == AuthorizationStatus.provisional) {
      //print('User granted provisional permission');
    } else {
      //print('User declined or has not accepted permission');
    }
  }

  void _handleForegroundMessages() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('Received a message while in the foreground!');
      print('Message data: ${message.data}');

      if (message.notification != null) {
        print('Message also contained a notification: ${message.notification!.title}, ${message.notification!.body}');
      }
      // Here you can display the notification in the UI if needed
    });
  }

  static Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
    print('Handling a background message: ${message.messageId}');
    // Add your background handling logic here
  }

  void _handleMessageOpenedApp(RemoteMessage message) {
    print('A new onMessageOpenedApp event was published!');
    // Navigate to a specific screen or do something else based on the message
  }
}
