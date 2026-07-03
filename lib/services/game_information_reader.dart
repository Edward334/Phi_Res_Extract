import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';

import '../models/song.dart';
import 'unity_fs_reader.dart';

class GameInformationReader {
  const GameInformationReader();

  Future<Map<String, Song>> readSongs(File apk) async {
    final tree = await _loadGameInformationTree();
    const serializedReader = UnitySerializedFileReader();

    final input = InputFileStream(apk.path);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      try {
        final files = {
          for (final file in archive.files)
            if (file.isFile) file.name: file,
        };
        final global = _archiveBytes(
          files['assets/bin/Data/globalgamemanagers.assets'],
        );
        final level0 = _archiveBytes(files['assets/bin/Data/level0']);
        if (global == null || level0 == null) {
          throw const FormatException('APK 中缺少 Unity 启动场景资源');
        }

        final globalFile = serializedReader.readFile(global);
        final scriptNames = <int, String>{};
        for (final object in globalFile.objects) {
          if (object.classId == 115) {
            scriptNames[object.pathId] = _readMonoScriptName(object);
          }
        }

        final levelFile = serializedReader.readFile(level0);
        for (final object in levelFile.objects) {
          if (object.classId != 114) {
            continue;
          }
          final scriptPathId = _readMonoBehaviourScriptPathId(object);
          if (scriptNames[scriptPathId] != 'GameInformation') {
            continue;
          }

          final data = const UnityTypeTreeReader().readObject(
            object.data,
            tree,
            endian: object.endian,
          );
          return _songsFromGameInformation(data);
        }
      } finally {
        await archive.clear();
      }
    } finally {
      await input.close();
    }

    throw const FormatException('APK 中没有找到 GameInformation');
  }

  Future<List<dynamic>> _loadGameInformationTree() async {
    final source = await rootBundle.loadString('tools/typetree.json');
    final trees = jsonDecode(source) as Map<String, dynamic>;
    final tree = trees['GameInformation'];
    if (tree is! List<dynamic>) {
      throw const FormatException('typetree.json 中缺少 GameInformation');
    }
    return tree;
  }

  Uint8List? _archiveBytes(ArchiveFile? file) {
    if (file == null) {
      return null;
    }
    final content = file.content;
    file.clear();
    return content is Uint8List
        ? content
        : Uint8List.fromList(content as List<int>);
  }

  String _readMonoScriptName(UnitySerializedObject object) {
    final reader = _EndianReader(object.data, object.endian);
    return reader.readAlignedString();
  }

  int _readMonoBehaviourScriptPathId(UnitySerializedObject object) {
    final reader = _EndianReader(object.data, object.endian);
    reader.readInt32();
    reader.readInt64();
    reader.readByte();
    reader.align(4);
    reader.readInt32();
    return reader.readInt64();
  }

  Map<String, Song> _songsFromGameInformation(Map<String, dynamic> data) {
    final songGroups = data['song'];
    if (songGroups is! Map<String, dynamic>) {
      throw const FormatException('GameInformation 中缺少 song 字段');
    }

    final songs = <String, Song>{};
    for (final entry in songGroups.entries) {
      if (entry.key == 'otherSongs' || entry.value is! List<dynamic>) {
        continue;
      }
      for (final item in (entry.value as List<dynamic>)) {
        if (item is! Map<String, dynamic>) {
          continue;
        }
        final songId = item['songsId'].toString().replaceFirst(
              RegExp(r'\.0$'),
              '',
            );
        final difficulties =
            (item['difficulty'] as List<dynamic>? ?? const []).map((value) {
          final parsed = double.tryParse(value.toString()) ?? 0;
          return (parsed * 10).roundToDouble() / 10;
        }).toList();
        songs[songId] = Song(
          id: songId,
          title: item['songsName']?.toString() ?? songId,
          composer: item['composer']?.toString() ?? '',
          illustrator: item['illustrator']?.toString() ?? '',
          charters: (item['charter'] as List<dynamic>? ?? const [])
              .map((value) => value.toString())
              .toList(),
          difficulties: difficulties.take(chartLevels.length).toList(),
          illustrationPath: null,
          musicPath: null,
          chartPaths: const {},
        );
      }
    }
    return songs;
  }
}

class _EndianReader {
  _EndianReader(this.data, this.endian);

  final Uint8List data;
  final Endian endian;
  var position = 0;

  int readByte() {
    final value = data[position];
    position += 1;
    return value;
  }

  int readInt32() {
    final value =
        ByteData.sublistView(data, position, position + 4).getInt32(0, endian);
    position += 4;
    return value;
  }

  int readInt64() {
    final value =
        ByteData.sublistView(data, position, position + 8).getInt64(0, endian);
    position += 8;
    return value;
  }

  String readAlignedString() {
    final length = readInt32();
    final value = utf8.decode(data.sublist(position, position + length));
    position += length;
    align(4);
    return value;
  }

  void align(int boundary) {
    final remainder = position % boundary;
    if (remainder != 0) {
      position += boundary - remainder;
    }
  }
}
