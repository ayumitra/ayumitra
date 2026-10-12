import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerAyumitraNotices() {
  LicenseRegistry.addLicense(() async* {
    for (final entry in {
      'Ayumitra': 'ayumitra',
      'image third-party components': 'image_third_party',
      'PDFium Android components': 'pdfium_android',
      'PDFium iOS components': 'pdfium_ios',
      'Roboto legacy font': 'roboto_legacy',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        entry.key,
      ], await rootBundle.loadString('assets/notices/${entry.value}.txt'));
    }
  });
}
