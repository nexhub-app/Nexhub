/// 源配置模型（PluginConfig）——共创式源码系统的单一自描述单元。
///
/// 一份 JSON 即一个源：声明式 selectors 或内嵌 JS 脚本，社区只写 JSON 即可贡献源，
/// 无需改 Dart、无需重编译。兼容 animeSource / mangaSource / novelSource 三种类型。
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../network/model/source_network_config.dart';

/// 源内容类型，决定解析/浏览/详情/播放的统一语义。
enum SourceType {
  animeSource,
  mangaSource,
  novelSource;

  static SourceType? parse(String? raw) {
    return switch (raw) {
      'animeSource' => animeSource,
      'mangaSource' => mangaSource,
      'novelSource' => novelSource,
      _ => null,
    };
  }

  String get apiName {
    return switch (this) {
      SourceType.animeSource => 'animeSource',
      SourceType.mangaSource => 'mangaSource',
      SourceType.novelSource => 'novelSource',
    };
  }
}

/// 镜像配置（站点主域失效时切换）。
class MirrorConfig {
  final String name;
  final String domain;
  final String baseUrl;

  const MirrorConfig({
    required this.name,
    required this.domain,
    required this.baseUrl,
  });

  factory MirrorConfig.fromJson(Map<String, dynamic> json) => MirrorConfig(
        name: json['name'] as String? ?? '',
        domain: json['domain'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? json['domain'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'domain': domain,
        'baseUrl': baseUrl,
      };
}

/// 站点配置：域名、基址、UA、Cookie、请求头、镜像列表。
class SiteConfig {
  final String domain;
  final String baseUrl;
  final String? userAgent;
  final String? cookies;
  final Map<String, String>? headers;
  final List<MirrorConfig> mirrors;

  const SiteConfig({
    required this.domain,
    required this.baseUrl,
    this.userAgent,
    this.cookies,
    this.headers,
    this.mirrors = const [],
  });

  factory SiteConfig.fromJson(Map<String, dynamic> json) => SiteConfig(
        domain: json['domain'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? json['domain'] as String? ?? '',
        userAgent: json['userAgent'] as String?,
        cookies: json['cookies'] as String?,
        headers: (json['headers'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
        mirrors: (json['mirrors'] as List<dynamic>?)
                ?.cast<Map<String, dynamic>>()
                .map((e) => MirrorConfig.fromJson(e))
                .toList() ??
            const [],
      );

  Map<String, dynamic> toJson() => {
        'domain': domain,
        'baseUrl': baseUrl,
        if (userAgent != null) 'userAgent': userAgent,
        if (cookies != null) 'cookies': cookies,
        if (headers != null) 'headers': headers,
        'mirrors': mirrors.map((e) => e.toJson()).toList(),
      };
}

/// 单个路由（latest/explore/category/search/detail/episodes/video/chapters/images/...）。
class RouteConfig {
  final String url;
  final String method;
  final Map<String, String>? headers;
  final Map<String, String>? params;
  final String? responseType; // json | html
  final ParserOverride? parser; // 路由级解析覆盖

  const RouteConfig({
    required this.url,
    this.method = 'get',
    this.headers,
    this.params,
    this.responseType,
    this.parser,
  });

  /// 兼容字符串写法：`"https://x/search?q={keyword}"` 与对象写法。
  factory RouteConfig.fromJson(dynamic json) {
    if (json is String) {
      return RouteConfig(url: json);
    }
    final map = json as Map<String, dynamic>;
    return RouteConfig(
      url: map['url'] as String,
      method: map['method'] as String? ?? 'get',
      headers: (map['headers'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      ),
      params: (map['params'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      ),
      responseType: map['responseType'] as String?,
      parser: map['parser'] == null
          ? null
          : ParserOverride.fromJson(map['parser'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'method': method,
        if (headers != null) 'headers': headers,
        if (params != null) 'params': params,
        if (responseType != null) 'responseType': responseType,
        if (parser != null) 'parser': parser!.toJson(),
      };
}

/// 解析覆盖（hybrid 模式下针对某个 API 单独指定解析方式）。
///
/// golden 源常见写法：`"overrides": { "<api>": { "function": "parseX", "script": "…", "type": "script" } }`。
/// 旧版解析器用 `entrypoints`（Map<api, 函数名>）表达同样的意图；这里同时兼容两种写法：
/// - [function]：针对「当前 api」直接声明的函数名（golden 覆盖写法）。
/// - [entrypoints]：api→函数名 的映射（旧版写法）。
/// 解析时优先 [function]，回退 [entrypoints][apiName]，再回退 apiName 本身（见 ScriptResolver）。
class ParserOverride {
  final String type; // builtin | script
  final Map<String, String>? entrypoints;
  final String? script;
  final String? function; // golden 覆盖写法：此 override 针对当前 api 的入口函数名

  const ParserOverride({
    required this.type,
    this.entrypoints,
    this.script,
    this.function,
  });

  factory ParserOverride.fromJson(Map<String, dynamic> json) => ParserOverride(
        type: json['type'] as String? ?? 'builtin',
        entrypoints: (json['entrypoints'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
        script: json['script'] as String?,
        function: json['function'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        if (entrypoints != null) 'entrypoints': entrypoints,
        if (script != null) 'script': script,
        if (function != null) 'function': function,
      };
}

/// 解析器配置：builtin / hybrid / script + 内嵌脚本 + 路由级 overrides。
class ParserConfig {
  final String type; // builtin | hybrid | script
  final Map<String, String>? entrypoints;
  final String? script;
  final Map<String, ParserOverride>? overrides;

  const ParserConfig({
    required this.type,
    this.entrypoints,
    this.script,
    this.overrides,
  });

  factory ParserConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ParserConfig(type: 'builtin');
    return ParserConfig(
      type: json['type'] as String? ?? 'builtin',
      entrypoints: (json['entrypoints'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      ),
      script: json['script'] as String?,
      overrides: (json['overrides'] as Map?)?.map(
        (k, v) => MapEntry(
          k.toString(),
          ParserOverride.fromJson(v as Map<String, dynamic>),
        ),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        if (entrypoints != null) 'entrypoints': entrypoints,
        if (script != null) 'script': script,
        if (overrides != null)
          'overrides': overrides!.map((k, v) => MapEntry(k, v.toJson())),
      };

  /// 解析某 API 时实际使用的解析类型（考虑 hybrid overrides）。
  String effectiveTypeFor(String apiName) {
    if (type == 'hybrid' && overrides != null) {
      final o = overrides![apiName];
      if (o != null) return o.type;
    }
    return type;
  }
}

/// 分类配置（MacCMS 动态分类从 `class` 推断；静态分类从 `categoryEntries` 读取）。
class CategoryConfig {
  final bool dynamicCategories;
  final String? categories; // JSONPath / CSS
  final String? id;
  final String? title;
  /// 静态分类列表（适用于无 MacCMS API 的 HTML/JSON 爬虫源）。
  ///
  /// 当 [dynamicCategories] 为 false 且此列表非空时，[MediaApiService.fetchCategories]
  /// 直接返回此列表，分类条即可默认显示。每项形如 `{"id":"1","title":"动作"}`。
  final List<Map<String, String>> categoryEntries;

  const CategoryConfig({
    this.dynamicCategories = false,
    this.categories,
    this.id,
    this.title,
    this.categoryEntries = const <Map<String, String>>[],
  });

  factory CategoryConfig.fromJson(Map<String, dynamic>? json) => CategoryConfig(
        dynamicCategories: json?['dynamicCategories'] as bool? ?? false,
        categories: json?['categories'] as String?,
        id: json?['id'] as String?,
        title: json?['title'] as String?,
        categoryEntries: (json?['categoryEntries'] as List<dynamic>?)
                ?.map((e) => Map<String, String>.from(e as Map))
                .toList(growable: false) ??
            const <Map<String, String>>[],
      );

  Map<String, dynamic> toJson() => {
        'dynamicCategories': dynamicCategories,
        if (categories != null) 'categories': categories,
        if (id != null) 'id': id,
        if (title != null) 'title': title,
        if (categoryEntries.isNotEmpty) 'categoryEntries': categoryEntries,
      };
}

/// 首页板块配置（共创式：源自行声明首页要展示的多个板块）。
///
/// 每个板块复用源已有的 [RouteConfig]（如 latest / category / explore）与对应
/// 解析器，配合 [params] 做占位符替换。这样"网站首页有几个榜单/分区"完全由源
/// 决定，app 只负责竖向堆叠渲染，绝不写死站点逻辑。
///
/// 向后兼容：源未声明 `homeSections` 时，[MediaApiService] 回退为单块「最新更新」
/// （即调用 `latest` 路由），与旧行为一致。
class HomeSectionConfig {
  /// 板块唯一标识（同一源内不重复），也用于「查看更多」跳转定位。
  final String id;

  /// 板块标题（用户可见）。为空时 UI 用 [id] 兜底。
  final String title;

  /// 该板块调用的路由名（须存在于 `routes` 中，如 latest/category/explore）。
  final String route;

  /// 路由占位符替换值（如 `{"category":"hots"}` 替换 `{category}`）。
  final Map<String, String> params;

  /// 展示样式提示：grid（网格，默认）| rank（排行，带序号）| scroll（横向滑动）。
  final String style;

  /// 板块最多展示条目数（0 = 不限制，取解析结果全部）。
  final int limit;

  /// 是否显示「查看更多」入口（跳转到该 route 的完整列表页）。
  final bool more;

  const HomeSectionConfig({
    required this.id,
    this.title = '',
    required this.route,
    this.params = const <String, String>{},
    this.style = 'grid',
    this.limit = 12,
    this.more = true,
  });

  factory HomeSectionConfig.fromJson(Map<String, dynamic> json) =>
      HomeSectionConfig(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        route: json['route'] as String? ?? 'latest',
        params: (json['params'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            ) ??
            const <String, String>{},
        style: json['style'] as String? ?? 'grid',
        limit: (json['limit'] as num?)?.toInt() ?? 12,
        more: json['more'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (title.isNotEmpty) 'title': title,
        'route': route,
        if (params.isNotEmpty) 'params': params,
        'style': style,
        'limit': limit,
        'more': more,
      };
}

/// 单个筛选选项（值 + 展示标签）。
class FilterOptionConfig {
  /// 选项值，用于替换该分组 [FilterGroupConfig.param] 对应的占位符。
  final String value;

  /// 用户可见标签。
  final String label;

  const FilterOptionConfig({required this.value, required this.label});

  factory FilterOptionConfig.fromJson(Map<String, dynamic> json) =>
      FilterOptionConfig(
        value: (json['value'] ?? json['id'] ?? '').toString(),
        label: (json['label'] ?? json['name'] ?? json['value'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {'value': value, 'label': label};
}

/// 单个筛选分组（如「地区」「题材」「排序」）。
///
/// 选中某选项后，app 以 [route]（缺省用 [SourceFilterConfig.route]）调用对应路由，
/// 并把选项 [FilterOptionConfig.value] 代入 [param] 占位符。筛选维度完全由源声明，
/// 修复旧版「筛选按钮写死年份/地区/排序/状态」的问题。
class FilterGroupConfig {
  final String id;
  final String title;

  /// 该分组驱动的路由名（缺省继承 [SourceFilterConfig.route]）。
  final String? route;

  /// 该分组选项值要代入的路由占位符名（如 `category` / `keyword` / `sort`）。
  final String param;

  /// 是否允许多选（默认单选）。
  final bool multiSelect;

  final List<FilterOptionConfig> options;

  const FilterGroupConfig({
    required this.id,
    this.title = '',
    this.route,
    required this.param,
    this.multiSelect = false,
    this.options = const <FilterOptionConfig>[],
  });

  factory FilterGroupConfig.fromJson(Map<String, dynamic> json) =>
      FilterGroupConfig(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        route: json['route'] as String?,
        param: json['param'] as String? ?? 'category',
        multiSelect: json['multiSelect'] as bool? ?? false,
        options: (json['options'] as List<dynamic>?)
                ?.whereType<Map>()
                .map((e) =>
                    FilterOptionConfig.fromJson(Map<String, dynamic>.from(e)))
                .toList(growable: false) ??
            const <FilterOptionConfig>[],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (title.isNotEmpty) 'title': title,
        if (route != null) 'route': route,
        'param': param,
        if (multiSelect) 'multiSelect': multiSelect,
        'options': options.map((e) => e.toJson()).toList(),
      };
}

/// 源级筛选配置（若干筛选分组的集合）。
///
/// 向后兼容：源未声明 `filters` 时，[MediaApiService] 可从 `selectors.category`
/// 的 categories + tags 自动兜底生成筛选分组，使既有源无需改 JSON 也能获得动态筛选。
class SourceFilterConfig {
  /// 各分组缺省驱动的路由名。
  final String route;

  /// 全局筛选分组（站点的统一维度，或作为未声明分类覆盖时的兜底）。
  final List<FilterGroupConfig> groups;

  /// 按分类 id 的筛选分组覆盖（如 dalvdm：热门新番无年份、动漫大全/电影有年份）。
  /// key 为分类 [CategoryEntry.id]（如 "23"/"20"/"24"）。命中时优先用它，
  /// 否则回退 [groups]。实现「每个分类筛选各不相同」而无需在 Dart 写死。
  final Map<String, List<FilterGroupConfig>> byCategory;

  /// 按分类 id 的默认筛选值（用户未选时由源声明补齐，用户选中值优先覆盖）。
  /// 用于 MacCMS 等「show 路由第 1 页需带默认 sort/year」的站点：
  /// 如 233动漫国漫(2) 真值链接恒带 sort=hits、year=2026，用户不手动选这些维度时，
  /// 若不补齐会让 show 路由拼出空 sort/year 段，服务端重写规则不匹配 → 筛选无结果。
  /// key 为分类 id（如 "2"）；value 为「占位符名→默认值」映射（如 {sort:hits,year:2026}）。
  /// 仅作用于声明了的分类，其余分类返回空（不强行套用全局默认，避免破坏
  /// 剧场/美漫/特摄等「sort/year 本就应为空」的分类）。
  final Map<String, Map<String, String>> defaults;

  const SourceFilterConfig({
    this.route = 'category',
    this.groups = const <FilterGroupConfig>[],
    this.byCategory = const <String, List<FilterGroupConfig>>{},
    this.defaults = const <String, Map<String, String>>{},
  });

  /// 取某分类的筛选分组；声明了分类覆盖且命中则返回它，否则回退全局 [groups]。
  List<FilterGroupConfig> groupsFor(String categoryId) {
    if (categoryId.isNotEmpty && byCategory.containsKey(categoryId)) {
      return byCategory[categoryId]!;
    }
    return groups;
  }

  /// 取某分类的默认筛选值（用户未选时由源声明补齐，如国漫 sort=hits/year=2026）。
  /// 用户选中值优先于默认（合并在调用方 [_categoryPageVars] 处理）。
  Map<String, String> defaultsFor(String categoryId) {
    if (categoryId.isNotEmpty && defaults.containsKey(categoryId)) {
      return Map<String, String>.from(defaults[categoryId]!);
    }
    return const <String, String>{};
  }

  bool get isEmpty => groups.isEmpty && byCategory.isEmpty;

  factory SourceFilterConfig.fromJson(Map<String, dynamic> json) =>
      SourceFilterConfig(
        route: json['route'] as String? ?? 'category',
        groups: (json['groups'] as List<dynamic>?)
                ?.whereType<Map>()
                .map((e) =>
                    FilterGroupConfig.fromJson(Map<String, dynamic>.from(e)))
                .toList(growable: false) ??
            const <FilterGroupConfig>[],
        byCategory: (json['byCategory'] as Map<Object?, Object?>?)?.map(
              (k, v) => MapEntry(
                k.toString(),
                (v as List<dynamic>)
                    .whereType<Map>()
                    .map((e) =>
                        FilterGroupConfig.fromJson(Map<String, dynamic>.from(e)))
                    .toList(growable: false),
              ),
            ) ??
            const <String, List<FilterGroupConfig>>{},
        defaults: (json['defaults'] as Map<Object?, Object?>?)?.map(
              (k, v) => MapEntry(
                k.toString(),
                (v as Map<Object?, Object?>)
                    .map((ik, iv) => MapEntry(ik.toString(), iv.toString())),
              ),
            ) ??
            const <String, Map<String, String>>{},
      );

  Map<String, dynamic> toJson() => {
        'route': route,
        'groups': groups.map((e) => e.toJson()).toList(),
        if (byCategory.isNotEmpty)
          'byCategory': byCategory
              .map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
        if (defaults.isNotEmpty)
          'defaults': defaults.map((k, v) => MapEntry(k, Map<String, String>.from(v))),
      };
}

/// 反盗链配置（补 Referer / 指定 UA 等）。
class AntiHotlinkingConfig {
  final String? referer;
  final Map<String, String>? headers;
  /// 部分源（如 pms_fsdm / pms_cycani 等）要求携带特定 User-Agent 才能绕开
  /// 反盗链（C1）。旧模型只读了 referer，丢失 userAgent 导致这类源请求被拒。
  final String? userAgent;

  const AntiHotlinkingConfig({this.referer, this.headers, this.userAgent});

  factory AntiHotlinkingConfig.fromJson(Map<String, dynamic>? json) =>
      AntiHotlinkingConfig(
        referer: json?['referer'] as String?,
        headers: (json?['headers'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
        userAgent: json?['userAgent'] as String?,
      );
}

/// WebView 验证配置。
class WebviewConfig {
  final bool adblock;
  final int timeoutSeconds;

  const WebviewConfig({this.adblock = true, this.timeoutSeconds = 20});

  factory WebviewConfig.fromJson(Map<String, dynamic>? json) => WebviewConfig(
        adblock: json?['adblock'] as bool? ?? true,
        timeoutSeconds: json?['timeoutSeconds'] as int? ?? 20,
      );
}

/// 评论登录配置（comments.login 段）。
///
/// - [url]：WebView 登录页地址。
/// - [checkCookie]：Cookie 中出现该键名即视为已登录（快速判断）。
/// - [checkUrl] + [loggedInSelector]：可选的探测端点二次确认
///   （GET checkUrl，选择器命中非空即登录有效）。
class CommentsLoginConfig {
  final String? url;
  final String? checkCookie;
  final String? checkUrl;
  final String? loggedInSelector;

  const CommentsLoginConfig({
    this.url,
    this.checkCookie,
    this.checkUrl,
    this.loggedInSelector,
  });

  factory CommentsLoginConfig.fromJson(Map<String, dynamic> json) =>
      CommentsLoginConfig(
        url: json['url'] as String?,
        checkCookie: json['checkCookie'] as String?,
        checkUrl: json['checkUrl'] as String?,
        loggedInSelector: json['loggedInSelector'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (url != null) 'url': url,
        if (checkCookie != null) 'checkCookie': checkCookie,
        if (checkUrl != null) 'checkUrl': checkUrl,
        if (loggedInSelector != null) 'loggedInSelector': loggedInSelector,
      };
}

/// 评论配置（可选 comments 段）——源声明评论路由与登录方式。
///
/// - [routes]：复用 [RouteConfig]，仅 `list` 必需；`replies` / `post` /
///   `reply` / `like` / `report` 均可选——未声明的操作对应按钮不渲染。
/// - [selectors]：声明式选择器（JSONPath / CSS / XPath，与顶层 selectors
///   同引擎）：items / commentId / author / avatar / content / time /
///   likeCount / replyCount / success 等。
/// - [login]：登录方式声明，缺省表示源不支持登录（只读评论）。
/// - [provider]：预留扩展点，默认 `source`；`bangumi` 本期仅解析不实现。
///
/// 源未声明该段（[PluginConfig.comments] 为 null）时，详情页完全不渲染
/// 任何评论 UI 元素；旧源 JSON 无需修改，零破坏向后兼容。
class CommentsConfig {
  final String provider; // source | bangumi（预留）
  final Map<String, RouteConfig> routes;
  final Map<String, dynamic>? selectors;
  final CommentsLoginConfig? login;

  const CommentsConfig({
    this.provider = 'source',
    this.routes = const {},
    this.selectors,
    this.login,
  });

  factory CommentsConfig.fromJson(Map<String, dynamic> json) {
    final routesMap = <String, RouteConfig>{};
    final rawRoutes = json['routes'] as Map?;
    if (rawRoutes != null) {
      rawRoutes.forEach((k, v) {
        routesMap[k.toString()] = RouteConfig.fromJson(v);
      });
    }
    return CommentsConfig(
      provider: json['provider'] as String? ?? 'source',
      routes: routesMap,
      selectors: json['selectors'] as Map<String, dynamic>?,
      login: json['login'] is Map
          ? CommentsLoginConfig.fromJson(
              Map<String, dynamic>.from(json['login'] as Map))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'routes': routes.map((k, v) => MapEntry(k, v.toJson())),
        if (selectors != null) 'selectors': selectors,
        if (login != null) 'login': login!.toJson(),
      };

  /// 是否声明了必需的列表路由（未声明则评论功能不可用）。
  bool get hasList => routes.containsKey('list');

  /// 某操作路由是否已声明（未声明 → 对应按钮不渲染）。
  bool hasRoute(String name) => routes.containsKey(name);

  /// 是否支持登录（声明了 login.url 或 checkCookie）。
  bool get supportsLogin =>
      login != null && (login!.url != null || login!.checkCookie != null);
}

/// 将源 JSON 里的 version 规范为 int（缺省 1）。
/// 支持 int / 数字 / "12" / "1.3.0"（取首段），方便源作者用简单递增整数版本号。
int _coerceVersion(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) {
    final first = v.split('.').first;
    return int.tryParse(first) ?? 1;
  }
  return 1;
}

/// 完整源配置（PluginConfig）。
class PluginConfig {
  final String id;
  final String name;
  final SourceType type;
  final String? responseType; // json | html
  final bool useWebview;
  final SiteConfig site;
  final ParserConfig parser;
  final Map<String, RouteConfig> routes;
  final Map<String, dynamic>? selectors; // 声明式选择器（JSONPath / CSS / XPath）
  final CategoryConfig category;
  /// 首页多板块配置（源自行声明）。为空 → 回退单块「最新更新」。
  final List<HomeSectionConfig> homeSections;
  /// 动态筛选配置（源自行声明）。为 null → 服务层从 category+tags 兜底生成。
  final SourceFilterConfig? filters;
  final bool stealthMode;
  final AntiHotlinkingConfig antiHotlinking;
  final WebviewConfig webviewConfig;
  /// 评论配置（可选）。为 null → 详情页不渲染任何评论 UI。
  final CommentsConfig? comments;
  final bool deprecated;
  final bool enabled;
  final bool enabledExplore;
  final bool isHidden;
  final String? migrationMessage;
  final String? engine; // 保留字段，校验器不消费
  /// 源级网络覆盖（可选 `network` 块）。为 null → 该源完全继承全局网络配置。
  final SourceNetworkConfig? network;
  /// 源版本号（整数，缺省 1）。导入时 **≥ 已安装版本** 才覆盖（高版本升级 /
  /// 同版本刷新），**< 已安装版本** 不覆盖（防止误装旧版冲掉新源）。
  final int version;

  const PluginConfig({
    required this.id,
    required this.name,
    required this.type,
    this.responseType,
    this.useWebview = false,
    required this.site,
    required this.parser,
    this.routes = const {},
    this.selectors,
    this.category = const CategoryConfig(),
    this.homeSections = const <HomeSectionConfig>[],
    this.filters,
    this.stealthMode = true,
    this.antiHotlinking = const AntiHotlinkingConfig(),
    this.webviewConfig = const WebviewConfig(),
    this.comments,
    this.deprecated = false,
    this.enabled = true,
    this.enabledExplore = true,
    this.isHidden = false,
    this.migrationMessage,
    this.engine,
    this.network,
    this.version = 1,
  });

  factory PluginConfig.fromJson(Map<String, dynamic> json) {
    final type = SourceType.parse(json['type'] as String?);
    if (type == null) {
      throw const PluginConfigException('unknown source type');
    }
    final routesMap = <String, RouteConfig>{};
    final rawRoutes = json['routes'] as Map?;
    if (rawRoutes != null) {
      rawRoutes.forEach((k, v) {
        routesMap[k.toString()] = RouteConfig.fromJson(v);
      });
    }
    return PluginConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      type: type,
      responseType: json['responseType'] as String?,
      useWebview: json['useWebview'] as bool? ?? false,
      site: SiteConfig.fromJson(json['site'] as Map<String, dynamic>),
      parser: ParserConfig.fromJson(json['parser'] as Map<String, dynamic>?),
      routes: routesMap,
      selectors: json['selectors'] as Map<String, dynamic>?,
      category: CategoryConfig.fromJson(json['category'] as Map<String, dynamic>?),
      homeSections: (json['homeSections'] as List<dynamic>?)
              ?.whereType<Map>()
              .map((e) => HomeSectionConfig.fromJson(
                  Map<String, dynamic>.from(e)))
              .toList(growable: false) ??
          const <HomeSectionConfig>[],
      filters: json['filters'] is Map
          ? SourceFilterConfig.fromJson(
              Map<String, dynamic>.from(json['filters'] as Map))
          : null,
      stealthMode: json['stealthMode'] as bool? ?? true,
      antiHotlinking:
          AntiHotlinkingConfig.fromJson(json['antiHotlinking'] as Map<String, dynamic>?),
      webviewConfig: WebviewConfig.fromJson(json['webviewConfig'] as Map<String, dynamic>?),
      comments: json['comments'] is Map
          ? CommentsConfig.fromJson(
              Map<String, dynamic>.from(json['comments'] as Map))
          : null,
      deprecated: json['deprecated'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
      enabledExplore: json['enabledExplore'] as bool? ?? true,
      isHidden: json['isHidden'] as bool? ?? false,
      migrationMessage: json['migrationMessage'] as String?,
      engine: json['engine'] as String?,
      network: json['network'] is Map
          ? SourceNetworkConfig.fromJson(
              Map<String, dynamic>.from(json['network'] as Map))
          : null,
      version: _coerceVersion(json['version']),
    );
  }

  /// 从 JSON 字符串构造。
  factory PluginConfig.fromJsonString(String source) =>
      PluginConfig.fromJson(jsonDecode(source) as Map<String, dynamic>);

  Map<String, dynamic> toJson() => {
        'id': id,
        'version': version,
        'name': name,
        'type': type.apiName,
        if (responseType != null) 'responseType': responseType,
        'useWebview': useWebview,
        'site': site.toJson(),
        'parser': parser.toJson(),
        'routes': routes.map((k, v) => MapEntry(k, v.toJson())),
        if (selectors != null) 'selectors': selectors,
        'category': category.toJson(),
        if (homeSections.isNotEmpty)
          'homeSections': homeSections.map((e) => e.toJson()).toList(),
        if (filters != null) 'filters': filters!.toJson(),
        'stealthMode': stealthMode,
        'antiHotlinking': {
          'referer': antiHotlinking.referer,
          if (antiHotlinking.userAgent != null)
            'userAgent': antiHotlinking.userAgent,
        },
        'webviewConfig': {
          'adblock': webviewConfig.adblock,
          'timeoutSeconds': webviewConfig.timeoutSeconds,
        },
        if (comments != null) 'comments': comments!.toJson(),
        'deprecated': deprecated,
        'enabled': enabled,
        'enabledExplore': enabledExplore,
        'isHidden': isHidden,
        if (migrationMessage != null) 'migrationMessage': migrationMessage,
        if (network != null) 'network': network!.toJson(),
      };

  bool get isDeprecated => deprecated;
  bool get isEnabled => enabled;

  /// 复制并修改部分字段（用于启用/禁用/隐藏等状态变更）。
  PluginConfig copyWith({
    bool? enabled,
    bool? enabledExplore,
    bool? isHidden,
    bool? deprecated,
    String? migrationMessage,
    SourceNetworkConfig? network,
    int? version,
  }) =>
      PluginConfig(
        id: id,
        name: name,
        type: type,
        responseType: responseType,
        useWebview: useWebview,
        site: site,
        parser: parser,
        routes: routes,
        selectors: selectors,
        category: category,
        homeSections: homeSections,
        filters: filters,
        stealthMode: stealthMode,
        antiHotlinking: antiHotlinking,
        webviewConfig: webviewConfig,
        comments: comments,
        deprecated: deprecated ?? this.deprecated,
        enabled: enabled ?? this.enabled,
        enabledExplore: enabledExplore ?? this.enabledExplore,
        isHidden: isHidden ?? this.isHidden,
        migrationMessage: migrationMessage ?? this.migrationMessage,
        engine: engine,
        network: network ?? this.network,
        version: version ?? this.version,
      );

  /// 必填字段校验，返回错误列表（空 = 通过）。
  List<String> validate() {
    final errors = <String>[];
    if (id.isEmpty) errors.add('missing: id');
    if (name.isEmpty) errors.add('missing: name');
    if (site.baseUrl.isEmpty) errors.add('missing: site.baseUrl');
    if (type == SourceType.animeSource && !routes.containsKey('latest')) {
      errors.add('animeSource requires route "latest"');
    }
    // 源级 network 块校验（作为警告汇总，不阻断启用）。
    final net = network;
    if (net != null) {
      for (final key in net.validate()) {
        errors.add('network: $key');
      }
    }
    return errors;
  }

  /// 解析路由 URL：替换 {page}/{keyword}/{id}/{category}/{cid}/{mid}/{chapterId}
  /// 等占位符，相对路径按 activeBaseUrl 补全；绝对 URL 替换 host 指向新镜像
  /// （P8.2.2 §廿二 镜像切换后 route 指向新镜像）。
  String resolveRouteUrl(
    String apiName, {
    required String activeBaseUrl,
    Map<String, String> vars = const {},
  }) {
    // 评论路由命名空间：`comments.list` / `comments.post` 等查找
    // comments.routes，占位符替换 / 镜像切换 / 相对路径补全全部复用。
    final route = _routeFor(apiName);
    if (route == null) {
      throw PluginConfigException('route not found: $apiName');
    }
    var url = route.url;
    // video 路由通常为 `{url}` 直通：调用方已传入播放页绝对地址时直接返回，
    // 否则会被 activeBaseUrl 前缀拼接成 `https://base/https://episode` 双 host 坏链，
    // 导致播放页抓取失败、解析不到视频源。此修复对所有源通用，不针对特定站点。
    if (apiName == 'video' && url.trim() == '{url}') {
      final rawUrl = vars['url'];
      if (rawUrl != null && rawUrl.isNotEmpty) {
        // 绝对地址（含 host）直接返回，避免被 activeBaseUrl 前缀成双 host 坏链
        // （如 `https://base/https://episode`），导致播放页抓取失败、解析不到视频。
        if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) {
          return rawUrl;
        }
        // 根相对地址（如 `/anime/.../play/1.html`，233 动漫播放页即此类）：
        // base 先去掉尾斜杠再拼接，否则会出现 `https://host//anime/...` 双斜杠
        // 坏链，播放器拿到错误地址 → 0×0 黑屏。对齐下方通用拼接逻辑但提前返回，
        // 避免先拼成 `host/{url}` 再 replaceAll('{url}', '/anime/...') 产生双斜杠。
        final base = activeBaseUrl.endsWith('/')
            ? activeBaseUrl.substring(0, activeBaseUrl.length - 1)
            : activeBaseUrl;
        if (rawUrl.startsWith('/')) {
          return '$base$rawUrl';
        }
        // 纯相对地址：基于 base 目录 resolve。
        return Uri.parse(base.endsWith('/') ? base : '$base/')
            .resolve(rawUrl)
            .toString();
      }
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      // 绝对 URL：替换 host 指向新镜像（保留 path/query）
      url = _replaceHost(url, activeBaseUrl);
    } else {
      final base = activeBaseUrl.endsWith('/')
          ? activeBaseUrl.substring(0, activeBaseUrl.length - 1)
          : activeBaseUrl;
      url = url.startsWith('/') ? '$base$url' : '$base/$url';
    }
    vars.forEach((k, v) {
      // 用户搜索词等自由文本必须 URL 编码：否则中文关键词（如「海贼王」）原样
      // 塞进查询串会导致 GET 请求非法 / 被服务器误解 → 搜索返回错乱或空
      // （中文站「作品搜索内容不正确」「主演搜索不全」的根因）。
      // 此外，筛选值也可能是中文（如 MacCMS 站 genre=「奇幻」直接作为路径段
      // `/show/2--hits-奇幻--...html`）：服务端期望 %E5%A5%87%E5%B9%BB 编码形式，
      // 原样插入中文会导致匹配失败返回空列表（「筛选无结果」的通用根因）。
      // 规则：keyword 恒编码；其余占位符仅当值含非 ASCII 字符且不是 URL/路径
      // （不含 '/' 与 ':'）时编码——避免误编码 {url}/{detailUrl} 等整段地址。
      // 用 encodeComponent（空格→%20）兼顾查询串与路径段两种落点。
      final String value;
      if (apiName == 'show' &&
          k == 'page' &&
          (v == '1' || v == '0')) {
        // MacCMS show 路由第 1 页段为空：真值形如 /show/2--hits-奇幻--------2026.html
        // （page 段为空段，共 8 连字符）。若注入 "1" 会拼出 -----1---，服务端重写
        // 规则不匹配 → 返回空/404，筛选无结果。仅作用于 show 路由，避免影响
        // latest 等查询串分页（那些需保留 page=1）。第 2 页起 page>=2 正常保留。
        value = '';
      } else if (k == 'keyword') {
        value = Uri.encodeComponent(v);
      } else if (v.contains(RegExp(r'[^\x00-\x7F]')) &&
          !v.contains('/') &&
          !v.contains(':')) {
        value = Uri.encodeComponent(v);
      } else {
        value = v;
      }
      url = url.replaceAll('{$k}', value);
    });
    // 兼容旧版「采集api」导出的源：详情/选集路由常用 {season_id}/{sid}/{avid}
    // 占位，而新解析器统一用 {id}。旧应用能正常解析正是靠这些别名映射。
    // 不映射会导致占位被清空成 "...&id=" 从而「详情页空」。
    // 注意：必须无条件执行别名映射——上一版把这段放进 `if (idVal != null)`
    // 里，导致调用方只传 {id} 时 {season_id} 永远不被替换，cleanup 后变成
    // `/detail/id/.html` 这种坏 URL，详情页静默失败（历史记录点进去灰屏的根因）。
    final idVal = vars['id'];
    if (idVal != null && idVal.isNotEmpty) {
      url = url
          .replaceAll('{season_id}', idVal)
          .replaceAll('{sid}', idVal)
          .replaceAll('{avid}', idVal);
    }
    // 详情路由兜底：若仍有未替换的占位符（如调用方只传了 {id} 而 URL 用了
    // {season_id}），且本次携带了 detailUrl，则直接用真实详情地址替换，避免
    // 构造出坏 URL。历史记录条目常只有 detailUrl 这一个可用标识，这条兜底能让
    // 「从历史点进去」的详情页稳定加载，而非灰屏。
    if (apiName == 'detail' && url.contains('{')) {
      final detailUrl = vars['detailUrl'];
      if (detailUrl != null && detailUrl.isNotEmpty) {
        url = detailUrl;
      }
    }
    // 播放/剧集兜底：若仍有未替换占位符（如 video 路由 /play{season_id}-1-
    // {episode_id}/ 只拿到 {url} 而 season_id/episode_id 缺失），且携带了完整的
    // 剧集地址 url（含所属线路的播放页），直接使用它，避免被 cleanup 清成
    // /play-1-/ 这种坏地址。这让「剧集 url 即播放页（含线路）」的多线路场景对
    // 所有源通用生效，而无需给每个源写死 season_id/episode_id 拆解规则。
    if (url.contains('{')) {
      final rawUrl = vars['url'];
      if (rawUrl != null && rawUrl.isNotEmpty) {
        if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) {
          url = rawUrl;
        } else if (rawUrl.startsWith('/')) {
          final b = activeBaseUrl.endsWith('/')
              ? activeBaseUrl.substring(0, activeBaseUrl.length - 1)
              : activeBaseUrl;
          url = '$b$rawUrl';
        }
      }
    }
    // Clean up unreplaced placeholders (e.g. {category} when loading home
    // page without a category). Prevents malformed URLs like
    // /vodshow/{category}--------1---.html which cause 404/error pages
    // and silent empty-list failures.
    // 注意：正则用 `[^}]*` 以兼容空占位符 `{}`，避免残留花括号污染 URL。
    url = url.replaceAll(RegExp(r'\{[^}]*\}'), '');
    debugPrint('[PluginConfig] resolveRouteUrl: apiName=$apiName finalUrl=$url');
    return url;
  }

  /// 将 [originalUrl] 的 scheme+host 替换为 [newBaseUrl] 的 scheme+host，
  /// 保留原 URL 的 path/query/fragment。
  ///
  /// 关键：必须用字符串方式仅替换「scheme://host[:port]」前缀，**不能**走
  /// `Uri.parse(...).toString()`——后者会把 query 里的 `{page}`/`{id}` 等占位符
  /// 重新编码成 `%7Bpage%7D`，导致后续 `replaceAll('{page}', v)` 永远匹配不到，
  /// 占位符原样留在 URL 里（如 `page=%7Bpage%7D`），站点收到非法参数返回错误页，
  /// 解析器拿到 HTML 而非 JSON → 列表/详情/选集/图片全部解析为空。这是「媒体与
  /// 漫画都解析不到内容」的根因之一。
  static String _replaceHost(String originalUrl, String newBaseUrl) {
    try {
      final base = Uri.parse(newBaseUrl);
      final scheme = base.scheme.isNotEmpty ? base.scheme : 'https';
      final host = base.host;
      // 镜像站通常为标准端口：新基址是 80/443/0 时省略端口（丢弃原 URL 的非标准
      // 端口，避免拼出 mirror.com:8080 这类错址）；新基址带非标准端口则保留。
      final newPort = base.port;
      final portStr =
          (newPort == 0 || newPort == 80 || newPort == 443) ? '' : ':$newPort';
      final match = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*)://([^/:?#]+)(:\d+)?');
      return originalUrl.replaceFirstMapped(match, (_) => '$scheme://$host$portStr');
    } catch (_) {
      // URL 解析失败，返回原 URL
      return originalUrl;
    }
  }

  /// 路由查找：`comments.` 前缀指向 [comments] 段声明的评论路由，
  /// 其余走主 [routes] 表。
  RouteConfig? _routeFor(String apiName) {
    if (apiName.startsWith('comments.')) {
      return comments?.routes[apiName.substring('comments.'.length)];
    }
    return routes[apiName];
  }

  /// 路由级声明的 responseType，缺省回退到顶层。
  String? responseTypeFor(String apiName) =>
      _routeFor(apiName)?.responseType ?? responseType;
}

/// 源配置解析异常（校验/路由缺失）。
class PluginConfigException implements Exception {
  final String message;
  const PluginConfigException(this.message);
  @override
  String toString() => 'PluginConfigException: $message';
}
