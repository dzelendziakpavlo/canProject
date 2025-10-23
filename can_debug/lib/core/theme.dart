import 'package:flutter/material.dart';

/// Кастомна темна тема з теплими акцентами
class AppTheme {
  // Теплі кольори
  static const Color primaryOrange = Color(0xFFFF6B35); // Теплий оранжевий
  static const Color primaryAmber = Color(0xFFFFAB00);  // Теплий бурштиновий
  static const Color accentRed = Color(0xFFFF5722);     // Теплий червоний
  static const Color accentGreen = Color(0xFF4CAF50);   // Зелений для успіху
  
  // Темні кольори фону
  static const Color darkBackground = Color(0xFF1A1A1A);    // Темний фон
  static const Color darkSurface = Color(0xFF2A2A2A);       // Темні картки
  static const Color darkContainer = Color(0xFF3A3A3A);     // Контейнери
  static const Color darkBorder = Color(0xFF4A4A4A);        // Границі
  
  // Текстові кольори
  static const Color textPrimary = Color(0xFFFFFFFF);       // Білий текст
  static const Color textSecondary = Color(0xFFBDBDBD);     // Сірий текст
  static const Color textMuted = Color(0xFF9E9E9E);         // Приглушений текст

  // Градієнти
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primaryOrange, primaryAmber],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [darkBackground, Color(0xFF2D2D2D)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      
      // Основні кольори
      colorScheme: const ColorScheme.dark(
        primary: primaryOrange,
        primaryContainer: darkContainer,
        secondary: primaryAmber,
        secondaryContainer: darkSurface,
        surface: darkSurface,
        surfaceContainerHighest: darkContainer,
        background: darkBackground,
        error: accentRed,
        onPrimary: textPrimary,
        onSecondary: textPrimary,
        onSurface: textPrimary,
        onBackground: textPrimary,
        onError: textPrimary,
        outline: darkBorder,
      ),

      // Фон Scaffold
      scaffoldBackgroundColor: darkBackground,

      // AppBar тема
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: Colors.transparent,
        foregroundColor: textPrimary,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),

      // Card тема
      cardTheme: CardThemeData(
        elevation: 8,
        color: darkSurface,
        shadowColor: Colors.black.withOpacity(0.3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),

      // Кнопки
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: textPrimary,
          backgroundColor: primaryOrange,
          elevation: 6,
          shadowColor: primaryOrange.withOpacity(0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),

      // Floating Action Button
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryOrange,
        foregroundColor: textPrimary,
        elevation: 8,
      ),

      // Input декорації
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryOrange, width: 2),
        ),
        labelStyle: const TextStyle(color: textSecondary),
        hintStyle: const TextStyle(color: textMuted),
      ),

      // Таби
      tabBarTheme: const TabBarThemeData(
        indicatorColor: primaryAmber,
        labelColor: textPrimary,
        unselectedLabelColor: textMuted,
        indicatorSize: TabBarIndicatorSize.tab,
      ),

      // Іконки
      iconTheme: const IconThemeData(
        color: textSecondary,
        size: 24,
      ),

      // Текстові стилі
      textTheme: const TextTheme(
        displayLarge: TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
        displayMedium: TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
        displaySmall: TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
        headlineLarge: TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        headlineMedium: TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        headlineSmall: TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: textPrimary, fontWeight: FontWeight.w500),
        titleSmall: TextStyle(color: textPrimary, fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(color: textPrimary),
        bodyMedium: TextStyle(color: textSecondary),
        bodySmall: TextStyle(color: textMuted),
        labelLarge: TextStyle(color: textPrimary, fontWeight: FontWeight.w500),
        labelMedium: TextStyle(color: textSecondary),
        labelSmall: TextStyle(color: textMuted),
      ),

      // Divider
      dividerColor: darkBorder,
      dividerTheme: const DividerThemeData(
        color: darkBorder,
        thickness: 1,
      ),

      // SnackBar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: darkContainer,
        contentTextStyle: const TextStyle(color: textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Кастомні іконки для автомобільної тематики
class AutomotiveIcons {
  static const IconData engine = Icons.settings;
  static const IconData transmission = Icons.tune;
  static const IconData abs = Icons.car_repair;
  static const IconData airbag = Icons.security;
  static const IconData bodyControl = Icons.electrical_services;
  static const IconData dashboard = Icons.dashboard;
  static const IconData canBus = Icons.hub;
  static const IconData errorRate = Icons.trending_up;
  static const IconData networkTopology = Icons.device_hub;
  static const IconData liveMonitor = Icons.monitor_heart;
  static const IconData analytics = Icons.analytics;
  static const IconData export = Icons.file_download;
  static const IconData settings = Icons.tune;
  static const IconData play = Icons.play_circle_filled;
  static const IconData stop = Icons.stop_circle;
  static const IconData reset = Icons.refresh;
}