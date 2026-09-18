/// 判断插件 icon URL 是否指向 SVG。
///
/// 两种形态会走到这里：
///   1. 已安装插件的静态路径（形如 `.../static/icon.svg`）—— 直接看扩展名；
///   2. 商店条目走服务端代理，形如 `/api/v1/proxy?url=<encoded url>`，
///      本身不带 `.svg` 后缀，此前 `endsWith('.svg')` 全部误判为位图，
///      交给 `Image.network` 解码 SVG 报错并回退到首字母（
///      songloft-org/songloft 插件商店 icon 只显示文字的根因）。
///      需要解析 `url=` 查询参数、解码后再看真正目标的扩展名。
bool isSvgIconUrl(String? icon) {
  final raw = (icon ?? '').trim();
  if (raw.isEmpty) return false;
  final qmark = raw.indexOf('?');
  final path = qmark < 0 ? raw : raw.substring(0, qmark);
  if (path.toLowerCase().endsWith('.svg')) return true;
  if (qmark < 0) return false;
  final query = raw.substring(qmark + 1);
  for (final part in query.split('&')) {
    if (!part.startsWith('url=')) continue;
    final rawTarget = part.substring(4);
    String target;
    try {
      target = Uri.decodeComponent(rawTarget);
    } on ArgumentError {
      target = rawTarget;
    }
    final targetQmark = target.indexOf('?');
    final targetPath = targetQmark < 0 ? target : target.substring(0, targetQmark);
    return targetPath.toLowerCase().endsWith('.svg');
  }
  return false;
}
