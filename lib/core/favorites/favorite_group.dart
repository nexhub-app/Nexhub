/// 收藏分组模型。
///
/// 分组是用户自建的「标签」，一个收藏条目可归属多个分组
/// （多分组标签模型），与 [FavoriteEntry.category]（站点题材）严格区分。
/// 分组**按模块（动漫 / 漫画 / 小说）独立**，互不互通，
/// 持久化到 [PrefsBackend] 键 `favorite_groups_v1`。
library;

import 'dart:math';

import '../models/plugin_config.dart';

/// 虚拟「未分组」的哨兵 id——不落库，仅用于筛选语义
/// （命中该 id 表示筛选 groupIds 为空的条目）。
const String kUngroupedId = '_ungrouped';

/// 单个收藏分组。
class FavoriteGroup {
  final String id;

  /// 用户输入的分组名（创建 / 重命名时做重名校验）。
  final String name;

  /// 分组所属模块（动漫 / 漫画 / 小说）。不同模块的分组互不互通。
  final SourceType sourceType;

  /// 手动排序序号（越小越靠前）。
  final int sortOrder;

  /// 创建时间（毫秒时间戳）。
  final int createdAt;

  /// 是否隐藏：隐藏后不显示在分类栏与筛选，但仍可在「分类管理」中恢复显示。
  final bool hidden;

  const FavoriteGroup({
    required this.id,
    required this.name,
    required this.sourceType,
    required this.sortOrder,
    required this.createdAt,
    this.hidden = false,
  });

  /// 生成新分组 id（时间戳 + 随机后缀，避免同毫秒冲突）。
  static String newId() {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int rand = Random().nextInt(0xFFFF);
    return 'grp_${now}_$rand';
  }

  FavoriteGroup copyWith({
    String? name,
    SourceType? sourceType,
    int? sortOrder,
    bool? hidden,
  }) =>
      FavoriteGroup(
        id: id,
        name: name ?? this.name,
        sourceType: sourceType ?? this.sourceType,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt,
        hidden: hidden ?? this.hidden,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'sourceType': sourceType.apiName,
        'sortOrder': sortOrder,
        'createdAt': createdAt,
        'hidden': hidden,
      };

  factory FavoriteGroup.fromJson(Map<String, dynamic> json) => FavoriteGroup(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        sourceType: SourceType.parse(json['sourceType'] as String?) ??
            SourceType.animeSource,
        sortOrder: json['sortOrder'] as int? ?? 0,
        createdAt: json['createdAt'] as int? ?? 0,
        hidden: json['hidden'] as bool? ?? false,
      );
}
