import 'package:flutter/material.dart';

/// Offers another capture after a page is saved. Processing is the default
/// when the dialog is dismissed or the five-page limit has been reached.
Future<bool> askForAnotherCameraPage(
  BuildContext context,
  int capturedPages,
) async {
  if (capturedPages >= 5) return false;
  final pages = capturedPages == 1 ? 'page' : 'pages';
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('$capturedPages $pages captured'),
          content: const Text(
            'Add another page to this report, or process the pages you’ve '
            'captured. You can include up to 5 pages.',
          ),
          actions: [
            TextButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Add another page'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Process $capturedPages $pages'),
            ),
          ],
        ),
      ) ??
      false;
}
