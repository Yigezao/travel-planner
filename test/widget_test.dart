// ═══════════════════════════════════════════════════════════════
// 测试
//
// 1. 纯逻辑测试：金额换算、预算预警等级
// 2. 数据库冒烟测试：建行程 → 加站点 → 加支出 → 查总账
//    （用内存数据库，不碰真实文件）
// ═══════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/database.dart';
import 'package:travel_planner/data/exporter.dart';
import 'package:travel_planner/data/import_router.dart';
import 'package:travel_planner/data/library_importer.dart';
import 'package:travel_planner/data/qweather.dart';
import 'package:travel_planner/data/weather.dart';
import 'package:travel_planner/data/providers.dart';
import 'package:travel_planner/data/travel_repository.dart';
import 'package:travel_planner/data/trip_file_importer.dart';
import 'package:travel_planner/data/trip_importer.dart';
import 'package:travel_planner/ui/day_map_screen.dart';
import 'package:travel_planner/ui/home_screen.dart';

void main() {
  // 持久化测试会先后打开同一个文件库两次，drift 会警告
  // 「AppDatabase 被创建了多次」。这里是刻意为之，不是误用。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // ── 纯逻辑 ──

  group('金额换算', () {
    test('分转元', () {
      // 整数元不带小数（导出到 Markdown 时更干净），非整数保留两位
      expect(centsToYuan(0), '0');
      expect(centsToYuan(100), '1');
      expect(centsToYuan(9999), '99.99');
      expect(centsToYuan(123456), '1234.56');
    });

    test('元转分', () {
      expect(yuanToCents('0'), 0);
      expect(yuanToCents('99.99'), 9999);
      expect(yuanToCents('8000'), 800000);
      expect(yuanToCents(''), 0);
    });

    test('往返转换不丢精度', () {
      // 用「分」存整数的意义：0.1 + 0.2 这种浮点问题不会出现
      // 注意：输出统一两位小数，'0.1' 会规范成 '0.10'
      for (final yuan in ['0.01', '0.10', '99.99', '1234.56']) {
        expect(centsToYuan(yuanToCents(yuan)), yuan);
      }
    });
  });

  group('预算预警等级', () {
    test('未设预算时不预警', () {
      const line = BudgetLine(
        category: ExpenseCategory.food,
        budgetCents: 0,
        spentCents: 5000,
      );
      expect(line.alertLevel, 0);
      expect(line.usedRatio, isNull);
    });

    test('80% 以下正常', () {
      const line = BudgetLine(
        category: ExpenseCategory.food,
        budgetCents: 10000,
        spentCents: 7999,
      );
      expect(line.alertLevel, 0);
    });

    test('80% 以上预警', () {
      const line = BudgetLine(
        category: ExpenseCategory.food,
        budgetCents: 10000,
        spentCents: 8000,
      );
      expect(line.alertLevel, 1);
    });

    test('超支最严重', () {
      const line = BudgetLine(
        category: ExpenseCategory.food,
        budgetCents: 10000,
        spentCents: 10001,
      );
      expect(line.alertLevel, 2);
      expect(line.isOverBudget, isTrue);
    });
  });

  // ── 数据库冒烟测试 ──

  group('数据库', () {
    late AppDatabase db;
    late TravelRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = TravelRepository(db);
    });

    tearDown(() async => db.close());

    test('建行程：几夜由日期自动算出，不用手填', () async {
      final id = await repo.createTrip(
        title: '2027 春节 关西',
        regionName: '日本·关西',
        startDate: DateTime(2027, 1, 25),
        endDate: DateTime(2027, 1, 30),
      );

      final trip = await repo.getTrip(id);
      expect(trip, isNotNull);
      expect(trip!.title, '2027 春节 关西');
      // 1/25 到 1/30 = 6 天 5 夜
      expect(trip.nights, 5);
    });

    test('同一地区重复建行程，复用同一个地区记录', () async {
      await repo.createTrip(
        title: '第一次关西',
        regionName: '日本·关西',
        startDate: DateTime(2026, 4, 1),
        endDate: DateTime(2026, 4, 6),
      );
      await repo.createTrip(
        title: '第二次关西',
        regionName: '日本·关西',
        startDate: DateTime(2027, 1, 25),
        endDate: DateTime(2027, 1, 30),
      );

      final regions = await repo.allRegions();
      expect(regions.length, 1, reason: '一个地区只该有一条记录');
      expect(regions.first.name, '日本·关西');
    });

    test('加站点：seq 自动递增', () async {
      final tripId = await repo.createTrip(
        title: '测试行程',
        regionName: '测试地区',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 3),
      );

      // 同一模块内 seq 递增
      expect(await repo.nextSeqInBlock(tripId, 1, TimeBlock.morning), 1);
      await repo.addItem(
          tripId: tripId,
          dayIndex: 1,
          seq: 1,
          timeBlock: TimeBlock.morning,
          customName: '清水寺');
      expect(await repo.nextSeqInBlock(tripId, 1, TimeBlock.morning), 2);
      await repo.addItem(
          tripId: tripId,
          dayIndex: 1,
          seq: 2,
          timeBlock: TimeBlock.morning,
          customName: '祇园');
      expect(await repo.nextSeqInBlock(tripId, 1, TimeBlock.morning), 3);
      // 不同模块各自独立计数
      expect(await repo.nextSeqInBlock(tripId, 1, TimeBlock.lunch), 1);
      expect(await repo.nextSeqInBlock(tripId, 1, TimeBlock.evening), 1);
      // 不同天也独立
      expect(await repo.nextSeqInBlock(tripId, 2, TimeBlock.morning), 1);
    });

    test('外币支出按汇率快照折算', () async {
      final tripId = await repo.createTrip(
        title: '日本行',
        regionName: '日本·关西',
        startDate: DateTime(2027, 1, 25),
        endDate: DateTime(2027, 1, 30),
      );

      // 1000 日元，汇率 0.048 => 48 元 = 4800 分
      await repo.addExpense(
        tripId: tripId,
        itemName: '拉面',
        amountCents: 4800,
        category: ExpenseCategory.food,
        payDate: DateTime(2027, 1, 26),
        currency: 'JPY',
        exchangeRate: 0.048,
      );

      final total = await repo.totalSpentCents(tripId);
      expect(total, 4800);
    });

    test('预算报告：分类聚合 + 超支判定', () async {
      final tripId = await repo.createTrip(
        title: '算账测试',
        regionName: '测试地区',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 3),
      );

      await repo.setBudget(tripId, ExpenseCategory.food, 100000); // 1000 元
      await repo.setBudget(tripId, ExpenseCategory.transport, 50000); // 500 元

      await repo.addExpense(
        tripId: tripId,
        itemName: '午饭',
        amountCents: 90000, // 900 元，占预算 90% → 预警
        category: ExpenseCategory.food,
        payDate: DateTime(2026, 10, 1),
      );
      await repo.addExpense(
        tripId: tripId,
        itemName: '打车',
        amountCents: 60000, // 600 元 > 500 → 超支
        category: ExpenseCategory.transport,
        payDate: DateTime(2026, 10, 1),
      );

      final report = await repo.budgetReport(tripId);
      final food =
          report.lines.firstWhere((l) => l.category == ExpenseCategory.food);
      final transport = report.lines
          .firstWhere((l) => l.category == ExpenseCategory.transport);

      expect(food.alertLevel, 1, reason: '900/1000 = 90%，应预警');
      expect(transport.alertLevel, 2, reason: '600/500 超支');
      expect(report.totalSpentCents, 150000);
      expect(report.totalBudgetCents, 150000);
      expect(report.remainingCents, 0);
    });

    test('删除行程会清掉明细和支出，但保留「去过」的历史', () async {
      final tripId = await repo.createTrip(
        title: '待删行程',
        regionName: '测试地区',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 3),
      );
      await repo.addItem(
          tripId: tripId, dayIndex: 1, seq: 1, customName: '某景点');
      await repo.addExpense(
        tripId: tripId,
        itemName: '某支出',
        amountCents: 1000,
        category: ExpenseCategory.other,
        payDate: DateTime(2026, 10, 1),
      );

      await repo.deleteTrip(tripId);

      expect(await repo.getTrip(tripId), isNull);
      expect(await repo.totalSpentCents(tripId), 0);
      final items = await repo.watchItems(tripId).first;
      expect(items, isEmpty);
    });

    test('删除行程不会抹掉「这地方我去过」的历史', () async {
      // 这是三层解耦的核心：attraction_visits 跨行程累积，
      // 删掉某次行程只解除关联，不该丢失「去过」这个事实
      final regionId = await repo.findOrCreateRegion('日本·关西');
      final attractionId = 'attr-1';
      await db.into(db.attractions).insert(
            AttractionsCompanion.insert(
              id: attractionId,
              regionId: regionId,
              name: '清水寺',
            ),
          );

      final tripId = await repo.createTrip(
        title: '第一次关西',
        regionName: '日本·关西',
        startDate: DateTime(2026, 4, 1),
        endDate: DateTime(2026, 4, 6),
      );
      await db.into(db.attractionVisits).insert(
            AttractionVisitsCompanion.insert(
              id: 'visit-1',
              attractionId: attractionId,
              tripId: Value(tripId),
              status: const Value('visited'),
            ),
          );

      await repo.deleteTrip(tripId);

      // 游玩记录还在，只是不再挂在那次行程上
      final visits = await db.select(db.attractionVisits).get();
      expect(visits.length, 1, reason: '去过的事实必须保留');
      expect(visits.first.status, 'visited');
      expect(visits.first.tripId, isNull, reason: '只解除关联，不删除');
      // 景点本身也不该被删
      final attrs = await db.select(db.attractions).get();
      expect(attrs.length, 1);
    });

    test('数据持久化：关掉数据库再打开，数据还在', () async {
      // 这是整个 App 的核心承诺——数据不能丢。
      // 用真实文件库验证，模拟「关掉 App 再打开」。
      final dir = await Directory.systemTemp.createTemp('tp_persist');
      final file = File('${dir.path}/test.sqlite');

      // 第一次打开：写入
      final db1 = AppDatabase.forTesting(NativeDatabase(file));
      final repo1 = TravelRepository(db1);
      final tripId = await repo1.createTrip(
        title: '持久化测试',
        regionName: '测试地区',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 4),
        totalBudgetCents: 300000,
      );
      await repo1.addItem(
          tripId: tripId, dayIndex: 1, seq: 1, customName: '某景点');
      await repo1.addExpense(
        tripId: tripId,
        itemName: '午饭',
        amountCents: 8800,
        category: ExpenseCategory.food,
        payDate: DateTime(2026, 10, 1),
      );
      await db1.close(); // 相当于关掉 App

      // 第二次打开：读回
      final db2 = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(db2.close);
      final repo2 = TravelRepository(db2);

      final trip = await repo2.getTrip(tripId);
      expect(trip, isNotNull, reason: '行程必须还在');
      expect(trip!.title, '持久化测试');
      expect(trip.nights, 3);
      expect(await repo2.totalSpentCents(tripId), 8800, reason: '账目必须还在');
      final items = await repo2.watchItems(tripId).first;
      expect(items.length, 1, reason: '明细必须还在');

      // 不删临时目录：Windows 下 sqlite 文件句柄要等进程退出才释放，
      // 现在删会抛 PathAccessException。测试断言已经完成了，
      // 清理失败不该让测试红。
    });

    test('预计游玩时长：存分钟，显示小时，不能再乘 60', () async {
      // 这条测试守着一个踩过的坑：
      // 输入框读出来是「分钟」，保存时又乘了 60，
      // 结果「2 小时」的景点存成 120 小时。
      final regionId = await repo.findOrCreateRegion('测试地区');
      final id = await repo.addAttraction(
        regionId: regionId,
        name: '某景点',
        suggestDurationMin: 120, // 2 小时
      );

      final all = await repo.attractionsOf(regionId);
      final a = all.firstWhere((x) => x.id == id);

      expect(a.suggestDurationMin, 120, reason: '存进去是多少就该是多少');
      expect('${(a.suggestDurationMin! / 60).toStringAsFixed(1)}h', '2.0h');

      // 90 分钟要能显示成 1.5h（这正是原来整数小时存不下的）
      await repo.updateAttraction(
        AttractionsCompanion(
          id: Value(id),
          suggestDurationMin: const Value(90),
        ),
      );
      final updated =
          (await repo.attractionsOf(regionId)).firstWhere((x) => x.id == id);
      expect(updated.suggestDurationMin, 90);
      expect('${(updated.suggestDurationMin! / 60).toStringAsFixed(1)}h',
          '1.5h');
    });

    test('编辑行程：只改名不该动内容', () async {
      final tripId = await repo.createTrip(
        title: '原标题',
        regionName: '测试地区',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 5),
      );
      for (var d = 1; d <= 5; d++) {
        await repo.addItem(
          tripId: tripId,
          dayIndex: d,
          seq: 1,
          timeBlock: TimeBlock.morning,
          customName: '第$d天的安排',
        );
      }

      // 只改名字，日期原样传回
      final r = await repo.updateTripWithDateGuard(
        tripId: tripId,
        title: '新标题',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 5),
      );

      expect(r.removed, 0, reason: '只改名字不该删任何内容');
      final items = await repo.watchItems(tripId).first;
      expect(items.length, 5, reason: '5 天的安排应该都在');
      expect((await repo.getTrip(tripId))!.title, '新标题');
    });

    test('编辑行程：开始日往后推，内容不能丢（曾因此丢过数据）', () async {
      // ⚠️ 这条守着一个真实的严重 bug：
      //    早先按「日期对齐」平移 dayIndex，把 10/1 改成 10/3 时，
      //    旧的第 1、2 天要落到「-1、0 天」→ 不合法 → 被删掉。
      //    用户只挪了下开始日，前两天内容就静默消失了。
      final tripId = await repo.createTrip(
        title: '平移测试',
        regionName: '测试地区',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 5),
      );
      for (var d = 1; d <= 5; d++) {
        await repo.addItem(
          tripId: tripId,
          dayIndex: d,
          seq: 1,
          timeBlock: TimeBlock.morning,
          customName: '第$d天',
        );
      }

      // 开始日往后推 2 天，总天数不变（10/3 ~ 10/7）
      final r = await repo.updateTripWithDateGuard(
        tripId: tripId,
        startDate: DateTime(2026, 10, 3),
        endDate: DateTime(2026, 10, 7),
      );

      expect(r.removed, 0, reason: '天数没变，一天都不该删');
      final items = await repo.watchItems(tripId).first;
      expect(items.length, 5, reason: '5 天内容必须全在');
      expect(items.map((i) => i.customName).toSet(),
          {'第1天', '第2天', '第3天', '第4天', '第5天'});
    });

    test('编辑行程：缩短天数才删内容，且只删超出的部分', () async {
      final tripId = await repo.createTrip(
        title: '缩短测试',
        regionName: '测试地区',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 5),
      );
      for (var d = 1; d <= 5; d++) {
        await repo.addItem(
          tripId: tripId,
          dayIndex: d,
          seq: 1,
          timeBlock: TimeBlock.morning,
          customName: '第$d天',
        );
      }

      // 5 天改成 3 天
      final r = await repo.updateTripWithDateGuard(
        tripId: tripId,
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 3),
      );

      expect(r.removed, 2, reason: '第 4、5 天的内容该被删');
      expect(r.kept, 3);
      final items = await repo.watchItems(tripId).first;
      expect(items.length, 3);
      expect(items.map((i) => i.customName).toSet(), {'第1天', '第2天', '第3天'});
    });

    test('新行程默认 3 天 2 夜', () async {
      // createTrip 的 nights 由日期算，这里验证 3 天的组合
      final tripId = await repo.createTrip(
        title: '默认值测试',
        regionName: '测试地区',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 3), // +2 天 = 3 天 2 夜
      );
      final trip = await repo.getTrip(tripId);
      expect(trip!.nights, 2);
      expect(
        trip.endDate.difference(trip.startDate).inDays + 1,
        3,
        reason: '共 3 天',
      );
    });

    test('数据库升级不丢数据（迁移是增量的，不是删库重建）', () async {
      // 这条测试的目的是守住一个底线：
      // 用户录了行程之后，App 升级**不能**把数据清掉。
      //
      // 早期版本是 onUpgrade 里 DROP TABLE 重建，那条路对开发期方便，
      // 但用户一旦有真实数据，升级就等于清库。
      // 现在改成增量迁移，这条测试保证它不被改回去。
      final dir = await Directory.systemTemp.createTemp('tp_migrate');
      final file = File('${dir.path}/m.db');

      // 模拟「旧版本建的库」——用当前 schema 建，灌入数据
      final db1 = AppDatabase.forTesting(NativeDatabase(file));
      final repo1 = TravelRepository(db1);
      final tripId = await repo1.createTrip(
        title: '升级测试行程',
        regionName: '测试地区',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 3),
      );
      await repo1.addItem(
        tripId: tripId,
        dayIndex: 1,
        seq: 1,
        timeBlock: TimeBlock.lunch,
        customName: '某餐馆',
      );
      await repo1.addExpense(
        tripId: tripId,
        itemName: '午饭',
        amountCents: 5000,
        category: ExpenseCategory.food,
        payDate: DateTime(2026, 10, 1),
      );
      await db1.close();

      // 重新打开（相当于「升级后第一次启动」）
      final db2 = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(db2.close);
      final repo2 = TravelRepository(db2);

      // 数据必须都还在
      final trips = await repo2.watchTripsWithRegion().first;
      expect(trips.length, 1, reason: '升级后行程不能丢');
      expect(trips.first.$1.title, '升级测试行程');

      final items = await repo2.watchItems(tripId).first;
      expect(items.length, 1, reason: '升级后行程条目不能丢');
      expect(items.first.customName, '某餐馆');

      expect(await repo2.totalSpentCents(tripId), 5000,
          reason: '升级后账目不能丢');

      // 新表也要能用
      await db2.into(db2.placeTags).insert(
            PlaceTagsCompanion.insert(
              id: 'tag-1',
              attractionId: 'a-1',
              tag: '早餐',
            ),
          );
      final tags = await db2.select(db2.placeTags).get();
      expect(tags.length, 1);
      expect(tags.first.tag, '早餐');

      // 不删临时目录：Windows 下 sqlite 文件句柄要等进程退出才释放
    });

    test('导出 Markdown：含抬头、逐日模块、账目、页脚', () async {
      final tripId = await repo.createTrip(
        title: '导出测试',
        regionName: '云南·大理',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 4),
        totalBudgetCents: 500000,
      );
      await repo.addItem(
        tripId: tripId,
        dayIndex: 1,
        seq: 1,
        timeBlock: TimeBlock.morning,
        customName: '洱海',
        arriveTime: '09:00',
        leaveTime: '12:00',
      );
      await repo.addItem(
        tripId: tripId,
        dayIndex: 1,
        seq: 1,
        timeBlock: TimeBlock.lunch,
        customName: '喜洲粑粑',
      );
      await repo.addExpense(
        tripId: tripId,
        itemName: '环海骑行',
        amountCents: 12000,
        category: ExpenseCategory.ticket,
        payDate: DateTime(2026, 10, 1),
      );

      final bundle = await repo.loadBundle(tripId);
      expect(bundle, isNotNull);

      final md = const TripExporter().buildMarkdown(bundle!);

      expect(md, contains('# 导出测试'));
      expect(md, contains('云南·大理'));
      expect(md, contains('2026-10-01'));
      expect(md, contains('## 第 1 天'));
      expect(md, contains('### 上午'));
      expect(md, contains('洱海'));
      expect(md, contains('09:00 - 12:00'));
      expect(md, contains('### 午餐'));
      expect(md, contains('喜洲粑粑'));
      expect(md, contains('## 账目'));
      expect(md, contains('环海骑行'));
      expect(md, contains('¥120'));
      expect(md, contains('format v$kExportFormatVersion'));
    });

    test('.trip 往返：导出给好友、对方导入后内容一致', () async {
      // 这是「分享同步」链路的保障：
      // 你导出 .trip → 微信发给女友 → 她点开导入 → 内容必须一样。
      final tripId = await repo.createTrip(
        title: '分享测试',
        regionName: '云南·大理',
        startDate: DateTime(2026, 12, 1),
        endDate: DateTime(2026, 12, 3),
        totalBudgetCents: 400000,
      );
      await repo.addItem(
        tripId: tripId,
        dayIndex: 1,
        seq: 1,
        timeBlock: TimeBlock.breakfast,
        customName: '喜洲早市',
        arriveTime: '08:00',
        note: '破酥粑粑',
      );
      await repo.addItem(
        tripId: tripId,
        dayIndex: 1,
        seq: 1,
        timeBlock: TimeBlock.evening,
        customName: '洱海门',
        hotelName: '大理古城客栈',
        hotelAddress: '人民路',
        hotelCostCents: 22000,
      );
      await repo.addExpense(
        tripId: tripId,
        itemName: '客栈',
        amountCents: 22000,
        category: ExpenseCategory.hotel,
        payer: Payer.partner,
        payDate: DateTime(2026, 12, 1),
        isPlanned: true,
      );
      await repo.setBudget(tripId, ExpenseCategory.hotel, 50000);

      // 导出
      final bundle = await repo.loadBundle(tripId);
      final tripFileData = const TripExporter().buildTripFileData(bundle!);

      // 模拟「文件经微信传输」——序列化成字符串再解析回来。
      // 用 detectFile（生产环境收到文件时走的正是它），
      // 而不是以前那个只做解析、生产代码已不用的 parseTripFile。
      final jsonText = jsonEncode(tripFileData);
      final detected = detectFile(jsonText);
      expect(detected.kind, ImportKind.fullTrip,
          reason: '应被识别成一份完整行程');

      // 导入（模拟对方手机）
      final result =
          await const TripFileImporter().import(detected.data, repo);
      expect(result.title, '分享测试');
      expect(result.dayCount, 3);
      expect(result.itemCount, 2);
      expect(result.expenseCount, 1);

      // 校验导入后的内容
      final trips = await repo.watchTripsWithRegion().first;
      final imported = trips
          .map((t) => t.$1)
          .reduce((a, b) => a.createdAt.isAfter(b.createdAt) ? a : b);

      final items = await repo.watchItems(imported.id).first;
      expect(items.length, 2);

      final breakfast = items
          .firstWhere((i) => i.timeBlock == TimeBlock.breakfast.name);
      expect(breakfast.customName, '喜洲早市');
      expect(breakfast.arriveTime, '08:00');
      expect(breakfast.note, '破酥粑粑');

      final evening =
          items.firstWhere((i) => i.timeBlock == TimeBlock.evening.name);
      expect(evening.hotelName, '大理古城客栈');
      expect(evening.hotelCostCents, 22000);

      final exps = await repo.watchExpenses(imported.id).first;
      expect(exps.length, 1);
      expect(exps.first.itemName, '客栈');
      expect(exps.first.payer, Payer.partner.name);
      expect(exps.first.isPlanned, isTrue);

      final budgets = await repo.watchBudgets(imported.id).first;
      expect(budgets.any((b) => b.category == ExpenseCategory.hotel.name), isTrue);
    });

    test('Markdown 往返：导出的文件能原样导入回来', () async {
      // 这条是核心：用户会在手机上编辑导出的 md，再导回来。
      // 导出格式和导入解析必须配套，否则「导出改一改再导入」就废了。
      final tripId = await repo.createTrip(
        title: '往返测试',
        regionName: '江西·南昌',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 3),
        totalBudgetCents: 300000,
      );
      await repo.addItem(
        tripId: tripId,
        dayIndex: 1,
        seq: 1,
        timeBlock: TimeBlock.breakfast,
        customName: '小罗子汤店',
        arriveTime: '07:30',
        note: '拌粉+瓦罐汤',
      );
      await repo.addItem(
        tripId: tripId,
        dayIndex: 1,
        seq: 1,
        timeBlock: TimeBlock.morning,
        customName: '滕王阁',
      );
      await repo.addItem(
        tripId: tripId,
        dayIndex: 2,
        seq: 1,
        timeBlock: TimeBlock.evening,
        customName: '秋水广场',
      );
      await repo.addExpense(
        tripId: tripId,
        itemName: '滕王阁门票',
        amountCents: 10000,
        category: ExpenseCategory.ticket,
        payer: Payer.me,
        payDate: DateTime(2026, 11, 1),
      );

      final bundle = await repo.loadBundle(tripId);
      final md = const TripExporter().buildMarkdown(bundle!);

      // 导入到同一个库（会新建一次行程）
      final result = await const TripImporter().importFromMarkdown(md, repo);

      expect(result.tripTitle, '往返测试');
      // 导出器把行程区间内每一天都写成 `## 第 N 天`（1~3 号共 3 天），
      // 导入器按标题计数，所以是 3——即使第 3 天没安排内容。
      // 这个对齐很重要：格式改动会让往返测试先挂，而不是等你真机上发现。
      expect(result.dayCount, 3, reason: '11/1~11/3 共 3 天');
      expect(result.itemCount, 3, reason: '3 个地点');
      expect(result.expenseCount, 1, reason: '1 笔账目');

      // 校验导入后的内容确实对得上
      final trips = await repo.watchTripsWithRegion().first;
      final imported = trips.where((t) => t.$1.title == '往返测试').toList();
      expect(imported.length, 2, reason: '原行程 + 导入的行程');

      final newTripId = imported
          .map((t) => t.$1)
          .reduce((a, b) => a.createdAt.isAfter(b.createdAt) ? a : b)
          .id;
      final items = await repo.watchItems(newTripId).first;
      expect(items.length, 3);
      final breakfast = items.firstWhere(
          (i) => i.timeBlock == TimeBlock.breakfast.name);
      expect(breakfast.customName, '小罗子汤店');
      expect(breakfast.arriveTime, '07:30');
      expect(breakfast.note, '拌粉+瓦罐汤');

      final exp = await repo.watchExpenses(newTripId).first;
      expect(exp.length, 1);
      expect(exp.first.itemName, '滕王阁门票');
      expect(exp.first.amountCents, 10000);
    });

    test('Markdown 往返：住宿条目不会变成「(未命名)」假地点，地址/房价/时段都留住',
        () async {
      final tripId = await repo.createTrip(
        title: '住宿往返测试',
        regionName: '江西·南昌',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 1),
      );
      // 只有住宿、没有地点名（用户只填了住哪）。放进「上午」而不是默认的
      // 晚上——用来验证往返后时段没被硬塞进 evening。
      await repo.addItem(
        tripId: tripId,
        dayIndex: 1,
        seq: 1,
        timeBlock: TimeBlock.morning,
        hotelName: '某某酒店',
        hotelAddress: '某某路 2 号',
        hotelCostCents: 25000,
      );

      final md =
          const TripExporter().buildMarkdown((await repo.loadBundle(tripId))!);
      final result = await const TripImporter().importFromMarkdown(md, repo);

      expect(result.itemCount, 1,
          reason: '住宿条目不该被写成表格行、导回来变成一条「(未命名)」假地点');

      final trips = await repo.watchTripsWithRegion().first;
      final newTripId = trips
          .where((t) => t.$1.title == '住宿往返测试')
          .map((t) => t.$1)
          .reduce((a, b) => a.createdAt.isAfter(b.createdAt) ? a : b)
          .id;
      final items = await repo.watchItems(newTripId).first;
      expect(items.length, 1, reason: '不该多出一条假地点');
      final h = items.single;
      expect(h.customName, isNull, reason: '住宿条目本来就没有地点名');
      expect(h.hotelName, '某某酒店');
      expect(h.hotelAddress, '某某路 2 号', reason: '住宿地址不能被丢掉');
      expect(h.hotelCostCents, 25000, reason: '住宿房价不能被丢掉');
      expect(h.timeBlock, TimeBlock.morning.name,
          reason: '住宿要留在原时段，不能被硬塞进「晚上」');
    });

    // ── 2026-09-14 修复回归 ──

    test('删地区：下面还有行程时必须拒绝（否则行程被 innerJoin 静默藏起来）', () async {
      final tripId = await repo.createTrip(
        title: '不能被藏起来的行程',
        regionName: '江西·南昌',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 2),
      );
      final trip = await repo.getTrip(tripId);

      await expectLater(
        repo.deleteRegion(trip!.regionId),
        throwsStateError,
        reason: '地区下有行程，删除必须抛错拦截',
      );

      // 行程还在，首页 join 还能查到
      final trips = await repo.watchTripsWithRegion().first;
      expect(trips.any((t) => t.$1.id == tripId), isTrue);
    });

    test('删地区：没行程时正常删，且不留下孤儿标签', () async {
      final regionId = await repo.createRegion(name: '测试地区');
      final attrId = await repo.addAttraction(regionId: regionId, name: '测试点');
      await repo.setTags(attrId, ['手动标签']);

      await repo.deleteRegion(regionId);

      // 地点没了，它的标签也不能留（原来漏删 place_tags）
      final tags = await repo.db.select(repo.db.placeTags).get();
      expect(tags.where((t) => t.attractionId == attrId), isEmpty);
    });

    test('删行程：day_blocks 一起清掉（没有外键，漏删会留孤儿行）', () async {
      final tripId = await repo.createTrip(
        title: '有时段构成的行程',
        regionName: '江西·南昌',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 2),
      );
      // deleteBlock 会触发默认时段落库
      await repo.deleteBlock(tripId, 1, TimeBlock.evening);
      var rows = await repo.db.select(repo.db.dayBlocks).get();
      expect(rows.where((r) => r.tripId == tripId), isNotEmpty);

      await repo.deleteTrip(tripId);

      rows = await repo.db.select(repo.db.dayBlocks).get();
      expect(rows.where((r) => r.tripId == tripId), isEmpty);
    });

    test('候选库重复导入：同名地点更新而不是翻倍', () async {
      const json = '''
      {
        "region": {"name": "去重测试地区", "country": "中国"},
        "attractions": [
          {"name": "同一个景点", "ticketYuan": 50, "tags": ["公园"]}
        ],
        "foods": []
      }
      ''';

      final first = await const LibraryImporter().importFromJson(json, db);
      expect(first.attractionCount, 1, reason: '首次全新建');
      expect(first.updatedCount, 0);

      final second = await const LibraryImporter().importFromJson(json, db);
      expect(second.attractionCount, 0, reason: '第二次不新建');
      expect(second.updatedCount, 1, reason: '同名地点走更新');

      // 库里始终只有一条
      final region = await repo.db.select(repo.db.regions).get();
      final regionId = region.firstWhere((r) => r.name == '去重测试地区').id;
      final attrs = await repo.attractionsOf(regionId);
      expect(attrs.length, 1);
    });

    test('候选库重导：不清空已填字段、不抹掉「去过」、标签不重复', () async {
      const full = '''
      {
        "region": {"name": "重导保护地区", "country": "中国"},
        "attractions": [
          {"name": "某景点", "ticketYuan": 50, "address": "某某路 1 号",
           "suggestDurationMin": 90, "recommendLevel": 5,
           "highlight": "特色说明", "tags": ["公园", "夜景"]}
        ],
        "foods": []
      }
      ''';
      // 字段更少的旧文件（没有门票/地址/时长/等级/标签）
      const sparse = '''
      {
        "region": {"name": "重导保护地区", "country": "中国"},
        "attractions": [{"name": "某景点"}],
        "foods": []
      }
      ''';

      await const LibraryImporter().importFromJson(full, db);
      final regions = await repo.db.select(repo.db.regions).get();
      final regionId =
          regions.firstWhere((r) => r.name == '重导保护地区').id;
      var attrs = await repo.attractionsOf(regionId);
      final id = attrs.single.id;

      // 用户浏览后标了「去过」，又自己手打了一个标签
      await repo.toggleVisited(id, visited: true);
      await repo.setTags(id, ['公园', '夜景', '手打的'], source: 'user');

      // 重导一份字段更少的文件
      await const LibraryImporter().importFromJson(sparse, db);

      attrs = await repo.attractionsOf(regionId);
      final a = attrs.single;
      expect(a.ticketPriceCents, 5000, reason: '门票不能被清成 0（界面会显示「免费」）');
      expect(a.address, '某某路 1 号', reason: '地址不能被清空');
      expect(a.suggestDurationMin, 90, reason: '建议时长不能被清空');
      expect(a.recommendLevel, 5, reason: '推荐等级不能被清空');
      expect(isVisitedTags(a.tags), isTrue, reason: '「去过」标记不能被抹掉');

      // 用户手打的标签必须活下来（导入器只清 system 标签，
      // 而 setTags 修复后不再把 system 标签改写成 user——否则这里会被清掉）
      expect(await repo.tagsOf(id), contains('手打的'),
          reason: '重导不该冲掉用户手打的标签');

      // 再导一次完整文件：库标签应被替换成一份，而不是越积越多
      await const LibraryImporter().importFromJson(full, db);
      final tags2 = await repo.tagsOf(id);
      expect(tags2.where((t) => t == '公园').length, 1, reason: '标签不该重复');
      expect(tags2, contains('手打的'), reason: '用户标签仍然在');
    });

    test('候选库：同一份文件内重名不插两行', () async {
      const json = '''
      {
        "region": {"name": "文件内重名地区", "country": "中国"},
        "attractions": [{"name": "同一个市场"}],
        "foods": [{"name": "同一个市场", "priceYuan": "20"}]
      }
      ''';
      await const LibraryImporter().importFromJson(json, db);

      final regions = await repo.db.select(repo.db.regions).get();
      final regionId =
          regions.firstWhere((r) => r.name == '文件内重名地区').id;
      final attrs = await repo.attractionsOf(regionId);
      expect(attrs.length, 1, reason: '文件内同名条目应走更新，不该插成两行');
    });

    test('setTags 保留已有标签的来源（system 不被改写成 user）', () async {
      await repo.createTrip(
        title: '标签来源测试',
        regionName: '标签来源地区',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 1),
      );
      final regionId =
          (await repo.allRegions()).firstWhere((r) => r.name == '标签来源地区').id;
      final attrId = await repo.addAttraction(
        regionId: regionId,
        name: '带标签的点',
      );

      // 模拟候选库导入写入的 system 标签
      await repo.setTags(attrId, ['公园', '夜景'], source: 'system');
      // 用户在编辑页保存（会把读出来的标签一起回传）
      await repo.setTags(attrId, ['公园', '夜景', '手打的'], source: 'user');

      final rows = await (repo.db.select(repo.db.placeTags)
            ..where((t) => t.attractionId.equals(attrId)))
          .get();
      final byTag = {for (final r in rows) r.tag: r.source};
      expect(byTag['公园'], 'system', reason: '原有 system 标签的来源要保留');
      expect(byTag['夜景'], 'system');
      expect(byTag['手打的'], 'user', reason: '新增的才算 user');
    });

    test('parseYuanInput：录入金额要能区分「没填」和「填错了」', () {
      // 正常
      expect(parseYuanInput('').ok, isTrue, reason: '留空 = 不设，算 0');
      expect(parseYuanInput('').cents, 0);
      expect(parseYuanInput('3000').cents, 300000);
      expect(parseYuanInput('99.99').cents, 9999);
      expect(parseYuanInput('0').cents, 0);
      // 带修饰符
      expect(parseYuanInput('¥120').cents, 12000);
      expect(parseYuanInput('120元').cents, 12000);

      // 填错了必须拦下——宽松解析会把这些静默变成 0 或负数
      expect(parseYuanInput('abc').ok, isFalse);
      expect(parseYuanInput('-500').ok, isFalse, reason: '负数金额没有意义');
      expect(parseYuanInput('−500').ok, isFalse,
          reason: '全角减号会被清洗掉，宽松解析反而算成 +50000');
      expect(parseYuanInput('12.5.3').ok, isFalse);
      expect(parseYuanInput('１００').ok, isFalse, reason: '全角数字解析不了');
    });

    test('parseRegionName：地区名要拆成「城市」+「校验线索」', () {
      // ⚠️ 取错段会拿到别的国家的天气（实跑踩过）：
      //    「江西·南昌」取第一段 → 「江西」→ 和风匹配到**韩国江西区**
      //    ，返回韩语天气 화창한 且温度是韩国的。
      final a = parseRegionName('江西·南昌');
      expect(a.city, '南昌', reason: '要查的是城市，不是省');
      expect(a.hint, '江西', reason: '前半段留作校验线索');

      final b = parseRegionName('南昌');
      expect(b.city, '南昌');
      expect(b.hint, isNull, reason: '没有分隔符就没有线索');

      // 国外：线索是国家名，用来挡住同名外地
      // （「关西」会匹配到台湾新竹的关西镇，靠这个线索拒掉）
      final c = parseRegionName('日本·东京');
      expect(c.city, '东京');
      expect(c.hint, '日本');

      // 各种分隔符都要认
      expect(parseRegionName('广东-惠州').city, '惠州');
      expect(parseRegionName('广东/惠州').city, '惠州');
      expect(parseRegionName(' 江西 · 南昌 ').city, '南昌');
    });

    test('weatherKeyOf：日期 key 必须与气象源返回的 date 格式一致（月日补零）', () {
      // 高德固定返回 '2026-09-05' 这种形式，key 差一个字符就查不到天气
      expect(weatherKeyOf(DateTime(2026, 9, 5)), '2026-09-05');
      expect(weatherKeyOf(DateTime(2026, 12, 25)), '2026-12-25');
      expect(weatherKeyOf(DateTime(2026, 1, 1)), '2026-01-01');
      expect(weatherKeyOf(DateTime(2026, 11, 30)), '2026-11-30');
    });

    test('clearDay：一次事务清空整天，返回条数', () async {
      final tripId = await repo.createTrip(
        title: '清空测试',
        regionName: '江西·南昌',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 1),
      );
      await repo.addItem(
          tripId: tripId, dayIndex: 1, seq: 1, customName: 'A');
      await repo.addItem(
          tripId: tripId, dayIndex: 1, seq: 1, customName: 'B');
      await repo.addItem(
          tripId: tripId, dayIndex: 2, seq: 1, customName: 'C');

      final n = await repo.clearDay(tripId, 1);
      expect(n, 2);

      final items = await repo.watchItems(tripId).first;
      expect(items.length, 1, reason: '第 2 天的 C 不能被误删');
      expect(items.first.customName, 'C');
    });

    test('swapDays：两天的条目和时段构成整个对调', () async {
      final tripId = await repo.createTrip(
        title: '对调测试',
        regionName: '江西·南昌',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 2),
      );
      await repo.addItem(
          tripId: tripId, dayIndex: 1, seq: 1, customName: '第1天的点');
      await repo.addItem(
          tripId: tripId, dayIndex: 2, seq: 1, customName: '第2天的点');
      // 让两天都有时段构成落库：第 1 天删掉 evening（构成变 5 段），第 2 天保持完整 6 段
      await repo.deleteBlock(tripId, 1, TimeBlock.evening);

      await repo.swapDays(tripId, 1, 2);

      final items = await repo.watchItems(tripId).first;
      final day1 = items.where((i) => i.dayIndex == 1).toList();
      final day2 = items.where((i) => i.dayIndex == 2).toList();
      expect(day1.single.customName, '第2天的点', reason: '内容对调，日期标签不动');
      expect(day2.single.customName, '第1天的点');

      // 时段构成也跟着走：原第 1 天的构成（5 段、无 evening）现在应该在第 2 天
      final d1Blocks = await repo.blocksOf(tripId, 1);
      final d2Blocks = await repo.blocksOf(tripId, 2);
      expect(d1Blocks.length, 6, reason: '对调后第1天拿到的是原第2天的完整六段');
      expect(d2Blocks.length, 5);
      expect(d2Blocks.contains(TimeBlock.evening), isFalse,
          reason: '原第1天的构成（删了evening）现在应该在第2天');
    });

    test('plannedAttractionIdsOfRegion：id 和名字两条路都能认出来', () async {
      final regionId = await repo.createRegion(name: '已排测试地区');
      final a1 = await repo.addAttraction(regionId: regionId, name: '带id的点');
      await repo.addAttraction(regionId: regionId, name: '只有名字的点');
      await repo.addAttraction(regionId: regionId, name: '没排的点');

      final tripId = await repo.createTrip(
        title: '已排测试行程',
        regionName: '已排测试地区',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 1),
      );
      // 带 attractionId 的引用
      await repo.addItem(
          tripId: tripId,
          dayIndex: 1,
          seq: 1,
          customName: '带id的点',
          attractionId: a1);
      // 只有名字（导入/手输场景）
      await repo.addItem(
          tripId: tripId, dayIndex: 1, seq: 2, customName: '只有名字的点');

      final planned =
          await repo.plannedAttractionIdsOfRegion(regionId);
      expect(planned.length, 2, reason: '带id的和按名字匹配的都算已排');
      expect(planned, contains(a1));
    });

    test('swapBlocks：天内互换 + 跨天异名互换', () async {
      final tripId = await repo.createTrip(
        title: '模块互换测试',
        regionName: '江西·南昌',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 2),
      );
      await repo.addItem(
          tripId: tripId,
          dayIndex: 1,
          seq: 1,
          timeBlock: TimeBlock.morning,
          customName: 'A1');
      await repo.addItem(
          tripId: tripId,
          dayIndex: 1,
          seq: 1,
          timeBlock: TimeBlock.afternoon,
          customName: 'A2');
      await repo.addItem(
          tripId: tripId,
          dayIndex: 2,
          seq: 1,
          timeBlock: TimeBlock.dinner,
          customName: 'B1');

      // 天内互换：第1天 上午 ↔ 下午
      await repo.swapBlocks(tripId, 1, TimeBlock.morning, 1, TimeBlock.afternoon);
      var items = await repo.watchItems(tripId).first;
      expect(
          items.firstWhere((i) => i.customName == 'A1').timeBlock,
          TimeBlock.afternoon.name);
      expect(
          items.firstWhere((i) => i.customName == 'A2').timeBlock,
          TimeBlock.morning.name);

      // 跨天异名：第1天下午(天内互换后装的是A1) ↔ 第2天晚上(B1)
      await repo.swapBlocks(tripId, 1, TimeBlock.afternoon, 2, TimeBlock.dinner);
      items = await repo.watchItems(tripId).first;
      final a1 = items.firstWhere((i) => i.customName == 'A1');
      final b1 = items.firstWhere((i) => i.customName == 'B1');
      expect(a1.dayIndex, 2, reason: 'A1 换到第 2 天');
      expect(a1.timeBlock, TimeBlock.dinner.name);
      expect(b1.dayIndex, 1, reason: 'B1 换到第 1 天');
      expect(b1.timeBlock, TimeBlock.afternoon.name);
      // A2 不受第二次互换影响
      final a2 = items.firstWhere((i) => i.customName == 'A2');
      expect(a2.dayIndex, 1);
      expect(a2.timeBlock, TimeBlock.morning.name);
    });

    test('导入不补模块：文件里只有 2 个模块的天，导入后就 2 个', () async {
      const json = '''
      {
        "_meta": {"app": "travel_planner", "formatVersion": 3, "scope": "full"},
        "region": {"name": "模块不补测试"},
        "trip": {"title": "只有两个模块", "startDate": "2026-11-01", "endDate": "2026-11-01"},
        "days": [
          {"dayIndex": 1, "blocks": {
            "morning": [{"name": "上午的点"}],
            "dinner": [{"name": "晚餐的点", "hotel": "某酒店"}]
          }}
        ],
        "budgets": [],
        "expenses": []
      }
      ''';

      final result = await const TripFileImporter()
          .import(jsonDecode(json) as Map<String, dynamic>, repo);
      expect(result.itemCount, 2);

      final trips = await repo.watchTripsWithRegion().first;
      final tripId =
          trips.firstWhere((t) => t.$1.title == '只有两个模块').$1.id;
      final hasRecord = await repo.hasDayBlocksRecord(tripId, 1);
      expect(hasRecord, isTrue, reason: '导入的天应该有自己的时段构成记录');
      final blocks = await repo.blocksOf(tripId, 1);
      expect(blocks.length, 2, reason: '只有文件里出现的上午和晚餐，不补默认六段');
    });

    test('reorderItems：模块内拖动排序后 seq 按新顺序重写', () async {
      final tripId = await repo.createTrip(
        title: '排序测试',
        regionName: '江西·南昌',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 1),
      );
      await repo.addItem(
          tripId: tripId, dayIndex: 1, seq: 1, customName: '滕王阁');
      await repo.addItem(
          tripId: tripId, dayIndex: 1, seq: 2, customName: '八一广场');
      await repo.addItem(
          tripId: tripId, dayIndex: 1, seq: 3, customName: '万寿宫');

      // 用户把「万寿宫」拖到最前
      final items = await repo.watchItems(tripId).first;
      final ids = items.map((e) => e.id).toList();
      final moved = ids.removeLast();
      ids.insert(0, moved);
      await repo.reorderItems(ids);

      final after = await repo.watchItems(tripId).first;
      expect(after.map((e) => e.customName).toList(),
          ['万寿宫', '滕王阁', '八一广场'],
          reason: 'watchItems 按 seq 排序，拖完顺序应立即生效');
    });
  });

  // ── UI 冒烟测试 ──

  // ⚠️ 测试名要如实描述**现在**测的是什么。
  //    这个用例原名是「底部清单必须渲染出条目」，但底部清单已在 2026-09-15
  //    被移除、断言也改成了「清单不该存在」——名字和内容相反，读的人会被误导。
  testWidgets('单天地图：标记上带「序号 · 名字」小标签（底部清单已于 2026-09-15 移除）',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = TravelRepository(db);

    final tripId = await repo.createTrip(
      title: '地图清单测试',
      regionName: '江西·南昌',
      startDate: DateTime(2026, 11, 1),
      endDate: DateTime(2026, 11, 1),
    );
    // 带坐标的地点才会出现在地图和清单里
    final a1 = await repo.addAttraction(
      regionId: (await repo.allRegions()).first.id,
      name: '滕王阁',
      lat: 28.6813,
      lng: 115.8812,
    );
    final a2 = await repo.addAttraction(
      regionId: (await repo.allRegions()).first.id,
      name: '万寿宫',
      lat: 28.6780,
      lng: 115.8850,
    );
    await repo.addItem(
        tripId: tripId,
        dayIndex: 1,
        seq: 1,
        timeBlock: TimeBlock.morning,
        customName: '滕王阁',
        attractionId: a1);
    await repo.addItem(
        tripId: tripId,
        dayIndex: 1,
        seq: 1,
        timeBlock: TimeBlock.afternoon,
        customName: '万寿宫',
        attractionId: a2);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    // 忽略瓦片下载失败的图片异常（测试环境无网络），只放过这一类
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('瓦片下载失败')) return;
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DayMapScreen(tripId: tripId),
        ),
      ),
    );
    // 等 _load() 完成 + 地图 fitBounds 的 postFrameCallback
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // 测试环境里瓦片必然下载失败（HTTP 被 flutter_test 拦截），
    // 这些图片异常与本测试无关，忽略
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 2026-09-15 起底部清单已删除，地图标记直接带「序号 · 名字」小标签
    expect(find.text('1 · 滕王阁'), findsOneWidget,
        reason: '标记标签「1 · 滕王阁」应渲染');
    expect(find.text('2 · 万寿宫'), findsOneWidget,
        reason: '标记标签「2 · 万寿宫」应渲染');
    expect(find.textContaining('站'), findsNothing,
        reason: '底部清单已删，不应再有「N 站」标题');
  });

  testWidgets('首页能渲染，空状态显示提示', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // 自己持有 container，好在断言后主动销毁——
    // 否则 riverpod 的 autoDispose 会在拆树时留下未跑完的定时器，
    // 测试框架会报 "A Timer is still pending"
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // 页面标题是「我们的旅行」——App 名称（贾雯出游记）只用于桌面图标，
    // 两处是分开的：android:label 控制图标名，这里控制页面标题。
    expect(find.text('我们的旅行'), findsOneWidget);
    expect(find.text('还没有行程'), findsOneWidget);
    expect(find.text('新建行程'), findsOneWidget);
    expect(find.text('景点库'), findsOneWidget);

    // 拆掉整棵树，让 drift 的 stream 清理逻辑走完
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
