import 'package:flutter/material.dart';

/// A small, non-dismissible "working" dialog with a spinner and a message —
/// used for actions that take a noticeable moment, like merging documents
/// into one PDF, so the user gets feedback between tapping the action and
/// the result appearing instead of the screen looking frozen.
///
/// Call [hideLoadingDialog] once the work finishes (success or failure) to
/// dismiss it.
Future<void> showLoadingDialog(
  BuildContext context, {
  String message = "Please wait...",
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(width: 20),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    ),
  );
}

/// Dismisses a dialog shown via [showLoadingDialog].
///
/// Uses the root navigator so it closes the loading dialog specifically,
/// even if the calling page has pushed something else on top in the
/// meantime.
void hideLoadingDialog(BuildContext context) {
  Navigator.of(context, rootNavigator: true).pop();
}