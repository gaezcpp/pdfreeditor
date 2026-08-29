import 'dart:ui';

/// The object model of a document being edited, as the backend reports it.
///
/// All geometry is in PDF points with the origin at the page's top-left, which
/// is also Flutter's convention — so mapping to screen coordinates is a single
/// scale factor, with no axis flip.
class EditorDocument {
  const EditorDocument({
    required this.id,
    required this.filename,
    required this.pageCount,
    required this.revision,
    required this.expiresAt,
    required this.operationCount,
    required this.pages,
  });

  final String id;
  final String filename;
  final int pageCount;

  /// Bumped by the server on every edit. Also the cache key for a page render.
  final int revision;

  final DateTime expiresAt;
  final int operationCount;
  final List<EditorPage> pages;

  bool get hasEdits => operationCount > 0;

  EditorPage page(int number) =>
      pages.firstWhere((page) => page.number == number, orElse: () => pages.first);

  factory EditorDocument.fromJson(Map<String, dynamic> json) => EditorDocument(
        id: json['id'] as String,
        filename: json['filename'] as String,
        pageCount: json['page_count'] as int,
        revision: json['revision'] as int,
        expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
        operationCount: json['operation_count'] as int,
        pages: (json['pages'] as List)
            .map((page) => EditorPage.fromJson((page as Map).cast<String, dynamic>()))
            .toList(),
      );
}

class EditorPage {
  const EditorPage({
    required this.number,
    required this.width,
    required this.height,
    required this.spans,
    required this.images,
  });

  final int number;
  final double width;
  final double height;
  final List<EditorSpan> spans;
  final List<EditorImage> images;

  factory EditorPage.fromJson(Map<String, dynamic> json) => EditorPage(
        number: json['number'] as int,
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
        spans: (json['spans'] as List)
            .map((span) => EditorSpan.fromJson((span as Map).cast<String, dynamic>()))
            .toList(),
        images: (json['images'] as List)
            .map((image) => EditorImage.fromJson((image as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// One editable run of text.
class EditorSpan {
  const EditorSpan({
    required this.index,
    required this.text,
    required this.bbox,
    required this.font,
    required this.size,
    required this.color,
    required this.substituteFont,
    required this.added,
  });

  final int index;
  final String text;
  final Rect bbox;
  final String font;
  final double size;
  final String color;

  /// The base-14 face the server will actually redraw this run in.
  final String substituteFont;

  /// True for a run the user placed, as opposed to one the document came with.
  final bool added;

  /// True when editing this run will visibly change its typeface.
  ///
  /// The original font is embedded as a subset with no usable unicode map, so
  /// new characters cannot be drawn with it. Worth warning about before the
  /// user commits, rather than surprising them afterwards.
  bool get changesTypeface => !font.toLowerCase().startsWith(
        switch (substituteFont) {
          'hebo' || 'helv' || 'heit' || 'hebi' => 'helvetica',
          _ => font.toLowerCase(),
        },
      );

  factory EditorSpan.fromJson(Map<String, dynamic> json) => EditorSpan(
        index: json['index'] as int,
        text: json['text'] as String,
        bbox: _rectFrom(json['bbox'] as List),
        font: json['font'] as String,
        size: (json['size'] as num).toDouble(),
        color: json['color'] as String,
        substituteFont: json['substitute_font'] as String,
        added: json['added'] as bool? ?? false,
      );
}

class EditorImage {
  const EditorImage({
    required this.index,
    required this.bbox,
    required this.width,
    required this.height,
    required this.added,
  });

  final int index;
  final Rect bbox;
  final int width;
  final int height;
  final bool added;

  factory EditorImage.fromJson(Map<String, dynamic> json) => EditorImage(
        index: json['index'] as int,
        bbox: _rectFrom(json['bbox'] as List),
        width: json['width'] as int,
        height: json['height'] as int,
        added: json['added'] as bool? ?? false,
      );
}

Rect _rectFrom(List<dynamic> bbox) => Rect.fromLTRB(
      (bbox[0] as num).toDouble(),
      (bbox[1] as num).toDouble(),
      (bbox[2] as num).toDouble(),
      (bbox[3] as num).toDouble(),
    );
