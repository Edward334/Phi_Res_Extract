import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

class AddressableAsset {
  const AddressableAsset({required this.key, required this.bundle});

  final String key;
  final String bundle;

  Map<String, String> toJson() => {'key': key, 'bundle': bundle};
}

class ApkAddressablesReader {
  const ApkAddressablesReader();

  Future<List<AddressableAsset>> readTrackAssets(File apk) async {
    final catalog = await _readCatalog(apk);
    final keyData = base64Decode(catalog['m_KeyDataString'] as String);
    final bucketData = base64Decode(catalog['m_BucketDataString'] as String);
    final entryData = base64Decode(catalog['m_EntryDataString'] as String);

    final table = <_AddressableRow>[];
    final reader = _ByteReader(bucketData);
    final bucketCount = reader.readInt24();
    for (var index = 0; index < bucketCount; index += 1) {
      var keyPosition = reader.readInt24();
      final keyType = keyData[keyPosition];
      keyPosition += 1;

      final Object keyValue;
      if (keyType == 0) {
        final length = keyData[keyPosition];
        keyPosition += 4;
        keyValue =
            utf8.decode(keyData.sublist(keyPosition, keyPosition + length));
      } else if (keyType == 1) {
        final length = keyData[keyPosition];
        keyPosition += 4;
        keyValue = _decodeUtf16Le(
          keyData.sublist(keyPosition, keyPosition + length),
        );
      } else if (keyType == 4) {
        keyValue = keyData[keyPosition];
      } else {
        throw FormatException('Unsupported addressable key type $keyType');
      }

      int? entryValue;
      final entryCount = reader.readInt24();
      for (var entryIndex = 0; entryIndex < entryCount; entryIndex += 1) {
        final entryPosition = reader.readInt24();
        final offset = 4 + 28 * entryPosition;
        entryValue = entryData[offset + 8] ^ entryData[offset + 9] << 8;
      }
      table.add(_AddressableRow(keyValue, entryValue));
    }

    for (var index = 0; index < table.length; index += 1) {
      final bundleIndex = table[index].bundleIndex;
      if (bundleIndex != null && bundleIndex != 65535) {
        table[index] = table[index].copyWith(bundle: table[bundleIndex].key);
      }
    }

    return [
      for (final row in table)
        if (row.key case final String key)
          if (row.bundle case final String bundle)
            if (_isTrackAsset(key))
              AddressableAsset(
                key: key.startsWith('Assets/Tracks/')
                    ? key.substring('Assets/Tracks/'.length)
                    : key,
                bundle: bundle,
              ),
    ];
  }

  Future<Map<String, dynamic>> _readCatalog(File apk) async {
    final input = InputFileStream(apk.path);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      try {
        final catalogFile = archive.files.firstWhere(
          (file) => file.name == 'assets/aa/catalog.json',
        );
        return jsonDecode(utf8.decode(catalogFile.content as List<int>))
            as Map<String, dynamic>;
      } finally {
        await archive.clear();
      }
    } finally {
      await input.close();
    }
  }

  bool _isTrackAsset(String key) {
    if (key.startsWith('Assets/Tracks/#')) {
      return false;
    }
    return key.startsWith('Assets/Tracks/') || key.startsWith('avatar.');
  }

  String _decodeUtf16Le(List<int> bytes) {
    final codeUnits = <int>[];
    for (var index = 0; index + 1 < bytes.length; index += 2) {
      codeUnits.add(bytes[index] | bytes[index + 1] << 8);
    }
    return String.fromCharCodes(codeUnits);
  }
}

class _AddressableRow {
  const _AddressableRow(this.key, this.bundleIndex, {this.bundle});

  final Object key;
  final int? bundleIndex;
  final Object? bundle;

  _AddressableRow copyWith({Object? bundle}) {
    return _AddressableRow(key, bundleIndex, bundle: bundle);
  }
}

class _ByteReader {
  _ByteReader(this.data);

  final Uint8List data;
  var position = 0;

  int readInt24() {
    final value =
        data[position] ^ data[position + 1] << 8 ^ data[position + 2] << 16;
    position += 4;
    return value;
  }
}
