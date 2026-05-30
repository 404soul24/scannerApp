import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/auth_gate.dart';

const String supabaseUrl = 'https://xpsuryegelcfwjwpmxud.supabase.co';
const String supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhwc3VyeWVnZWxjZndqd3BteHVkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg4NjI0NzIsImV4cCI6MjA5NDQzODQ3Mn0.Lc2YvNa72BylvMTvvgFFmsIohWCf9G75GqEZGoUJ8W0';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  runApp(const AbsenceScannerApp());
}

class AbsenceScannerApp extends StatelessWidget {
  const AbsenceScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Scan d'Absences",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF00BFA6),
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF161B22),
          elevation: 0,
          centerTitle: true,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF161B22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 4,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.5),
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}
