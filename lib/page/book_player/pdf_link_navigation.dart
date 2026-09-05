import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

PdfLinkHandlerParams pdfInternalLinkHandler(PdfViewerController controller) =>
    PdfLinkHandlerParams(
      linkColor: Colors.transparent,
      enableAutoLinkDetection: false,
      onLinkTap: (link) {
        final destination = link.dest;
        if (destination != null && controller.isReady) {
          unawaited(controller.goToDest(destination));
        }
      },
    );
