import 'dart:typed_data';

/// Internal container for the exact original bytes of a photographed report.
///
/// It stores 1–5 images in capture order. Image formats remain unchanged and
/// are decoded only by the parser/viewer. No compression, metadata rewriting,
/// text extraction, or clinical interpretation happens in this codec.
///
/// Layout: AYUPAGES (8 ASCII bytes), version (u8), page count (u8), one
/// big-endian u32 length per page, then the concatenated image bytes.
class CameraPages {
  CameraPages._();

  static const maxPages = 5;
  static const maxBytes = 30 * 1024 * 1024;
  static const _version = 1;
  static const _magic = <int>[65, 89, 85, 80, 65, 71, 69, 83];
  static const _fixedHeaderBytes = 10;

  static Uint8List encode(List<Uint8List> pages) {
    if (pages.isEmpty || pages.length > maxPages) {
      throw const FormatException('A camera report needs 1–5 images.');
    }
    final headerLength = _fixedHeaderBytes + 4 * pages.length;
    var totalLength = headerLength;
    for (final page in pages) {
      if (page.isEmpty || page.length > maxBytes) {
        throw const FormatException('A camera image has an invalid size.');
      }
      totalLength += page.length;
      if (totalLength > maxBytes) {
        throw const FormatException('A camera report must fit within 30 MB.');
      }
    }
    final bundle = Uint8List(totalLength);
    bundle.setRange(0, _magic.length, _magic);
    bundle[8] = _version;
    bundle[9] = pages.length;
    final header = ByteData.sublistView(bundle);
    var offset = headerLength;
    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      header.setUint32(_fixedHeaderBytes + 4 * index, page.length, Endian.big);
      bundle.setRange(offset, offset + page.length, page);
      offset += page.length;
    }
    return bundle;
  }

  static List<Uint8List> decode(Uint8List bundle) {
    if (bundle.length < _fixedHeaderBytes + 4 || bundle.length > maxBytes) {
      throw const FormatException('The camera report has an invalid size.');
    }
    for (var index = 0; index < _magic.length; index++) {
      if (bundle[index] != _magic[index]) {
        throw const FormatException('This is not a camera report bundle.');
      }
    }
    if (bundle[8] != _version) {
      throw const FormatException('The camera report version is unsupported.');
    }
    final count = bundle[9];
    if (count < 1 || count > maxPages) {
      throw const FormatException('A camera report needs 1–5 images.');
    }
    final headerLength = _fixedHeaderBytes + 4 * count;
    if (bundle.length < headerLength) {
      throw const FormatException('The camera report header is incomplete.');
    }
    final header = ByteData.sublistView(bundle);
    final lengths = <int>[];
    var expectedLength = headerLength;
    for (var index = 0; index < count; index++) {
      final length = header.getUint32(
        _fixedHeaderBytes + 4 * index,
        Endian.big,
      );
      if (length < 1 || length > maxBytes) {
        throw const FormatException('A camera image has an invalid size.');
      }
      expectedLength += length;
      if (expectedLength > maxBytes || expectedLength > bundle.length) {
        throw const FormatException('The camera report is incomplete.');
      }
      lengths.add(length);
    }
    if (expectedLength != bundle.length) {
      throw const FormatException('The camera report contains trailing bytes.');
    }
    final pages = <Uint8List>[];
    var offset = headerLength;
    for (final length in lengths) {
      // Independent byte copies keep callers from modifying another page or
      // the encrypted-original buffer through a shared mutable view.
      pages.add(bundle.sublist(offset, offset + length));
      offset += length;
    }
    return pages;
  }
}
