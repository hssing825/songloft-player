import 'package:flutter_test/flutter_test.dart';
import 'package:songloft_flutter/features/jsplugin/presentation/widgets/plugin_icon_utils.dart';

/// 商店条目的 icon URL 由后端拼装成 `/api/v1/proxy?url=<encoded>`。
/// 早前用 `endsWith('.svg')` 判断，路径部分是 `/api/v1/proxy`，没有 `.svg` 后缀，
/// 全部 SVG icon 都被误判为位图，交给 `Image.network` 解码 SVG 报错并
/// 兜底成首字母。这批用例锁住修复。
void main() {
  group('isSvgIconUrl', () {
    test('识别裸文件名 icon.svg', () {
      expect(isSvgIconUrl('icon.svg'), isTrue);
      expect(isSvgIconUrl('LOGO.SVG'), isTrue);
      expect(isSvgIconUrl('icon.png'), isFalse);
    });

    test('忽略路径尾部的 query string', () {
      expect(isSvgIconUrl('icon.svg?v=2'), isTrue);
      expect(isSvgIconUrl('  icon.svg  '), isTrue);
      expect(isSvgIconUrl('svg-preview.png'), isFalse);
    });

    test('空值不算 SVG', () {
      expect(isSvgIconUrl(null), isFalse);
      expect(isSvgIconUrl(''), isFalse);
    });

    test('识别 /api/v1/proxy?url=<encoded svg>', () {
      final encoded = Uri.encodeComponent(
        'https://raw.githubusercontent.com/songloft-org/songloft-plugin-stats/main/static/icon.svg',
      );
      expect(isSvgIconUrl('/api/v1/proxy?url=$encoded'), isTrue);
    });

    test('proxy 里的位图仍旧不算 SVG', () {
      final encoded = Uri.encodeComponent('https://example.com/logo.png');
      expect(isSvgIconUrl('/api/v1/proxy?url=$encoded'), isFalse);
    });

    test('proxy 目标自己带 query 时仍能识别 svg 扩展', () {
      final encoded = Uri.encodeComponent('https://example.com/icon.svg?v=2');
      expect(isSvgIconUrl('/api/v1/proxy?url=$encoded'), isTrue);
    });
  });
}
