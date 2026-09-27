/// JSONPath 求值器，支持文档 selector 中出现的形态：
/// `$.list`、`$.vod_name`、`$.list[0].vod_name`、`$.list[*]`、`$.list[*].id`，
/// 以及 扩展的形态：嵌套路径、条件过滤 `[?(...)]`、递归下降 `..`、
/// 数组切片 `[1:3]` / `[-1]` / `[-2:]` / `[::2]`、负索引。
///
/// 返回标量或 List（调用方自行判空/遍历）。无效/不存在的路径返回 null，
/// 递归下降与切片/过滤类多值操作命中为空时返回空 List。
library;

class JsonPath {
  JsonPath._();

  /// 对 [root] 求值 [path]。公开 API（保持向后兼容）。
  static dynamic eval(String path, dynamic root) {
    if (!path.startsWith('\$')) return null;
    final tokens = _tokenize(path.substring(1));
    return _apply(tokens, 0, root);
  }

  static dynamic _apply(List<_Token> tokens, int i, dynamic cur, {bool strict = false}) {
    if (i >= tokens.length) return cur;
    final tok = tokens[i];

    if (tok is _DescendToken) {
      return _descend(tokens, i, cur);
    }

    if (tok is _KeyToken) {
      if (cur is Map) {
        return _apply(tokens, i + 1, cur[tok.key], strict: strict);
      }
      // 列表上的 key 自动映射（保留 `$.list[*].id` / `$.list.id` 语义）；
      // 递归下降内部使用 strict 模式，不触发自动映射。
      if (cur is List && !strict) {
        return [for (final e in cur) _apply(tokens, i, e, strict: false)];
      }
      return null;
    }

    if (tok is _StarToken) {
      if (cur is! List) return null;
      if (strict) {
        // 递归下降中显式展开：对每个元素应用剩余 token。
        return [for (final e in cur) _apply(tokens, i + 1, e, strict: true)];
      }
      // 非递归模式保留原 pass-through 语义。
      return _apply(tokens, i + 1, cur, strict: false);
    }

    if (tok is _IndexToken) {
      if (cur is! List) return null;
      var idx = tok.index;
      if (idx < 0) idx = cur.length + idx;
      if (idx < 0 || idx >= cur.length) return null;
      return _apply(tokens, i + 1, cur[idx], strict: strict);
    }

    if (tok is _SliceToken) {
      if (cur is! List) return null;
      final sliced = _slice(cur, tok);
      return _apply(tokens, i + 1, sliced, strict: strict);
    }

    if (tok is _FilterToken) {
      if (cur is! List) return null;
      final filtered = [for (final e in cur) if (_evalFilter(tok.expr, e)) e];
      return _apply(tokens, i + 1, filtered, strict: strict);
    }

    return null;
  }

  /// 递归下降：收集 [cur] 及其全部后代节点，对每个节点应用剩余 token，
  /// 结果中的 List 展平、null 剔除，最终返回扁平 List。
  static List<dynamic> _descend(List<_Token> tokens, int i, dynamic cur) {
    final all = <dynamic>[];
    void collect(dynamic node) {
      all.add(node);
      if (node is Map) {
        for (final v in node.values) {
          collect(v);
        }
      } else if (node is List) {
        for (final e in node) {
          collect(e);
        }
      }
    }

    collect(cur);
    final out = <dynamic>[];
    for (final node in all) {
      final r = _apply(tokens, i + 1, node, strict: true);
      if (r == null) continue;
      if (r is List) {
        out.addAll(r);
      } else {
        out.add(r);
      }
    }
    return out;
  }

  static List<dynamic> _slice(List<dynamic> cur, _SliceToken t) {
    final n = cur.length;
    final step = t.step ?? 1;
    if (step == 0) return const <dynamic>[];
    final out = <dynamic>[];
    if (step > 0) {
      var start = t.start ?? 0;
      var end = t.end ?? n;
      if (start < 0) start += n;
      if (end < 0) end += n;
      if (start < 0) start = 0;
      if (start > n) start = n;
      if (end < 0) end = 0;
      if (end > n) end = n;
      for (var idx = start; idx < end; idx += step) {
        out.add(cur[idx]);
      }
    } else {
      var start = t.start ?? n - 1;
      var end = t.end;
      if (start < 0) start += n;
      if (end != null && end < 0) end += n;
      if (start > n - 1) start = n - 1;
      if (start < 0) start = 0;
      var endIdx = end ?? -1;
      for (var idx = start; idx > endIdx; idx += step) {
        if (idx >= 0 && idx < n) out.add(cur[idx]);
      }
    }
    return out;
  }

  /// 求值过滤表达式 `@.field OP value`，[elem] 为当前数组元素（`@`）。
  static bool _evalFilter(String expr, dynamic elem) {
    final m = _filterRe.firstMatch(expr.trim());
    if (m == null) return false;
    final fieldPath = m.group(1)!;
    final op = m.group(2)!;
    final rawVal = m.group(3)!.trim();

    dynamic lhs = elem;
    for (final f in fieldPath.split('.')) {
      if (lhs is Map) {
        lhs = lhs[f];
      } else {
        return false;
      }
    }

    dynamic rhs;
    final len = rawVal.length;
    if (len >= 2 &&
        ((rawVal.startsWith("'") && rawVal.endsWith("'")) ||
            (rawVal.startsWith('"') && rawVal.endsWith('"')))) {
      rhs = rawVal.substring(1, len - 1);
    } else {
      final numVal = num.tryParse(rawVal);
      rhs = numVal ?? rawVal;
    }
    return _compare(lhs, op, rhs);
  }

