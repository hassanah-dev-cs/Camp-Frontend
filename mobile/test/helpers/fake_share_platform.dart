// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

export 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Fake implementation of [SharePlatform] for capturing share requests in tests.
class FakeSharePlatform extends SharePlatform {
  ShareParams? lastParams;
  int callCount = 0;

  @override
  Future<ShareResult> share(ShareParams params) async {
    callCount++;
    lastParams = params;
    return const ShareResult('success', ShareResultStatus.success);
  }

  void reset() {
    lastParams = null;
    callCount = 0;
  }
}

/// Fake implementation of [PathProviderPlatform] for returning system temp in tests.
class FakePathProviderPlatform extends PathProviderPlatform {
  FakePathProviderPlatform([this._delegate]);

  final PathProviderPlatform? _delegate;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;

  @override
  Future<String?> getApplicationSupportPath() async =>
      _delegate != null ? await _delegate.getApplicationSupportPath() : Directory.systemTemp.path;

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      _delegate != null ? await _delegate.getApplicationDocumentsPath() : Directory.systemTemp.path;
}

