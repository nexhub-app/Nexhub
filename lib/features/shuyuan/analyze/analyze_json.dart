/// JSON 规则解析器：支持 `$.a.b`、`$["key"]`、`$[index]`、`$.a[*].b`（通配后
/// 接字段）、`$..x`（深度扫描）等 JSONPath 风格取值（对齐 jayway JsonPath 在
/// 书源中的常用子集）。
library;

import 'dart:convert';

class AnalyzeByJson {
  dynamic content;

  AnalyzeByJson(this.content);

  dynamic get _jsonData {
    if (content is String) {
      try {
        return json.decode(content as String);
      } catch (_) {
        return null;
      }
    }
    return content;
  }

  String getString(String rule) {
    if (rule.isEmpty) return '';
    final result = _resolvePath(rule);
    if (result == null) return '';
    if (result is List) {
      return result.map((e) => e.toString()).join('\n');
    }
    return result.toString();
  }

  List<String> getStringList(String rule) {
    if (rule.isEmpty) return [];
    final result = _resolvePath(rule);
    if (result == null) return [];
    if (result is List) {
      return result.map((e) => e.toString()).toList();
    }
    return [result.toString()];
  }

  List<dynamic> getList(String rule) {
    if (rule.isEmpty) return [];
    final result = _resolvePath(rule);
    if (result == null) return [];
    if (result is List) return result;
    return [result];
  }

  dynamic getObject(String rule) {
    if (rule.isEmpty) return null;
    return _resolvePath(rule);
  }

  dynamic _resolvePath(String path) {
    final data = _jsonData;
    if (data == null) return null;

    final tokens = _tokenize(path);
    if (tokens.isEmpty) return data;
    return _navigate(data, tokens);
  }

  /// 路径分词：`.field`、`['key']`、`["key"]`、`[index]`、`[*]`、`..`（深扫）。
  static List<_JsonPathToken> _tokenize(String path) {
    final tokens = <_JsonPathToken>[];
    var i = 0;
    final s = path;

    while (i < s.length) {
      final c = s[i];
      if (c == r'$') {
        i += 1;
      } else if (c == '.') {
        if (i + 1 < s.length && s[i + 1] == '.') {
          tokens.add(const _JsonPathToken(_JsonTokenType.deepScan, ''));
          i += 2;
        } else {
          i += 1;
        }
      } else if (c == '[') {
        final end = _findBracketEnd(s, i);
        if (end < 0) break;
        final inner = s.substring(i + 1, end).trim();
        if (inner == '*' || inner.isEmpty) {
          tokens.add(const _JsonPathToken(_JsonTokenType.wildcard, ''));
        } else if ((inner.startsWith("'") && inner.endsWith("'")) ||
            (inner.startsWith('"') && inner.endsWith('"'))) {
          tokens.add(_JsonPathToken(
              _JsonTokenType.key, inner.substring(1, inner.length - 1)));
        } else {
          final idx = int.tryParse(inner);
          if (idx != null) {
            tokens.add(_JsonPathToken(_JsonTokenType.arrayIndex, inner));
          } else {
            tokens.add(_JsonPathToken(_JsonTokenType.key, inner));
          }
        }
        i = end + 1;
      } else if (c == '@' || c == ',') {
        // 过滤器表达式（[?(@...)]）等不支持的语法：终止分词，按已知前缀求值。
        break;
      } else {
        var j = i;
        while (j < s.length && s[j] != '.' && s[j] != '[') {
          j += 1;
        }
        tokens.add(_JsonPathToken(_JsonTokenType.key, s.substring(i, j)));
        i = j;
      }
    }
    return tokens;
  }

  /// 括号闭合位置（跳过引号内的 `]`）。
  static int _findBracketEnd(String s, int start) {
    var quote = false;
    var quoteChar = '';
    for (var i = start + 1; i < s.length; i++) {
      final c = s[i];
      if (quote) {
        if (c == quoteChar) quote = false;
      } else if (c == "'" || c == '"') {
        quote = true;
        quoteChar = c;
      } else if (c == ']') {
        return i;
      }
    }
    return -1;
  }

  /// 逐 token 导航：通配符把当前节点集合展开为全部子元素，后续 token 逐个
  /// 作用于每个元素（`$.rows[*].name` → 所有 rows 元素的 name 列表）。
  dynamic _navigate(dynamic root, List<_JsonPathToken> tokens) {
    var current = <dynamic>[root];
    for (final token in tokens) {
      final next = <dynamic>[];
      for (final node in current) {
        switch (token.type) {
          case _JsonTokenType.key:
            _applyKey(node, token.name, next);
          case _JsonTokenType.arrayIndex:
            if (node is List) {
              final idx = int.tryParse(token.name) ?? -1;
              if (idx >= 0 && idx < node.length) next.add(node[idx]);
            }
          case _JsonTokenType.wildcard:
            if (node is List) {
              next.addAll(node);
            } else if (node is Map) {
              next.addAll(node.values);
            }
          case _JsonTokenType.deepScan:
            _collectAll(node, next);
        }
      }
      current = next;
    }
    if (current.isEmpty) return null;
    if (current.length == 1) return current.first;
    return current;
  }

  static void _applyKey(dynamic node, String name, List<dynamic> out) {
    if (node is Map) {
      // 不含该键时不追加 null（深度扫描 `$..field` 会遍历大量无关 Map，
      // 追加 null 会把结果污染成 [null, 值, null, ...]）。
      if (node.containsKey(name)) {
        out.add(node[name]);
      }
    } else if (node is List) {
      // 纯数字键作用在数组上等于下标（`$.items.0`）。
      final idx = int.tryParse(name);
      if (idx != null && idx >= 0 && idx < node.length) {
        out.add(node[idx]);
      }
    }
  }

  /// 深度扫描：收集自身与全部后代节点（`$..field` 语义：任意层级的 field）。
  static void _collectAll(dynamic node, List<dynamic> out) {
    out.add(node);
    if (node is Map) {
      for (final v in node.values) {
        _collectAll(v, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collectAll(v, out);
      }
    }
  }
}

enum _JsonTokenType { key, arrayIndex, wildcard, deepScan }

class _JsonPathToken {
  final _JsonTokenType type;
  final String name;

  const _JsonPathToken(this.type, this.name);
}
