/// 文件夹导入的选择弹窗（B 阶段：文件夹=一部作品，内部文件=章/话）。
///
/// 用户在导入页「选择目录」后，若文件夹内含多个匹配文件，弹此窗询问
/// 「合并为整本/整部」还是「逐文件分别导入」。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';
import 'package:nexhub/core/widgets/app_segmented_tabs.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/local/saf_bridge.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:path/path.dart' as p;

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

/// 目录文件多选结果：所选文件 + 导入模式（合并为一部 / 逐个分开）。
class FolderFileSelectResult {
  final List<String> selectedFiles;
  final FolderImportMode mode;

  const FolderFileSelectResult(this.selectedFiles, this.mode);
}

/// 选文件夹导入漫画时，列出目录内候选文件（漫画归档 + 其它非图片文件），
/// 让用户勾选要导入的文件，并选择「合并为一部」还是「逐个分开」。
///
/// 每个文件 = 一话；勾选后可在弹窗内「在目录里选择」具体要导入哪些。
/// 返回 [FolderFileSelectResult]；用户取消（点空白/返回/未勾选任何文件确认）返回 null。
///
/// [files] 候选文件路径（archives + others，已自然排序）；[isSaf] 为 true 时用
/// [safBaseName] 取显示名（content:// URI 无法用 [p.basename]）。
Future<FolderFileSelectResult?> showFolderFileSelectSheet(
  BuildContext context, {
  required String folderName,
  required List<String> files,
  required bool isSaf,
  FolderImportMode initialMode = FolderImportMode.merge,
}) async {
  if (files.isEmpty) return null;
  return showModalBottomSheet<FolderFileSelectResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(ctx).size.height * 0.85,
      ),
      child: _FolderFileSelectSheet(
        folderName: folderName,
        files: files,
        isSaf: isSaf,
        initialMode: initialMode,
      ),
    ),
  );
}

class _FolderFileSelectSheet extends StatefulWidget {
  final String folderName;
  final List<String> files;
  final bool isSaf;
  final FolderImportMode initialMode;

  const _FolderFileSelectSheet({
    required this.folderName,
    required this.files,
    required this.isSaf,
    required this.initialMode,
  });

  @override
  State<_FolderFileSelectSheet> createState() => _FolderFileSelectSheetState();
}

class _FolderFileSelectSheetState extends State<_FolderFileSelectSheet> {
  late final Set<String> _selected = <String>{...widget.files};
  late FolderImportMode _mode = widget.initialMode;

  String _nameOf(String path) =>
      widget.isSaf ? safBaseName(path) : p.basename(path);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: <Widget>[
        // 标题 + 说明
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceLg,
            AppTokens.spaceLg,
            AppTokens.spaceLg,
            AppTokens.spaceSm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                l10n.folderFileSelectTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                l10n.folderFileSelectHint(widget.files.length),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),

        // 全选 / 全不选
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceLg,
            vertical: AppTokens.spaceXs,
          ),
          child: Row(
            children: <Widget>[
              TextButton(
                onPressed: () => setState(() => _selected.addAll(widget.files)),
                child: Text(l10n.folderFileSelectAll),
              ),
              TextButton(
                onPressed: () => setState(() => _selected.clear()),
                child: Text(l10n.folderFileSelectNone),
              ),
              const Spacer(),
              Text(
                '${_selected.length}/${widget.files.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // 文件勾选列表（可滚动）
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: widget.files.length,
            itemBuilder: (ctx, i) {
              final file = widget.files[i];
              final checked = _selected.contains(file);
              return CheckboxListTile(
                value: checked,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _selected.add(file);
                  } else {
                    _selected.remove(file);
                  }
                }),
                title: Text(
                  _nameOf(file),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            },
          ),
        ),
        const Divider(height: 1),

        // 合并为一部 / 逐个分开 开关
        Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AppSegmentedTabs<FolderImportMode>(
                selected: <FolderImportMode>{_mode},
                onSelectionChanged: (s) {
                  if (s.isNotEmpty) setState(() => _mode = s.first);
                },
                segments: <ButtonSegment<FolderImportMode>>[
                  ButtonSegment<FolderImportMode>(
                    value: FolderImportMode.merge,
                    label: Text(l10n.folderFileSelectMerge),
                  ),
                  ButtonSegment<FolderImportMode>(
                    value: FolderImportMode.perFile,
                    label: Text(l10n.folderFileSelectSeparate),
                  ),
                ],
              ),
              const SizedBox(height: AppTokens.spaceMd),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(
                            FolderFileSelectResult(
                              _selected.toList(),
                              _mode,
                            ),
                          ),
                  child: Text(l10n.folderFileSelectConfirm(_selected.length)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
