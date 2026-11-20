// lib/ui/legal_links.dart
//
// Privacy Policy / Terms links shown on sign-up, sign-in, Settings and Help.
// Both stores require the privacy policy to be reachable inside the app.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/url.dart';

Future<void> openLegalUrl(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final uri = Uri.tryParse(url);
  var ok = false;
  if (uri != null) {
    try {
      ok = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      ok = false;
    }
  }
  if (!ok) {
    messenger?.showSnackBar(SnackBar(content: Text('Could not open $url')));
  }
}

/// "By continuing you agree to our Terms of Service and Privacy Policy."
class LegalConsentText extends StatefulWidget {
  const LegalConsentText({
    super.key,
    this.prefix = 'By continuing, you agree to our ',
    this.termsUrl = ApiConstants.termsOfServiceUrl,
    this.privacyUrl = ApiConstants.privacyPolicyUrl,
    this.textAlign = TextAlign.center,
  });

  final String prefix;
  final String termsUrl;
  final String privacyUrl;
  final TextAlign textAlign;

  @override
  State<LegalConsentText> createState() => _LegalConsentTextState();
}

class _LegalConsentTextState extends State<LegalConsentText> {
  late final TapGestureRecognizer _terms = TapGestureRecognizer()
    ..onTap = () => openLegalUrl(context, widget.termsUrl);
  late final TapGestureRecognizer _privacy = TapGestureRecognizer()
    ..onTap = () => openLegalUrl(context, widget.privacyUrl);

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final link = base?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w700,
      decoration: TextDecoration.underline,
    );
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: widget.prefix),
          TextSpan(text: 'Terms of Service', style: link, recognizer: _terms),
          const TextSpan(text: ' and '),
          TextSpan(text: 'Privacy Policy', style: link, recognizer: _privacy),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: widget.textAlign,
    );
  }
}
