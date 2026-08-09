import 'dart:async';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ffi/ffi.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart' as media_domain;
import 'package:immich_mobile/platform/local_image_api.g.dart' as local_api;
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';

part 'local_image_request.dart';
part 'thumbhash_image_request.dart';
part 'remote_image_request.dart';

abstract class ImageRequest {
  static int _nextRequestId = 0;

  final int requestId = _nextRequestId++;
  bool _isCancelled = false;

  get isCancelled => _isCancelled;

  ImageRequest();

  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0});

  Future<ui.Codec?> loadCodec();

  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    return _onCancelled();
  }

  void _onCancelled();

  Future<(ui.Codec, ui.ImageDescriptor)?> _codecFromEncodedBytes(Uint8List bytes) async {
    if (_isCancelled) {
      return null;
    }

    final buffer = await ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    var transferred = false;
    try {
      if (_isCancelled) {
        return null;
      }
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (_isCancelled) {
        return null;
      }
      codec = await descriptor.instantiateCodec();
      if (_isCancelled) {
        return null;
      }
      transferred = true;
      return (codec, descriptor);
    } finally {
      try {
        if (!transferred) {
          try {
            codec?.dispose();
          } finally {
            descriptor?.dispose();
          }
        }
      } finally {
        buffer.dispose();
      }
    }
  }

  Future<ui.FrameInfo?> _fromEncodedBytes(Uint8List bytes) async {
    final result = await _codecFromEncodedBytes(bytes);
    if (result == null) return null;

    final (codec, descriptor) = result;
    try {
      if (_isCancelled) {
        return null;
      }
      final frame = await codec.getNextFrame();
      if (_isCancelled) {
        frame.image.dispose();
        return null;
      }
      return frame;
    } finally {
      try {
        codec.dispose();
      } finally {
        descriptor.dispose();
      }
    }
  }

  Future<ui.FrameInfo?> _fromDecodedPlatformImage(int address, int width, int height, int rowBytes) async {
    final pointer = Pointer<Uint8>.fromAddress(address);
    if (_isCancelled) {
      malloc.free(pointer);
      return null;
    }

    try {
      return await _fromDecodedBytes(pointer.asTypedList(rowBytes * height), width, height, rowBytes);
    } finally {
      malloc.free(pointer);
    }
  }

  Future<ui.FrameInfo?> _fromDecodedBytes(Uint8List bytes, int width, int height, int rowBytes) async {
    if (_isCancelled) {
      return null;
    }

    final buffer = await ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      if (_isCancelled) {
        return null;
      }
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        rowBytes: rowBytes,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      if (_isCancelled) {
        return null;
      }
      codec = await descriptor.instantiateCodec();
      if (_isCancelled) {
        return null;
      }
      final frame = await codec.getNextFrame();
      if (_isCancelled) {
        frame.image.dispose();
        return null;
      }
      return frame;
    } finally {
      try {
        codec?.dispose();
      } finally {
        try {
          descriptor?.dispose();
        } finally {
          buffer.dispose();
        }
      }
    }
  }

  void _releaseNativeBuffer(int address) {
    if (address > 0) {
      malloc.free(Pointer<Uint8>.fromAddress(address));
    }
  }
}
