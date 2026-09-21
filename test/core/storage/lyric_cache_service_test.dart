import 'package:flutter_test/flutter_test.dart';
import 'package:songloft_flutter/core/storage/lyric_cache_service.dart';

/// 覆盖 songloft-org/songloft#477 的客户端修复：
/// LyricCacheService 现在按 song.updatedAt 判断缓存新鲜度。
/// 单例内部维护内存缓存，此文件里的每个 case 使用互不相同的 URL 以避免跨用例污染。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('songUpdatedAt 一致时按新格式回读原文本', () async {
    final svc = LyricCacheService();
    const url = '/api/v1/songs/1001/lyric';
    await svc.put(url, 'A', songUpdatedAt: '2026-09-21T12:00:00.000Z');

    final hit = await svc.get(url, songUpdatedAt: '2026-09-21T12:00:00.000Z');
    expect(hit, 'A');
  });

  test('songUpdatedAt 变化时视为 miss 并清理缓存', () async {
    final svc = LyricCacheService();
    const url = '/api/v1/songs/1002/lyric';
    await svc.put(url, 'A', songUpdatedAt: '2026-09-21T12:00:00.000Z');

    final stale = await svc.get(url, songUpdatedAt: '2026-09-21T13:00:00.000Z');
    expect(stale, isNull);

    // 清理后再次 get 也应 miss（不是把旧值又回读出来）
    final again = await svc.get(url, songUpdatedAt: '2026-09-21T12:00:00.000Z');
    expect(again, isNull);
  });

  test('旧格式（裸文本）带 songUpdatedAt 查询时视为过期', () async {
    final svc = LyricCacheService();
    const url = '/api/v1/songs/1003/lyric';
    // 未带 songUpdatedAt 写入即为旧格式（裸文本）
    await svc.put(url, 'legacy-payload');

    final miss = await svc.get(url, songUpdatedAt: '2026-09-21T12:00:00.000Z');
    expect(miss, isNull);
  });

  test('未指定 songUpdatedAt 时保持旧行为（兼容旧调用点）', () async {
    final svc = LyricCacheService();
    const url = '/api/v1/songs/1004/lyric';
    await svc.put(url, 'legacy-payload');

    final hit = await svc.get(url);
    expect(hit, 'legacy-payload');
  });
}
