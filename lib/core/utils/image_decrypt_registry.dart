/// 源声明式图片字节解密注册表。
///
/// 背景：部分源站（图床）对**图片字节本身**加密（而非仅防盗链 Referer），
/// 浏览器端由站点自带的 JS（Web Worker + CryptoJS）解密后渲染。此类站点
/// 无论怎么配 Referer/UA，客户端拿到的 `image/webp` 都是密文，直接解码失败。
///
/// 本注册表让**源 JSON 声明解密方式**（源即插件：密钥/算法都在源文件里，
/// 引擎不写死任何站点逻辑）：
///
/// ```json
/// "imageTransform": {
///   "matchHosts": ["cdn.example.com", "cdn-mirror.example.com"],
///   "decrypt": {
///     "algo": "aes-cbc",
///     "key": "16字节密钥原文",
///     "keyEncoding": "utf8",
///     "ivSource": "prefixBytes",
///     "ivLength": 16,
///     "padding": "pkcs7"
///   }
/// }
/// ```
///
/// 支持的算法（覆盖社区常见的图片字节加密方式）：
///
/// | algo       | 说明 | IV | padding |
/// |------------|------|----|---------|
/// | `aes-cbc`  | AES-CBC | `prefixBytes`（文件头 N 字节为 IV，最常见）/ `fixed`（源声明 `iv` 字段）/ `none`（全零 IV） | `pkcs7`（缺省）/ `none`（不去填充，密文长度恒为 16 倍数） |
/// | `aes-ecb`  | AES-ECB | 无（`prefixBytes` 语义退化为「跳过文件头 N 字节」） | 同上 |
/// | `rc4`      | RC4 流密码（整文件作为密文体） | 同上（可跳过文件头） | 无 |
/// | `xor`      | 重复密钥 XOR（key 循环异或） | 同上（可跳过文件头） | 无 |
///
/// `keyEncoding` / `ivEncoding`：`utf8`（缺省）/ `base64` / `hex`。
/// `matchHosts` 必须枚举**所有**可能下发图片的 CDN host（部分站点按
/// 镜像域名轮换图床 host，漏一个 host 该镜像的图就是密文坏图）。
///
/// 生效点（统一走 [matchFor] / [decrypt]）：
/// - [DioImageFileService]（SourceImage 全部图片：封面列表/详情封面/阅读器正文，
///   解密后的明文进磁盘缓存，save/share 自动继承）；
/// - 漫画离线下载 [comic_download_handler]（下载即解密，本地阅读无需再解）。
///
/// 注册时机：[PluginConfig.fromJson] 解析到 `imageTransform` 块时按 host
/// 幂等注册（内置源启动解析、Hive 回灌、导入更新都会走到）。源被删除后
/// 残留条目只影响该 host 的图片解密尝试（解密失败按原文返回），无害。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'crypto_utils.dart';

/// 单条图片解密规则（由源 `imageTransform.decrypt` 段构造）。
class ImageDecryptRule {
  /// 算法：`aes-cbc` / `aes-ecb` / `rc4` / `xor`。
  final String algo;

  /// 密钥字节（按 keyEncoding 解码后）。
  final List<int> key;

  /// IV 来源：`prefixBytes`（文件头 N 字节为 IV；流密码/ECB 下退化为跳过头部）、
  /// `fixed`（用 [fixedIv]）、`none`（AES-CBC 用全零 IV）。
  final String ivSource;

  /// 头部长度（prefixBytes 模式，AES 为 16）。
  final int ivLength;

  /// 固定 IV（ivSource=fixed 时使用，须 16 字节）。
  final List<int> fixedIv;

  /// 填充：`pkcs7`（缺省）/ `none`（仅 AES 系列有效）。
  final String padding;

  const ImageDecryptRule({
    required this.algo,
    required this.key,
    required this.ivSource,
    required this.ivLength,
    required this.fixedIv,
    required this.padding,
  });
}

/// 全局 host → 解密规则注册表。
abstract final class ImageBytesDecryptRegistry {
  static final Map<String, ImageDecryptRule> _rules = <String, ImageDecryptRule>{};

