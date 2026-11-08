// ═══════════════════════════════════════════════════════════════
// 内置景点库的端到端回归测试
//
// 为什么需要它：内置库是**资源文件 + 启动时导入**的组合，
// 中间有太多能静默失效的地方：
//   · pubspec 的 assets 配错 → 资源根本没打进 APK
//   · 文件名和 kBundledCityIds 对不上 → rootBundle 找不到
//   · 某个库的 JSON 结构不对 → 导入抛异常
//   · 导入路径回归 → 地区建不出来
// 而 `installIfNeeded` **会吞掉导入异常**（不让某个坏库挡住 App 启动），
// 所以上面任何一种情况在运行时都表现为「App 正常启动，但景点库是空的」——
// 用户看得见，日志里看不见。这个测试就是用来把这类问题**在 CI 里**顶出来的。
//
// 它跑真实的 rootBundle + 真实的 LibraryImporter，断言每个内置库
// 都能建出对应地区。
// ═══════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:travel_planner/data/bundled_library.dart';
import 'package:travel_planner/data/database.dart';

void main() {
  // ⚠️ 必须初始化绑定：rootBundle 在测试里没有绑定会抛
  //    「Binding has not yet been initialized」，而 installIfNeeded 会把这个
  //    异常吞掉 → 测试表现为「0 城导入」，看起来像 App 的 bug。
  //    （我第一版干跑就撞上了，排查了半天。）
  TestWidgetsFlutterBinding.ensureInitialized();

  test('assets/library 里不该有「没进列表」的死文件', () {
    // ⚠️ 反向检查：installIfNeeded 只遍历 kBundledCityIds，
    //    所以**目录里多出来的 json 永远不会被导入**——它静静地躺在那，
    //    占 APK 体积、看起来像内置了，实际用户拿不到。
    //    加城市时最容易犯的错就是「丢了文件、忘了加 id」。
    final dir = Directory('assets/library');
    expect(dir.existsSync(), isTrue, reason: 'assets/library 不存在');

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => f.uri.pathSegments.last.replaceAll('.json', ''))
        .toList()
      ..sort();

    final listed = [...kBundledCityIds]..sort();

    final orphan = files.where((f) => !listed.contains(f)).toList();
    expect(
      orphan,
      isEmpty,
      reason: '这些文件在 assets/library/ 里，但不在 kBundledCityIds 里，'
          '永远不会被导入（白占体积）：$orphan。'
          '要么把 id 加进列表，要么删掉文件。',
    );

    final missing = listed.where((id) => !files.contains(id)).toList();
    expect(
      missing,
      isEmpty,
      reason: '这些 id 在列表里但没有对应文件，导入时会静默失败：$missing',
    );
  });

  test('每个内置景点库都能被真实导入并建出地区', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final imported = await BundledLibrary.installIfNeeded(db);
    final regions = await db.select(db.regions).get();
    final places = await db.select(db.attractions).get();

    // 出问题时把实际状态打出来，便于一眼定位是哪个库坏了
    // ignore: avoid_print
    print('内置库 ${kBundledCityIds.length} 个 → 导入 ${imported.length} 城 · '
        'regions=${regions.length} · places=${places.length}');

    expect(
      imported.length,
      kBundledCityIds.length,
      reason: '有内置库导入失败。检查：①pubspec 的 assets 是否覆盖该文件 '
          '②assets/library/<id>.json 是否存在 ③JSON 是否合法（有 region 段）',
    );
    expect(regions.length, kBundledCityIds.length, reason: '每个内置库都该建出地区');
    expect(places, isNotEmpty, reason: '导入了地区却没有地点');

    // 每个地区都该有地点
    final byRegion = <String, int>{};
    for (final p in places) {
      byRegion[p.regionId] = (byRegion[p.regionId] ?? 0) + 1;
    }
    final emptyRegions =
        regions.where((r) => (byRegion[r.id] ?? 0) == 0).map((r) => r.name);
    expect(emptyRegions, isEmpty, reason: '这些地区一个地点都没有：$emptyRegions');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('第二次调用不重复导入（标记生效）', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await BundledLibrary.installIfNeeded(db);
    final first = (await db.select(db.attractions).get()).length;

    final again = await BundledLibrary.installIfNeeded(db);
    final second = (await db.select(db.attractions).get()).length;

    expect(again, isEmpty, reason: '第二次不该再导入');
    expect(second, first, reason: '地点数不该翻倍');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
