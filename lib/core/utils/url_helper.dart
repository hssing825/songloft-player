import 'package:flutter/foundation.dart';

import '../../config/app_config.dart';
import '../storage/secure_storage.dart';
import 'audio_format_helper.dart';

/// URL 构建工具类
///
/// 统一处理歌曲、封面、歌词等资源的 URL 拼接逻辑：
/// - 相对路径（/api/v1/...）：自动拼接 baseUrl + access_token
/// - 外部完整 URL（http/https）：直接返回
///
/// 所有客户端资源访问都应使用此类，确保认证 token 正确传递。
class UrlHelper {
  /// 构建完整的资源 URL
  ///
  /// [url] 资源 URL，可能是相对路径或完整 URL
  /// 返回：带有 baseUrl 和 access_token 的完整 URL
  static String buildResourceUrl(String url) {
    if (url.isEmpty) return '';

    // 外部 URL 直接返回
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }

    // 相对路径：拼接 resolvedBaseUrl + basePath + access_token
    // 用 resolvedBaseUrl（入口域名 302 解析后的真实地址）而非 baseUrl（身份 URL）：
    // 播放/封面流由播放器内核/Image 直接请求，走不了 Dio 的重定向重解析拦截器，且带
    // access_token 查询参数，跨 host 的 302 不保证保留 query，故必须直连真实地址
    // （songloft-org/songloft-player#22）。取舍：若播放中途 STUN 端口突变会断当前流，
    // 此时 API 拦截器已在后台刷新 resolvedBaseUrl，切歌/重播即用新端口恢复。
    final token = SecureStorageService.cachedAccessToken ?? '';
    final separator = url.contains('?') ? '&' : '?';
    final fullUrl =
        '${AppConfig.resolvedBaseUrl}${AppConfig.basePath}$url${separator}access_token=$token';

