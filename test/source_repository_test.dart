import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/services/source_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  group('SourceRepository', () {
    final repo = SourceRepository.fromJsonList(<Map<String, dynamic>>[
      {
        'id': 'pms_test',
        'name': 'Test Media',
        'type': 'animeSource',
        'site': {
          'domain': 'https://example.com',
          'baseUrl': 'https://example.com',
        },
        'parser': {'type': 'builtin'},
        'routes': {
          'latest': {'url': '/api.php/provide/vod/?ac=list'},
        },
        'enabled': true,
      },
      {
        'id': 'manga_test',
        'name': 'Test Manga',
        'type': 'mangaSource',
        'site': {
          'domain': 'https://m.example.com',
          'baseUrl': 'https://m.example.com',
        },
        'parser': {'type': 'builtin'},
        'routes': {},
        'enabled': false,
      },
    ]);

    test('byType filters active sources', () {
      expect(repo.byType(SourceType.animeSource), hasLength(1));
      expect(repo.byType(SourceType.mangaSource), isEmpty);
    });

    test('getById returns matching config', () {
      expect(repo.getById('pms_test')?.name, 'Test Media');
      expect(repo.getById('missing'), isNull);
    });

    test('activeSources excludes disabled', () {
      expect(repo.activeSources, hasLength(1));
    });

    test('内置新版自动覆盖过期的用户导入副本', () {
      // 用户导入过 goda 旧版（v4：无 UA、旧 CDN）→ 应被内置新版（v5）自动覆盖。
      final staleRepo = SourceRepository.fromJsonList(<Map<String, dynamic>>[
        {
          'id': 'manga_goda',
          'name': 'GoDa漫画(旧副本)',
          'type': 'mangaSource',
          'version': 4,
          'site': {
            'domain': 'godamh.com',
            'baseUrl': 'https://godamh.com',
          },
          'parser': {'type': 'hybrid'},
          'routes': {},
          'enabled': true,
        },
      ]);
      staleRepo.seedBuiltinsForTest(<PluginConfig>[
        PluginConfig.fromJson(<String, dynamic>{
          'id': 'manga_goda',
          'name': 'GoDa漫画',
          'type': 'mangaSource',
          'version': 5,
          'site': {
            'domain': 'godamh.com',
            'baseUrl': 'https://godamh.com',
            'userAgent': 'Mozilla/5.0 test',
          },
          'parser': {'type': 'hybrid'},
          'routes': {},
          'enabled': true,
        }),
      ]);
      final goda = staleRepo.getById('manga_goda');
      expect(goda, isNotNull);
      // 内置 v5 胜出：名称/版本/UA 均为内置新值。
      expect(goda!.version, 5);
      expect(goda.name, 'GoDa漫画');
      expect(goda.site.userAgent, isNotEmpty);
    });

    test('用户导入的更新版本（≥内置）仍优先', () {
      // 用户导入 v99（高于内置）→ 保留用户副本。
      final freshRepo = SourceRepository.fromJsonList(<Map<String, dynamic>>[
        {
          'id': 'manga_goda',
          'name': 'GoDa漫画(用户版)',
          'type': 'mangaSource',
          'version': 99,
          'site': {
            'domain': 'godamh.com',
            'baseUrl': 'https://godamh.com',
          },
          'parser': {'type': 'hybrid'},
          'routes': {},
          'enabled': true,
        },
      ]);
      freshRepo.seedBuiltinsForTest(<PluginConfig>[
        PluginConfig.fromJson(<String, dynamic>{
          'id': 'manga_goda',
          'name': 'GoDa漫画',
          'type': 'mangaSource',
          'version': 5,
          'site': {
            'domain': 'godamh.com',
            'baseUrl': 'https://godamh.com',
          },
          'parser': {'type': 'hybrid'},
          'routes': {},
          'enabled': true,
        }),
      ]);
      final goda = freshRepo.getById('manga_goda');
      expect(goda, isNotNull);
      expect(goda!.version, 99);
      expect(goda.name, 'GoDa漫画(用户版)');
    });

    test('用户编辑过（屏蔽内置）但内置更新 → 内置新版恢复展示', () {
      // 模拟 replaceSource 编辑：内置被屏蔽 + 导入副本生效。
      final editedRepo = SourceRepository.fromJsonList(<Map<String, dynamic>>[
        {
          'id': 'manga_goda',
          'name': 'GoDa漫画(用户改镜像)',
          'type': 'mangaSource',
          'version': 5,
          'site': {
            'domain': 'godamh.com',
            'baseUrl': 'https://mirror.user.example',
          },
          'parser': {'type': 'hybrid'},
          'routes': {},
          'enabled': true,
        },
      ]);
      editedRepo.seedBuiltinsForTest(<PluginConfig>[
        PluginConfig.fromJson(<String, dynamic>{
          'id': 'manga_goda',
          'name': 'GoDa漫画',
          'type': 'mangaSource',
          'version': 6,
          'site': {
            'domain': 'godamh.com',
            'baseUrl': 'https://godamh.com',
          },
          'parser': {'type': 'hybrid'},
          'routes': {},
          'enabled': true,
        }),
      ]);
      // 用户编辑过 → 内置被屏蔽。
      editedRepo.replaceSource(editedRepo.getById('manga_goda')!);
      final goda = editedRepo.getById('manga_goda');
      // 内置 v6 > 导入 v5 → 内置新版恢复。
      expect(goda, isNotNull);
      expect(goda!.version, 6);
      expect(goda.site.baseUrl, 'https://godamh.com');
    });
  });
}
