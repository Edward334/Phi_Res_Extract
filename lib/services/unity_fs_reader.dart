import 'dart:convert';
import 'dart:typed_data';

class UnityFsFile {
  const UnityFsFile({
    required this.path,
    required this.offset,
    required this.size,
    required this.data,
  });

  final String path;
  final int offset;
  final int size;
  final Uint8List data;
}

class UnityTextAsset {
  const UnityTextAsset({
    required this.name,
    required this.bytes,
  });

  final String name;
  final Uint8List bytes;

  String get text => utf8.decode(bytes);
}

class UnitySerializedObject {
  const UnitySerializedObject({
    required this.pathId,
    required this.classId,
    required this.typeId,
    required this.endian,
    required this.data,
  });

  final int pathId;
  final int classId;
  final int typeId;
  final Endian endian;
  final Uint8List data;
}

class UnitySerializedFile {
  const UnitySerializedFile({
    required this.version,
    required this.endian,
    required this.objects,
  });

  final int version;
  final Endian endian;
  final List<UnitySerializedObject> objects;
}

class UnityFsReader {
  const UnityFsReader();

  List<UnityFsFile> readFiles(Uint8List source) {
    final reader = _BinaryReader(source);
    final signature = reader.readNullTerminatedString();
    if (signature != 'UnityFS') {
      throw FormatException('Unsupported Unity bundle signature: $signature');
    }

    reader.readUint32();
    reader.readNullTerminatedString();
    reader.readNullTerminatedString();

    reader.readUint64();
    final compressedInfoSize = reader.readUint32();
    final uncompressedInfoSize = reader.readUint32();
    final flags = reader.readUint32();
    final infoAtEnd = flags & 0x80 != 0;
    final blocksInfoCompression = flags & 0x3f;

    if (!infoAtEnd && flags & 0x200 != 0) {
      reader.align(16);
    }
    final compressedInfoOffset =
        infoAtEnd ? source.length - compressedInfoSize : reader.position;
    final compressedInfo = Uint8List.sublistView(
      source,
      compressedInfoOffset,
      compressedInfoOffset + compressedInfoSize,
    );
    final blocksInfo = _decodeBlock(
      compressedInfo,
      compression: blocksInfoCompression,
      uncompressedSize: uncompressedInfoSize,
    );

    final info = _BinaryReader(blocksInfo);
    info.skip(16);
    final blockCount = info.readUint32();
    final blocks = <_UnityFsBlock>[];
    for (var index = 0; index < blockCount; index += 1) {
      blocks.add(
        _UnityFsBlock(
          uncompressedSize: info.readUint32(),
          compressedSize: info.readUint32(),
          flags: info.readUint16(),
        ),
      );
    }

    final nodeCount = info.readUint32();
    final nodes = <_UnityFsNode>[];
    for (var index = 0; index < nodeCount; index += 1) {
      nodes.add(
        _UnityFsNode(
          offset: info.readUint64(),
          size: info.readUint64(),
          flags: info.readUint32(),
          path: info.readNullTerminatedString(),
        ),
      );
    }

    var dataOffset =
        infoAtEnd ? reader.position : compressedInfoOffset + compressedInfoSize;
    if (!infoAtEnd && flags & 0x200 != 0) {
      final remainder = dataOffset % 16;
      if (remainder != 0) {
        dataOffset += 16 - remainder;
      }
    }
    final output = BytesBuilder(copy: false);
    for (final block in blocks) {
      final compressed = Uint8List.sublistView(
        source,
        dataOffset,
        dataOffset + block.compressedSize,
      );
      output.add(
        _decodeBlock(
          compressed,
          compression: block.flags & 0x3f,
          uncompressedSize: block.uncompressedSize,
        ),
      );
      dataOffset += block.compressedSize;
    }
    final data = output.takeBytes();

    return [
      for (final node in nodes)
        UnityFsFile(
          path: node.path,
          offset: node.offset,
          size: node.size,
          data:
              Uint8List.sublistView(data, node.offset, node.offset + node.size),
        ),
    ];
  }

  Uint8List _decodeBlock(
    Uint8List source, {
    required int compression,
    required int uncompressedSize,
  }) {
    return switch (compression) {
      0 => source,
      2 || 3 => _Lz4BlockDecoder().decode(source, uncompressedSize),
      _ =>
        throw FormatException('Unsupported UnityFS compression: $compression'),
    };
  }
}

class UnitySerializedFileReader {
  const UnitySerializedFileReader();