  static bool _compare(dynamic lhs, String op, dynamic rhs) {
    switch (op) {
      case '==':
        return _equals(lhs, rhs);
      case '!=':
        return !_equals(lhs, rhs);
      case '>':
      case '>=':
      case '<':
      case '<=':
        break;
      default:
        return false;
    }
    final c = _cmp(lhs, rhs);
    if (c == null) return false;
    switch (op) {
      case '>':
        return c > 0;
      case '>=':
        return c >= 0;
      case '<':
        return c < 0;
      case '<=':
        return c <= 0;
    }
    return false;
  }

  static bool _equals(dynamic a, dynamic b) {
    if (a is num && b is num) return a == b;
    return a == b;
  }

  static int? _cmp(dynamic a, dynamic b) {
    if (a is num && b is num) return a.compareTo(b);
    if (a is String && b is String) return a.compareTo(b);
    return null;
  }

  static final RegExp _filterRe =
      RegExp(r'^@\s*\.?\s*([\w]+(?:\.[\w]+)*)\s*(==|!=|>=|<=|>|<)\s*(.+)$');

  static List<_Token> _tokenize(String body) {
    final tokens = <_Token>[];
    var pos = 0;
    while (pos < body.length) {
      final ch = body[pos];
      if (ch == '.') {
        if (pos + 1 < body.length && body[pos + 1] == '.') {
          tokens.add(const _DescendToken());
          pos += 2;
          continue;
        }
        pos += 1;
        final key = _readKey(body, pos);
        if (key.isNotEmpty) {
          tokens.add(_KeyToken(key));
          pos += key.length;
        }
        continue;
      }
      if (ch == '[') {
        final end = _findMatchingBracket(body, pos);
        if (end == -1) break;
        final inner = body.substring(pos + 1, end);
        final t = _parseBracket(inner);
        if (t != null) tokens.add(t);
        pos = end + 1;
        continue;
      }
      if (_isWordChar(ch)) {
        // 形如 `..key` 中紧跟 `..` 的无前导点 key。
        final key = _readKey(body, pos);
        tokens.add(_KeyToken(key));
        pos += key.length;
        continue;
      }
      pos += 1;
    }
    return tokens;
  }

  static int _findMatchingBracket(String body, int start) {
    var depth = 0;
    var inQuote = false;
    var quoteChar = '';
    for (var i = start; i < body.length; i++) {
      final c = body[i];
      if (inQuote) {
        if (c == quoteChar) inQuote = false;
        continue;
      }
      if (c == "'" || c == '"') {
        inQuote = true;
        quoteChar = c;
        continue;
      }
      if (c == '[') {
        depth++;
      } else if (c == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static _Token? _parseBracket(String inner) {
    final s = inner.trim();
    if (s.isEmpty) return null;
    if (s == '*') return const _StarToken();
    if (s.startsWith('?(') && s.endsWith(')')) {
      final expr = s.substring(2, s.length - 1);
      return _FilterToken(expr);
    }
    final len = s.length;
    if (len >= 2 &&
        ((s.startsWith("'") && s.endsWith("'")) ||
            (s.startsWith('"') && s.endsWith('"')))) {
      return _KeyToken(s.substring(1, len - 1));
    }
    if (s.contains(':')) return _parseSlice(s);
    final idx = int.tryParse(s);
    if (idx != null) return _IndexToken(idx);
    return _KeyToken(s);
  }

  static _SliceToken _parseSlice(String s) {
    final parts = s.split(':');
    int? start;
    int? end;
    int? step;
    if (parts.isNotEmpty && parts[0].trim().isNotEmpty) {
      start = int.tryParse(parts[0].trim());
    }
    if (parts.length >= 2 && parts[1].trim().isNotEmpty) {
      end = int.tryParse(parts[1].trim());
    }
    if (parts.length >= 3 && parts[2].trim().isNotEmpty) {
      step = int.tryParse(parts[2].trim());
    }
    return _SliceToken(start: start, end: end, step: step);
  }

  static String _readKey(String body, int pos) {
    var i = pos;
    while (i < body.length && _isWordChar(body[i])) {
      i++;
    }
    return body.substring(pos, i);
  }

  static bool _isWordChar(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 48 && code <= 57) || // 0-9
        (code >= 65 && code <= 90) || // A-Z
        (code >= 97 && code <= 122) || // a-z
        code == 95 || // _
        code >= 128; // non-ASCII (CJK 等)
  }
}

sealed class _Token {
  const _Token();
}

class _KeyToken extends _Token {
  final String key;
  const _KeyToken(this.key);
}

class _IndexToken extends _Token {
  final int index;
  const _IndexToken(this.index);
}

class _StarToken extends _Token {
  const _StarToken();
}

class _SliceToken extends _Token {
  final int? start;
  final int? end;
  final int? step;
  const _SliceToken({this.start, this.end, this.step});
}

class _FilterToken extends _Token {
  final String expr;
  const _FilterToken(this.expr);
}

class _DescendToken extends _Token {
  const _DescendToken();
}
