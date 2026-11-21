import 'package:flutter/material.dart';

import 'app/controller.dart';
import 'ui/home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EspInkApp());
}

class EspInkApp extends StatefulWidget {
  const EspInkApp({super.key, this.controller});
  final EspInkController? controller;
  @override
  State<EspInkApp> createState() => _EspInkAppState();
}

class _EspInkAppState extends State<EspInkApp> {
  late final EspInkController controller =
      widget.controller ?? EspInkController();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  @override
  void initState() {
    super.initState();
    controller.addListener(_onChange);
    if (widget.controller == null) {
      controller.init(
        demoMode:
            const bool.fromEnvironment('DEMO_MODE') ||
            Uri.base.queryParameters['demo'] == '1',
      );
    }
  }

  void _onChange() {
    if (controller.message.isEmpty) return;
    final text = controller.message;
    controller.clearMessage();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      messenger.currentState?.hideCurrentSnackBar();
      messenger.currentState?.showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          showCloseIcon: true,
          duration: const Duration(seconds: 5),
        ),
      );
    });
  }

  @override
  void dispose() {
    controller.removeListener(_onChange);
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1967D2),
      brightness: Brightness.light,
      surface: const Color(0xFFFAFBFF),
    );
    return MaterialApp(
      title: 'ESP-INK',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messenger,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF7F9FC),
        fontFamily: 'NotoSansSC',
        fontFamilyFallback: const ['Noto Sans CJK SC', 'Noto Sans SC'],
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w600,
            letterSpacing: -.9,
          ),
          headlineMedium: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            letterSpacing: -.7,
          ),
          titleLarge: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w600,
            letterSpacing: -.3,
          ),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          bodyMedium: TextStyle(fontSize: 14, height: 1.5),
          bodySmall: TextStyle(fontSize: 12, height: 1.5),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF7F9FC),
          elevation: 0,
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFE5E9F0),
          thickness: 1,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE1E6EF)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: scheme.primary, width: 1.6),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            textStyle: const TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            side: const BorderSide(color: Color(0xFFD8DFEA)),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xFFF8FAFF),
          showDragHandle: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFFF7F9FC),
          indicatorColor: scheme.primaryContainer.withValues(alpha: .7),
          elevation: 0,
        ),
      ),
      home: EspInkHome(controller: controller),
    );
  }
}
