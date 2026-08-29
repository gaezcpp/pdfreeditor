import 'package:flutter/material.dart';

/// The editing actions the backend exposes, and what each one needs from the UI.
enum PdfTool {
  compress(
    label: 'Compress',
    description: 'Shrink a PDF without changing its pages.',
    icon: Icons.compress,
    endpoint: '/pdf/compress',
    allowsMultiple: false,
  ),
  merge(
    label: 'Merge',
    description: 'Join several PDFs into one, in the order you pick them.',
    icon: Icons.merge_type,
    endpoint: '/pdf/merge',
    allowsMultiple: true,
  ),
  split(
    label: 'Split',
    description: 'Pull out the pages you need, like 1-3,7.',
    icon: Icons.content_cut,
    endpoint: '/pdf/split',
    allowsMultiple: false,
  ),
  addText(
    label: 'Add text',
    description: 'Stamp a word or a note onto a page.',
    icon: Icons.text_fields,
    endpoint: '/pdf/add-text',
    allowsMultiple: false,
  );

  const PdfTool({
    required this.label,
    required this.description,
    required this.icon,
    required this.endpoint,
    required this.allowsMultiple,
  });

  final String label;
  final String description;
  final IconData icon;
  final String endpoint;

  /// Merge is the only tool that takes more than one file.
  final bool allowsMultiple;

  /// How many files must be chosen before the action can run.
  int get minimumFiles => allowsMultiple ? 2 : 1;
}