  /// 按 host 幂等注册（同名 host 以最后一次注册为准——源更新时自然覆盖）。
  static void register({
    required List<String> hosts,
    required ImageDecryptRule rule,
  }) {
    for (final String h in hosts) {
      final String host = h.trim().toLowerCase();
      if (host.isEmpty) continue;
      _rules[host] = rule;
    }
  }

  /// 按 URL host 取规则；未注册返回 null（绝大多数源走不到解密分支）。
  static ImageDecryptRule? matchFor(Uri url) => _rules[url.host.toLowerCase()];

  /// 解密图片字节。规则不匹配/算法不支持/解密失败 → 返回原字节（调用方
  /// 无需关心是否发生过解密）。
  static Uint8List decrypt(Uri url, Uint8List bytes) {
    final ImageDecryptRule? rule = matchFor(url);
    if (rule == null || bytes.isEmpty) return bytes;
    try {
      switch (rule.algo) {
        case 'aes-cbc':
          return _aesCbc(bytes, rule);
        case 'aes-ecb':
          return _aesEcb(bytes, rule);
        case 'rc4':
          return _rc4(_stripPrefix(bytes, rule), rule.key);
        case 'xor':
          return _xor(_stripPrefix(bytes, rule), rule.key);
        default:
          return bytes;
      }
    } on Object {
      // 解密失败（密钥轮换/截断/非该源图片）按原文交还，交给上层按坏图处理。
      return bytes;
    }
  }

  /// prefixBytes 模式：剥掉文件头 IV，返回密文体（长度不足时返回原文）。
  static Uint8List _stripPrefix(Uint8List bytes, ImageDecryptRule rule) {
    if (rule.ivSource != 'prefixBytes') return bytes;
    if (bytes.length <= rule.ivLength) return bytes;
    return Uint8List.sublistView(bytes, rule.ivLength);
  }

  /// AES-CBC：IV 三来源（prefixBytes / fixed / 全零）+ pkcs7/none 填充。
  static Uint8List _aesCbc(Uint8List bytes, ImageDecryptRule rule) {
    List<int> iv;
    Uint8List body;
    if (rule.ivSource == 'prefixBytes') {
      if (bytes.length <= rule.ivLength) return bytes;
      iv = bytes.sublist(0, rule.ivLength);
      body = Uint8List.sublistView(bytes, rule.ivLength);
    } else if (rule.ivSource == 'fixed') {
      if (rule.fixedIv.length != 16) return bytes;
      iv = rule.fixedIv;
      body = bytes;
    } else {
      iv = Uint8List(16);
      body = bytes;
    }
    if (body.isEmpty || body.length % 16 != 0) return bytes;
    if (rule.padding == 'none') {
      return _aesCbcNoPadding(body, rule.key, iv);
    }
    return Uint8List.fromList(
      CryptoUtils.aesCbcDecryptBytes(body, key: rule.key, iv: iv),
    );
  }

  /// AES-CBC 无填充：按块解（CBCBlockCipher 跨调用保持链状态，逐块顺序解即可）。
  static Uint8List _aesCbcNoPadding(Uint8List body, List<int> key, List<int> iv) {
    final cbc = CBCBlockCipher(AESEngine())
      ..init(
        false,
        ParametersWithIV(
          KeyParameter(Uint8List.fromList(key)),
          Uint8List.fromList(iv),
        ),
      );
    final out = Uint8List(body.length);
    final block = Uint8List(16);
    for (var off = 0; off < body.length; off += 16) {
      block.setAll(0, Uint8List.sublistView(body, off, off + 16));
      cbc.processBlock(block, 0, out, off);
    }
    return out;
  }

  /// AES-ECB：pkcs7 / none 填充。
  static Uint8List _aesEcb(Uint8List bytes, ImageDecryptRule rule) {
    final Uint8List body = _stripPrefix(bytes, rule);
    if (body.isEmpty || body.length % 16 != 0) return bytes;
    if (rule.padding != 'none') {
      return Uint8List.fromList(CryptoUtils.aesEcbDecrypt(body, key: rule.key));
    }
    final ecb = ECBBlockCipher(AESEngine())
      ..init(false, KeyParameter(Uint8List.fromList(rule.key)));
    final out = Uint8List(body.length);
    final block = Uint8List(16);
    for (var off = 0; off < body.length; off += 16) {
      block.setAll(0, Uint8List.sublistView(body, off, off + 16));
      ecb.processBlock(block, 0, out, off);
    }
    return out;
  }

