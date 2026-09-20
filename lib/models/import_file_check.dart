import 'dart:io';
import 'package:anx_reader/models/book.dart';

class ImportFileCheck {
  final String filePath;
  final String? md5;
  final FileStat? fingerprintStat;
  final bool isDuplicate;
  final Book? duplicateBook;
  final bool isRestore;
  final Book? restoreBook;

  ImportFileCheck({
    required this.filePath,
    required this.md5,
    this.fingerprintStat,
    required this.isDuplicate,
    this.duplicateBook,
    this.isRestore = false,
    this.restoreBook,
  });
}
