import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pin_service.dart';

enum _ChangeStep { verifyOld, enterNew, confirmNew }

/// Verifies the current PIN, then walks through the same enter/confirm
/// flow as [PinSetupPage] for the replacement PIN. Pops `true` on success.
class PinChangePage extends StatefulWidget {
  const PinChangePage({super.key});

  @override
  State<PinChangePage> createState() => _PinChangePageState();
}

class _PinChangePageState extends State<PinChangePage> {
  static const int pinLength = 4;

  _ChangeStep _step = _ChangeStep.verifyOld;
  String? _newPin;
  String? _error;
  bool _busy = false;

  final List<TextEditingController> _controllers = List.generate(
    pinLength,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _focusNodes = List.generate(
    pinLength,
    (_) => FocusNode(),
  );

  String get _entered => _controllers.map((c) => c.text).join();

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  void _clearEntry() {
    for (final c in _controllers) {
      c.clear();
    }
    _focusNodes[0].requestFocus();
  }

  Future<void> _handleComplete() async {
    final value = _entered;

    switch (_step) {
      case _ChangeStep.verifyOld:
        setState(() => _busy = true);
        final ok = await pinService.verifyPin(value);
        if (!mounted) return;

        if (!ok) {
          final remaining = await pinService.remainingLockout();
          if (!mounted) return;
          setState(() {
            _busy = false;
            _error = remaining != null
                ? "Too many attempts. Try again in ${remaining.inSeconds}s."
                : "Incorrect PIN.";
          });
          _clearEntry();
          return;
        }

        setState(() {
          _busy = false;
          _step = _ChangeStep.enterNew;
          _error = null;
        });
        _clearEntry();
        break;

      case _ChangeStep.enterNew:
        setState(() {
          _newPin = value;
          _step = _ChangeStep.confirmNew;
          _error = null;
        });
        _clearEntry();
        break;

      case _ChangeStep.confirmNew:
        if (value != _newPin) {
          setState(() {
            _error = "PINs didn't match. Let's try again.";
            _step = _ChangeStep.enterNew;
            _newPin = null;
          });
          _clearEntry();
          return;
        }
        setState(() => _busy = true);
        await pinService.setPin(value);
        if (!mounted) return;
        Navigator.pop(context, true);
        break;
    }
  }

  String get _title {
    switch (_step) {
      case _ChangeStep.verifyOld:
        return 'Enter current PIN';
      case _ChangeStep.enterNew:
        return 'Enter new PIN';
      case _ChangeStep.confirmNew:
        return 'Confirm new PIN';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change PIN')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_reset, size: 64, color: Colors.blue),
              const SizedBox(height: 24),
              Text(
                _title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
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
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        maxLength: 1,
                        obscureText: true,
                        obscuringCharacter: '●',
                        enabled: !_busy,
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
                          if (_entered.length == pinLength) {
                            _focusNodes[index].unfocus();
                            _handleComplete();
                          }
                        },
                      ),
                    ),
                  );
                }),
              ),
              if (_busy) ...[
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
            ],
          ),
        ),
      ),
    );
  }
}