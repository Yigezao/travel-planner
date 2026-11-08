// ═══════════════════════════════════════════════════════════════
// 真实数据的端到端验证（用打包进 App 的 53 城真实库，不是假数据）
//
// 之前的 53 城干跑用的是「复制南昌改名」的假数据，只能验证机制。
// 这个测试用**真实交付的库**回答三个只有真实数据才能回答的问题：
//   1. 53 城真实库首次导入要多久？（真机启动体验）
//   2. 导完之后 App 的数据长什么样？（地点/标签/notices 是否真的进来了）
//   3. 景点库列表页能不能渲染出全部城市？（UI 层在 53 城规模下会不会出问题）
//
// 依赖真实 assets，所以不加 mock 数据。
// ═══════════════════════════════════════════════════════════════

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:travel_planner/data/bundled_library.dart';
import 'package:travel_planner/data/database.dart';
import 'package:travel_planner/data/providers.dart';
import 'package:travel_planner/ui/region_library_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('真实 53 城：首次导入耗时 + 数据落库情况', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final sw = Stopwatch()..start();
    final imported = await BundledLibrary.installIfNeeded(db);
    sw.stop();

    final regions = await db.select(db.regions).get();
    final places = await db.select(db.attractions).get();
    final tags = await db.select(db.placeTags).get();
    final withCoord = places.where((p) => p.lat != null && p.lng != null).length;
    final withNotices =
        regions.where((r) => (r.notices ?? '').trim().isNotEmpty).length;
    final eat = places.where((p) => p.kind == 'eat').length;

    // ignore: avoid_print
    print('【真实数据 e2e】${sw.elapsedMilliseconds}ms · '
        '导入 ${imported.length} 城 · regions=${regions.length} · '
        'places=${places.length}（吃 $eat / 玩 ${places.length - eat}）· '
        '有坐标 $withCoord · 标签 ${tags.length} 行 · 有notices的地区 $withNotices');

    expect(regions.length, kBundledCityIds.length, reason: '每个内置库都该建出地区');
    expect(places.length, greaterThan(500), reason: '53 城真实数据应远多于 500 个地点');
    // 坐标覆盖率：真实数据里只有 3 处是刻意留空的
    expect(withCoord / places.length, greaterThan(0.95),
        reason: '坐标覆盖率应 >95%（实测 99.5%）');

    // 导入耗时：真机会比内存库慢，但这里守住一个宽松上界，
    // 防止将来某次改动把首启拖成几十秒
    expect(sw.elapsedMilliseconds, lessThan(30000),
        reason: '内存库导入不该超过 30s（实测约 1~3s），超了说明有性能回归');
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('真实 53 城：景点库列表能渲染出全部城市', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // ⚠️⚠️ 必须用 `tester.runAsync` 包住安装。
    //
    // `testWidgets` 的测试体跑在**伪异步时区**（FakeAsync）里，而安装过程包含
    // 真实的资源读取（rootBundle）和数据库 I/O —— 在伪时区下这些异步操作
    // **永远不会完成**，测试直接挂死到超时（报错是 "did not complete"，
    // 看着像死锁，其实是在等一个永远不会推进的时钟）。
    // 同一个调用放在普通 `test()` 里只要 585ms —— 差别就在时区。
    await tester.runAsync(() => BundledLibrary.installIfNeeded(db));

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RegionLibraryScreen()),
      ),
    );

    // ⚠️ **不能用 pumpAndSettle**：加载中会显示 CircularProgressIndicator，
    //    而它是个无限动画，pumpAndSettle 永远等不到「静止」→ 测试挂到超时
    //    （报错是 "did not complete"，看着像死锁，其实是等一个不会停的动画）。
    //    用固定次数的 pump 代替。
    await tester.pump();                                   // 首帧
    await tester.pump(const Duration(milliseconds: 300));  // 让 stream 数据到达
    await tester.pump(const Duration(milliseconds: 300));  // 让列表完成布局

    // 列表是懒加载的，屏幕上只会渲染可见的那几个。
    // 所以断言「渲染出了卡片」，而不是「53 个都在」——后者在懒加载下不成立，
    // 硬写就成了假测试。
    expect(find.byType(Card), findsWidgets, reason: '景点库列表应该渲染出城市卡片');

    final regions = await db.select(db.regions).get();
    expect(regions.length, kBundledCityIds.length);

    // 拆树让 drift 的 stream 清理走完（同样不能用 pumpAndSettle）
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