  List<UnityTextAsset> readTextAssets(Uint8List source) {
    final file = readFile(source);
    return [
      for (final object in file.objects)
        if (object.classId == 49) _readTextAsset(object.data, object.endian),
    ];
  }

  UnitySerializedFile readFile(Uint8List source) {
    var reader = _BinaryReader(source);
    var metadataSize = reader.readUint32();
    reader.readUint32();
    final version = reader.readUint32();
    var dataOffset = reader.readUint32();
    var endian = Endian.big;

    if (version >= 9) {
      endian = reader.readByte() == 1 ? Endian.big : Endian.little;
      reader.skip(3);
      if (version >= 22) {
        metadataSize = reader.readUint32();
        reader.readUint64();
        dataOffset = reader.readUint64();
        reader.readUint64();
      }
    } else {
      reader.position = source.length - metadataSize;
      endian = reader.readByte() == 1 ? Endian.big : Endian.little;
    }

    reader = _BinaryReader(source, position: reader.position, endian: endian);

    if (version >= 7) {
      reader.readNullTerminatedString();
    }
    if (version >= 8) {
      reader.readInt32();
    }
    final enableTypeTree = version >= 13 ? reader.readByte() != 0 : true;

    final typeCount = reader.readInt32();
    final classIds = <int>[];
    for (var index = 0; index < typeCount; index += 1) {
      classIds.add(
        _readSerializedType(
          reader,
          version: version,
          enableTypeTree: enableTypeTree,
          isRefType: false,
        ),
      );
    }

    var bigIdEnabled = false;
    if (version >= 7 && version < 14) {
      bigIdEnabled = reader.readInt32() != 0;
    }

    final objects = <UnitySerializedObject>[];
    final objectCount = reader.readInt32();
    for (var index = 0; index < objectCount; index += 1) {
      final int pathId;
      if (bigIdEnabled) {
        pathId = reader.readUint64();
      } else if (version < 14) {
        pathId = reader.readInt32();
      } else {
        reader.align(4);
        pathId = reader.readUint64();
      }

      final byteStart =
          (version >= 22 ? reader.readUint64() : reader.readUint32()) +
              dataOffset;
      final byteSize = reader.readUint32();
      final typeId = reader.readInt32();
      final classId = version < 16 ? reader.readUint16() : classIds[typeId];

      if (version < 11) {
        reader.readUint16();
      }
      if (version >= 11 && version < 17) {
        reader.readUint16();
      }
      if (version == 15 || version == 16) {
        reader.readByte();
      }

      objects.add(
        UnitySerializedObject(
          pathId: pathId,
          classId: classId,
          typeId: typeId,
          endian: endian,
          data: Uint8List.sublistView(
            source,
            byteStart,
            byteStart + byteSize,
          ),
        ),
      );
    }

    return UnitySerializedFile(
      version: version,
      endian: endian,
      objects: objects,
    );
  }

  int _readSerializedType(
    _BinaryReader reader, {
    required int version,
    required bool enableTypeTree,
    required bool isRefType,
  }) {
    final classId = reader.readInt32();
    if (version >= 16) {
      reader.readByte();
    }
    final scriptTypeIndex = version >= 17 ? reader.readInt16() : -1;
    if (version >= 13) {
      final hasScriptId = (isRefType && scriptTypeIndex >= 0) ||
          (version < 16 && classId < 0) ||
          (version >= 16 && classId == 114);
      if (hasScriptId) {
        reader.skip(16);
      }
      reader.skip(16);
    }

    if (enableTypeTree) {
      if (version >= 12 || version == 10) {
        final nodeCount = reader.readInt32();
        final stringBufferSize = reader.readInt32();
        final nodeSize = version >= 19 ? 32 : 24;
        reader.skip(nodeCount * nodeSize + stringBufferSize);
      } else {
        throw FormatException(
          'Unsupported serialized type tree version: $version',
        );
      }

      if (version >= 21) {
        if (isRefType) {
          reader.readNullTerminatedString();
          reader.readNullTerminatedString();
          reader.readNullTerminatedString();
        } else {
          final dependencyCount = reader.readInt32();
          reader.skip(dependencyCount * 4);
        }
      }
    }

    return classId;
  }

  UnityTextAsset _readTextAsset(Uint8List source, Endian endian) {
    final reader = _BinaryReader(source, endian: endian);
    final name = reader.readAlignedString();
    final bytes = reader.readAlignedBytes();
    return UnityTextAsset(name: name, bytes: bytes);
  }
}

