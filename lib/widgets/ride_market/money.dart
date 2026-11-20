// lib/widgets/ride_market/money.dart
//
// Single money formatter for the ride / logistics flows (NGN first).
import 'package:intl/intl.dart' as intl;

final Map<String, intl.NumberFormat> _cache = <String, intl.NumberFormat>{};

String currencySymbol(String currency) {
  switch (currency.trim().toUpperCase()) {
    case '':
    case 'NGN':
      return '₦';
    case 'USD':
      return r'$';
    case 'EUR':
      return '€';
    case 'GBP':
      return '£';
    case 'GHS':
      return 'GH₵';
    default:
      return '${currency.trim().toUpperCase()} ';
  }
}

/// `₦12,500` / `₦12,500.50`. Kobo are shown only when non-zero (or forced).
/// Non-finite or negative input renders as `—`.
String formatMoney(num? amount, {String currency = 'NGN', bool forceDecimals = false}) {
  if (amount == null || !amount.isFinite || amount < 0) return '—';
  final bool decimals = forceDecimals || (amount * 100).round() % 100 != 0;
  final String sym = currencySymbol(currency);
  final String key = '$sym|$decimals';
  final intl.NumberFormat f = _cache[key] ??=
      intl.NumberFormat.currency(locale: 'en', symbol: sym, decimalDigits: decimals ? 2 : 0);
  return f.format(amount);
}

/// Parses money-like values from loosely typed JSON (`"1,200.50"`, 1200, null).
double parseMoney(Object? v) {
  if (v == null) return 0;
  if (v is num) return v.isFinite ? v.toDouble() : 0;
  final double? d = double.tryParse(v.toString().replaceAll(',', '').trim());
  return (d == null || !d.isFinite) ? 0 : d;
}
