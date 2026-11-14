import 'package:flutter/material.dart';

/// Shows [message] as a snack bar in the nearest [ScaffoldMessenger], or in a
/// dialog when there is none or when [context] is inside a popup route (a
/// bottom sheet or dialog), whose page would hide the snack bar.
///
/// These widgets are built on `package:flutter/material.dart`. An app built on
/// `package:material_ui` has only that package's messenger, a different type
/// these widgets cannot reach, so the error goes to a dialog instead (which
/// needs `MaterialUiCompatibilityBridge` above the app's Navigator).
void showUiError(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger != null && ModalRoute.of(context) is! PopupRoute) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
    return;
  }
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
