// ═══════════════════════════════════════════════════════════════
// 出行规划 App · 入口
//
// 情侣两人出行用：记行程、算账、存回忆。
// 数据全部本地。两台手机之间靠导出 .trip 文件互传同步。
//
// 支持从微信/QQ「用其他应用打开」直接导入行程文件——
// 见 lib/data/shared_file_handler.dart 与 AndroidManifest 的 intent-filter。
// ═══════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/bundled_library.dart';
import 'data/database.dart';
import 'data/import_router.dart';
import 'data/library_importer.dart';
import 'data/providers.dart';
import 'data/shared_file_handler.dart';
import 'data/tile_cache.dart';
import 'data/trip_file_importer.dart';
import 'data/trip_importer.dart';
import 'ui/app_toast.dart';
import 'ui/home_screen.dart';

/// 全局 Navigator key：文件在冷启动时到达，那时还没法用 context 找 Navigator
final navigatorKey = GlobalKey<NavigatorState>();

/// 用户选择「并入哪个行程的第几天」
class DayMergeChoice {
  const DayMergeChoice({
    required this.tripId,
    required this.tripTitle,
    required this.dayIndex,
  });

  final String tripId;
  final String tripTitle;
  final int dayIndex;
}

/// 单天文件的落位对话框：选行程 + 选第几天
Future<DayMergeChoice?> showDayMergeDialog(
  List<(Trip, String)> trips,
  DetectedFile detected,
  NavigatorState nav,
) async {
  final ctx = nav.overlay?.context;
  if (ctx == null) return null;

  return showModalBottomSheet<DayMergeChoice>(
    context: ctx,
    isScrollControlled: true,
    builder: (sheetCtx) => _DayMergeSheet(trips: trips, detected: detected),
  );
}

class _DayMergeSheet extends StatefulWidget {
  const _DayMergeSheet({required this.trips, required this.detected});

  final List<(Trip, String)> trips;
  final DetectedFile detected;

  @override
  State<_DayMergeSheet> createState() => _DayMergeSheetState();
}

class _DayMergeSheetState extends State<_DayMergeSheet> {
  int _tripIndex = 0;
  int _day = 1;