  /// RC4 流密码（字节级；CryptoUtils.rc4 返回 String，不适合二进制）。
  static Uint8List _rc4(Uint8List data, List<int> key) {
    if (key.isEmpty) return data;
    final S = List<int>.generate(256, (i) => i);
    int j = 0;
    for (int i = 0; i < 256; i++) {
      j = (j + S[i] + key[i % key.length]) & 0xff;
      final t = S[i];
      S[i] = S[j];
      S[j] = t;
    }
    final out = Uint8List(data.length);
    int a = 0, b = 0;
    for (int i = 0; i < data.length; i++) {
      a = (a + 1) & 0xff;
      b = (b + S[a]) & 0xff;
      final t = S[a];
      S[a] = S[b];
      S[b] = t;
      out[i] = data[i] ^ S[(S[a] + S[b]) & 0xff];
    }
    return out;
  }

  /// 重复密钥 XOR。
  static Uint8List _xor(Uint8List data, List<int> key) {
    if (key.isEmpty) return data;
    final out = Uint8List(data.length);
    for (int i = 0; i < data.length; i++) {
      out[i] = data[i] ^ key[i % key.length];
    }
    return out;
  }

  /// 测试/源删除辅助：清空注册表。
  static void clear() => _rules.clear();
}

/// 从源 JSON `imageTransform.decrypt` 段构造规则。
///
/// `keyEncoding` / `ivEncoding`：`utf8`（缺省）/ `base64` / `hex`。
/// AES 系列校验密钥长度 16/24/32；rc4/xor 接受任意非空密钥。
ImageDecryptRule? imageDecryptRuleFromJson(Map<String, dynamic>? json) {
  if (json == null) return null;
  final String algo = (json['algo'] as String?)?.toLowerCase() ?? 'aes-cbc';
  const Set<String> supported = <String>{'aes-cbc', 'aes-ecb', 'rc4', 'xor'};
  if (!supported.contains(algo)) return null;
  final String ivSource = (json['ivSource'] as String?) ?? 'prefixBytes';
  final int ivLength = (json['ivLength'] as num?)?.toInt() ?? 16;
  final String padding = (json['padding'] as String?)?.toLowerCase() ?? 'pkcs7';
  final dynamic rawKey = json['key'];
  if (rawKey is! String || rawKey.isEmpty) return null;
  final String keyEncoding =
      (json['keyEncoding'] as String?)?.toLowerCase() ?? 'utf8';
  List<int>? key = _decodeBytes(rawKey, keyEncoding);
  if (key == null) return null;
  if (algo.startsWith('aes') &&
      key.length != 16 &&
      key.length != 24 &&
      key.length != 32) {
    return null;
  }
  // 固定 IV：ivEncoding 缺省沿用 keyEncoding。
  List<int> fixedIv = const <int>[];
  if (ivSource == 'fixed') {
    final dynamic rawIv = json['iv'];
    if (rawIv is! String || rawIv.isEmpty) return null;
    final String ivEncoding =
        (json['ivEncoding'] as String?)?.toLowerCase() ?? keyEncoding;
    fixedIv = _decodeBytes(rawIv, ivEncoding) ?? const <int>[];
  }
  return ImageDecryptRule(
    algo: algo,
    key: key,
    ivSource: ivSource,
    ivLength: ivLength,
    fixedIv: fixedIv,
    padding: padding,
  );
}

/// 按 utf8/base64/hex 解码；失败返回 null。
List<int>? _decodeBytes(String raw, String encoding) {
  switch (encoding) {
    case 'base64':
      try {
        return base64Decode(raw);
      } on FormatException {
        return null;
      }
    case 'hex':
      try {
        return CryptoUtils.hexDecode(raw);
      } on FormatException {
        return null;
      }
    default:
      return utf8.encode(raw);
  }
}
