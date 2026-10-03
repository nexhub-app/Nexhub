import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';

/// pms_javchu.json 配置层验收。v4 起 javchu.com（官方第四镜像域）已停放
/// （80=Namecheap parking、源站 IP 全死），源整体迁移到主域 hanime1.me 的
/// AV 分区——与 pms_hanime 同平台同结构，仅 genre/tags/sort 值域不同。
/// 验收用引擎真实的 PluginConfig.fromJson 消费交付物文件。
void main() {
  late PluginConfig source;

  setUpAll(() {
    final file = File('plugins/builtin/pms_javchu.json');
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    source = PluginConfig.fromJson(map);
  });

  group('pms_javchu 独立源配置', () {
    test('基础块：独立 id、同构路由集', () {
      expect(source.id, 'pms_javchu');
      expect(source.type, SourceType.animeSource);
      expect(source.site.baseUrl, 'https://hanime1.me');
      for (final r in const [
        'latest',
        'search',
        'detail',
        'episodes',
        'category',
        'video',
        'favorites',
        'favoritesAdd',
      ]) {
        expect(source.routes.containsKey(r), isTrue, reason: '路由 $r 就位');
      }
    });

    test('hosts：hanime1.me 五条 Cloudflare IP（与 hanime 源同池，沙箱 --resolve 实证服务 AV 分区）', () {
      final hosts = source.network?.hosts ?? const <dynamic>[];
      final meHosts = hosts.where((h) => '${h.host}' == 'hanime1.me').toList();
      expect(meHosts.length, 5,
          reason: 'v4 迁移后与 pms_hanime 同池：5 条 CF 边缘 IP');
      final ips = meHosts.map((h) => '${h.ip}').toSet();
      expect(ips, <String>{
        '172.64.229.154', '162.159.0.1', '108.162.192.1',
        '172.64.33.1', '104.19.0.1',
      });
      expect(meHosts.every((h) => '${h.enabled}' == 'true'), isTrue);
      // 死域残留必须清干净——停放域 IP（2.59 WorldStream 死源站 /
      // 104.219 Namecheap 停放页）留着只会 TLS 炸或拉到 parking 页。
      expect(
        ips.intersection(<String>{'2.59.170.20', '104.219.250.37'}),
        isEmpty,
      );
    });

    test('死域零残留：javchu.com 域名在交付物中完全消失', () {
      final raw = File('plugins/builtin/pms_javchu.json').readAsStringSync();
      expect(raw.contains('javchu.com'), isFalse,
          reason: 'javchu.com 已停放（Namecheap parking + 源站 IP 全死），'
              '26 处引用必须全部迁 hanime1.me');
      // mirrors/hosts/cookieDomains 全部指向主域。
      for (final m in source.site.mirrors) {
        expect(m.domain, 'hanime1.me');
        expect(m.baseUrl, 'https://hanime1.me');
      }
      final hosts = source.network?.hosts ?? const <dynamic>[];
      expect(hosts.every((h) => '${h.host}' == 'hanime1.me'), isTrue);
      final domains = source.network?.cookieDomains ?? const <String>[];
      expect(domains, <String>['hanime1.me', '.hanime1.me']);
    });

    test('评论/收藏链路同构落地', () {
      final comments = source.comments;
      expect(comments!.login!.url, 'https://hanime1.me/login');
      // Laravel 会话键名同构（参考库四站共用同一 cookie jar 语义）。
      expect(comments.login!.checkCookie, 'hanime1_session');
      expect(comments.routes.containsKey('list'), isTrue);
      expect(comments.routes.containsKey('replies'), isTrue);
      final wf = source.webFavorite!;
      expect(wf.route, 'favorites');
      expect(wf.addRoute, 'favoritesAdd');
      expect(source.hasWebFavoriteBrowse, isTrue);
      expect(source.hasWebFavoriteAdd, isTrue);
      final ov = source.parser.overrides ?? const <String, ParserOverride>{};
      expect(ov['favList']?.type, 'script');
      expect(ov['folders']?.type, 'script');
      expect(ov['favoritesAdd']?.type, 'script');
    });

    test('v3 筛选对齐 AV 站：genre 6 值 + tags 面 + tags[] 数组占位', () {
      final raw = File('plugins/builtin/pms_javchu.json').readAsStringSync();
      // javchu 不再复用 hanime 的里番向 genre 值。
      for (final banned in const ['裏番', '泡麵番', 'Motion Anime', '新番預告']) {
        expect(raw.contains(banned), isFalse,
            reason: 'AV 站无此类型：$banned');
      }
      expect(source.version, 4);
      expect(source.routes['search']!.url, contains('tags[]={tags}'),
          reason: 'v3 起与 hanime 同构：tags[] 重复参数数组语义');
      expect(raw.contains('&tags={tags}'), isFalse);
      final groups = source.filters?.groups ?? const <FilterGroupConfig>[];
      final byId = {for (final g in groups) g.id: g};
      final genreValues =
          byId['genre']!.options.map((o) => o.value).toSet();
      expect(genreValues, <String>{
        '日本AV', '素人業餘', '高清無碼', 'AI解碼', '國產AV', '國產素人',
      });
      final tagGroup = byId['tags']!;
      expect(tagGroup.multiSelect, isTrue, reason: 'tags 面支持多选');
      final tagValues = tagGroup.options.map((o) => o.value).toSet();
      expect(tagValues, <String>{'中文字幕'});
      final categoryEntries = source.category.categoryEntries;
      final catValues = categoryEntries
          .map((e) => e['id'])
          .toSet();
      expect(catValues, genreValues, reason: '分类与筛选 genre 同值集');
    });

    test('v2 homeSections：AV 站 12 版块参数映射逐一落地', () {
      final sections = source.homeSections;
      expect(sections.length, 12, reason: '参考库 buildCategoryList AV 分支 12 版块');
      expect(sections.every((s) => s.route == 'search'), isTrue);
      HomeSectionConfig sectionOf(String id) =>
          sections.firstWhere((x) => x.id == id);
      Map<String, Object> paramsOf(String id) => sectionOf(id).params;

      expect(sectionOf('latest-av').title, '最新AV');
      expect(paramsOf('latest-av')['genre'], '日本AV');
      expect(paramsOf('latest-release')['sort'], '最新上市');
      expect(paramsOf('latest-upload')['sort'], '最新上傳');
      expect(paramsOf('watching-now')['sort'], '他們在看');
      expect(paramsOf('amateur-nomask')['genre'], '素人業餘');
      expect(paramsOf('amateur-nomask')['sort'], '最新上傳');
      expect(paramsOf('hd-uncensored')['genre'], '高清無碼');
      expect(paramsOf('ai-decensored')['genre'], 'AI解碼');
      expect(paramsOf('china-av')['genre'], '國產AV');
      expect(paramsOf('chinese-amateur')['genre'], '國產素人');
      // javchu 特有：AI生成版块 = tags 中文字幕 + sort（无 genre）。
      expect(paramsOf('chinese-subtitle')['tags'], '中文字幕');
      expect(paramsOf('chinese-subtitle')['sort'], '最新上傳');
      expect(paramsOf('chinese-subtitle').containsKey('genre'), isFalse);
      expect(paramsOf('ranking-today')['sort'], '本日排行');
      expect(paramsOf('ranking-this-month')['sort'], '本月排行');
    });
  });
}
