import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

class TapTapApk {
  const TapTapApk({
    required this.versionName,
    required this.versionCode,
    required this.updateDate,
    required this.size,
    required this.url,
    required this.md5,
  });

  final String versionName;
  final int versionCode;
  final String updateDate;
  final int size;
  final String url;
  final String md5;
}

class TapTapApkResolver {
  const TapTapApkResolver();

  static const _appId = 165287;
  static const _secret = 'PeCkE6Fu0B10Vm9BKfPfANwCUAn5POcs';
  static const _host = 'api.taptapdada.com';
  static const _userAgent = 'okhttp/3.12.1';

  Future<TapTapApk> resolveLatest() async {
    final uid = _uuidV4();
    final xUa = 'V=1&PN=TapTap&VN=2.40.1-rel.100000&VN_CODE=240011000&LOC=CN'
        '&LANG=zh_CN&CH=default&UID=$uid&NT=1&SR=1080x2030'
        '&DEB=Xiaomi&DEM=Redmi+Note+5&OSV=9';
    final detail = await _requestJson(
      'GET',
      '/app/v2/detail-by-id/$_appId?X-UA=${Uri.encodeComponent(xUa)}',
    );
    final apkId = detail['data']?['download']?['apk_id'];
    if (apkId == null) {
      throw const FormatException('TapTap response missing apk_id');
    }

    final nonce = _nonce();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final param = 'abi=arm64-v8a,armeabi-v7a,armeabi'
        '&id=$apkId&node=$uid&nonce=$nonce&sandbox=1'
        '&screen_densities=xhdpi&time=$now';
    final signBase = 'X-UA=$xUa&$param$_secret';
    final sign = md5.convert(utf8.encode(signBase)).toString();
    final apkDetail = await _requestJson(
      'POST',
      '/apk/v1/detail?X-UA=${Uri.encodeComponent(xUa)}',
      body: '$param&sign=$sign',
    );
    final url = _findFirstUrl(apkDetail);
    if (url == null) {
      throw const FormatException('TapTap response missing APK download URL');
    }

    final app = detail['data'] as Map<String, dynamic>? ?? {};
    final apk = apkDetail['data']?['apk'] as Map<String, dynamic>? ?? {};
    return TapTapApk(
      versionName: apk['version_name'] as String? ?? 'unknown',
      versionCode: (apk['version_code'] as num?)?.toInt() ?? 0,
      updateDate: app['update_date'] as String? ?? '',
      size: (apk['size'] as num?)?.toInt() ?? 0,
      url: url,
      md5: apk['md5'] as String? ?? '',
    );
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    String? body,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('https://$_host$path'),
      );
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      if (body != null) {
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        );
        request.write(body);
      }
      final response = await request.close();
      final source = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'TapTap 请求失败：HTTP ${response.statusCode}',
          uri: Uri.parse('https://$_host$path'),
        );
      }
      return jsonDecode(source) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  static String? _findFirstUrl(Object? value) {
    if (value is String &&
        value.startsWith(RegExp('https?://')) &&
        (value.contains('.apk') ||
            value.contains('download') ||
            value.contains('apk'))) {
      return value;
    }
    if (value is Map) {
      for (final key in const [
        'download_url',
        'downloadUrl',
        'url',
        'uri',
        'apk_url',
        'apkUrl',
      ]) {
        final url = _findFirstUrl(value[key]);
        if (url != null) {
          return url;
        }
      }
      for (final item in value.values) {
        final url = _findFirstUrl(item);
        if (url != null) {
          return url;
        }
      }
    }
    if (value is List) {
      for (final item in value) {
        final url = _findFirstUrl(item);
        if (url != null) {
          return url;
        }
      }
    }
    return null;
  }

  static String _nonce() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return List.generate(
      5,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  static String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0'));
    final value = hex.join();
    return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }
}
