import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/theme/app_fonts.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/theme/theme_controller.dart';

/// path_provider 桩：getApplicationSupportDirectory 指到测试临时目录。
class _MockPathProvider extends PathProviderPlatform {
  final String supportPath;
  _MockPathProvider(this.supportPath);

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 仓库内置的真字体（有效 TTF），用作自定义字体导入链路的测试源。
  final File bundledTtf =
      File('assets/fonts/SmileySans-Oblique.ttf');

  Directory supportDir() => Directory.systemTemp.createTempSync('nexhub_font');

  group('ThemeController.appFont（内置字体）', () {
    test('默认跟随系统：family 为 null，主题用平台默认字族', () async {
      final backend = InMemoryBackend();
      final controller = ThemeController(backend: backend);
      await controller.load();

      expect(controller.appFontId, kAppFontSystemId);
      expect(controller.appFontFamily, isNull);
      // ThemeData(fontFamily: null) 会落到 Typography 的平台默认字族名
      // （如 Roboto），但绝不应该是任何一款内置字体。
      final String? family =
          controller.lightTheme().textTheme.bodyMedium?.fontFamily;
      expect(
        kBuiltInAppFonts.map((AppFontOption f) => f.family),
        isNot(contains(family)),
      );
    });

    test('切换内置字体：family 生效并写进主题（light/dark 两套）', () async {
      final controller = ThemeController(backend: InMemoryBackend());
      await controller.setAppFont('smileySans');

      expect(controller.appFontFamily, 'Smiley Sans');
      expect(
        controller.lightTheme().textTheme.bodyMedium?.fontFamily,
        'Smiley Sans',
      );
      expect(
        controller.darkTheme().textTheme.bodyMedium?.fontFamily,
        'Smiley Sans',
      );
      // 玄色手工主题同样带上字体。
      controller.setSeed(AppTokens.seedXuanSe);
      expect(
        controller.lightTheme().textTheme.bodyMedium?.fontFamily,
        'Smiley Sans',
      );
    });

    test('切换后持久化 appFont 字段', () async {
      final backend = InMemoryBackend();
      final controller = ThemeController(backend: backend);
      await controller.setAppFont('lxgwWenKai');

      final raw = await backend.get(ThemeController.storageKey);
      expect(raw, isNotNull);
      expect(raw!.contains('"appFont":"lxgwWenKai"'), isTrue);
    });

    test('旧版本 JSON（无 appFont 字段）向后兼容：跟随系统', () async {
      final backend = InMemoryBackend();
      await backend.set(
        ThemeController.storageKey,
        '{"mode":"dark","seed":4283191674,"useMonet":true}',
      );

      final controller = ThemeController(backend: backend);
      await controller.load();

      expect(controller.appFontId, kAppFontSystemId);
      expect(controller.appFontFamily, isNull);
    });

    test('未知字体 id（脏数据）回退跟随系统', () async {
      final backend = InMemoryBackend();
      await backend.set(
        ThemeController.storageKey,
        '{"mode":"light","useMonet":false,"appFont":"noSuchFont"}',
      );

      final controller = ThemeController(backend: backend);
      await controller.load();

      expect(controller.appFontId, kAppFontSystemId);
    });
  });

  group('ThemeController.appFont（自定义字体）', () {
    late PathProviderPlatform original;
    late Directory tempSupport;

    setUp(() {
      tempSupport = supportDir();
      original = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _MockPathProvider(tempSupport.path);
    });

    tearDown(() {
      PathProviderPlatform.instance = original;
      tempSupport.deleteSync(recursive: true);
    });

    test('导入自定义字体：复制进私有目录、注册临时字族并生效', () async {
      final controller = ThemeController(backend: InMemoryBackend());

      final ok = await controller.setAppFontCustom(
        sourcePath: bundledTtf.path,
        displayName: 'my-font.ttf',
      );

      expect(ok, isTrue);
      expect(controller.appFontId, kAppFontCustomId);
      expect(controller.appFontCustomName, 'my-font.ttf');
      // 每次导入使用全新字族名（重复注册同名字族不会刷新字形）。
      final family = controller.appFontFamily!;
      expect(family, startsWith('NexhubAppCustomFont'));
      // 字体文件确实落在受管的 app_fonts/ 目录内。
      final managed = controller.appFontCustomPath!;
      expect(managed, contains('app_fonts'));
      expect(File(managed).existsSync(), isTrue);
      expect(File(managed).lengthSync(), bundledTtf.lengthSync());
      // 主题立即用上新字族。
      expect(
        controller.lightTheme().textTheme.bodyMedium?.fontFamily,
        family,
      );
    });

    test('再次导入替换旧文件：旧受管拷贝被清理，源文件不动', () async {
      final controller = ThemeController(backend: InMemoryBackend());
      await controller.setAppFontCustom(
        sourcePath: bundledTtf.path,
        displayName: 'first.ttf',
      );
      final firstPath = controller.appFontCustomPath!;

      await controller.setAppFontCustom(
        sourcePath: bundledTtf.path,
        displayName: 'second.ttf',
      );

      expect(controller.appFontCustomName, 'second.ttf');
      expect(controller.appFontCustomPath, isNot(firstPath));
      expect(File(firstPath).existsSync(), isFalse,
          reason: '旧受管拷贝应被删除');
      expect(File(bundledTtf.path).existsSync(), isTrue,
          reason: '用户源文件不可被删除');
    });

    test('清除自定义字体：回到跟随系统并删除受管文件', () async {
      final controller = ThemeController(backend: InMemoryBackend());
      await controller.setAppFontCustom(
        sourcePath: bundledTtf.path,
        displayName: 'my.ttf',
      );
      final managedPath = controller.appFontCustomPath!;

      await controller.clearAppFontCustom();

      expect(controller.appFontId, kAppFontSystemId);
      expect(controller.appFontFamily, isNull);
      expect(controller.appFontCustomPath, isNull);
      expect(File(managedPath).existsSync(), isFalse);
    });

    test('冷启动恢复：受管文件存在则恢复自定义字体', () async {
      // 先造一份持久化数据 + 对应的受管文件。
      final backend0 = InMemoryBackend();
      final controller0 = ThemeController(backend: backend0);
      await controller0.setAppFontCustom(
        sourcePath: bundledTtf.path,
        displayName: 'restored.ttf',
      );
      final raw = await backend0.get(ThemeController.storageKey);

      final backend = InMemoryBackend();
      await backend.set(ThemeController.storageKey, raw!);
      final controller = ThemeController(backend: backend);
      await controller.load();

      expect(controller.appFontId, kAppFontCustomId);
      expect(controller.appFontCustomName, 'restored.ttf');
      expect(controller.appFontFamily, isNotNull);
    });

    test('冷启动恢复：受管文件丢失则回退跟随系统', () async {
      final backend = InMemoryBackend();
      await backend.set(
        ThemeController.storageKey,
        jsonEncode(<String, dynamic>{
          'mode': 'light',
          'useMonet': false,
          'appFont': kAppFontCustomId,
          'appFontCustomPath': '${supportDir().path}/missing.ttf',
          'appFontCustomFamily': 'NexhubAppCustomFont1',
          'appFontCustomName': 'missing.ttf',
        }),
      );

      final controller = ThemeController(backend: backend);
      await controller.load();

      expect(controller.appFontId, kAppFontSystemId);
      expect(controller.appFontFamily, isNull);
    });
  });
}
