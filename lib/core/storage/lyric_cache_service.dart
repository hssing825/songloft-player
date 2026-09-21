import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 缓存文件的信封结构（新格式）。
///
/// 旧格式为裸文本 payload，读取时被判定为旧格式并按 miss 处理。
class _LyricEnvelope {
  final String? songUpdatedAt;
  final String payload;
  const _LyricEnvelope({required this.payload, this.songUpdatedAt});
}

/// 歌词本地缓存服务
///
/// 将网络加载的歌词文本缓存到本地文件系统，避免重复请求。
/// 缓存目录：{appDocDir}/lyric_cache/
/// 文件名：URL 的 SHA1 hash + .lrc
///
/// Web 平台不支持文件缓存，降级为纯内存缓存。
class LyricCacheService {
  static final LyricCacheService _instance = LyricCacheService._();
  factory LyricCacheService() => _instance;
  LyricCacheService._();

  /// 内存缓存（所有平台通用，作为一级缓存）
  final Map<String, String> _memoryCache = {};

  /// 缓存目录（延迟初始化，仅非 Web 平台使用）
  Directory? _cacheDir;

  /// 是否已初始化缓存目录
  bool _initialized = false;

  /// 初始化缓存目录
  Future<void> _ensureInitialized() async {
    if (_initialized || kIsWeb) return;
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      _cacheDir = Directory('${appDocDir.path}/lyric_cache');
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }
      _initialized = true;
    } catch (e) {
      debugPrint('[LyricCacheService] 初始化缓存目录失败: $e');
    }
  }

  /// 根据 URL 生成缓存文件名（使用简单 hash，避免额外依赖）
  String _hashUrl(String url) {
    // 使用 Dart 内置的 hashCode 组合生成足够唯一的文件名
    final bytes = utf8.encode(url);
    int hash1 = 0x811c9dc5; // FNV offset basis
    for (final byte in bytes) {
      hash1 ^= byte;
      hash1 = (hash1 * 0x01000193) & 0xFFFFFFFF; // FNV prime
    }
    int hash2 = 0;
    for (final byte in bytes) {
      hash2 = (hash2 * 31 + byte) & 0xFFFFFFFF;
    }
    return '${hash1.toRadixString(16).padLeft(8, '0')}${hash2.toRadixString(16).padLeft(8, '0')}';
  }

  /// 获取缓存文件路径
  File? _getCacheFile(String url) {
    if (_cacheDir == null) return null;
    final hash = _hashUrl(url);
    return File('${_cacheDir!.path}/$hash.lrc');
  }

  /// 获取缓存的歌词（先查内存，再查文件）。
  ///
  /// 传入 [songUpdatedAt]（推荐使用 song.updatedAt.toIso8601String()）后，
  /// 若缓存中的 songUpdatedAt 与之不一致 → 视为 miss 并清掉旧文件，
  /// 让下一次调用 [put] 写入带新时间戳的最新歌词。
  /// 不传 [songUpdatedAt]（例如清缓存前的探测）时退化为按 URL 直查旧行为。
  Future<String?> get(String url, {String? songUpdatedAt}) async {
    String? raw;

    // 1. 查内存缓存
    final memCached = _memoryCache[url];
    if (memCached != null) {
      raw = memCached;
    } else if (!kIsWeb) {
      // 2. 查文件缓存
      await _ensureInitialized();
      final file = _getCacheFile(url);
      if (file != null) {
        try {
          if (await file.exists()) {
            raw = await file.readAsString();
            _memoryCache[url] = raw;
          }
        } catch (e) {
          debugPrint('[LyricCacheService] 读取缓存文件失败: $e');
        }
      }
    }

    if (raw == null) return null;

    final decoded = _decodeEnvelope(raw);
    if (songUpdatedAt != null) {
      if (decoded == null || decoded.songUpdatedAt != songUpdatedAt) {
        // 缺 songUpdatedAt（旧格式）或时间戳变化 → 视为失效，顺手清掉
        await remove(url);
        return null;
      }
      return decoded.payload;
    }
    // 未指定 songUpdatedAt 时兼容返回：新格式取 payload，旧格式原样返回
    return decoded?.payload ?? raw;
  }

  /// 缓存歌词（同时写入内存和文件）。
  ///
  /// 传入 [songUpdatedAt] 后，写入时以 JSON 信封包裹 `{songUpdatedAt, payload}`，
  /// 供后续 [get] 判断是否失效。
  Future<void> put(String url, String lyricText, {String? songUpdatedAt}) async {
    final stored =
        songUpdatedAt == null
            ? lyricText
            : jsonEncode({
              'songUpdatedAt': songUpdatedAt,
              'payload': lyricText,
            });

    // 写入内存缓存
    _memoryCache[url] = stored;

    // Web 平台不写文件
    if (kIsWeb) return;

    // 写入文件缓存
    await _ensureInitialized();
    final file = _getCacheFile(url);
    if (file == null) return;

    try {
      await file.writeAsString(stored);
    } catch (e) {
      debugPrint('[LyricCacheService] 写入缓存文件失败: $e');
    }
  }

  /// 按 URL 清除单条缓存（内存 + 文件）。
  /// 用户手动调整歌词后调用，避免下次进入歌词页拿到旧的缓存内容。
  Future<void> remove(String url) async {
    _memoryCache.remove(url);
    if (kIsWeb) return;
    await _ensureInitialized();
    final file = _getCacheFile(url);
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('[LyricCacheService] 删除缓存文件失败: $e');
    }
  }

  /// 清理全部歌词缓存
  Future<void> clear() async {
    _memoryCache.clear();

    if (kIsWeb) return;

    await _ensureInitialized();
    if (_cacheDir == null) return;

    try {
      if (await _cacheDir!.exists()) {
        await _cacheDir!.delete(recursive: true);
        await _cacheDir!.create(recursive: true);
      }
    } catch (e) {
      debugPrint('[LyricCacheService] 清理缓存失败: $e');
    }
  }

  /// 解析新格式信封；非 JSON 或字段不符时返回 null（视为旧格式）。
  _LyricEnvelope? _decodeEnvelope(String raw) {
    final trimmed = raw.trimLeft();
    if (!trimmed.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final payload = decoded['payload'];
      if (payload is! String) return null;
      final ts = decoded['songUpdatedAt'];
      return _LyricEnvelope(
        payload: payload,
        songUpdatedAt: ts is String ? ts : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// 获取歌词缓存大小（字节）
  Future<int> getCacheSize() async {
    if (kIsWeb) return 0;

    await _ensureInitialized();
    if (_cacheDir == null) return 0;

    int totalSize = 0;
    try {
      if (await _cacheDir!.exists()) {
        await for (final entity in _cacheDir!.list()) {
          if (entity is File) {
            totalSize += await entity.length();
          }
        }
      }
    } catch (e) {
      debugPrint('[LyricCacheService] 获取缓存大小失败: $e');
    }
    return totalSize;
  }
}