class UnityTypeTreeReader {
  const UnityTypeTreeReader();

  Map<String, dynamic> readObject(
    Uint8List source,
    List<dynamic> nodes, {
    required Endian endian,
  }) {
    if (nodes.isEmpty) {
      throw const FormatException('Unity type tree is empty.');
    }
    final root = _TypeTreeNode.fromList(nodes);
    final value = _readValue(root, _BinaryReader(source, endian: endian));
    if (value is! Map<String, dynamic>) {
      throw const FormatException(
          'Unity type tree root did not read an object.');
    }
    return value;
  }

  dynamic _readValue(_TypeTreeNode node, _BinaryReader reader) {
    final align = node.aligned;
    dynamic value;

    switch (node.type) {
      case 'SInt8':
        value = reader.readInt8();
      case 'UInt8':
      case 'char':
        value = reader.readByte();
      case 'short':
      case 'SInt16':
        value = reader.readInt16();
      case 'unsigned short':
      case 'UInt16':
        value = reader.readUint16();
      case 'int':
      case 'SInt32':
        value = reader.readInt32();
      case 'unsigned int':
      case 'UInt32':
      case 'Type*':
        value = reader.readUint32();
      case 'long long':
      case 'SInt64':
        value = reader.readInt64();
      case 'unsigned long long':
      case 'UInt64':
      case 'FileSize':
        value = reader.readUint64();
      case 'float':
        value = reader.readFloat32();
      case 'double':
        value = reader.readFloat64();
      case 'bool':
        value = reader.readByte() != 0;
      case 'string':
        value = reader.readAlignedString();
      case 'TypelessData':
        value = reader.readBytes(reader.readInt32());
      case 'pair':
        value = [
          _readValue(node.children[0], reader),
          _readValue(node.children[1], reader),
        ];
      default:
        if (node.children.isNotEmpty && node.children.first.type == 'Array') {
          value = _readVector(node, reader);
        } else {
          value = <String, dynamic>{
            for (final child in node.children)
              child.name: _readValue(child, reader),
          };
        }
    }

    if (align) {
      reader.align(4);
    }
    return value;
  }

  List<dynamic> _readVector(_TypeTreeNode node, _BinaryReader reader) {
    final array = node.children.first;
    final size = reader.readInt32();
    if (size < 0) {
      throw const FormatException('Negative Unity array size.');
    }
    if (array.children.length < 2) {
      throw const FormatException(
          'Unity array node is missing its data child.');
    }
    final subtype = array.children[1];
    final values = [
      for (var index = 0; index < size; index += 1)
        _readValueWithoutTrailingAlign(subtype, reader),
    ];
    if (array.aligned || subtype.aligned) {
      reader.align(4);
    }
    return values;
  }

  dynamic _readValueWithoutTrailingAlign(
    _TypeTreeNode node,
    _BinaryReader reader,
  ) {
    if (node.type == 'bool') {
      return reader.readByte() != 0;
    }
    if (node.type == 'UInt8' || node.type == 'char') {
      return reader.readByte();
    }
    if (node.type == 'SInt8') {
      return reader.readInt8();
    }
    return _readValue(node, reader);
  }
}

class _TypeTreeNode {
  _TypeTreeNode({
    required this.type,
    required this.name,
    required this.level,
    required this.metaFlag,
  });

  final String type;
  final String name;
  final int level;
  final int metaFlag;
  final children = <_TypeTreeNode>[];

  bool get aligned => metaFlag & 0x4000 != 0;

  static _TypeTreeNode fromList(List<dynamic> nodes) {
    final stack = <_TypeTreeNode>[];
    _TypeTreeNode? root;
    for (final raw in nodes.cast<Map<String, dynamic>>()) {
      final node = _TypeTreeNode(
        type: raw['m_Type'] as String? ?? '',
        name: raw['m_Name'] as String? ?? '',
        level: (raw['m_Level'] as num?)?.toInt() ?? 0,
        metaFlag: (raw['m_MetaFlag'] as num?)?.toInt() ?? 0,
      );
      while (stack.isNotEmpty && stack.last.level >= node.level) {
        stack.removeLast();
      }
      if (stack.isEmpty) {
        root = node;
      } else {
        stack.last.children.add(node);
      }
      stack.add(node);
    }
    if (root == null) {
      throw const FormatException('Unity type tree did not contain a root.');
    }
    return root;
  }
}

