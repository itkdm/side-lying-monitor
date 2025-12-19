import 'dart:ui';

import 'package:flutter/material.dart';
import '../services/theme_repository.dart';

/// Shared frosted glass card used across pages to keep UI consistent.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = ThemeRepository.instance.isDark;
    final glassColor = isDark ? Colors.white : Colors.black;
    
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                glassColor.withOpacity(isDark ? 0.08 : 0.05),
                glassColor.withOpacity(isDark ? 0.02 : 0.01),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(
              color: glassColor.withOpacity(isDark ? 0.16 : 0.1),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

