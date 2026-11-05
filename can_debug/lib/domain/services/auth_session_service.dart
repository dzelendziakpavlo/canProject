import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight persistent auth session manager.
/// Stores the last logged in username and a simple flag.
class AuthSessionService {
  static const _keyUsername = 'auth_username';
  static const _keyLoggedIn = 'auth_logged_in';

  static AuthSessionService? _instance;
  static AuthSessionService get instance => _instance ??= AuthSessionService._();
  AuthSessionService._();

  String? _cachedUsername;
  bool _cachedLoggedIn = false;
  bool _initialized = false;

  String? get username => _cachedUsername;
  bool get isLoggedIn => _cachedLoggedIn;
  bool get isInitialized => _initialized;

  Future<void> initialize() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    _cachedLoggedIn = prefs.getBool(_keyLoggedIn) ?? false;
    _cachedUsername = prefs.getString(_keyUsername);
    _initialized = true;
  }

  Future<void> saveLogin(String username) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLoggedIn, true);
    await prefs.setString(_keyUsername, username);
    _cachedLoggedIn = true;
    _cachedUsername = username;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyLoggedIn);
    await prefs.remove(_keyUsername);
    _cachedLoggedIn = false;
    _cachedUsername = null;
  }
}