class _UnityFsBlock {
  const _UnityFsBlock({
    required this.uncompressedSize,
    required this.compressedSize,
    required this.flags,
  });

  final int uncompressedSize;
  final int compressedSize;
  final int flags;
}

class _UnityFsNode {
  const _UnityFsNode({
    required this.offset,
    required this.size,
    required this.flags,
    required this.path,
  });

  final int offset;
  final int size;
  final int flags;
  final String path;
}

class _BinaryReader {
  _BinaryReader(
    this.data, {
    this.position = 0,
    this.endian = Endian.big,
  });

  final Uint8List data;
  var position = 0;
  final Endian endian;

  int readByte() {
    final value = data[position];
    position += 1;
    return value;
  }

  int readInt8() {
    final value = ByteData.sublistView(data, position, position + 1).getInt8(0);
    position += 1;
    return value;
  }

  int readInt16() {
    final value =
        ByteData.sublistView(data, position, position + 2).getInt16(0, endian);
    position += 2;
    return value;
  }

  int readUint16() {
    final value =
        ByteData.sublistView(data, position, position + 2).getUint16(0, endian);
    position += 2;
    return value;
  }

  int readInt32() {
    final value =
        ByteData.sublistView(data, position, position + 4).getInt32(0, endian);
    position += 4;
    return value;
  }

  int readUint32() {
    final value =
        ByteData.sublistView(data, position, position + 4).getUint32(0, endian);
    position += 4;
    return value;
  }

  int readUint64() {
    final value =
        ByteData.sublistView(data, position, position + 8).getUint64(0, endian);
    position += 8;
    return value;
  }

  int readInt64() {
    final value =
        ByteData.sublistView(data, position, position + 8).getInt64(0, endian);
    position += 8;
    return value;
  }

  double readFloat32() {
    final value = ByteData.sublistView(data, position, position + 4)
        .getFloat32(0, endian);
    position += 4;
    return value;
  }

  double readFloat64() {
    final value = ByteData.sublistView(data, position, position + 8)
        .getFloat64(0, endian);
    position += 8;
    return value;
  }

  Uint8List readBytes(int count) {
    final value = Uint8List.sublistView(data, position, position + count);
    position += count;
    return value;
  }

  Uint8List readAlignedBytes() {
    final length = readInt32();
    final bytes = readBytes(length);
    align(4);
    return bytes;
  }

  String readAlignedString() {
    return utf8.decode(readAlignedBytes());
  }

  String readNullTerminatedString() {
    final start = position;
    while (position < data.length && data[position] != 0) {
      position += 1;
    }
    final value = utf8.decode(data.sublist(start, position));
    position += 1;
    return value;
  }

  void skip(int count) {
    position += count;
  }

  void align(int boundary) {
    final remainder = position % boundary;
    if (remainder != 0) {
      position += boundary - remainder;
    }
  }
}

class _Lz4BlockDecoder {
  Uint8List decode(Uint8List source, int expectedSize) {
    final output = Uint8List(expectedSize);
    var inputOffset = 0;
    var outputOffset = 0;

    while (inputOffset < source.length) {
      final token = source[inputOffset++];
      var literalLength = token >> 4;
      if (literalLength == 15) {
        int value;
        do {
          value = source[inputOffset++];
          literalLength += value;
        } while (value == 255);
      }

      output.setRange(
        outputOffset,
        outputOffset + literalLength,
        source,
        inputOffset,
      );
      inputOffset += literalLength;
      outputOffset += literalLength;

      if (inputOffset >= source.length) {
        break;
      }

      final matchOffset = source[inputOffset] | source[inputOffset + 1] << 8;
      inputOffset += 2;
      if (matchOffset == 0) {
        throw const FormatException('Invalid LZ4 match offset.');
      }

      var matchLength = token & 0x0f;
      if (matchLength == 15) {
        int value;
        do {
          value = source[inputOffset++];
          matchLength += value;
        } while (value == 255);
      }
      matchLength += 4;

      final matchStart = outputOffset - matchOffset;
      if (matchStart < 0) {
        throw const FormatException('Invalid LZ4 back reference.');
      }
      for (var index = 0; index < matchLength; index += 1) {
        output[outputOffset + index] = output[matchStart + index];
      }
      outputOffset += matchLength;
    }

    if (outputOffset != expectedSize) {
      throw FormatException(
        'LZ4 decoded $outputOffset bytes, expected $expectedSize.',
      );
    }
    return output;
  }
}
