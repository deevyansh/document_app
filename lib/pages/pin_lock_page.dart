import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pin_service.dart';

/// Full-screen PIN gate shown whenever the app is opened while the lock is
/// enabled. Rendered in place of the document screen (see the `pinLock`
/// branch in `main.dart`'s `build()`) rather than pushed as a route, so
/// there's nothing to pop back past.
class PinLockPage extends StatefulWidget {
  final VoidCallback onUnlocked;
  final VoidCallback onForgotPin;

  const PinLockPage({
    super.key,
    required this.onUnlocked,
    required this.onForgotPin,
  });

  @override
  State<PinLockPage> createState() => _PinLockPageState();
}

class _PinLockPageState extends State<PinLockPage> {
  static const int pinLength = 4;

  final List<TextEditingController> _controllers = List.generate(
    pinLength,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _focusNodes = List.generate(
    pinLength,
    (_) => FocusNode(),
  );

  String? _error;
  bool _checking = false;
  Duration? _lockoutRemaining;
  Timer? _lockoutTimer;

  String get _enteredPin => _controllers.map((c) => c.text).join();

    @override
    void initState() {
      super.initState();
      _refreshLockoutStatus();
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        FocusScope.of(context).requestFocus(_focusNodes[0]);
      });
    }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    _lockoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshLockoutStatus() async {
    final remaining = await pinService.remainingLockout();
    if (!mounted) return;
    setState(() => _lockoutRemaining = remaining);

    if (remaining != null) {
      _lockoutTimer?.cancel();
      _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (
        timer,
      ) async {
        final r = await pinService.remainingLockout();
        if (!mounted) return;
        setState(() => _lockoutRemaining = r);
        if (r == null) timer.cancel();
      });
    }
  }

  void _clearEntry() {
    for (final c in _controllers) {
      c.clear();
    }
    _focusNodes[0].requestFocus();
  }

  Future<void> _submit() async {
    if (_enteredPin.length != pinLength || _checking) return;

    setState(() {
      _checking = true;
      _error = null;
    });

    final ok = await pinService.verifyPin(_enteredPin);
    if (!mounted) return;

    if (ok) {
      widget.onUnlocked();
      return;
    }

    final remaining = await pinService.remainingLockout();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _lockoutRemaining = remaining;
      _error = remaining != null
          ? "Too many attempts. Try again in ${remaining.inSeconds}s."
          : "Incorrect PIN. Please try again.";
    });
    _clearEntry();
    if (remaining != null) _refreshLockoutStatus();
  }

  @override
  Widget build(BuildContext context) {
    final isLockedOut = _lockoutRemaining != null;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_outline, size: 72, color: Colors.blue),
                const SizedBox(height: 24),
                const Text(
                  'Enter your PIN',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'DocEzy is locked for your privacy',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(pinLength, (index) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: SizedBox(
                        width: 52,
                        height: 60,
                        child: TextField(
                          controller: _controllers[index],
                          focusNode: _focusNodes[index],
                          enabled: !isLockedOut && !_checking,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          textAlignVertical: TextAlignVertical.center,
                          maxLength: 1,
                          obscureText: true,
                          obscuringCharacter: '●',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: InputDecoration(
                            counterText: '',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: _error != null
                                    ? Colors.red
                                    : Colors.grey.shade400,
                              ),
                            ),
                            filled: true,
                            fillColor: Colors.grey[50],
                          ),
                          onChanged: (value) {
                            if (_error != null) setState(() => _error = null);
                            if (value.isNotEmpty && index < pinLength - 1) {
                              _focusNodes[index + 1].requestFocus();
                            }
                            if (_enteredPin.length == pinLength) {
                              _focusNodes[index].unfocus();
                              _submit();
                            }
                          },
                        ),
                      ),
                    );
                  }),
                ),
                if (_checking) ...[
                  const SizedBox(height: 20),
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 32),
                TextButton(
                  onPressed: isLockedOut ? null : widget.onForgotPin,
                  child: const Text(
                    'Forgot PIN?',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}