  @override
  Widget build(BuildContext context) {
    final trip = widget.trips[_tripIndex].$1;
    final totalDays = trip.endDate.difference(trip.startDate).inDays + 1;

    // ⚠️ 天数**下界**也要兜住：脏数据（结束日期早于开始日期）会让
    //    totalDays ≤ 0。只夹上界的话 _day 会变成 0 或负数，天数 chips
    //    全是空的，而「并入」照常提交 dayIndex=0/负数 —— 内容被写进一个
    //    界面上不存在的天。这里直接不让继续。
    if (totalDays < 1) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.4,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          children: const [
            Text('这份行程的日期不对',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            SizedBox(height: 8),
            Text('结束日期早于开始日期，没法选「并入哪一天」。\n'
                '请先到行程里把日期改正确，再回来导入。'),
            SizedBox(height: 16),
          ],
        ),
      );
    }

    // 选中的行程变了，天数可能超出范围，纠正一下
    if (_day > totalDays) _day = totalDays;
    if (_day < 1) _day = 1;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text('并入哪个行程？',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(
            '文件：${widget.detected.title ?? "未命名"}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          // 用 Card + InkWell 自绘选中态，
          // 不用 RadioListTile——它的 groupValue/onChanged 已在 Flutter 3.32 废弃
          for (var i = 0; i < widget.trips.length; i++)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              color: _tripIndex == i
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _tripIndex = i),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        _tripIndex == i
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.trips[i].$1.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            Text(widget.trips[i].$2,
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const Divider(height: 24),
          const Text('并入第几天？',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var d = 1; d <= totalDays; d++)
                ChoiceChip(
                  label: Text('第 $d 天'),
                  selected: _day == d,
                  onSelected: (_) => setState(() => _day = d),
                ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              DayMergeChoice(
                tripId: trip.id,
                tripTitle: trip.title,
                dayIndex: _day,
              ),
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('并入'),
          ),
          const SizedBox(height: 8),
          const Text(
            '会把文件里的地点追加到目标天的对应时段，不会覆盖你已有的安排。',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

/// 候选库导入前的确认框
Future<bool> showLibraryImportDialog(
  String regionName,
  Map<String, dynamic> data,
  NavigatorState nav,
) async {
  final ctx = nav.overlay?.context;
  if (ctx == null) return false;

  final attractions = data['attractions'];
  final foods = data['foods'];
  final aCount = attractions is List ? attractions.length : 0;
  final fCount = foods is List ? foods.length : 0;

  final result = await showDialog<bool>(
    context: ctx,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('导入这个景点库？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            regionName,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text('景点 $aCount 个 · 美食 $fCount 个'),
          const SizedBox(height: 12),
          const Text(
            '会存入「景点库」，之后排行程时可以直接从里面挑地点。\n\n'
            '已有同名地区会合并进去。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: const Text('导入'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 导入前的确认框。抽成独立函数是为了让调用点不跨 await 用 BuildContext。
Future<bool> showImportConfirmDialog(
  String summary,
  Map<String, dynamic> data,
  NavigatorState nav,
) async {
  final ctx = nav.overlay?.context;
  if (ctx == null) return false;

  // ⚠️ data['trip'] 可能缺失（手改过的文件带 _meta.scope 但没写 trip 段），
  //    直接 `as Map` 会抛异常把导入路径整个打断
  final trip = data['trip'];
  final title =
      (trip is Map) ? (trip['title']?.toString() ?? '') : '';

  final result = await showDialog<bool>(
    context: ctx,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('导入这个行程？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(summary, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          const Text(
            '会新建一份行程，不影响你已有的数据。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: const Text('导入'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Markdown 行程的确认框（没有可解析的 Map，只给标题和摘要）
Future<bool> showMarkdownImportDialog(
  String title,
  String summary,
  NavigatorState nav,
) async {
  final ctx = nav.overlay?.context;
  if (ctx == null) return false;

  final result = await showDialog<bool>(
    context: ctx,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('导入这个行程？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(summary, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          const Text(
            '会新建一份行程，不影响你已有的数据。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: const Text('导入'),
        ),
      ],
    ),
  );
  return result ?? false;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: TravelPlannerApp()));
}

class TravelPlannerApp extends ConsumerStatefulWidget {
  const TravelPlannerApp({super.key});

  @override
  ConsumerState<TravelPlannerApp> createState() => _TravelPlannerAppState();
}

class _TravelPlannerAppState extends ConsumerState<TravelPlannerApp> {
  StreamSubscription<IncomingTripFile>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = SharedFileHandler.instance.onTripFile.listen(_handleIncoming);
    // 延迟到首帧后再启动监听，避免冷启动时弹框找不到 Navigator
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SharedFileHandler.instance.start();
      _installBundledLibraries();
      // 后台清一次 14 天没看的地图瓦片（不阻塞启动，失败无所谓）
      unawaited(CachedTileProvider.sweepStaleTiles());
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// 首次启动导入内置景点库（如南昌），只做一次
  Future<void> _installBundledLibraries() async {
    try {
      final db = ref.read(databaseProvider);

      // 先修坐标：老版本存的 WGS-84 会让地图上所有点偏 604 米。
      // 一次性批量转成 GCJ-02（幂等，只跑一次）。
      final migration = await BundledLibrary.migrateCoordinatesIfNeeded(db);

      // 内置城市会越来越多（目标 51 个），首次导入要几十秒——
      // 不能一声不吭地跑。每 10 个城市报一次进度（每个都报会刷屏）。
      var lastShown = 0;
      final imported = await BundledLibrary.installIfNeeded(
        db,
        onProgress: (done, all, _) {
          if (!mounted) return;
          if (done == all || done - lastShown >= 10) {
            lastShown = done;
            AppToast.show(context, '正在导入景点库 $done/$all');
          }
        },
      );

      if (imported.isEmpty &&
          migration.converted == 0 &&
          !migration.skippedUndecidable) {
        return;
      }
      ref.invalidate(regionsProvider);
      ref.invalidate(tripsProvider);
      if (!mounted) return;
      if (imported.isNotEmpty) {
        // 51 个城市的名字全列出来会把提示撑爆，只报个数
        AppToast.show(
          context,
          imported.length == 1
              ? '已内置景点库：${imported.first}'
              : '已内置 ${imported.length} 个城市的景点库',
        );
      } else if (migration.converted > 0) {
        AppToast.show(context, '已修正 ${migration.converted} 个地点的坐标');
      } else if (migration.skippedUndecidable) {
        // 判断不出坐标是不是已经是 GCJ-02 → 一条都没改（保守，见
        // bundled_library 里的说明）。但必须说出来：万一地图整体偏移，
        // 用户至少知道是什么原因、也知道去哪里重新取坐标。
        AppToast.show(
          context,
          '坐标格式核对不了，已保持原样未转换。若地图整体偏移，'
          '可在「景点库」里用「补全经纬度」重新取一次',
        );
      }
    } catch (e) {
      // 内置库失败不该影响 App 正常使用，但**不能完全静默**：
      // 这里面包含「WGS-84 → GCJ-02」的坐标迁移，失败意味着地图上所有点
      // 偏 604 米，而用户此前看不到任何提示，只会觉得地图不准。
      if (!mounted) return;
      AppToast.show(context, '内置景点库没装好（不影响其他功能）：$e');
    }
  }

  /// 收到分享进来的 .trip 文件 → 弹确认框 → 导入
  Future<void> _handleIncoming(IncomingTripFile file) async {
    // ⚠️ 整个函数必须包一层 try。
    //    它是被 `listen(_handleIncoming)` 直接调用的（不 await），
    //    一旦抛异常就成了「无人接管的异步错误」——用户那边一点提示都没有，
    //    只看到「用其他应用打开」之后毫无反应。
    //    收到被手改坏的文件就会走到这里：比如 region.name 被写成数字，
    //    detectFile / tripFileSummary 里强转 String 直接炸。
    try {
      final nav = navigatorKey.currentState;
      if (nav == null) return;

      String content;
      try {
        content = await readTripFile(file);
      } catch (e) {
        _toast('读不到文件：$e');
        return;
      }

      // Markdown 行程文件不走 JSON 解析（jsonDecode 会失败），
      // 按内容特征单独识别：以 # 开头、含「## 第 N 天」
      final trimmed = content.trimLeft();
      if (!trimmed.startsWith('{') && trimmed.startsWith('#')) {
        await _importMarkdown(content, nav);
        return;
      }

      // 自动识别文件类型：整天行程 / 单天 / 候选库
      final detected = detectFile(content);

      switch (detected.kind) {
        case ImportKind.fullTrip:
          await _importFullTrip(detected, nav);
        case ImportKind.singleDay:
          await _importSingleDay(detected, nav);
        case ImportKind.library:
          await _importLibrary(content, detected, nav);
        case ImportKind.unknown:
          _toast('认不出这个文件。它可能是别的 App 导出的，'
              '或者内容被改坏了。');
      }
    } catch (e) {
      _toast('导入出错：$e');
    }
  }

  /// 整天行程 → 新建一份行程
  Future<void> _importFullTrip(DetectedFile detected, NavigatorState nav) async {
    final summary = tripFileSummary(detected.data);
    final ok = await showImportConfirmDialog(summary, detected.data, nav);
    if (!ok) return;

    try {
      final repo = ref.read(repoProvider);
      final result = await const TripFileImporter().import(detected.data, repo);
      ref.invalidate(tripsProvider);
      _toast('导入成功：${result.summary}');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  /// Markdown 行程 → 新建一份行程。
  ///
  /// 导出菜单里提供「导出 Markdown，可以自己改」——改完得能导回来，
  /// 否则导出就是单程票。这里只做轻量预览（标题 + 天数），
  /// 真正的宽容解析在 TripImporter 里。
  Future<void> _importMarkdown(String md, NavigatorState nav) async {
    String? title;
    var dayCount = 0;
    for (final line in const LineSplitter().convert(md)) {
      final t = line.trim();
      if (title == null && t.startsWith('# ')) {
        title = t.substring(2).trim();
      }
      if (RegExp(r'^##\s*第\s*\d+\s*天').hasMatch(t)) dayCount++;
    }
    if (title == null || title.isEmpty || dayCount == 0) {
      _toast('认不出这个 Markdown 行程（需要 # 标题和 ## 第 N 天）');
      return;
    }

    final ok = await showMarkdownImportDialog(
      title,
      '$dayCount 天行程（Markdown 文件）',
      nav,
    );
    if (!ok) return;

    try {
      final repo = ref.read(repoProvider);
      final result = await const TripImporter().importFromMarkdown(md, repo);
      ref.invalidate(tripsProvider);
      _toast('导入成功：${result.summary}');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  /// 单天行程 → 并入已有行程的某一天
  Future<void> _importSingleDay(DetectedFile detected, NavigatorState nav) async {    final repo = ref.read(repoProvider);
    final trips = await repo.watchTripsWithRegion().first;
    if (trips.isEmpty) {
      _toast('你还没有任何行程，先新建一个再导入');
      return;
    }

    final choice = await showDayMergeDialog(trips, detected, nav);
    if (choice == null) return;

    try {
      final count = await const TripFileImporter().mergeDayInto(
        detected.data,
        repo,
        tripId: choice.tripId,
        dayIndex: choice.dayIndex,
      );
      ref.invalidate(tripsProvider);
      _toast('已并入「${choice.tripTitle}」第 ${choice.dayIndex} 天，共 $count 个地点');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  /// 候选库 → 建地区 + 景点资料
  Future<void> _importLibrary(
    String content,
    DetectedFile detected,
    NavigatorState nav,
  ) async {
    final regionName = detected.title ?? '未命名地区';
    final ok = await showLibraryImportDialog(regionName, detected.data, nav);
    if (!ok) return;

    try {
      final db = ref.read(databaseProvider);
      final result =
          await const LibraryImporter().importFromData(detected.data, db);
      ref.invalidate(regionsProvider);
      ref.invalidate(tripsProvider);
      _toast('已导入景点库：${result.regionName}'
          '（新增 ${result.attractionCount + result.foodCount}'
          '${result.updatedCount > 0 ? ' · 更新 ${result.updatedCount}' : ''}）');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  void _toast(String msg) {
    final ctx = navigatorKey.currentState?.overlay?.context;
    if (ctx == null) return;
    AppToast.show(ctx, msg);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // ⚠️ MaterialApp.title 只用于系统任务切换器里的显示名，
      //    桌面图标下的名字是 AndroidManifest 的 android:label（= 贾雯出游记）。
      //    页面内标题是 HomeScreen 里的「我们的旅行」，三处互不影响。
      title: '贾雯出游记',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B8EC9),
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
