import 'package:anx_reader/service/sync/library_transfer_progress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final libraryTransfersProvider = StreamProvider<Map<String, LibraryTransfer>>(
  (ref) => libraryTransferProgress.stream,
);
