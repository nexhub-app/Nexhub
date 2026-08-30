/// 翻译术语表编辑器（F1：术语表与人名一致性）。
///
/// 管理全局术语表（作品维度 = 全局；作品级表由后续作品详情入口开放）：
/// 增删改、JSON 导入（同术语覆盖合并）/ 导出（分享文本）。条目按
/// 「术语 → 统一译名 + 可接受别名 + 备注」组织，翻译时经
/// [PromptBuilder.glossarySection] 注入三条链路的 system prompt。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';
import 'package:nexhub/core/widgets/app_animations.dart';
import 'package:share_plus/share_plus.dart';

import '../../novel/domain/novel_summary_settings.dart';
import 'widgets/settings_widgets.dart';

class TranslationGlossaryScreen extends StatefulWidget {
  const TranslationGlossaryScreen({super.key});

  @override
  State<TranslationGlossaryScreen> createState() =>
      _TranslationGlossaryScreenState();
}

class _TranslationGlossaryScreenState extends State<TranslationGlossaryScreen> {
  final GlossaryManager _manager = GlossaryManager();
  List<GlossaryEntry> _entries = const <GlossaryEntry>[];
  bool _loading = true;
  String _lang = '中文';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _lang = await NovelSummarySettings.instance.getTranslationTargetLanguage();
      final list = await _manager.effectiveEntries(
          GlossaryManager.globalWorkId, _lang);
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _upsert(GlossaryEntry entry) async {
    final list = await _manager.saveEntry(
        GlossaryManager.globalWorkId, _lang, entry);
    if (!mounted) return;
    setState(() => _entries = list);
  }

  Future<void> _remove(GlossaryEntry entry) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.delete),
        content: Text(l10n.glossaryDeleteConfirm(entry.term)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final list = await _manager.removeEntry(
        GlossaryManager.globalWorkId, _lang, entry.id);
    if (!mounted) return;
    setState(() => _entries = list);
  }

  Future<void> _showEditor([GlossaryEntry? existing]) async {
    final l10n = AppLocalizations.of(context);
    final termCtrl = TextEditingController(text: existing?.term ?? '');
    final preferredCtrl = TextEditingController(text: existing?.preferred ?? '');
    final aliasesCtrl = TextEditingController(
      text: existing?.aliases.join('、') ?? '',
    );
    final noteCtrl = TextEditingController(text: existing?.note ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(existing == null ? l10n.glossaryAdd : l10n.glossaryEdit),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: termCtrl,
                autofocus: existing == null,
                decoration: InputDecoration(
                  labelText: l10n.glossaryTerm,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              TextField(
                controller: preferredCtrl,
                decoration: InputDecoration(
                  labelText: l10n.glossaryPreferred,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              TextField(
                controller: aliasesCtrl,
                decoration: InputDecoration(
                  labelText: l10n.glossaryAliases,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              TextField(
                controller: noteCtrl,
                decoration: InputDecoration(
                  labelText: l10n.glossaryNote,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: termCtrl,
            builder: (context, term, _) => ValueListenableBuilder<TextEditingValue>(
              valueListenable: preferredCtrl,
              builder: (context, pref, _) => FilledButton(
                onPressed: term.text.trim().isNotEmpty &&
                        pref.text.trim().isNotEmpty
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: Text(l10n.save),
              ),
            ),
          ),
        ],
      ),
    );
    // 先取值再释放（退场动画期间控制器仍被输入框引用）。
    final term = termCtrl.text.trim();
    final preferred = preferredCtrl.text.trim();
    final aliasesRaw = aliasesCtrl.text;
    final note = noteCtrl.text.trim();
    termCtrl.dispose();
    preferredCtrl.dispose();
    aliasesCtrl.dispose();
    noteCtrl.dispose();
    if (saved != true) return;
    await _upsert(GlossaryEntry(
      id: existing?.id ?? '',
      term: term,
      preferred: preferred,
      aliases: <String>[
        for (final a in aliasesRaw.split(RegExp(r'[、,，;；/]'))) a.trim(),
      ].where((a) => a.isNotEmpty).toList(),
      note: note,
    ));
  }

  Future<void> _export() async {
    final json = GlossaryManager.exportJson(_entries);
    await Share.share(json);
  }

  Future<void> _import() async {
    final l10n = AppLocalizations.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['json', 'txt'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    try {
      final raw = await File(path).readAsString();
      final incoming = GlossaryManager.parseImportJson(raw);
      final merged = await _manager.importMerge(
          GlossaryManager.globalWorkId, _lang, incoming);
      if (!mounted) return;
      setState(() => _entries = merged);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.glossaryImportOk(incoming.length))),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.glossaryImportFail)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShrinkTitleScaffold(
      title: Text(l10n.glossaryTitle),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTokens.spaceLg, AppTokens.spaceMd, AppTokens.spaceLg, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    l10n.glossaryTargetLang(_lang),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                            color: Theme.of(context).colorScheme.outline),
                  ),
                ),
                IconButton(
                  tooltip: l10n.glossaryImport,
                  icon: const Icon(Icons.upload_file),
                  onPressed: _import,
                ),
                IconButton(
                  tooltip: l10n.glossaryExport,
                  icon: const Icon(Icons.ios_share),
                  onPressed: _entries.isEmpty ? null : _export,
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                    ? Center(
                        child: Padding(
                          padding:
                              const EdgeInsets.all(AppTokens.spaceXl),
                          child: Text(
                            l10n.glossaryEmpty,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color:
                                  Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(AppTokens.spaceLg),
                        itemCount: _entries.length,
                        itemBuilder: (context, i) {
                          final e = _entries[i];
                          return Card(
                            margin: const EdgeInsets.only(
                                bottom: AppTokens.spaceSm),
                            child: ListTile(
                              title: Text(
                                '${e.term} → ${e.preferred}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              subtitle: e.aliases.isEmpty
                                  ? null
                                  : Text(
                                      l10n.glossaryAliasesPreview(
                                          e.aliases.join('、')),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _remove(e),
                              ),
                              onTap: () => _showEditor(e),
                            ),
                          );
                        },
                      ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              child: FilledButton.icon(
                onPressed: () => _showEditor(),
                icon: const Icon(Icons.add),
                label: Text(l10n.glossaryAdd),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
