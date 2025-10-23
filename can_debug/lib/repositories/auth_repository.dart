import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../data/database_helper.dart';
import '../models/user_model.dart';

class AuthRepository {
  AuthRepository._();
  static final AuthRepository instance = AuthRepository._();

  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    return sha256.convert(bytes).toString();
  }

  Future<UserModel> registerUser({required String username, required String password}) async {
    final db = await DatabaseHelper.instance.database;

    // Check if user exists
    final existing = await db.query(
      DatabaseHelper.usersTable,
      where: 'username = ?',
      whereArgs: [username],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      throw const AuthException('User already exists');
    }

    final String passwordHash = _hashPassword(password);
    final String createdAt = DateTime.now().toUtc().toIso8601String();

    final user = UserModel(username: username, passwordHash: passwordHash, createdAt: createdAt);

    final id = await db.insert(DatabaseHelper.usersTable, user.toMap(), conflictAlgorithm: ConflictAlgorithm.abort);

    return UserModel(id: id, username: username, passwordHash: passwordHash, createdAt: createdAt);
  }

  Future<UserModel> loginUser({required String username, required String password}) async {
    final db = await DatabaseHelper.instance.database;
    final String passwordHash = _hashPassword(password);

    final rows = await db.query(
      DatabaseHelper.usersTable,
      where: 'username = ?',
      whereArgs: [username],
      limit: 1,
    );

    if (rows.isEmpty) {
      throw const AuthException('Invalid username or password');
    }

    final user = UserModel.fromMap(rows.first);

    if (user.passwordHash != passwordHash) {
      throw const AuthException('Invalid username or password');
    }

    return user;
  }
}

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => 'AuthException: $message';
}
