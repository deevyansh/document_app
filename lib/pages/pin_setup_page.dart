import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pin_service.dart';

enum _SetupStep { enter, confirm }

/// Used both to enable the PIN lock for the first time, and to set a fresh
/// PIN after a successful forgot-PIN reset. Pops `true` on success so the
/// caller can flip its own "PIN enabled" state.
class PinSetupPage extends StatefulWidget {
  final String title;
  final String subtitle;

  const PinSetupPage({
    super.key,
    this.title = 'Set your PIN',
    this.subtitle = 'Choose a 4-digit PIN to lock DocEzy',
  });

  @override
  State<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends State<PinSetupPage> {
  static const int pinLength = 4;

  _SetupStep _step = _SetupStep.enter;
  String? _firstPin;
  String? _error;
  bool _saving = false;

  final List<TextEditingController> _controllers = List.generate(
    pinLength,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _focusNodes = List.generate(
    pinLength,
    (_) => FocusNode(),
  );

  String get _enteredPin => _controllers.map((c) => c.text).join();

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
    final pin = _enteredPin;

    if (_step == _SetupStep.enter) {
      setState(() {
        _firstPin = pin;
        _step = _SetupStep.confirm;
        _error = null;
      });
      _clearEntry();
      return;
    }

    // Confirm step.
    if (pin != _firstPin) {
      setState(() {
        _error = "PINs didn't match. Let's try again.";
        _step = _SetupStep.enter;
        _firstPin = null;
      });
      _clearEntry();
      return;
    }

    setState(() => _saving = true);
    await pinService.setPin(pin);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final isConfirmStep = _step == _SetupStep.confirm;

    return Scaffold(
      appBar: AppBar(title: const Text('App Lock')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isConfirmStep
                    ? Icons.check_circle_outline
                    : Icons.lock_outline,
                size: 64,
                color: Colors.blue,
              ),
              const SizedBox(height: 24),
              Text(
                isConfirmStep ? 'Confirm your PIN' : widget.title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isConfirmStep ? 'Enter the same PIN again' : widget.subtitle,
                style: const TextStyle(fontSize: 14, color: Colors.grey),
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
                        enabled: !_saving,
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
                            _handleComplete();
                          }
                        },
                      ),
                    ),
                  );
                }),
              ),
              if (_saving) ...[
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