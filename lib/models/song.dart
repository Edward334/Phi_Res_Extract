import 'dart:convert';

const chartLevels = ['EZ', 'HD', 'IN', 'AT'];

class SongCatalog {
  SongCatalog({
    required this.schemaVersion,
    required this.generatedAt,
    required this.source,
    required this.apkVersionName,
    required this.apkVersionCode,
    required this.songs,
  });

  final int schemaVersion;
  final DateTime? generatedAt;
  final String source;
  final String? apkVersionName;
  final int? apkVersionCode;
  final List<Song> songs;

  factory SongCatalog.fromJson(Map<String, dynamic> json) {
    return SongCatalog(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      generatedAt: DateTime.tryParse(json['generatedAt'] as String? ?? ''),
      source: json['source'] as String? ?? 'unknown',
      apkVersionName: json['apkVersionName'] as String?,
      apkVersionCode: (json['apkVersionCode'] as num?)?.toInt(),
      songs: (json['songs'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Song.fromJson)
          .toList(),
    );
  }

  factory SongCatalog.fromString(String source) {
    return SongCatalog.fromJson(jsonDecode(source) as Map<String, dynamic>);
  }
}

class Song {
  Song({
    required this.id,
    required this.title,
    required this.composer,
    required this.illustrator,
    required this.charters,
    required this.difficulties,
    required this.illustrationPath,
    required this.musicPath,
    required this.chartPaths,
  });

  final String id;
  final String title;
  final String composer;
  final String illustrator;
  final List<String> charters;
  final List<double> difficulties;
  final String? illustrationPath;
  final String? musicPath;
  final Map<String, String> chartPaths;

  List<ChartLevel> get levels {
    final codes = <String>[
      for (var index = 0; index < difficulties.length; index += 1)
        if (difficulties[index] > 0 ||
            chartPaths.containsKey(
              index < chartLevels.length ? chartLevels[index] : 'L$index',
            ))
          index < chartLevels.length ? chartLevels[index] : 'L$index',
      for (var index = 0; index < chartLevels.length; index += 1)
        if (chartPaths.containsKey(chartLevels[index]) &&
            difficulties.length <= index)
          chartLevels[index],
    ];

    return [
      for (final code in codes)
        ChartLevel(
          code: code,
          difficulty: _difficultyFor(code),
          charter: _charterFor(code),
          chartPath: chartPaths[code],
        ),
    ];
  }

  double? _difficultyFor(String code) {
    final index = chartLevels.indexOf(code);
    if (index < 0 || index >= difficulties.length) {
      return null;
    }
    return difficulties[index] > 0 ? difficulties[index] : null;
  }

  String _charterFor(String code) {
    final index = chartLevels.indexOf(code);
    if (index < 0 || index >= charters.length) {
      return '';
    }
    return charters[index];
  }

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      composer: json['composer'] as String? ?? '',
      illustrator: json['illustrator'] as String? ?? '',
      charters: (json['charters'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(),
      difficulties: (json['difficulties'] as List<dynamic>? ?? const [])
          .map((item) => double.tryParse(item.toString()) ?? 0)
          .toList(),
      illustrationPath: json['illustrationPath'] as String?,
      musicPath: json['musicPath'] as String?,
      chartPaths: (json['chartPaths'] as Map<String, dynamic>? ?? const {}).map(
        (key, value) => MapEntry(key, value.toString()),
      ),
    );
  }
}

class ChartLevel {
  const ChartLevel({
    required this.code,
    required this.difficulty,
    required this.charter,
    required this.chartPath,
  });

  final String code;
  final double? difficulty;
  final String charter;
  final String? chartPath;
}
