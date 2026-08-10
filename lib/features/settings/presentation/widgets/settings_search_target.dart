/// 设置搜索的「滚动到具体设置」机制。
///
/// 设计目的：让设置搜索结果不只能跳转到设置页，还能直接滚动到页内具体某项
/// （如搜索「主题色」直接滚到「自定义取色器」那一行，而不是只打开外观页）。
///
/// 用法：
/// 1. 各设置页把每个有意义的可设置项包一个 `ValueKey<String>(id)`，
///    id 在全应用内唯一（推荐命名空间：`appearance.colors`、`playback.danmaku`）。
/// 2. 把页面 body 用 [SettingsAutoScroll] 包裹（替换原 ListView 外层）。
/// 3. 搜索注册表中的 [SettingEntry.scrollKeyId] 设成目标 id；搜索结果
///    跳转前调用 [requestSettingsScroll]，目标页 initState 后自动滚到该 Key。
///
/// 实现要点：
/// - 用全局变量 [pendingSettingsScrollKeyId] 暂存 id（避免给每个屏加构造参数）。
/// - [SettingsAutoScroll] 在首帧后查找子树里匹配的 [ValueKey]，调
///   `Scrollable.ensureVisible` 让目标滚入视口。
/// - 页面 body 必须是**可一次性构建**的（Column + SingleChildScrollView），
///   否则懒构建的 ListView 里目标项可能尚未挂载，找不到 Key。
library;

import 'package:flutter/material.dart';

/// 等待被消费的「待滚动 Key id」。搜索设置页跳转前 set；新页面 initState 后 consume。
String? _pendingSettingsScrollKeyId;

/// 标记下次进入设置页时滚动到 [id] 对应的 [ValueKey] 位置。
///
/// 搜索结果点击时调用，再立即 `Navigator.push` 进设置页。
void requestSettingsScroll(String id) {
  _pendingSettingsScrollKeyId = id;
}

/// 由 [SettingsAutoScroll] 在首帧后调用，消费并返回待滚动的 id。
String? consumePendingSettingsScrollKey() {
  final id = _pendingSettingsScrollKeyId;
  _pendingSettingsScrollKeyId = null;
  return id;
}

/// 在子树中查找首个 widget.key == [target] 的 [BuildContext]，找不到返回 null。
BuildContext? findContextWithValueKey(BuildContext root, ValueKey<String> target) {
  BuildContext? result;
  bool found = false;
  void visit(Element e) {
    if (found) return;
    final Key? k = e.widget.key;
    if (k is ValueKey<String> && k.value == target.value) {
      result = e;
      found = true;
      return;
    }
    e.visitChildren(visit);
  }
  visit(root as Element);
  return result;
}

/// 包裹设置页 body：在首帧后若有 pending 滚动请求，自动滚到对应 [ValueKey]。
///
/// 推荐把页面的主内容用此组件包一层；页面内容请用 `Column` + `SingleChildScrollView`
/// 确保目标项一开始就在树中（懒构建的 ListView 里目标项可能尚未挂载）。
class SettingsAutoScroll extends StatefulWidget {
  final Widget child;

  const SettingsAutoScroll({super.key, required this.child});

  @override
  State<SettingsAutoScroll> createState() => _SettingsAutoScrollState();
}

class _SettingsAutoScrollState extends State<SettingsAutoScroll> {
  @override
  void initState() {
    super.initState();
    final id = consumePendingSettingsScrollKey();
    if (id == null) return;
    final target = ValueKey<String>(id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = findContextWithValueKey(context, target);
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: 0.05,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}