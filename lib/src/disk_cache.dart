import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter_advanced_networkimage/src/utils.dart' show crc32;

/// Stand for [getTemporaryDirectory] and
/// [getApplicationDocumentsDirectory] in path_provider plugin.
enum StoreDirectoryType {
  temporary,
  document,
}

/// Singleton for managing cache files.
class DiskCache {
  static final DiskCache _instance = DiskCache._internal();
  factory DiskCache() => _instance;
  DiskCache._internal();

  /// Maximum number of entries to store in the cache.
  ///
  /// Once this many entries have been cached, the least-recently-used entry is
  /// evicted when adding a new entry.
  int get maxEntries => _maxEntries;
  int _maxEntries = 5000; // default: 5000
  /// Changes the maximum cache size.
  set maxEntries(int value) {
    assert(value != null);
    assert(value >= 0);
    if (value == maxEntries) return;
    _maxEntries = value;
  }

  /// Maximum size of entries to store in the cache in bytes.
  ///
  /// Once more than this amount of bytes have been cached, the
  /// least-recently-used entry is evicted until there are fewer than the
  /// maximum bytes.
  int get maxSizeBytes => _maxSizeBytes;
  int _maxSizeBytes = 1000 << 20; // default: 1 GiB
  /// Changes the maximum cache bytes.
  set maxSizeBytes(int value) {
    assert(value != null);
    assert(value >= 0);
    if (value == maxSizeBytes) return;
    _maxSizeBytes = value;
    if (maxSizeBytes == 0) {
      clear();
    } else {
      _checkCacheSize();
    }
  }

  /// Maximum read operations to save the metadata.
  ///
  /// Once this many operations have been reached,
  /// the metadata will be saved.
  int maxCommitOps = 10;
  int _currentOps = 0;

  int get _currentEntries => _metadata != null ? _metadata.keys.length : 0;
  int get _currentSizeBytes {
    int size = 0;
    _metadata.values.forEach((item) => size += item['size']);
    return size;
  }

  Map<String, dynamic> _metadata;

  static const String _metadataFilename = 'imagecache_metadata.json';

  Future<void> _initMetaData() async {
    Directory dir = await getApplicationDocumentsDirectory();
    File path = File(join(dir.path, _metadataFilename));
    try {
      if (path.existsSync())
        _metadata = json.decode(await path.readAsString());
      else
        _metadata = {};
    } catch (e) {
      debugPrint(e.toString());
      _metadata = {};
    }
  }

  Future<void> _commitMetaData([bool force = false]) async {
    if (!force) {
      if (_currentEntries < maxEntries && _currentSizeBytes < maxEntries)
        return;
      _currentOps += 1;
      if (_currentOps < maxCommitOps) return;
    }
    File path = File(join(
        (await getApplicationDocumentsDirectory()).path, _metadataFilename));
    await path.writeAsString(json.encode(_metadata));
    _currentOps = 0;
  }

  /// Clean up the bad cache files in metadata.
  Future<void> keepCacheHealth() async {
    _metadata.removeWhere((k, v) {
      if (!File(v['path']).existsSync()) return true;
      if (DateTime.fromMillisecondsSinceEpoch(v['createdTime'] + v['maxAge'])
              .compareTo(DateTime.now()) <
          0) {
        File(v['path']).deleteSync();
        return true;
      }
      Uint8List data = File(v['path']).readAsBytesSync();
      if (v['crc32'] != null && v['crc32'] != crc32(data)) {
        File(v['path']).deleteSync();
        return true;
      }
    });
    await _checkCacheSize();
    await _commitMetaData();
  }

  /// Load the cache image from [DiskCache].
  Future<Uint8List> load(String uid) async {
    if (_metadata == null) await _initMetaData();
    try {
      if (_metadata.containsKey(uid)) {
        if (!File(_metadata[uid]['path']).existsSync()) {
          _metadata.remove(uid);
          await _commitMetaData();
          return null;
        }
        if (DateTime.fromMillisecondsSinceEpoch(
              _metadata[uid]['createdTime'] + _metadata[uid]['maxAge'],
            ).compareTo(DateTime.now()) <
            0) {
          await File(_metadata[uid]['path']).delete();
          _metadata.remove(uid);
          await _commitMetaData();
          return null;
        }
        Uint8List data = await File(_metadata[uid]['path']).readAsBytes();
        if (_metadata[uid]['crc32'] != null &&
            _metadata[uid]['crc32'] != crc32(data)) {
          await File(_metadata[uid]['path']).delete();
          _metadata.remove(uid);
          await _commitMetaData();
          return null;
        }
        if (_currentEntries >= maxEntries ||
            _currentSizeBytes >= maxSizeBytes) {
          _metadata[uid] = _metadata.remove(uid);
          await _commitMetaData();
        }
        return data;
      } else {
        return null;
      }
    } catch (e) {
      debugPrint(e.toString());
      return null;
    }
  }

