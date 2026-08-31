import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'constants.dart';

class PinService {
  static const _kPinEnabled = 'pin_enabled';
  static const _kPinHash = 'pin_hash';
  static const _kPinSalt = 'pin_salt';
  static const _kPinFailCount = 'pin_fail_count';
  static const _kPinLockedUntil = 'pin_locked_until';

  static const int maxAttempts = 5;
  static const Duration lockoutDuration = Duration(seconds: 30);

  Future<bool> isPinEnabled() async {
    final value = await storage.read(key: _kPinEnabled);
    return value == 'true';
  }

  String _generateSalt() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return base64UrlEncode(bytes);
  }

  String _hashPin(String pin, String salt) {
    final bytes = utf8.encode('$salt:$pin');
    return sha256.convert(bytes).toString();
  }

  /// Saves a new PIN and marks the lock as enabled. Also clears any
  /// existing lockout/failure state, since this is a fresh PIN.
  Future<void> setPin(String pin) async {
    final salt = _generateSalt();
    final hash = _hashPin(pin, salt);
    await storage.write(key: _kPinSalt, value: salt);
    await storage.write(key: _kPinHash, value: hash);
    await storage.write(key: _kPinEnabled, value: 'true');
    await _resetFailCount();
  }

  /// Checks [pin] against the stored hash. Returns false (without checking
  /// the hash) while a lockout is active. Updates the failure counter and
  /// lockout timestamp as a side effect.
  Future<bool> verifyPin(String pin) async {
    if (await isLockedOut()) return false;

    final salt = await storage.read(key: _kPinSalt);
    final storedHash = await storage.read(key: _kPinHash);
    if (salt == null || storedHash == null) return false;

    final candidateHash = _hashPin(pin, salt);
    final isMatch = candidateHash == storedHash;

    if (isMatch) {
      await _resetFailCount();
    } else {
      await _registerFailedAttempt();
    }
    return isMatch;
  }

  /// Verifies [oldPin] and, if correct, saves [newPin] in its place.
  Future<bool> changePin(String oldPin, String newPin) async {
    final valid = await verifyPin(oldPin);
    if (!valid) return false;
    await setPin(newPin);
    return true;
  }

  /// Turns the PIN lock off and removes the stored PIN entirely.
  Future<void> disablePin() async {
    await storage.delete(key: _kPinEnabled);
    await storage.delete(key: _kPinHash);
    await storage.delete(key: _kPinSalt);
    await _resetFailCount();
  }

  /// Used by the forgot-PIN flow: wipes the PIN (and disables the lock)
  /// after the user has verified their identity via email OTP, so they can
  /// set a fresh one via [setPin].
  Future<void> clearPin() => disablePin();

  Future<void> _registerFailedAttempt() async {
    final current =
        int.tryParse(await storage.read(key: _kPinFailCount) ?? '0') ?? 0;
    final updated = current + 1;
    await storage.write(key: _kPinFailCount, value: updated.toString());
    if (updated >= maxAttempts) {
      final until = DateTime.now().add(lockoutDuration);
      await storage.write(
        key: _kPinLockedUntil,
        value: until.toIso8601String(),
      );
    }
  }

  Future<void> _resetFailCount() async {
    await storage.delete(key: _kPinFailCount);
    await storage.delete(key: _kPinLockedUntil);
  }

  Future<bool> isLockedOut() async {
    final untilStr = await storage.read(key: _kPinLockedUntil);
    if (untilStr == null) return false;
    final until = DateTime.tryParse(untilStr);
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      // Lockout window has passed — clear it so the next check is clean.
      await storage.delete(key: _kPinLockedUntil);
      await storage.delete(key: _kPinFailCount);
      return false;
    }
    return true;
  }

  /// Null when there's no active lockout, otherwise how long remains.
  Future<Duration?> remainingLockout() async {
    final untilStr = await storage.read(key: _kPinLockedUntil);
    if (untilStr == null) return null;
    final until = DateTime.tryParse(untilStr);
    if (until == null) return null;
    final remaining = until.difference(DateTime.now());
    return remaining.isNegative ? null : remaining;
  }
}

final pinService = PinService();