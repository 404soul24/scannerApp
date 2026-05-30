import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/profile.dart';

class AuthService extends ChangeNotifier {
  final SupabaseClient _client = Supabase.instance.client;

  User? _user;
  Profile? _profile;
  bool _isLoading = false;
  String? _error;

  User? get user => _user;
  Profile? get profile => _profile;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAuthenticated => _user != null;
  bool get isAdmin => _profile?.isAdmin ?? false;

  StreamSubscription<AuthState>? _authSubscription;

  AuthService() {
    _user = _client.auth.currentUser;
    _authSubscription = _client.auth.onAuthStateChange.listen((data) {
      _user = data.session?.user;
      if (_user == null) {
        _profile = null;
      }
      notifyListeners();
    });

    if (_user != null) {
      _loadProfile();
    }
  }

  Future<void> _loadProfile() async {
    if (_user == null) return;

    try {
      final response = await _client
          .from('profiles')
          .select()
          .eq('id', _user!.id)
          .single();

      _profile = Profile.fromJson(response);
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load profile: $e';
      debugPrint(_error);
      notifyListeners();
    }
  }

  Future<bool> signIn(String email, String password) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final response = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      _user = response.user;
      await _loadProfile();
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _error = _translateAuthError(e.message);
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _error = 'Erreur de connexion. Veuillez réessayer.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
    _user = null;
    _profile = null;
    notifyListeners();
  }

  String? get sessionAccessToken => _client.auth.currentSession?.accessToken;

  String _translateAuthError(String message) {
    if (message.contains('Invalid login credentials')) {
      return 'Email ou mot de passe incorrect.';
    }
    if (message.contains('Email not confirmed')) {
      return 'Email non confirmé. Vérifiez votre boîte de réception.';
    }
    if (message.contains('Too many requests')) {
      return 'Trop de tentatives. Veuillez patienter quelques minutes.';
    }
    return message;
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }
}
