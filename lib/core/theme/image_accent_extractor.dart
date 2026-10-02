/// 详情页封面动态取色。
///
/// 从封面图（或 detail 路由回填后的封面）统计主色，归一化为一个适合作为
/// `ColorScheme.fromSeed` 种子的鲜艳中间调颜色。纯像素统计（[accentFromRgba]）
/// 与解码入口（[extractAccentColor]）分离，前者可直接注入字节做单元测试。
///
/// 取色走 [NexImageCacheManager] 同一磁盘缓存与防盗链 headers
/// （[SourceImage.buildHeaders]），命中缓存时零网络请求。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color, HSLColor;

import '../local/local_content_manager.dart' show isAndroidSafUri;
import '../local/saf_bridge.dart' show resolveSafUri;
import '../models/plugin_config.dart';
import '../network/dio_image_file_service.dart';
import '../settings/detail_appearance_settings.dart';
import '../widgets/source_image.dart';

/// 降采样统计边长：64² 足以稳定统计主色，且编解码开销可忽略。
const int _kSampleSize = 64;

/// 纯像素统计：rawRgba 字节 → 适合做种子的强调色；全灰图返回 null
/// （调用方保持默认强调色）。
///
/// 算法：4bit/通道量化分桶 → 得分 = 出现次数 × 饱和度加成（近黑/近白桶
/// 重罚，规避黑边、留白与纯白底）→ 取最高分桶，把色相保留、饱和度与
/// 亮度夹取到「鲜而不刺」的中间调区间。
Color? accentFromRgba(Uint8List rgba) {
  // 桶：key = r4<<8 | g4<<4 | b4。
  final List<int> counts = List<int>.filled(1 << 12, 0);
  final List<int> sumR = List<int>.filled(1 << 12, 0);
  final List<int> sumG = List<int>.filled(1 << 12, 0);
  final List<int> sumB = List<int>.filled(1 << 12, 0);

  for (int i = 0; i + 3 < rgba.length; i += 4) {
    // 全透明像素不参与统计。
    if (rgba[i + 3] < 255) continue;
    final int key =
        ((rgba[i] >> 4) << 8) | ((rgba[i + 1] >> 4) << 4) | (rgba[i + 2] >> 4);
    counts[key]++;
    sumR[key] += rgba[i];
    sumG[key] += rgba[i + 1];
    sumB[key] += rgba[i + 2];
  }

  _Bucket? best;
  double bestScore = 0;
  for (int key = 0; key < counts.length; key++) {
    final int n = counts[key];
    if (n == 0) continue;
    final HSLColor hsl = HSLColor.fromColor(Color.fromARGB(
      255,
      sumR[key] ~/ n,
      sumG[key] ~/ n,
      sumB[key] ~/ n,
    ));
    double score = n.toDouble();
    // 鲜色加成（灰域降权）、近黑近白重罚（黑边 / 纯白底）。
    score *= 0.25 + 2.0 * math.pow(hsl.saturation, 1.1).toDouble();
    if (hsl.lightness < 0.10 || hsl.lightness > 0.90) score *= 0.15;
    if (score > bestScore) {
      bestScore = score;
      best = _Bucket(hsl: hsl);
    }
  }

  final HSLColor? bestHsl = best?.hsl;
  if (bestHsl == null || bestHsl.saturation < 0.10) return null;
  // 归一化为种子色：fromSeed 会按 tonal palette 重建各角色，
  // 中间调 + 较高饱和的种子在深浅色下都能给出可读的结果。
  return bestHsl
      .withSaturation(bestHsl.saturation.clamp(0.40, 0.85))
      .withLightness(bestHsl.lightness.clamp(0.42, 0.60))
      .toColor();
}

class _Bucket {
  final HSLColor hsl;
  const _Bucket({required this.hsl});
}

/// 解码入口：URL（http / 本地路径 / SAF）→ 小图解码 → [accentFromRgba]。
/// 失败（网络 403、AVIF 不支持、文件不存在等）一律返回 null，不影响页面。
Future<Color?> extractAccentColor({
  required String url,
  PluginConfig? source,
}) async {
  try {
    Uint8List bytes;
    final bool isHttp =
        url.startsWith('http://') || url.startsWith('https://');
    if (isHttp) {
      final File file = await NexImageCacheManager.instance.getSingleFile(
        url,
        // 与 SourceImage 同一套防盗链 headers（Referer/UA/Cookie），请求指纹一致。
        headers: SourceImage.buildHeaders(url: url, source: source),
      );
      bytes = await file.readAsBytes();
    } else if (isAndroidSafUri(url)) {
      final String resolved = await resolveSafUri(url);
      if (resolved.isEmpty) return null;
      bytes = await File(resolved).readAsBytes();
    } else {
      bytes = await File(url).readAsBytes();
    }
    final ui.Codec codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: _kSampleSize,
      allowUpscaling: false,
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ByteData? data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    frame.image.dispose();
    codec.dispose();
    if (data == null) return null;
    return accentFromRgba(data.buffer.asUint8List());
  } on Object {
    return null;
  }
}

/// 详情页取色控制器：跟踪当前封面 URL，异步提取强调色并广播。
///
/// 结果按 URL 记忆（返回同一详情页不重复解码）；设置页中途打开动态取色
/// 时（[DetailAppearanceStore] 广播），对当前封面补一次提取。
class DetailAccentController extends ChangeNotifier {
  DetailAccentController() {
    DetailAppearanceStore.instance.addListener(_onStoreChanged);
  }

  String? _url;
  PluginConfig? _source;
  Color? _accent;
  bool _loading = false;

  /// 当前封面提取到的强调色；未开启 / 未加载完成 / 提取失败时为 null。
  Color? get accent => _accent;

  /// URL → 结果记忆。全灰图记 null 也算结果，避免反复重试。
  static final Map<String, Color?> _memo = <String, Color?>{};

  Future<void> update({String? coverUrl, PluginConfig? source}) async {
    final String? url = (coverUrl == null || coverUrl.isEmpty) ? null : coverUrl;
    if (url == _url) return;
    _url = url;
    _source = source;
    _accent = null;
    notifyListeners();
    if (url == null) return;
    await _extract();
  }

  Future<void> _extract() async {
    final String url = _url!;
    if (_memo.containsKey(url)) {
      _accent = _memo[url];
      notifyListeners();
      return;
    }
    if (_loading) return;
    _loading = true;
    try {
      final Color? color = await extractAccentColor(url: url, source: _source);
      if (_memo.length > 32) _memo.clear();
      _memo[url] = color;
      // 提取期间封面可能已切换（换源 / 详情回填），丢弃过期结果。
      if (_url != url) return;
      _accent = color;
    } finally {
      _loading = false;
    }
    notifyListeners();
  }

  void _onStoreChanged() {
    if (DetailAppearanceStore.instance.settings.dynamicAccentEnabled &&
        _url != null &&
        _accent == null &&
        !_loading) {
      unawaited(_extract());
    }
  }

  @override
  void dispose() {
    DetailAppearanceStore.instance.removeListener(_onStoreChanged);
    super.dispose();
  }
}
