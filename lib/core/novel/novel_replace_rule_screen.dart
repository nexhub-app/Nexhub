/// 替换规则管理页面（美化版）：列表 + 编辑 + 书籍级开关。
library;

import 'package:flutter/material.dart';
import '../../core/novel/novel_replace_rule.dart';
import '../../core/novel/novel_rule_cache.dart';
import '../utils/app_haptics.dart';

/// 替换规则管理页面入口：从阅读器设置进入。
class NovelReplaceRuleScreen extends StatefulWidget {
  final String bookId;
  final String bookName;

  const NovelReplaceRuleScreen({
    super.key,
    required this.bookId,
    required this.bookName,
  });

  @override
  State<NovelReplaceRuleScreen> createState() => _NovelReplaceRuleScreenState();
}

class _NovelReplaceRuleScreenState extends State<NovelReplaceRuleScreen> {
  NovelReplaceRuleSet? _ruleSet;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rules = await NovelRuleCache().getReplaceRules(widget.bookId);
    if (!mounted) return;
    setState(() {
      _ruleSet = rules;
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_ruleSet == null) return;
    await NovelRuleCache().saveReplaceRules(_ruleSet!);
    NovelRuleCache().invalidateReplaceRules(widget.bookId);
  }

  Future<void> _toggleEnabled() async {
    if (_ruleSet == null) return;
    setState(() => _ruleSet!.enabled = !_ruleSet!.enabled);
    await _save();
  }

  Future<void> _addRule() async {
    final rule = await Navigator.push<NovelReplaceRule>(
      context,
      MaterialPageRoute(
        builder: (_) => _ReplaceRuleEditScreen(rule: null),
      ),
    );
    if (rule != null) {
      setState(() => _ruleSet!.rules.add(rule));
      await _save();
    }
  }

  Future<void> _editRule(int index) async {
    final rule = await Navigator.push<NovelReplaceRule>(
      context,
      MaterialPageRoute(
        builder: (_) => _ReplaceRuleEditScreen(rule: _ruleSet!.rules[index]),
      ),
    );
    if (rule != null) {
      setState(() => _ruleSet!.rules[index] = rule);
      await _save();
    }
  }

