import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._internal();
  DatabaseHelper._internal();

  static const String _dbName = 'app.db';
  static const int _dbVersion = 1;

  static const String usersTable = 'users';

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final String dbPath = '${dir.path}/$_dbName';

    if (kDebugMode) {
      // ignore: avoid_print
      print('Opening database at: $dbPath');
    }

    return await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $usersTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE,
        passwordHash TEXT,
        createdAt TEXT
      )
    ''');
  }

  Future<void> close() async {
    final db = _db;
    if (db != null && db.isOpen) {
      await db.close();
      _db = null;
    }
  }
}
