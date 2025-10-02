import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart'; // To copy to clipboard
import 'package:lottie/lottie.dart';
import '../themes/app_theme.dart';

class TransactionDetailPage extends StatelessWidget {
  final Map<String, dynamic> transaction;

  const TransactionDetailPage({Key? key, required this.transaction}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Transaction Details',
          style: TextStyle(fontSize: 18), // Smaller font size
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12), // Reduced padding
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTransactionStatus(),
            const SizedBox(height: 16), // Reduced spacing
            _buildDetailCard(
              context,
              'Amount',
              'NGN ${_formatAmount(transaction['amount'])}',
            ),
            _buildDetailCard(context, 'Status', transaction['status'] ?? 'Unknown'),
            _buildDetailCard(
              context,
              'Description',
              transaction['title'] ?? 'No Description',
            ),
            _buildDetailCard(
              context,
              'Fee',
              'NGN ${_formatAmount(transaction['fee'])}',
            ),
            _buildDetailCard(context, 'Payment Method', transaction['payment_mode'] ?? 'Not Specified'),
            _buildDetailCard(context, 'Date & Time', _formatDateTime(transaction['datetime'])),
            _buildCopiableCard(context, 'Reference', transaction['reference'] ?? 'No Reference'),
            _buildCopiableCard(context, 'Token', transaction['recharge_token'] ?? 'No token'),
          ],
        ),
      ),
    );
  }

  // Method to display transaction status with Lottie animations
  Widget _buildTransactionStatus() {
    bool isSuccess = transaction['status'] == 'successful' || transaction['status'] == 'success';
    return Center(
      child: Column(
        children: [
          Lottie.asset(
            isSuccess ? 'assets/lottie/success.json' : 'assets/lottie/failure.json',
            height: 120, // Smaller animation
            width: 120,
            repeat: true,
          ),
          Text(
            isSuccess ? 'Transaction Successful' : 'Transaction Failed',
            style: AppTextStyles.bodyText.copyWith(
              fontSize: 16, // Smaller font
              color: isSuccess ? Colors.green : Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // Method to build each card containing transaction details
  Widget _buildDetailCard(BuildContext context, String label, String value) {
    return Card(
      elevation: 2, // Reduced elevation
      margin: const EdgeInsets.symmetric(vertical: 6), // Reduced margin
      child: Padding(
        padding: const EdgeInsets.all(12), // Reduced padding
        child: Row(
          children: [
            Icon(
              _getIconForLabel(label),
              color: AppColors.darkerColor,
              size: 20, // Smaller icon
            ),
            const SizedBox(width: 8), // Reduced spacing
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppTextStyles.bodyText.copyWith(
                      fontSize: 14, // Smaller font
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4), // Reduced spacing
                  Text(
                    value,
                    style: AppTextStyles.bodyText.copyWith(fontSize: 14), // Smaller font
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Method to build a copiable card for the transaction reference
  Widget _buildCopiableCard(BuildContext context, String label, String value) {
    return Card(
      elevation: 2, // Reduced elevation
      margin: const EdgeInsets.symmetric(vertical: 6), // Reduced margin
      child: Padding(
        padding: const EdgeInsets.all(12), // Reduced padding
        child: Row(
          children: [
            Icon(
              _getIconForLabel(label),
              color: AppColors.darkerColor,
              size: 20, // Smaller icon
            ),
            const SizedBox(width: 8), // Reduced spacing
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppTextStyles.bodyText.copyWith(
                      fontSize: 14, // Smaller font
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4), // Reduced spacing
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: value));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${label} copied to clipboard!')),
                      );
                    },
                    child: Row(
                      children: [
                        Text(
                          value,
                          style: AppTextStyles.bodyText.copyWith(
                            fontSize: 14, // Smaller font
                            color: Colors.blue,
                          ),
                        ),
                        const SizedBox(width: 4), // Reduced spacing
                        const Icon(Icons.copy, size: 14, color: Colors.blue), // Smaller icon
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Helper method to format DateTime
  String _formatDateTime(DateTime dateTime) {
    return DateFormat('MMM d, yyyy - h:mm a').format(dateTime);
  }

  // Helper method to format amount, handling null values
  String _formatAmount(num? amount) {
    return amount != null ? amount.toStringAsFixed(2) : '0.00';
  }

  // Helper method to get appropriate icon for each label
  IconData _getIconForLabel(String label) {
    switch (label.toLowerCase()) {
      case 'amount':
        return Icons.monetization_on;
      case 'status':
        return Icons.info;
      case 'description':
        return Icons.description;
      case 'fee':
        return Icons.attach_money;
      case 'payment method':
        return Icons.payment;
      case 'date & time':
        return Icons.calendar_today;
      case 'reference':
        return Icons.confirmation_number;
      default:
        return Icons.info;
    }
  }
}