/// 文件夹导入的选择弹窗（B 阶段：文件夹=一部作品，内部文件=章/话）。
///
/// 用户在导入页「选择目录」后，若文件夹内含多个匹配文件，弹此窗询问
/// 「合并为整本/整部」还是「逐文件分别导入」。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';
import 'package:nexhub/generated/app_localizations.dart';

/// 文件夹导入的选择结果。
enum FolderImportMode {
  /// 合并为整本/整部：文件夹内每个文件 = 一章/一话。
  merge,

  /// 逐文件分别导入，每个文件一条导入记录。
  perFile,
}

/// 选文件夹后询问「合并为整部」还是「逐文件导入」。
///
/// [folderName] 文件夹名；[typeLabel] 类型名（如「小说」「漫画」），用于提示文案。
/// 返回选中的模式；用户取消（点空白/返回）返回 null。
Future<FolderImportMode?> showFolderImportChoiceDialog(
  BuildContext context, {
  required String folderName,
  required String typeLabel,
}) async {
  final l10n = AppLocalizations.of(context);
  return showDialog<FolderImportMode>(
    context: context,
    builder: (ctx) => AppAlertDialog(
      title: Text(l10n.folderImportChoiceTitle(folderName)),
      content: Text(l10n.folderImportChoiceHint(typeLabel)),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(FolderImportMode.perFile),
          child: Text(l10n.folderImportChoicePerFile),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(FolderImportMode.merge),
          child: Text(l10n.folderImportChoiceMerge),
        ),
      ],
    ),
  );
}
