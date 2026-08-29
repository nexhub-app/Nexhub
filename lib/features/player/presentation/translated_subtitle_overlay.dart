/// 视频实时翻译字幕覆盖层（视频实时翻译功能）。
///
/// 渲染 [SubtitleTranslationController] 的当前译文：
/// - 译文大字居底部显示（位置随播放器控制栏显隐抬高避让）；
/// - 开启「显示原文」时原文以小字灰底显示在译文上方（外源视频 OCR /
///   学习语言场景）；
/// - 翻译中显示 subtle 进度点；整层 IgnorePointer，不与播放手势竞争。
library;

import 'package:flutter/material.dart';

import '../../../core/player/subtitle_translation_controller.dart';

class TranslatedSubtitleOverlay extends StatelessWidget {
  final SubtitleTranslationController controller;

  const TranslatedSubtitleOverlay({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, _) {
        if (!controller.enabled) return const SizedBox.shrink();
        final state = controller.state;
        final String? translated = state.translatedText;
        final String? source = state.sourceText;
        final bool showOriginal = controller.showOriginal &&
            source != null &&
            source.trim().isNotEmpty;
        if ((translated == null || translated.trim().isEmpty) && !showOriginal) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (showOriginal)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    source,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 13,
                      height: 1.3,
                    ),
                  ),
                ),
              if (translated != null && translated.trim().isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Stack(
                    alignment: Alignment.topRight,
                    children: <Widget>[
                      Text(
                        translated,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                          shadows: <Shadow>[
                            Shadow(
                                blurRadius: 4,
                                color: Colors.black54,
                                offset: Offset(0, 1)),
                          ],
                        ),
                      ),
                      if (state.translating)
                        const Padding(
                          padding: EdgeInsets.only(left: 8, top: 2),
                          child: SizedBox(
                            width: 8,
                            height: 8,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.4),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
