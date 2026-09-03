import 'package:flutter/material.dart';
import '../models/plugin_config.dart';
import '../settings/layout_settings.dart';
import '../theme/app_tokens.dart';
import 'app_animations.dart';
import 'app_cover_image.dart';
import 'highlight_text.dart';

/// 内容卡片（封面 + 标题 + 元信息 + 进度条/徽标）。
/// 动漫 / 漫画 / 小说 / 影视 四模块共用的统一卡片。
class ContentCard extends StatelessWidget {
  final String? coverUrl;
  final String title;

  /// 源配置：非空时 AppCoverImage 注入防盗链 headers，修复远程封面灰屏。
  final PluginConfig? source;
  final String? subtitle;
  final String? meta;
  final double? progress; // 0..1，非空时显示进度
  final VoidCallback? onTap;
  final String? heroTag;
  final double width;

  /// 搜索关键词高亮：非空时标题中命中的片段以主题色加粗强调
  /// （搜索结果列表用；普通卡片不传保持原样）。
  final String? highlightQuery;

  /// 入场动画的去重 key：非空时同一 key 全局只入场一次（避免列表滚动回来重复播放）。
  /// 缺省回退到 [heroTag]；两者皆空则该卡片每次挂载都播放。
  final String? entranceKey;
  const ContentCard({
    super.key,
    this.coverUrl,
    required this.title,
    this.subtitle,
    this.meta,
    this.progress,
    this.onTap,
    this.heroTag,
    this.source,
    this.width = 120,
    this.entranceKey,
    this.highlightQuery,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final LayoutSettings layout = LayoutSettingsStore.instance.settings;
    final bool _showProg =
        layout.showProgress && progress != null && progress! > 0;
    final bool _asBar = layout.progressDisplay == ProgressDisplayMode.bar;
    final Widget body = SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 封面用 Expanded 占满父约束（网格单元 200px）剩余高度，
            // 避免「固定封面高(≈171) + 标题/作者/年份几行文字」超出单元高度导致 RenderFlex 溢出。
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  AppCoverImage(
                    coverUrl: coverUrl,
                    source: source,
                    title: title,
                    width: width,
                    height: null,
                    heroTag: heroTag,
                    radius: layout.coverRadius,
                  ),
                  // 封面左下角：进度百分比徽标（仅"文字"显示方式时）
                  if (_showProg && !_asBar)
                    Positioned(
                    left: AppTokens.spaceSm,
                    bottom: AppTokens.spaceSm,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppTokens.spaceSm, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.88),
                        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                      ),
                      child: Text(
                        '${(progress! * 100).toInt()}%',
                        style:
                            TextStyle(color: scheme.onPrimary, fontSize: 11),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.spaceXs),
            if (layout.showTitle)
              HighlightText(
                text: title,
                query: highlightQuery,
                maxLines: layout.titleMaxLines,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontSize: layout.titleFontSize,
                    ),
              ),
            if (subtitle != null && layout.showAuthor) ...<Widget>[
              const SizedBox(height: AppTokens.spaceXxs),
              Text(subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            if (meta != null) ...<Widget>[
              const SizedBox(height: AppTokens.spaceXxs),
              Text(meta!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            // 底部线性进度条（仅"进度条"显示方式时）
            if (_showProg && _asBar) ...<Widget>[
              const SizedBox(height: AppTokens.spaceXs),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: scheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    // 移动端按压回弹：手指按下时卡片轻轻缩一下、松手弹性复位。
    // 纯交互驱动（按下才有、松手即停），零空闲开销；与底栏图标按钮同手感。
    // onTap 为空（如占位卡）时不缩放，避免静态卡无故晃动。
    final Widget tappable = AppTapScale(
      scale: 0.92,
      enable: onTap != null,
      haptic: true,
      child: body,
    );

    // 桌面端悬停微抬：鼠标悬停时轻轻放大上浮（触摸屏无 hover，天然不触发）。
    final Widget hoverable = AppHoverLift(child: tappable);

    // 「划入显现」入场：从下方划入 + 淡入（去缩放，纯 slide 感）。
    // 按 key 派生 0~300ms 错峰，首屏呈现自然的瀑布式划入。
    final String? key = entranceKey ?? heroTag;
    final Duration delay = key != null
        ? Duration(milliseconds: key.hashCode.abs() % 300)
        : Duration.zero;
    return Entrance(
      onceKey: key,
      delay: delay,
      fromScale: 1.0,
      offset: 30,
      duration: AppTokens.durSlow,
      child: hoverable,
    );
  }
}
