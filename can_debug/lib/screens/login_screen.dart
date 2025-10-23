import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../repositories/auth_repository.dart';
import '../core/theme.dart';
import '../presentation/widgets/animated_widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;
  bool _loading = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter username and password')),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      final user = await AuthRepository.instance.loginUser(username: username, password: password);
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/dashboard', arguments: user.username);
    } on AuthException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Login failed. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AnimatedCard(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          gradient: AppTheme.primaryGradient,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.security,
                          size: 48,
                          color: Colors.white,
                        ),
                      ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),
                      const SizedBox(height: 24),
                      Text(
                        'Welcome Back',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                        textAlign: TextAlign.center,
                      ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.3, end: 0),
                      const SizedBox(height: 8),
                      Text(
                        'Sign in to your automotive dashboard',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.7),
                        ),
                        textAlign: TextAlign.center,
                      ).animate().fadeIn(delay: 400.ms),
                      const SizedBox(height: 32),
                      TextField(
                        controller: _usernameController,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(
                            Icons.person_outline,
                            color: theme.colorScheme.primary,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          fillColor: theme.colorScheme.surface.withOpacity(0.1),
                        ),
                      ).animate().fadeIn(delay: 600.ms).slideX(begin: -0.3, end: 0),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        obscureText: _obscure,
                        onSubmitted: (_) => _login(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(
                            Icons.lock_outline,
                            color: theme.colorScheme.primary,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          fillColor: theme.colorScheme.surface.withOpacity(0.1),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscure ? Icons.visibility : Icons.visibility_off,
                              color: theme.colorScheme.primary,
                            ),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ).animate().fadeIn(delay: 800.ms).slideX(begin: 0.3, end: 0),
                      const SizedBox(height: 32),
                      SizedBox(
                        height: 56,
                        child: AnimatedButton(
                          onPressed: _loading ? null : _login,
                          child: _loading
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation<Color>(
                                          theme.colorScheme.onPrimary,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    const Text('Signing in...'),
                                  ],
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.login),
                                    const SizedBox(width: 8),
                                    const Text('Sign In'),
                                  ],
                                ),
                        ),
                      ).animate().fadeIn(delay: 1000.ms),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: _loading
                            ? null
                            : () {
                                Navigator.pushReplacementNamed(context, '/register');
                              },
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                        ),
                        child: const Text("Don't have an account? Sign up"),
                      ).animate().fadeIn(delay: 1200.ms),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