  /// Load the cache image save [DiskCache].
  Future<bool> save(String uid, Uint8List data, CacheRule rule) async {
    if (_metadata == null) await _initMetaData();
    Directory dir = Directory(join(
        (rule.storeDirectory == StoreDirectoryType.temporary
                ? await getTemporaryDirectory()
                : await getApplicationDocumentsDirectory())
            .path,
        'imagecache'));

    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await File(join(dir.path, uid)).writeAsBytes(data);

      Map<String, dynamic> metadata = {
        'path': join(dir.path, uid),
        'createdTime': DateTime.now().millisecondsSinceEpoch,
        'crc32': rule.checksum ? crc32(data) : null,
        'size': data.lengthInBytes,
        'maxAge': rule.maxAge.inMilliseconds,
      };
      _metadata[uid] = metadata;
      await _checkCacheSize();
      await _commitMetaData(true);

      return true;
    } catch (e) {
      debugPrint(e.toString());
      return false;
    }
  }

  Future<void> _checkCacheSize() async {
    while (_currentEntries > maxEntries || _currentSizeBytes > maxSizeBytes) {
      String key = _metadata.keys.first;
      if (File(_metadata[key]['path']).existsSync())
        await File(_metadata[key]['path']).delete();
      _metadata.remove(key);
    }
  }

  /// Evicts a single entry from [DiskCache], returning true if successful.
  Future<bool> evict(String uid) async {
    if (_metadata == null) await _initMetaData();
    try {
      if (_metadata.containsKey(uid) &&
          File(_metadata[uid]['path']).existsSync()) {
        await File(_metadata[uid]['path']).delete();
        _metadata.remove(uid);
        await _commitMetaData();
      }
      return true;
    } catch (e) {
      debugPrint(e.toString());
      return false;
    }
  }

  /// Evicts all entries from [DiskCache].
  Future<bool> clear() async {
    try {
      Directory tempDir =
          Directory(join((await getTemporaryDirectory()).path, 'imagecache'));
      Directory appDir = Directory(
          join((await getApplicationDocumentsDirectory()).path, 'imagecache'));
      File metadataFile = File(join(
          (await getApplicationDocumentsDirectory()).path, _metadataFilename));
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      if (appDir.existsSync()) await appDir.delete(recursive: true);
      if (metadataFile.existsSync()) await metadataFile.delete();
      return true;
    } catch (e) {
      debugPrint(e.toString());
      return false;
    }
  }

  /// Get cache folder size.
  Future<int> cacheSize() async {
    int size = 0;
    try {
      Directory tempDir =
          Directory(join((await getTemporaryDirectory()).path, 'imagecache'));
      Directory appDir = Directory(
          join((await getApplicationDocumentsDirectory()).path, 'imagecache'));
      if (tempDir.existsSync())
        tempDir.listSync().forEach((var file) => size += file.statSync().size);
      if (appDir.existsSync())
        appDir.listSync().forEach((var file) => size += file.statSync().size);
      return size;
    } catch (e) {
      debugPrint(e.toString());
      return null;
    }
  }
}

/// The rules used in [DiskCache].
class CacheRule {
  const CacheRule({
    this.maxAge = const Duration(days: 30),
    this.storeDirectory: StoreDirectoryType.temporary,
    this.checksum: false,
  })  : assert(maxAge != null),
        assert(storeDirectory != null),
        assert(checksum != null);

  /// Set a maximum age for the cache file.
  /// Default is 30 days.
  final Duration maxAge;

  /// Determining the type of folder for the cache file.
  /// Default is temp folder.
  final StoreDirectoryType storeDirectory;

  /// Checkum(CRC32) for cache file.
  /// Default is disabled;
  final bool checksum;
}
