/// 备份内容分类选择器（导入/导出与云同步共用）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../core/services/backup_archive.dart';
import '../../core/utils/app_haptics.dart';

/// 分类 → 本地化标签。
String backupCategoryLabel(AppLocalizations l10n, BackupCategory c) {
  switch (c) {
    case BackupCategory.source:
      return l10n.backupCategorySource;
    case BackupCategory.bookmark:
      return l10n.backupCategoryBookmark;
    case BackupCategory.progress:
      return l10n.backupCategoryProgress;
    case BackupCategory.settings:
      return l10n.backupCategorySettings;
    case BackupCategory.download:
      return l10n.backupCategoryDownload;
    case BackupCategory.danmaku:
      return l10n.backupCategoryDanmaku;
    case BackupCategory.other:
      return l10n.backupCategoryOther;
  }
}

/// 可在 UI 中勾选的全部分类（other 留给未来扩展，不单独显示）。
const List<BackupCategory> kSelectableBackupCategories = <BackupCategory>[
  BackupCategory.source,
  BackupCategory.bookmark,
  BackupCategory.progress,
  BackupCategory.settings,
  BackupCategory.download,
  BackupCategory.danmaku,
];

/// 备份分类多选组件。
class BackupCategorySelector extends StatelessWidget {
  final Set<BackupCategory> selected;
  final ValueChanged<Set<BackupCategory>> onChanged;
  final bool showHeader;

  const BackupCategorySelector({
    super.key,
    required this.selected,
    required this.onChanged,
    this.showHeader = true,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showHeader)
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.backupSelectScope,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton(
                onPressed: () => onChanged(
                  Set<BackupCategory>.from(kSelectableBackupCategories),
                ),
                child: Text(l10n.backupSelectAll),
              ),
            ],
          ),
        ...kSelectableBackupCategories.map(
          (c) => CheckboxListTile(
            title: Text(backupCategoryLabel(l10n, c)),
            value: selected.contains(c),
            onChanged: (v) {
              AppHaptics.selectionClick();
              final next = Set<BackupCategory>.from(selected);
              if (v == true) {
                next.add(c);
              } else {
                next.remove(c);
              }
              onChanged(next);
            },
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
          ),
        ),
      ],
    );
  }
}
