import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

class PasswordUtils {
  static final Random _rng = Random.secure();
  static const int _saltLength = 16;
  static const int _tempPasswordLength = 12;

  static String generateSalt() {
    final bytes = List<int>.generate(_saltLength, (_) => _rng.nextInt(256));
    return base64UrlEncode(bytes);
  }

  static String hashPassword({
    required String password,
    required String salt,
  }) {
    final bytes = utf8.encode('$salt::$password');
    return sha256.convert(bytes).toString();
  }

  static bool verifyPassword({
    required String password,
    required String salt,
    required String expectedHash,
  }) {
    final computed = hashPassword(password: password, salt: salt);
    return computed == expectedHash;
  }

  static bool isStrongEnough(String password) {
    if (password.length < 8) return false;
    final hasUpper = password.contains(RegExp(r'[A-Z]'));
    final hasLower = password.contains(RegExp(r'[a-z]'));
    final hasDigit = password.contains(RegExp(r'\d'));
    return hasUpper && hasLower && hasDigit;
  }

  static String generateTemporaryPassword() {
    const chars =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789@#';
    return List<String>.generate(
      _tempPasswordLength,
      (_) => chars[_rng.nextInt(chars.length)],
    ).join();
  }
}
