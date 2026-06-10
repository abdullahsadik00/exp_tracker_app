import 'package:flutter/material.dart';

class AppColors {
  // Brand Colors
  static const Color background = Color(0xFF0F172A);
  static const Color surface = Color(0xFF1E293B);
  static const Color accent = Color(0xFF3B82F6);
  
  // Text Colors
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFF94A3B8);
  
  // Status Colors
  static const Color credit = Color(0xFF22C55E);
  static const Color debit = Color(0xFFEF4444);
  
  // Chart / Member Colors
  static const Color memberMe = Color(0xFF3B82F6);
  static const Color memberMom = Color(0xFFD946EF);
  static const Color memberDad = Color(0xFF10B981);

  // Gradient helper
  static LinearGradient cardGradient(Color baseColor) {
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        baseColor.withOpacity(0.8),
        baseColor.withOpacity(0.5),
      ],
    );
  }
}