    // 该日志在每次构建资源 URL（封面/播放/歌词）时触发，且含 access_token；
    // 仅 debug 构建输出，避免 release 端日志刷屏与凭证明文落盘。
    if (kDebugMode) {
      debugPrint('[UrlHelper] Built resource URL: $fullUrl');
    }
    return fullUrl;
  }

  /// 构建歌曲播放 URL
  ///
  /// [songFormat] 歌曲原始格式（如 "wma"），用于判断当前平台是否需要转码。
  /// 当平台不支持该格式时自动追加 format 参数请求服务端转码。
  /// [quality] 音质偏好（'128'/'192'/'320'），非空且非 'original' 时追加 quality 参数。
  /// [hlsDirect] 为 true 时追加 `hls=direct`：让后端对 HLS 电台强制 302 直连源站、
  /// 绕过本机 HLS 反代（即使反代开关已开）。原生 player 自带 HLS 解析且无 CORS 限制，
  /// 直连可避免直播切片经反代往返后过期导致 404（songloft-org/songloft#249）；
  /// 后端对非 HLS 电台忽略此参数，故传入无害。浏览器不应传（需反代解决 CORS）。
  /// [audioTrack] 非空且 >= 0 时追加 `track=N`（audio-relative index），让后端抽取该音轨
  /// 播放（Web 双音轨切换，songloft-org/songloft#298）；此时**不再附加 format**——容器由后端
  /// 据音轨编码决定（AAC → m4a 无损 remux，否则 → mp3），避免与抽轨容器判定冲突。
  static String buildSongUrl(
    String url, {
    String? songFormat,
    String? quality,
    bool hlsDirect = false,
    int? audioTrack,
    bool normalize = false,
  }) {
    var result = buildResourceUrl(url);
    if (result.isEmpty) return '';
    if (audioTrack != null && audioTrack >= 0) {
      result += '${result.contains('?') ? '&' : '?'}track=$audioTrack';
    } else {
      final transcode = AudioFormatHelper.getTranscodeFormat(songFormat);
      if (transcode != null) {
        result += '${result.contains('?') ? '&' : '?'}format=$transcode';
      }
    }
    if (quality != null && quality.isNotEmpty && quality != 'original') {
      result += '${result.contains('?') ? '&' : '?'}quality=$quality';
    }
    if (hlsDirect) {
      result += '${result.contains('?') ? '&' : '?'}hls=direct';
    }
    if (normalize) {
      result += '${result.contains('?') ? '&' : '?'}normalize=1';
    }
    return result;
  }

  /// 构建视频播放 URL（用于应用内视频画面渲染与 DLNA 视频投屏）
  ///
  /// 追加 `media=video`：后端据此直出原容器（不转码，避免 ffmpeg -vn 丢画面），
  /// 并按容器真实类型返回 Content-Type（如 video/mp4）。
  /// 不追加 format/quality —— 视频需要保留完整音视频轨。
  static String buildVideoUrl(String url, {bool hlsDirect = false}) {
    final result = buildResourceUrl(url);
    if (result.isEmpty) return '';
    var u = appendMediaVideoParam(result);
    if (hlsDirect) {
      u += '${u.contains('?') ? '&' : '?'}hls=direct';
    }
    return u;
  }

  /// 给已构建的 URL 追加 `media=video` 查询参数。
  ///
  /// 原生端 SongloftMediaKitPlayer 靠 URL 含 `media=video` 判定视频源并创建视频纹理，
  /// 该参数是视频判定的唯一机制；video-hls 端点忽略多余 query，追加无副作用。
  static String appendMediaVideoParam(String url) {
    if (url.isEmpty) return url;
    return '$url${url.contains('?') ? '&' : '?'}media=video';
  }

  /// 构建视频 HLS 转码播放 URL。
  ///
  /// 视频格式不被播放端良好支持时（Web：非 mp4/webm/mov；原生：mpg/rmvb/wmv 等
  /// 老旧容器），使用后端实时转码为 HLS 的端点。URL 以 .m3u8 结尾，Web 端 hls.js
  /// 自动识别；原生端传 [mediaVideoFlag]=true 追加 `media=video`，供
  /// SongloftMediaKitPlayer 判定视频源以创建视频纹理（后端忽略该参数）。
  /// [songId] 歌曲 ID，用于构建 `/api/v1/songs/{id}/video-hls/playlist.m3u8` 路径。
  static String buildVideoHlsUrl(int songId, {bool mediaVideoFlag = false}) {
    final url = '/api/v1/songs/$songId/video-hls/playlist.m3u8';
    final result = buildResourceUrl(url);
    if (result.isEmpty) return '';
    return mediaVideoFlag ? appendMediaVideoParam(result) : result;
  }

  /// 构建封面图片 URL（兼容旧接口，内部调用 buildResourceUrl）
  ///
  /// [width] 非空时，给「本机后端封面端点」追加 `?w=<物理像素>` 服务端缩略参数。
  /// 全平台生效：服务端将封面等比缩放后以 JPEG 返回，大幅降低网络传输与客户端解码开销，
  /// 避免弱网/NAS 拥堵场景下全尺寸封面并发下载触发 ANR（songloft-org/songloft-player#39）。
  /// 外部封面 URL（CDN）不追加。
  static String buildCoverUrl(String coverUrl, {int? width}) {
    final url = buildResourceUrl(coverUrl);
    if (width != null) return appendCoverWidth(url, width);
    return url;
  }

  /// 给**已构建**的本机后端封面 URL 追加 `?w=` 缩略参数（全平台生效）。
  ///
  /// 服务端据 `?w=` 将封面等比缩放后以 JPEG 返回，大幅降低网络传输体积与客户端解码开销。
  /// 原生平台也走此路径：弱网/NAS 拥堵场景下，全尺寸封面（3~4MB）并发下载 + 主线程解码
  /// 会触发 ANR（songloft-org/songloft-player#39）。
  ///
  /// 供直接持有成品 URL 的场景复用（如 [NetworkCoverImage] 的调用方已 `buildCoverUrl`
  /// 过）。外部封面（http/https CDN）原样返回，避免破坏其缓存键/签名。已带 `w=` 的不重复追加。
  static String appendCoverWidth(String url, int width) {
    if (url.isEmpty || width <= 0) return url;
    if (!_isLocalBackendUrl(url)) return url;
    if (RegExp(r'[?&]w=').hasMatch(url)) return url;
    final separator = url.contains('?') ? '&' : '?';
    return '$url${separator}w=$width';
  }

  /// 判断 URL 是否指向本机后端（相对路径，或以已解析的 resolvedBaseUrl 打头的绝对 URL）。
  static bool _isLocalBackendUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      final base = AppConfig.resolvedBaseUrl;
      return base.isNotEmpty && url.startsWith(base);
    }
    // 相对路径（同源嵌入部署）视为本机后端。
    return url.startsWith('/');
  }

  /// 构建歌词 URL（兼容旧接口，内部调用 buildResourceUrl）
  static String buildLyricUrl(String lyricUrl) {
    return buildResourceUrl(lyricUrl);
  }
}