  Future<void> _deleteRule(int index) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('删除「${_ruleSet!.rules[index].name.isNotEmpty ? _ruleSet!.rules[index].name : _ruleSet!.rules[index].pattern}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirm == true) {
      setState(() => _ruleSet!.rules.removeAt(index));
      await _save();
    }
  }

  Color _scopeColor(String scope) {
    switch (scope) {
      case 'content': return Colors.blue;
      case 'title': return Colors.orange;
      case 'all': return Colors.purple;
      default: return Colors.grey;
    }
  }

  String _scopeLabel(String scope) {
    switch (scope) {
      case 'content': return '正文';
      case 'title': return '标题';
      case 'all': return '全部';
      default: return scope;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('替换规则 · ${widget.bookName}'),
        actions: [
          if (_ruleSet != null)
            IconButton(
              icon: Icon(
                _ruleSet!.enabled ? Icons.toggle_on : Icons.toggle_off_outlined,
                color: _ruleSet!.enabled ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
              ),
              tooltip: _ruleSet!.enabled ? '已启用' : '已禁用',
              onPressed: _toggleEnabled,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildList(theme),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addRule,
        icon: const Icon(Icons.add),
        label: const Text('添加规则'),
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    final rules = _ruleSet!.rules;
    if (rules.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _ruleSet!.enabled ? Icons.cleaning_services_outlined : Icons.toggle_off_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              _ruleSet!.enabled ? '暂无替换规则' : '替换规则已禁用',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _ruleSet!.enabled ? '点击右下角 + 添加规则' : '点击右上角开关启用',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
      itemCount: rules.length,
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          final item = rules.removeAt(oldIndex);
          rules.insert(newIndex, item);
          for (int i = 0; i < rules.length; i++) {
            rules[i].order = i;
          }
        });
        _save();
      },
      itemBuilder: (context, index) {
        final rule = rules[index];
        final scopeColor = _scopeColor(rule.scope);
        return Card(
          key: ValueKey(rule.id),
          margin: const EdgeInsets.symmetric(vertical: 4),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.3),
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _editRule(index),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
              child: Row(
                children: [
                  // 拖拽手柄
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        Icons.drag_handle,
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                        size: 24,
                      ),
                    ),
                  ),
                  // 启用指示
                  Icon(
                    rule.isEnabled ? Icons.check_circle : Icons.cancel_outlined,
                    color: rule.isEnabled ? Colors.green : Colors.grey,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  // 内容
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rule.name.isNotEmpty ? rule.name : rule.pattern,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: scopeColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _scopeLabel(rule.scope),
                                style: theme.textTheme.labelSmall?.copyWith(color: scopeColor),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: rule.isRegex
                                    ? Colors.amber.withValues(alpha: 0.15)
                                    : Colors.teal.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                rule.isRegex ? '正则' : '纯文本',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: rule.isRegex ? Colors.amber.shade800 : Colors.teal.shade700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // 替换摘要
                  if (rule.replacement.isNotEmpty)
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '→ ${rule.replacement}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  // 删除
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    color: theme.colorScheme.error,
                    onPressed: () => _deleteRule(index),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 替换规则编辑页面（美化版）。
class _ReplaceRuleEditScreen extends StatefulWidget {
  final NovelReplaceRule? rule;

  const _ReplaceRuleEditScreen({super.key, this.rule});

  @override
  State<_ReplaceRuleEditScreen> createState() => _ReplaceRuleEditScreenState();
}

class _ReplaceRuleEditScreenState extends State<_ReplaceRuleEditScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _patternCtrl;
  late final TextEditingController _replacementCtrl;
  late bool _isRegex;
  late String _scope;
  late bool _isEnabled;

  bool get _isNew => widget.rule == null;

  @override
  void initState() {
    super.initState();
    final r = widget.rule;
    _nameCtrl = TextEditingController(text: r?.name ?? '');
    _patternCtrl = TextEditingController(text: r?.pattern ?? '');
    _replacementCtrl = TextEditingController(text: r?.replacement ?? '');
    _isRegex = r?.isRegex ?? true;
    _scope = r?.scope ?? 'content';
    _isEnabled = r?.isEnabled ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _patternCtrl.dispose();
    _replacementCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final pattern = _patternCtrl.text.trim();
    if (pattern.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('替换模式不能为空'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final rule = NovelReplaceRule(
      id: widget.rule?.id,
      name: _nameCtrl.text.trim(),
      pattern: pattern,
      replacement: _replacementCtrl.text,
      isRegex: _isRegex,
      scope: _scope,
      isEnabled: _isEnabled,
      order: widget.rule?.order ?? 0,
    );
    Navigator.pop(context, rule);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '添加替换规则' : '编辑替换规则'),
        actions: [
          TextButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── 基本设置 ──
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('基本设置', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '规则名称',
                      hintText: '可选，便于识别',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _patternCtrl,
                    decoration: InputDecoration(
                      labelText: '匹配模式',
                      hintText: _isRegex ? r'正则表达式（如 ^广告.*$）' : '要替换的文本',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLines: 3,
                    minLines: 2,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _replacementCtrl,
                    decoration: const InputDecoration(
                      labelText: '替换为',
                      hintText: '留空则移除匹配文本',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLines: 2,
                    minLines: 1,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // ── 选项 ──
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3)),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('使用正则表达式'),
                  subtitle: Text(_isRegex ? '按正则模式匹配替换' : '按纯文本精确匹配'),
                  value: _isRegex,
                  onChanged: (v) {
                    AppHaptics.selectionClick();
                    setState(() => _isRegex = v);
                  },
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  title: const Text('作用范围'),
                  trailing: DropdownButton<String>(
                    value: _scope,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: 'content', child: Text('正文')),
                      DropdownMenuItem(value: 'title', child: Text('标题')),
                      DropdownMenuItem(value: 'all', child: Text('全部')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _scope = v);
                    },
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                SwitchListTile(
                  title: const Text('启用'),
                  value: _isEnabled,
                  onChanged: (v) {
                    AppHaptics.selectionClick();
                    setState(() => _isEnabled = v);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // ── 预览 ──
          if (_patternCtrl.text.isNotEmpty)
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('预览', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _isRegex
                            ? '示例：将匹配「${_patternCtrl.text}」${_replacementCtrl.text.isNotEmpty ? '替换为「${_replacementCtrl.text}」' : '移除'}'
                            : '将精确匹配「${_patternCtrl.text}」${_replacementCtrl.text.isNotEmpty ? '替换为「${_replacementCtrl.text}」' : '移除'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}