import 'dart:convert';
import 'dart:io';
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

class UnityTexture2D {
  const UnityTexture2D({
    required this.name,
    required this.width,
    required this.height,
    required this.format,
    required this.data,
  });

  final String name;
  final int width;
  final int height;
  final int format;
  final Uint8List data;

  bool get isRgb24 => format == 3 && data.length >= width * height * 3;
}

class UnityAudioClip {
  const UnityAudioClip({
    required this.name,
    required this.bytes,
    required this.extension,
  });

  final String name;
  final Uint8List bytes;
  final String extension;
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

  List<UnityTexture2D> readTexture2Ds(
    Uint8List source, {
    Map<String, Uint8List> resources = const {},
  }) {
    final file = readFile(source);
    return [
      for (final object in file.objects)
        if (object.classId == 28)
          if (_readTexture2D(object.data, object.endian, resources)
              case final texture?)
            texture,
    ];
  }

  List<UnityAudioClip> readAudioClips(
    Uint8List source, {
    Map<String, Uint8List> resources = const {},
  }) {
    final file = readFile(source);
    return [
      for (final object in file.objects)
        if (object.classId == 83)
          if (_readAudioClip(object.data, object.endian, resources)
              case final clip?)
            clip,
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

  UnityTexture2D? _readTexture2D(
    Uint8List source,
    Endian endian,
    Map<String, Uint8List> resources,
  ) {
    final reader = _BinaryReader(source, endian: endian);
    final name = reader.readAlignedString();
    reader.readInt32();
    reader.readInt32();
    final width = reader.readInt32();
    final height = reader.readInt32();
    reader.readInt32();
    reader.readInt32();
    final format = reader.readInt32();

    Uint8List data;
    final stream = _findTextureStream(source, endian);
    if (stream != null && stream.size > 0) {
      final resourceName = stream.path.split('/').last;
      final resource = resources[resourceName];
      if (resource == null || stream.offset + stream.size > resource.length) {
        return null;
      }
      data = Uint8List.sublistView(
        resource,
        stream.offset,
        stream.offset + stream.size,
      );
    } else {
      final imageSizeOffset =
          _findImageDataSizeOffset(source, endian, width, height, format);
      if (imageSizeOffset == null) {
        return null;
      }
      final imageSize = ByteData.sublistView(
        source,
        imageSizeOffset,
        imageSizeOffset + 4,
      ).getUint32(0, endian);
      data = Uint8List.sublistView(
        source,
        imageSizeOffset + 4,
        imageSizeOffset + 4 + imageSize,
      );
    }

    return UnityTexture2D(
      name: name,
      width: width,
      height: height,
      format: format,
      data: data,
    );
  }

  UnityAudioClip? _readAudioClip(
    Uint8List source,
    Endian endian,
    Map<String, Uint8List> resources,
  ) {
    final reader = _BinaryReader(source, endian: endian);
    final name = reader.readAlignedString();
    reader.readInt32();
    final channels = reader.readInt32();
    final frequency = reader.readInt32();
    reader.readInt32();
    reader.readFloat32();
    reader.readByte();
    reader.align(4);
    reader.readInt32();
    reader.readByte();
    reader.readByte();
    reader.readByte();
    reader.align(4);

    final stream = _readAudioStream(reader);
    if (reader.position + 4 <= source.length) {
      reader.readInt32();
    }

    Uint8List data;
    if (stream.size > 0) {
      final resourceName = stream.path.split('/').last;
      final resource = resources[resourceName];
      if (resource == null || stream.offset + stream.size > resource.length) {
        return null;
      }
      data = Uint8List.sublistView(
        resource,
        stream.offset,
        stream.offset + stream.size,
      );
    } else {
      return null;
    }

    if (_startsWith(data, const [0x4f, 0x67, 0x67, 0x53])) {
      return UnityAudioClip(name: name, bytes: data, extension: '.ogg');
    }
    if (_startsWith(data, const [0x52, 0x49, 0x46, 0x46])) {
      return UnityAudioClip(name: name, bytes: data, extension: '.wav');
    }
    if (data.length >= 8 &&
        data[4] == 0x66 &&
        data[5] == 0x74 &&
        data[6] == 0x79 &&
        data[7] == 0x70) {
      return UnityAudioClip(name: name, bytes: data, extension: '.m4a');
    }
    if (_startsWith(data, const [0x46, 0x53, 0x42, 0x35])) {
      return UnityAudioClip(
        name: name,
        bytes: const Fsb5VorbisExtractor().extract(
          data,
          fallbackChannels: channels,
          fallbackFrequency: frequency,
        ),
        extension: '.ogg',
      );
    }
    return UnityAudioClip(name: name, bytes: data, extension: '.bytes');
  }

  _AudioStream _readAudioStream(_BinaryReader reader) {
    final path = reader.readAlignedString();
    final offset = reader.readUint64();
    final size = reader.readUint64();
    return _AudioStream(offset: offset, size: size, path: path);
  }

  _TextureStream? _findTextureStream(Uint8List source, Endian endian) {
    for (var offset = 12; offset + 4 < source.length; offset += 4) {
      final length =
          ByteData.sublistView(source, offset, offset + 4).getInt32(0, endian);
      final pathStart = offset + 4;
      final pathEnd = pathStart + length;
      if (length <= 0 || pathEnd > source.length) {
        continue;
      }
      final path = utf8.decode(
        source.sublist(pathStart, pathEnd),
        allowMalformed: true,
      );
      if (!path.startsWith('archive:/') || !path.endsWith('.resS')) {
        continue;
      }
      final streamReader = _BinaryReader(
        source,
        position: offset - 12,
        endian: endian,
      );
      return _TextureStream(
        offset: streamReader.readUint64(),
        size: streamReader.readUint32(),
        path: path,
      );
    }
    return null;
  }

  int? _findImageDataSizeOffset(
    Uint8List source,
    Endian endian,
    int width,
    int height,
    int format,
  ) {
    if (format != 3) {
      return null;
    }
    final expected = width * height * 3;
    for (var offset = 0; offset + 4 <= source.length; offset += 4) {
      final value =
          ByteData.sublistView(source, offset, offset + 4).getUint32(0, endian);
      if (value == expected && offset + 4 + value <= source.length) {
        return offset;
      }
    }
    return null;
  }

  bool _startsWith(Uint8List data, List<int> prefix) {
    if (data.length < prefix.length) {
      return false;
    }
    for (var index = 0; index < prefix.length; index += 1) {
      if (data[index] != prefix[index]) {
        return false;
      }
    }
    return true;
  }
}

class _TextureStream {
  const _TextureStream({
    required this.offset,
    required this.size,
    required this.path,
  });

  final int offset;
  final int size;
  final String path;
}

class _AudioStream {
  const _AudioStream({
    required this.offset,
    required this.size,
    required this.path,
  });

  final int offset;
  final int size;
  final String path;
}

class Fsb5VorbisExtractor {
  const Fsb5VorbisExtractor();

  Uint8List extract(
    Uint8List source, {
    int? fallbackChannels,
    int? fallbackFrequency,
  }) {
    final reader = _BinaryReader(source, endian: Endian.little);
    final magic = ascii.decode(reader.readBytes(4));
    if (magic != 'FSB5') {
      throw FormatException('Unsupported FSB magic: $magic');
    }

    final version = reader.readUint32();
    final sampleCount = reader.readUint32();
    final sampleHeadersSize = reader.readUint32();
    final nameTableSize = reader.readUint32();
    final dataSize = reader.readUint32();
    final mode = reader.readUint32();
    reader.skip(8 + 16 + 8);
    if (version == 0) {
      reader.readUint32();
    }

    if (mode != 15) {
      throw FormatException('Unsupported FSB5 mode: $mode');
    }
    if (sampleCount != 1) {
      throw FormatException('Unsupported FSB5 sample count: $sampleCount');
    }

    final raw = reader.readUint64();
    var nextChunk = _bits(raw, 0, 1) == 1;
    final frequencyBits = _bits(raw, 1, 4);
    var channels = _bits(raw, 5, 1) + 1;
    final dataOffset = _bits(raw, 6, 28) * 16;
    final sampleFrames = _bits(raw, 34, 30);
    int? vorbisCrc;
    int? frequency = _frequencyValues[frequencyBits];

    while (nextChunk) {
      final chunk = reader.readUint32();
      nextChunk = _bits(chunk, 0, 1) == 1;
      final chunkSize = _bits(chunk, 1, 24);
      final chunkType = _bits(chunk, 25, 7);
      if (chunkType == 1 && chunkSize == 1) {
        channels = reader.readByte();
      } else if (chunkType == 2 && chunkSize == 4) {
        frequency = reader.readUint32();
      } else if (chunkType == 11 && chunkSize >= 4) {
        vorbisCrc = reader.readUint32();
        reader.skip(chunkSize - 4);
      } else {
        reader.skip(chunkSize);
      }
    }

    frequency ??= fallbackFrequency;
    if (frequency == null) {
      throw const FormatException('FSB5 sample frequency is missing.');
    }
    if (channels <= 0) {
      channels = fallbackChannels ?? channels;
    }
    if (vorbisCrc == null) {
      throw const FormatException('FSB5 sample has no Vorbis metadata.');
    }

    final setupHeader = _setupHeaders[vorbisCrc];
    if (setupHeader == null) {
      throw FormatException('Unsupported FSB5 Vorbis header CRC: $vorbisCrc');
    }

    final dataStart = 60 +
        (version == 0 ? 4 : 0) +
        sampleHeadersSize +
        nameTableSize +
        dataOffset;
    final dataEnd = dataStart + dataSize - dataOffset;
    if (dataStart < 0 || dataEnd > source.length || dataStart > dataEnd) {
      throw const FormatException('Invalid FSB5 sample data range.');
    }
    final packetData = Uint8List.sublistView(source, dataStart, dataEnd);

    final output = BytesBuilder(copy: false);
    var sequence = 0;
    _addOggPage(
      output,
      _buildVorbisIdHeader(
        channels: channels,
        frequency: frequency,
        blocksizeShort: _blocksizeShort,
        blocksizeLong: _blocksizeLong,
      ),
      sequence: sequence,
      granulePosition: 0,
      bos: true,
    );
    sequence += 1;
    _addOggPage(
      output,
      _buildVorbisCommentHeader(),
      sequence: sequence,
      granulePosition: 0,
    );
    sequence += 1;
    _addOggPage(
      output,
      setupHeader,
      sequence: sequence,
      granulePosition: 0,
    );
    sequence += 1;

    final packetReader = _BinaryReader(packetData, endian: Endian.little);
    var previousBlocksize = 0;
    var granulePosition = 0;
    while (packetReader.position + 2 <= packetData.length) {
      final packetSize = packetReader.readUint16();
      if (packetSize == 0) {
        break;
      }
      if (packetReader.position + packetSize > packetData.length) {
        throw const FormatException('Invalid FSB5 Vorbis packet size.');
      }
      final packet = packetReader.readBytes(packetSize);
      final blocksize = packet.isNotEmpty && packet[0] & 0x02 == 0
          ? _blocksizeShort
          : _blocksizeLong;
      granulePosition = previousBlocksize == 0
          ? 0
          : granulePosition + ((blocksize + previousBlocksize) ~/ 4);
      previousBlocksize = blocksize;
      final eos = packetReader.position + 2 > packetData.length ||
          ByteData.sublistView(
                packetData,
                packetReader.position,
                packetReader.position + 2,
              ).getUint16(0, Endian.little) ==
              0;
      _addOggPage(
        output,
        packet,
        sequence: sequence,
        granulePosition: granulePosition,
        eos: eos,
      );
      sequence += 1;
    }

    if (sampleFrames <= 0) {
      throw const FormatException('FSB5 sample frame count is missing.');
    }
    return output.takeBytes();
  }

  static const _blocksizeShort = 256;
  static const _blocksizeLong = 2048;

  static const _frequencyValues = {
    1: 8000,
    2: 11000,
    3: 11025,
    4: 16000,
    5: 22050,
    6: 24000,
    7: 32000,
    8: 44100,
    9: 48000,
  };

  static final Map<int, Uint8List> _setupHeaders = {
    3200735724: base64Decode(_setupHeaderQuality40),
    950688206: base64Decode(_setupHeaderQuality41),
  };

  static int _bits(int value, int start, int length) {
    return (value >> start) & ((1 << length) - 1);
  }

  static Uint8List _buildVorbisIdHeader({
    required int channels,
    required int frequency,
    required int blocksizeShort,
    required int blocksizeLong,
  }) {
    final output = BytesBuilder(copy: false);
    output.addByte(0x01);
    output.add(ascii.encode('vorbis'));
    output.add(_uint32Le(0));
    output.addByte(channels);
    output.add(_uint32Le(frequency));
    output.add(_uint32Le(0));
    output.add(_uint32Le(0));
    output.add(_uint32Le(0));
    output.addByte(
      (_ilog(blocksizeShort) - 1) | ((_ilog(blocksizeLong) - 1) << 4),
    );
    output.addByte(1);
    return output.takeBytes();
  }

  static Uint8List _buildVorbisCommentHeader() {
    final vendor = ascii.encode(
      'Xiph.Org libVorbis I 20200704 (Reducing Environment)',
    );
    final output = BytesBuilder(copy: false);
    output.addByte(0x03);
    output.add(ascii.encode('vorbis'));
    output.add(_uint32Le(vendor.length));
    output.add(vendor);
    output.add(_uint32Le(0));
    output.addByte(1);
    return output.takeBytes();
  }

  static int _ilog(int value) {
    var bits = 0;
    while (value > 0) {
      bits += 1;
      value >>= 1;
    }
    return bits;
  }

  static void _addOggPage(
    BytesBuilder output,
    Uint8List packet, {
    required int sequence,
    required int granulePosition,
    bool bos = false,
    bool eos = false,
  }) {
    final lacing = <int>[];
    var remaining = packet.length;
    while (remaining >= 255) {
      lacing.add(255);
      remaining -= 255;
    }
    lacing.add(remaining);
    if (lacing.length > 255) {
      throw const FormatException('Ogg packet is too large for one page.');
    }

    final page = BytesBuilder(copy: false);
    page.add(ascii.encode('OggS'));
    page.addByte(0);
    page.addByte((bos ? 0x02 : 0) | (eos ? 0x04 : 0));
    page.add(_int64Le(granulePosition));
    page.add(_uint32Le(1));
    page.add(_uint32Le(sequence));
    page.add(_uint32Le(0));
    page.addByte(lacing.length);
    page.add(lacing);
    page.add(packet);

    final bytes = page.takeBytes();
    final crc = _oggCrc(bytes);
    bytes[22] = crc & 0xff;
    bytes[23] = crc >> 8 & 0xff;
    bytes[24] = crc >> 16 & 0xff;
    bytes[25] = crc >> 24 & 0xff;
    output.add(bytes);
  }

  static int _oggCrc(Uint8List bytes) {
    var crc = 0;
    for (final byte in bytes) {
      crc =
          ((crc << 8) & 0xffffffff) ^ _oggCrcTable[((crc >> 24) & 0xff) ^ byte];
    }
    return crc & 0xffffffff;
  }

  static final List<int> _oggCrcTable = _buildOggCrcTable();

  static List<int> _buildOggCrcTable() {
    return [
      for (var index = 0; index < 256; index += 1)
        _buildOggCrcTableEntry(index),
    ];
  }

  static int _buildOggCrcTableEntry(int index) {
    var value = index << 24;
    for (var bit = 0; bit < 8; bit += 1) {
      value = (value & 0x80000000) != 0
          ? ((value << 1) ^ 0x04c11db7) & 0xffffffff
          : (value << 1) & 0xffffffff;
    }
    return value;
  }

  static List<int> _uint32Le(int value) {
    return [
      value & 0xff,
      value >> 8 & 0xff,
      value >> 16 & 0xff,
      value >> 24 & 0xff,
    ];
  }

  static List<int> _int64Le(int value) {
    return [
      value & 0xff,
      value >> 8 & 0xff,
      value >> 16 & 0xff,
      value >> 24 & 0xff,
      value >> 32 & 0xff,
      value >> 40 & 0xff,
      value >> 48 & 0xff,
      value >> 56 & 0xff,
    ];
  }

  static const _setupHeaderQuality40 =
      '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'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAEOAAABBg'
      'IRQasiIAiBMAcEgSJAmSBM0DSJYFTYOmwTQBkmVB06BpME0AAAAAAAAAAAAAJE2DpkHTIIoASdOg'
      'adA0iCIAAAAAAAAAAAAAkqZB06BpEEWApGnQNGgaRBEAAAAAAAAAAAAAzzQhihBFmCbAM02IIkQR'
      'pgkAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAGHAAAAgwoQwUGrIiAIgTAHA4imUBAIDjOJYFAACO'
      '41gWAABYliWKAABgWZooAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAYcAAACDChDBQashIAiAIAcCiKZQHHsSzgOJYFJMmy'
      'AJYF0DyApgFEEQAIAAAocAAACLBBU2JxgEJDVgIAUQAABsWxLE0TRZKkaZoniiRJ0zxPFGma53me'
      'acLzPM80IYqiaJoQRVE0TZimaaoqME1VFQAAUOAAABBgg6bE4gCFhqwEAEICAByKYlma5nmeJ4qm'
      'qZokSdM8TxRF0TRNU1VJkqZ5niiKommapqqyLE3zPFEURdNUVVWFpnmeKIqiaaqq6sLzPE8URdE0'
      'VdV14XmeJ4qiaJqq6roQRVE0TdNUTVV1XSCKpmmaqqqqrgtETxRNU1Vd13WB54miaaqqq7ouEE3T'
      'VFVVdV1ZBpimaaqq68oyQFVV1XVdV5YBqqqqruu6sgxQVdd1XVmWZQCu67qyLMsCAAAOHAAAAoyg'
      'k4wqi7DRhAsPQKEhKwKAKAAAwBimFFPKMCYhpBAaxiSEFEImJaXSUqogpFJSKRWEVEoqJaOUUmop'
      'VRBSKamUCkIqJZVSAADYgQMA2IGFUGjISgAgDwCAMEYpxhhzTiKkFGPOOScRUoox55yTSjHmnHPO'
      'SSkZc8w556SUzjnnnHNSSuacc845KaVzzjnnnJRSSuecc05KKSWEzkEnpZTSOeecEwAAVOAAABBg'
      'o8jmBCNBhYasBABSAQAMjmNZmuZ5omialiRpmud5niiapiZJmuZ5nieKqsnzPE8URdE0VZXneZ4o'
      'iqJpqirXFUXTNE1VVV2yLIqmaZqq6rowTdNUVdd1XZimaaqq67oubFtVVdV1ZRm2raqq6rqyDFzX'
      'dWXZloEsu67s2rIAAPAEBwCgAhtWRzgpGgssNGQlAJABAEAYg5BCCCFlEEIKIYSUUggJAAAYcAAA'
      'CDChDBQashIASAUAAIyx1lprrbXWQGettdZaa62AzFprrbXWWmuttdZaa6211lJrrbXWWmuttdZa'
      'a6211lprrbXWWmuttdZaa6211lprrbXWWmuttdZaa6211lprrbXWWmstpZRSSimllFJKKaWUUkop'
      'pZRSSgUA+lU4APg/2LA6wknRWGChISsBgHAAAMAYpRhzDEIppVQIMeacdFRai7FCiDHnJKTUWmzF'
      'c85BKCGV1mIsnnMOQikpxVZjUSmEUlJKLbZYi0qho5JSSq3VWIwxqaTWWoutxmKMSSm01FqLMRYj'
      'bE2ptdhqq7EYY2sqLbQYY4zFCF9kbC2m2moNxggjWywt1VprMMYY3VuLpbaaizE++NpSLDHWXAAA'
      'd4MDAESCjTOsJJ0VjgYXGrISAAgJACAQUooxxhhzzjnnpFKMOeaccw5CCKFUijHGnHMOQgghlIwx'
      '5pxzEEIIIYRSSsaccxBCCCGEkFLqnHMQQgghhBBKKZ1zDkIIIYQQQimlgxBCCCGEEEoopaQUQggh'
      'hBBCCKmklEIIIYRSQighlZRSCCGEEEIpJaSUUgohhFJCCKGElFJKKYUQQgillJJSSimlEkoJJYQS'
      'UikppRRKCCGUUkpKKaVUSgmhhBJKKSWllFJKIYQQSikFAAAcOAAABBhBJxlVFmGjCRcegEJDVgIA'
      'ZAAAkKKUUiktRYIipRikGEtGFXNQWoqocgxSzalSziDmJJaIMYSUk1Qy5hRCDELqHHVMKQYtlRhC'
      'xhik2HJLoXMOAAAAQQCAgJAAAAMEBTMAwOAA4XMQdAIERxsAgCBEZohEw0JweFAJEBFTAUBigkIu'
      'AFRYXKRdXECXAS7o4q4DIQQhCEEsDqCABByccMMTb3jCDU7QKSp1IAAAAAAADQDwAACQXAAREdHM'
      'YWRobHB0eHyAhIiMkAgAAAAAABoAfAAAJCVAREQ0cxgZGhscHR4fICEiIyQBAIAAAgAAAAAggAAE'
      'BAQAAAAAAAIAAAAEBA==';

  static const _setupHeaderQuality41 =
      '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'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAEOAAABBg'
      'IRQasiIAiBMAcEgSJAmSBM0DSJYFTYOmwTQBkmVB06BpME0AAAAAAAAAAAAAJE2DpkHTIIoASdOg'
      'adA0iCIAAAAAAAAAAAAAkqZB06BpEEWApGnQNGgaRBEAAAAAAAAAAAAAzzQhihBFmCbAM02IIkQR'
      'pgkAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAGHAAAAgwoQwUGrIiAIgTAHA4imUBAIDjOJYFAACO'
      '41gWAABYliWKAABgWZooAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAYcAAACDChDBQashIAiAIAcCiKZQHHsSzgOJYFJMmy'
      'AJYF0DyApgFEEQAIAAAocAAACLBBU2JxgEJDVgIAUQAABsWxLE0TRZKkaZoniiRJ0zxPFGma53me'
      'acLzPM80IYqiaJoQRVE0TZimaaoqME1VFQAAUOAAABBgg6bE4gCFhqwEAEICAByKYlma5nmeJ4qm'
      'qZokSdM8TxRF0TRNU1VJkqZ5niiKommapqqyLE3zPFEURdNUVVWFpnmeKIqiaaqq6sLzPE8URdE0'
      'VdV14XmeJ4qiaJqq6roQRVE0TdNUTVV1XSCKpmmaqqqqrgtETxRNU1Vd13WB54miaaqqq7ouEE3T'
      'VFVVdV1ZBpimaaqq68oyQFVV1XVdV5YBqqqqruu6sgxQVdd1XVmWZQCu67qyLMsCAAAOHAAAAoyg'
      'k4wqi7DRhAsPQKEhKwKAKAAAwBimFFPKMCYhpBAaxiSEFEImJaXSUqogpFJSKRWEVEoqJaOUUmop'
      'VRBSKamUCkIqJZVSAADYgQMA2IGFUGjISgAgDwCAMEYpxhhzTiKkFGPOOScRUoox55yTSjHmnHPO'
      'SSkZc8w556SUzjnnnHNSSuacc845KaVzzjnnnJRSSuecc05KKSWEzkEnpZTSOeecEwAAVOAAABBg'
      'o8jmBCNBhYasBABSAQAMjmNZmuZ5omialiRpmud5niiapiZJmuZ5nieKqsnzPE8URdE0VZXneZ4o'
      'iqJpqirXFUXTNE1VVV2yLIqmaZqq6rowTdNUVdd1XZimaaqq67oubFtVVdV1ZRm2raqq6rqyDFzX'
      'dWXZloEsu67s2rIAAPAEBwCgAhtWRzgpGgssNGQlAJABAEAYg5BCCCFlEEIKIYSUUggJAAAYcAAA'
      'CDChDBQashIASAUAAIyx1lprrbXWQGettdZaa62AzFprrbXWWmuttdZaa6211lJrrbXWWmuttdZa'
      'a6211lprrbXWWmuttdZaa6211lprrbXWWmuttdZaa6211lprrbXWWmstpZRSSimllFJKKaWUUkop'
      'pZRSSgUA+lU4APg/2LA6wknRWGChISsBgHAAAMAYpRhzDEIppVQIMeacdFRai7FCiDHnJKTUWmzF'
      'c85BKCGV1mIsnnMOQikpxVZjUSmEUlJKLbZYi0qho5JSSq3VWIwxqaTWWoutxmKMSSm01FqLMRYj'
      'bE2ptdhqq7EYY2sqLbQYY4zFCF9kbC2m2moNxggjWywt1VprMMYY3VuLpbaaizE++NpSLDHWXAAA'
      'd4MDAESCjTOsJJ0VjgYXGrISAAgJACAQUooxxhhzzjnnpFKMOeaccw5CCKFUijHGnHMOQgghlIwx'
      '5pxzEEIIIYRSSsaccxBCCCGEkFLqnHMQQgghhBBKKZ1zDkIIIYQQQimlgxBCCCGEEEoopaQUQggh'
      'hBBCCKmklEIIIYRSQighlZRSCCGEEEIpJaSUUgohhFJCCKGElFJKKYUQQgillJJSSimlEkoJJYQS'
      'UikppRRKCCGUUkpKKaVUSgmhhBJKKSWllFJKIYQQSikFAAAcOAAABBhBJxlVFmGjCRcegEJDVgIA'
      'ZAAAkKKUUiktRYIipRikGEtGFXNQWoqocgxSzalSziDmJJaIMYSUk1Qy5hRCDELqHHVMKQYtlRhC'
      'xhik2HJLoXMOAAAAQQCAgJAAAAMEBTMAwOAA4XMQdAIERxsAgCBEZohEw0JweFAJEBFTAUBigkIu'
      'AFRYXKRdXECXAS7o4q4DIQQhCEEsDqCABByccMMTb3jCDU7QKSp1IAAAAAAADADwAACQXAAREdHM'
      'YWRobHB0eHyAhIiMkAgAAAAAABgAfAAAJCVAREQ0cxgZGhscHR4fICEiIyQBAIAAAgAAAAAggAAE'
      'BAQAAAAAAAIAAAAEBA==';
}

class PngRgb24Encoder {
  const PngRgb24Encoder();

  Uint8List encode(UnityTexture2D texture) {
    if (!texture.isRgb24) {
      throw FormatException('Unsupported Texture2D format: ${texture.format}');
    }
    final raw = BytesBuilder(copy: false);
    final stride = texture.width * 3;
    for (var y = texture.height - 1; y >= 0; y -= 1) {
      raw.addByte(0);
      raw.add(
          Uint8List.sublistView(texture.data, y * stride, y * stride + stride));
    }

    final png = BytesBuilder(copy: false);
    png.add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    _addChunk(
      png,
      'IHDR',
      _uint32(texture.width) + _uint32(texture.height) + [8, 2, 0, 0, 0],
    );
    _addChunk(png, 'IDAT', ZLibEncoder().convert(raw.takeBytes()));
    _addChunk(png, 'IEND', const []);
    return png.takeBytes();
  }

  void _addChunk(BytesBuilder output, String type, List<int> data) {
    final typeBytes = ascii.encode(type);
    output.add(_uint32(data.length));
    output.add(typeBytes);
    output.add(data);
    output.add(_uint32(_crc32([...typeBytes, ...data])));
  }

  List<int> _uint32(int value) {
    return [
      value >> 24 & 0xff,
      value >> 16 & 0xff,
      value >> 8 & 0xff,
      value & 0xff,
    ];
  }

  int _crc32(List<int> data) {
    var crc = 0xffffffff;
    for (final byte in data) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit += 1) {
        crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
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
