// ═══════════════════════════════════════════════════════════════
// 行程详情：按「天 × 时段模块」组织
//
// 设计取向（用户明确要求）：**模块化，不要精细时间线**。
//   一天分六段：早餐 / 上午 / 午餐 / 下午 / 晚餐 / 晚上
//   时间填不填都行；每段里放几个地点，顺序可调。
//   出门在外计划常变，模块化比精确到分钟更实用。
// ═══════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/database.dart';
import '../data/exporter.dart';
import '../data/geocoder.dart';
import '../data/providers.dart';
import '../data/tile_cache.dart';
import '../data/travel_repository.dart';
import '../data/trip_poster_exporter.dart';
import '../data/weather.dart';
import 'app_toast.dart';
import 'day_map_screen.dart';
import 'expense_edit_screen.dart';
import 'item_edit_screen.dart';
import 'trip_edit_sheet.dart';

class TripDetailScreen extends ConsumerStatefulWidget {
  const TripDetailScreen({super.key, required this.tripId});

  final String tripId;

  @override
  ConsumerState<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends ConsumerState<TripDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tripAsync = ref.watch(tripProvider(widget.tripId));

    return tripAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(body: Center(child: Text('出错了：$e'))),
      data: (trip) {
        if (trip == null) {
          return const Scaffold(body: Center(child: Text('行程不存在')));
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(trip.title),
            actions: [
              // 改行程信息（名称/日期/预算/备注）
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: '修改行程',
                onPressed: () async {
                  final changed = await showTripEditSheet(context, ref, trip);
                  if (changed == true) {
                    ref.invalidate(tripProvider(trip.id));
                    ref.invalidate(tripsProvider);
                    ref.invalidate(dayBlocksProvider(trip.id));
                    ref.invalidate(tripItemsProvider(trip.id));
                  }
                },
              ),
              // 选择器入口在行程级（地区名动态取）——
              // 原来每个时段右侧一个「从景点库选」图标，6 个重复又占地方；
              // 原右上角的「景点库全景地图」已并入这个选择器（删除）
              Builder(builder: (ctx) {
                final regionName = ref
                    .watch(regionProvider(trip.regionId))
                    .valueOrNull
                    ?.name;
                return IconButton(
                  icon: const Icon(Icons.map_outlined),
                  tooltip: regionName == null
                      ? '从景点库选'
                      : '从$regionName景点库选',
                  onPressed: () {
                    Navigator.of(ctx).push(
                      MaterialPageRoute(
                        builder: (_) => _LibraryPicker(
                          tripId: trip.id,
                          regionName: regionName,
                        ),
                      ),
                    );
                  },
                );
              }),
            ],
            bottom: TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: '行程', icon: Icon(Icons.timeline)),
                Tab(text: '账目', icon: Icon(Icons.receipt_long)),
                Tab(text: '预算', icon: Icon(Icons.savings_outlined)),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabs,
            children: [
              _ItineraryTab(trip: trip),
              _ExpensesTab(trip: trip),
              _BudgetTab(trip: trip),
            ],
          ),
        );
      },
    );
  }

}

// ══════════════════════════════════════════════════════════════
// Tab 1 · 模块化行程
// ══════════════════════════════════════════════════════════════

class _ItineraryTab extends ConsumerWidget {
  const _ItineraryTab({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(tripItemsProvider(trip.id));
    // 景点库实时数据：行程条目显示时按 attractionId 联动
    // （库里改了名字/备注，行程里跟着变——原来存的是添加时的拷贝）
    final attractions =
        ref.watch(regionAttractionsProvider(trip.regionId)).valueOrNull;
    final attrById = {for (final a in attractions ?? const <Attraction>[]) a.id: a};
    // 注意事项来自景点库 region.notices（候选库带入）
    final region = ref.watch(regionProvider(trip.regionId)).valueOrNull;
    final notices = region?.notices;
    final noticeList = (notices == null || notices.trim().isEmpty)
        ? const <String>[]
        : notices
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();

    return itemsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('出错了：$e')),
      data: (items) {
        final totalDays = trip.endDate.difference(trip.startDate).inDays + 1;
        final byDay = <int, List<ItineraryItem>>{};
        for (final it in items) {
          byDay.putIfAbsent(it.dayIndex, () => []).add(it);
        }

        // 每天有哪些时段（用户可增删，6 个不是固定的）
        final blocksByDay =
            ref.watch(dayBlocksProvider(trip.id)).valueOrNull ?? const {};

        final hasNotices = noticeList.isNotEmpty;
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 40),
          itemCount: totalDays + (hasNotices ? 1 : 0),
          itemBuilder: (context, i) {
            // 📌 注意事项：和天数卡片同级，排在第 1 天之前
            if (hasNotices && i == 0) {
              return _NoticesCard(
                regionName: region?.name ?? '',
                notices: noticeList,
              );
            }
            final day = i + 1 - (hasNotices ? 1 : 0);
            return _DayCard(
              trip: trip,
              dayIndex: day,
              date: trip.startDate.add(Duration(days: day - 1)),
              items: byDay[day] ?? [],
              attrById: attrById,
              // 还没加载出来时，先用默认六段撑住，避免闪空
              blocks: blocksByDay[day] ?? TimeBlock.values.toList(),
              onChanged: () {
                ref.invalidate(tripItemsProvider(trip.id));
                ref.invalidate(dayBlocksProvider(trip.id));
              },
            );
          },
        );
      },
    );
  }
}

/// 📌 注意事项：内容来自景点库 region.notices（公有+地区特有），
/// 第一行动态拼当天天气（高德天气接口，查不到就不显示这行）
class _NoticesCard extends StatefulWidget {
  const _NoticesCard({required this.regionName, required this.notices});

  final String regionName;
  final List<String> notices;

  @override
  State<_NoticesCard> createState() => _NoticesCardState();
}

class _NoticesCardState extends State<_NoticesCard> {
  String? _weather;
  bool _weatherDone = false;

  @override
  void initState() {
    super.initState();
    _loadWeather();
  }

  Future<void> _loadWeather() async {
    final w = await Geocoder().fetchWeatherSummary(widget.regionName);
    if (!mounted) return;
    setState(() {
      _weather = w;
      _weatherDone = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: const Color(0xFFFFF8EC),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        title: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFE8A840).withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('📌 注意事项',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _weatherDone
                    ? (_weather ?? '今天 ${widget.regionName} 天气未知')
                    : '天气查询中…',
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        children: [
          for (final n in widget.notices)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Text('•',
                        style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: Color(0xFF8B6E3A))),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(n,
                        style: const TextStyle(
                            fontSize: 13, height: 1.4)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 一天 = 一张卡片，里面是六个时段模块
class _DayCard extends ConsumerWidget {
  const _DayCard({
    required this.trip,
    required this.dayIndex,
    required this.date,
    required this.items,
    required this.attrById,
    required this.blocks,
    required this.onChanged,
  });

  final Trip trip;
  final int dayIndex;
  final DateTime date;
  final List<ItineraryItem> items;

  /// 景点库实时数据（attractionId → Attraction），显示时联动
  final Map<String, Attraction> attrById;

  /// 这一天有哪些时段、按什么顺序（用户可增删，未必是 6 个）
  final List<TimeBlock> blocks;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final filledBlocks = TimeBlock.values
        .where((b) => items.any((i) => i.timeBlock == b.name))
        .length;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        initiallyExpanded: dayIndex == 1,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('第 $dayIndex 天',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            ),
            const SizedBox(width: 8),
            Text('${date.month}月${date.day}日',
                style: theme.textTheme.bodySmall),
            const Spacer(),
            if (filledBlocks > 0)
              Text('$filledBlocks 段',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary)),
            // 这一天的操作：看地图 / 导出这天 / 清空这天
            _DayMenu(
              trip: trip,
              dayIndex: dayIndex,
              onChanged: onChanged,
            ),
          ],
        ),
        children: [
          // 按这天保存的时段清单渲染——用户删过/插过之后就不是六个了
          for (final block in blocks)
            _BlockSection(
              trip: trip,
              dayIndex: dayIndex,
              block: block,
              attrById: attrById,
              // 是否只剩这一个时段（只剩一个就不让删，否则那天会空）
              isOnlyBlock: blocks.length <= 1,
              items: (items.where((i) => i.timeBlock == block.name).toList()
                ..sort((a, b) => a.seq.compareTo(b.seq))),
              onChanged: onChanged,
            ),
          // 旧数据里没有 timeBlock 的条目
          if (items.any((i) => i.timeBlock == null))
            _BlockSection(
              trip: trip,
              dayIndex: dayIndex,
              block: null,
              attrById: attrById,
              items: items.where((i) => i.timeBlock == null).toList()
                ..sort((a, b) => a.seq.compareTo(b.seq)),
              onChanged: onChanged,
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// 某一天的操作菜单：看地图 / 导出这一天
class _DayMenu extends ConsumerStatefulWidget {
  const _DayMenu({
    required this.trip,
    required this.dayIndex,
    required this.onChanged,
  });

  final Trip trip;
  final int dayIndex;
  final VoidCallback onChanged;

  @override
  ConsumerState<_DayMenu> createState() => _DayMenuState();
}

class _DayMenuState extends ConsumerState<_DayMenu> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      tooltip: '这一天的操作',
      onSelected: _handle,
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'map',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.map_outlined, size: 20),
            title: Text('看地图'),
            subtitle: Text('这一天的动线', style: TextStyle(fontSize: 11)),
          ),
        ),
        PopupMenuItem(
          value: 'swap',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.swap_vert, size: 20),
            title: Text('和另一天对调'),
            subtitle: Text('两天的安排整个互换', style: TextStyle(fontSize: 11)),
          ),
        ),
        PopupMenuItem(
          value: 'export',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.ios_share, size: 20),
            title: Text('导出这天的文件'),
            subtitle: Text('发给好友可并入他的行程', style: TextStyle(fontSize: 11)),
          ),
        ),
        PopupMenuItem(
          value: 'image_save',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.save_alt, size: 20),
            title: Text('这天的长图存相册'),
            subtitle: Text('保存到手机图库', style: TextStyle(fontSize: 11)),
          ),
        ),
        PopupMenuItem(
          value: 'image_share',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.image_outlined, size: 20),
            title: Text('分享这天的长图'),
            subtitle: Text('发给微信/QQ 好友', style: TextStyle(fontSize: 11)),
          ),
        ),
        PopupMenuItem(
          value: 'clear',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_sweep_outlined, size: 20),
            title: Text('清空这天'),
            subtitle: Text('把这一天的安排全删掉', style: TextStyle(fontSize: 11)),
          ),
        ),
      ],
    );
  }

  Future<void> _handle(String action) async {
    switch (action) {
      case 'map':
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DayMapScreen(
              tripId: widget.trip.id,
              initialDay: widget.dayIndex,
            ),
          ),
        );
        return;

      case 'swap':
        await _swapDay();
        return;

      case 'clear':
        await _clearDay();
        return;

      case 'export':
        await _runExport(() async {
          final repo = ref.read(repoProvider);
          final bundle = await repo.loadBundle(widget.trip.id);
          if (bundle == null) return;
          await const TripExporter()
              .exportSingleDayFile(bundle, widget.dayIndex);
        });
        return;

      case 'image_save':
        await _runExport(() async {
          final repo = ref.read(repoProvider);
          final bundle = await repo.loadBundle(widget.trip.id);
          if (bundle == null) return;
          final attractions = await repo.attractionsOf(bundle.region.id);
          final tags =
              await repo.tagsOfMany(attractions.map((a) => a.id).toList());
          // 逐日天气：长图在屏幕外渲染，取数必须在这里先做好再传进去
          final weather = await fetchDayWeather(bundle.region.name);
          if (!mounted) return;
          final overlay = Overlay.of(context);
          await const TripPosterExporter().saveToGallery(
            overlay,
            bundle,
            day: widget.dayIndex,
            attractions: attractions,
            tags: tags,
            dayWeather: weather.days,
            weatherHorizonDays: weather.horizonDays > 0
                ? weather.horizonDays
                : kForecastHorizonDays,
          );
          if (mounted) {
            AppToast.show(
              context,
              Platform.isAndroid || Platform.isIOS
                  ? '已保存到相册'
                  : '已保存到下载文件夹',
            );
          }
        });
        return;

      case 'image_share':
        await _runExport(() async {
          final repo = ref.read(repoProvider);
          final bundle = await repo.loadBundle(widget.trip.id);
          if (bundle == null) return;
          final attractions = await repo.attractionsOf(bundle.region.id);
          final tags =
              await repo.tagsOfMany(attractions.map((a) => a.id).toList());
          final weather = await fetchDayWeather(bundle.region.name);
          if (!mounted) return;
          final overlay = Overlay.of(context);
          await const TripPosterExporter().renderAndShare(
            overlay,
            bundle,
            day: widget.dayIndex,
            attractions: attractions,
            tags: tags,
            dayWeather: weather.days,
            weatherHorizonDays: weather.horizonDays > 0
                ? weather.horizonDays
                : kForecastHorizonDays,
          );
        });
        return;
    }
  }

  /// 统一的导出包装：转圈 + 失败提示
  Future<void> _runExport(Future<void> Function() work) async {
    setState(() => _busy = true);
    try {
      await work();
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 和另一天对调两天的全部安排。
  /// 场景：临时改了出行顺序（第 3 天的事挪到第 2 天），又不想手动搬每一条。
  Future<void> _swapDay() async {
    final trip = widget.trip;
    final totalDays = trip.endDate.difference(trip.startDate).inDays + 1;
    if (totalDays < 2) {
      AppToast.show(context, '行程只有一天，没法对调');
      return;
    }

    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Text('第 ${widget.dayIndex} 天和哪天对调？',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              const Divider(height: 1),
              for (var d = 1; d <= totalDays; d++)
                if (d != widget.dayIndex)
                  ListTile(
                    leading: const Icon(Icons.swap_vert),
                    title: Text('第 $d 天'),
                    subtitle: const Text('两天的安排整个互换',
                        style: TextStyle(fontSize: 11)),
                    onTap: () => Navigator.pop(ctx, d),
                  ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;

    await ref
        .read(repoProvider)
        .swapDays(widget.trip.id, widget.dayIndex, picked);
    widget.onChanged();
    if (!mounted) return;
    AppToast.show(context, '第 ${widget.dayIndex} 天和第 $picked 天已对调');
  }

  Future<void> _clearDay() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清空第 ${widget.dayIndex} 天？'),
        content: const Text(
          '这一天的所有安排都会被删掉，无法恢复。\n\n'
          '后面的天数不会往前挪（第3天还是第3天）。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final n = await ref
        .read(repoProvider)
        .clearDay(widget.trip.id, widget.dayIndex);
    widget.onChanged();
    if (!mounted) return;
    AppToast.show(context, '已清空 $n 项');
  }
}

/// 单个时段模块（早餐/上午/…）
class _BlockSection extends ConsumerWidget {
  const _BlockSection({
    required this.trip,
    required this.dayIndex,
    required this.block,
    required this.items,
    required this.attrById,
    required this.onChanged,
    this.isOnlyBlock = false,
  });

  final Trip trip;
  final int dayIndex;
  final TimeBlock? block;
  final List<ItineraryItem> items;

  /// 景点库实时数据，条目显示时联动（库里改名/改备注行程跟着变）
  final Map<String, Attraction> attrById;
  final VoidCallback onChanged;

  /// 这天只剩这一个时段了。为 true 时不让删（删了那天就空了）
  final bool isOnlyBlock;

  /// 拖拽排序落库。
  ///
  /// ⚠️ 必须 await + 报错：`reorderItems` 是逐条 UPDATE、且不在事务里，
  ///    中途失败会留下 seq 半新半旧。以前这里是「发了不管」，
  ///    写失败时界面顺序变了、库里没变 —— 下次刷新顺序「自己变回去」。
  Future<void> _reorder(
    BuildContext context,
    WidgetRef ref,
    List<String> ids,
  ) async {
    try {
      await ref.read(repoProvider).reorderItems(ids);
    } catch (_) {
      if (context.mounted) {
        AppToast.show(context, '排序没保存成功，请再拖一次');
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 时段名可能被用户改过，从 provider 取
    final labels = ref.watch(blockLabelsProvider).valueOrNull;
    final label = block == null
        ? '其他'
        : (labels?[block] ?? kTimeBlockLabels[block]!);
    final theme_ = _blockAccent(block);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 整个头部可以长摁 → 改时段名 / 清空这个时段
          GestureDetector(
            onLongPress: block == null ? null : () => _blockMenu(context, ref),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 16,
                  decoration: BoxDecoration(
                    color: theme_,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: items.isEmpty ? theme.colorScheme.outline : null,
                  ),
                ),
                const SizedBox(width: 6),
                Text('${items.length}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
                const Spacer(),
                // 「从景点库选」已上移到行程右上角 AppBar（带地区名）；
                // 这里只留手动添加一站
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 19,
                  icon: const Icon(Icons.add),
                  tooltip: '手动添加',
                  onPressed: () => _addManual(context),
                ),
              ],
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 11, bottom: 6),
              child: Text('—',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            )
          else
            // 模块内可拖动排序：长按右侧拖把手上下移动
            //（如下午的 滕王阁→八一广场→万寿宫 想换先后）
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: true,
              itemCount: items.length,
              // ⚠️ 这里用的是**已废弃的** onReorder，别顺手换成 onReorderItem：
              //    onReorder 收到的是「未按移除项调整过」的 newIndex，所以需要
              //    下面那行 `if (newIndex > oldIndex) newIndex--;` 手工修正；
              //    onReorderItem 已由框架做完这个调整，迁移时必须把那一行**删掉**，
              //    否则反向拖动会错位一格。
              onReorder: (oldIndex, newIndex) {
                final ids = items.map((e) => e.id).toList();
                if (newIndex > oldIndex) newIndex--;
                final id = ids.removeAt(oldIndex);
                ids.insert(newIndex, id);
                // 落库后 stream 自动刷新列表顺序
                _reorder(context, ref, ids);
              },
              itemBuilder: (context, i) {
                final it = items[i];
                return KeyedSubtree(
                  key: ValueKey('reorder_${it.id}'),
                  child: _ItemTile(
                      tripId: trip.id,
                      item: it,
                      live: it.attractionId == null
                          ? null
                          : attrById[it.attractionId]),
                );
              },
            ),
          const Divider(height: 12),
        ],
      ),
    );
  }

  Future<void> _addManual(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ItemEditScreen(
          tripId: trip.id,
          dayIndex: dayIndex,
          timeBlock: block,
        ),
      ),
    );
  }

  /// 长摁时段头部弹出的菜单：改名字 / 清空这个时段
  Future<void> _blockMenu(BuildContext context, WidgetRef ref) async {
    final b = block!;
    final currentLabels = ref.read(blockLabelsProvider).valueOrNull;
    final currentLabel = currentLabels?[b] ?? kTimeBlockLabels[b]!;

    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        // ⚠️ 必须可滚动：菜单加了「互换」后有 6 项，小屏上固定 Column
        //    会把最后两项（清空/删掉）顶出屏幕外，看起来像「功能不见了」
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Text(currentLabel,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  const Spacer(),
                  Text('${items.length} 项',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('修改时段名称'),
              subtitle: Text('现在是「$currentLabel」',
                  style: const TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('在上面插入时段'),
              subtitle: const Text('插到这一个的前面',
                  style: TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, 'insert_before'),
            ),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('在下面插入时段'),
              subtitle: const Text('插到这一个的后面',
                  style: TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, 'insert_after'),
            ),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.swap_horiz),
              title: const Text('和其他模块互换'),
              subtitle: const Text('两处内容整个对调，可跨天',
                  style: TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, 'swap_module'),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.backspace_outlined),
              title: const Text('清空里面内容'),
              subtitle: const Text('保留时段，只删掉里面的安排',
                  style: TextStyle(fontSize: 11)),
              enabled: items.isNotEmpty,
              onTap: () => Navigator.pop(ctx, 'clear'),
            ),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: Icon(
                Icons.delete_outline,
                color: isOnlyBlock ? Colors.grey : Colors.red,
              ),
              title: Text(
                '删掉这个时段',
                style: TextStyle(color: isOnlyBlock ? Colors.grey : Colors.red),
              ),
              subtitle: Text(
                isOnlyBlock
                    ? '这是这天最后一个时段，不能删'
                    : '第 $dayIndex 天不再显示「$currentLabel」'
                        '${items.isNotEmpty ? '，里面的 ${items.length} 项也会删掉' : ''}',
                style: const TextStyle(fontSize: 11),
              ),
              enabled: !isOnlyBlock,
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
        ),
      ),
    );

    if (!context.mounted || choice == null) return;

    switch (choice) {
      case 'rename':
        await _renameBlock(context, ref, b, currentLabel);
      case 'clear':
        await _clearBlock(context, ref, b, currentLabel);
      case 'delete':
        await _deleteBlock(context, ref, b, currentLabel);
      case 'insert_before':
        await _insertBlock(context, ref, afterBlock: null);
      case 'insert_after':
        await _insertBlock(context, ref, afterBlock: b.name);
      case 'swap_module':
        await _swapModule(context, ref);
    }
  }

  /// 和其他模块互换内容：天内互换（上午↔下午）或跨天互换（第2天上午↔第3天晚上）
  Future<void> _swapModule(BuildContext context, WidgetRef ref) async {
    // ⚠️ 这个守卫必须有，和 _swapDay 一样。
    //    没有它的话，单天行程打开互换面板时默认目标会算成「第 2 天」——
    //    那是个界面上根本不存在、也不渲染的天，用户一点就把内容搬过去，
    //    看着就是「内容凭空消失了」。
    final totalDays = trip.endDate.difference(trip.startDate).inDays + 1;
    if (totalDays < 2) {
      AppToast.show(context, '行程只有一天，没有别的天可以对调');
      return;
    }

    final picked = await showModalBottomSheet<({int day, TimeBlock block})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SwapModuleSheet(
        trip: trip,
        currentDay: dayIndex,
        currentBlock: block!,
      ),
    );
    if (picked == null || !context.mounted) return;

    try {
      await ref
          .read(repoProvider)
          .swapBlocks(trip.id, dayIndex, block, picked.day, picked.block);
    } catch (e) {
      // 数据层拒绝越界搬运时不会真的改数据，告诉用户就行
      if (context.mounted) AppToast.show(context, '互换没成功：$e');
      return;
    }
    onChanged();
    if (context.mounted) {
      AppToast.show(
          context,
          '已互换：第 $dayIndex 天${kTimeBlockLabels[block]}'
          ' ↔ 第 ${picked.day} 天${kTimeBlockLabels[picked.block]}');
    }
  }

  /// 插入一个新时段。
  ///
  /// [afterBlock] 为空 = 插到最前；否则插到它后面。
  ///
  /// 实现说明：时段只有六个枚举值，所以「新增」实际是
  /// 「把某个还没显示的时段插进来」，并给它起个名字。
  /// 六个都用完了就提示用户——不支持真正意义上的「第七个时段」，
  /// 那需要改枚举和数据库，成本远大于收益。
  Future<void> _insertBlock(
    BuildContext context,
    WidgetRef ref, {
    String? afterBlock,
  }) async {
    final repo = ref.read(repoProvider);
    // 先取好 labels，别等 await 之后再碰 ref
    final labels = ref.read(blockLabelsProvider).valueOrNull;

    final used = (await repo.blocksOf(trip.id, dayIndex)).toSet();
    final available =
        TimeBlock.values.where((b) => !used.contains(b)).toList();

    if (!context.mounted) return;
    if (available.isEmpty) {
      AppToast.show(context, '六个时段都在这天了，删掉一个再插');
      return;
    }

    final picked = await showModalBottomSheet<TimeBlock>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('插入哪个时段',
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const Divider(height: 1),
            for (final b in available)
              ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(labels?[b] ?? kTimeBlockLabels[b]!),
                onTap: () => Navigator.pop(ctx, b),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;

    await repo.insertBlock(trip.id, dayIndex, picked, afterBlock: afterBlock);
    onChanged();
    if (context.mounted) {
      AppToast.show(
        context,
        '已插入「${labels?[picked] ?? kTimeBlockLabels[picked]!}」',
      );
    }
  }

  /// 把整个时段从这一天删掉（6 个变 5 个）
  Future<void> _deleteBlock(
    BuildContext context,
    WidgetRef ref,
    TimeBlock b,
    String label,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删掉「$label」这个时段？'),
        content: Text(
          items.isEmpty
              ? '第 $dayIndex 天将不再显示「$label」，剩下 5 个时段。'
              : '第 $dayIndex 天的「$label」里有 ${items.length} 项，'
                  '会一起删掉，无法恢复。\n\n删掉后这天剩 5 个时段。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删掉'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final n = await ref
        .read(repoProvider)
        .deleteBlock(trip.id, dayIndex, b);
    onChanged();
    if (context.mounted) {
      AppToast.show(context, n > 0 ? '已删掉「$label」（含 $n 项）' : '已删掉「$label」');
    }
  }

  Future<void> _renameBlock(
    BuildContext context,
    WidgetRef ref,
    TimeBlock b,
    String currentLabel,
  ) async {
    final ctrl = TextEditingController(text: currentLabel);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「${kTimeBlockLabels[b]}」叫什么'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '名称',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '留空恢复成「${kTimeBlockLabels[b]}」',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();

    if (saved == null) return;
    await ref.read(repoProvider).setBlockLabel(b, saved);
    ref.invalidate(blockLabelsProvider);
    if (context.mounted) AppToast.show(context, '已更新');
  }

  Future<void> _clearBlock(
    BuildContext context,
    WidgetRef ref,
    TimeBlock b,
    String label,
  ) async {
    if (items.isEmpty) {
      AppToast.show(context, '「$label」本来就没有安排');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清空「$label」？'),
        content: Text(
          '第 $dayIndex 天的「$label」里有 ${items.length} 项，都会被删掉，无法恢复。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    // 走仓库的事务方法，不再在这里循环调 deleteItem：
    // 循环是 N 次独立写，删到一半抛异常就只清掉一部分，界面和库对不上。
    try {
      final n = await ref
          .read(repoProvider)
          .clearBlock(trip.id, dayIndex, block);
      onChanged();
      if (context.mounted) AppToast.show(context, '已清空 $n 项');
    } catch (_) {
      if (context.mounted) AppToast.show(context, '清空失败，请再试一次');
    }
  }


  static Color _blockAccent(TimeBlock? b) => switch (b) {
        TimeBlock.breakfast => const Color(0xFFE8A840),
        TimeBlock.morning => const Color(0xFF5B8EC9),
        TimeBlock.lunch => const Color(0xFFE8783A),
        TimeBlock.afternoon => const Color(0xFF5AAA75),
        TimeBlock.dinner => const Color(0xFF9B7BC9),
        TimeBlock.evening => const Color(0xFF7B9CB5),
        null => Colors.grey,
      };
}

class _ItemTile extends ConsumerWidget {
  const _ItemTile({
    required this.tripId,
    required this.item,
    this.live,
  });

  final String tripId;
  final ItineraryItem item;

  /// 关联的景点库实时数据（attractionId 命中时非空）。
  /// 显示优先用库里的最新值——添加时拷贝的 customName/note 只是
  /// 景点被删后的兜底，不该覆盖用户在景点库做的后续编辑。
  final Attraction? live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final displayName = live?.name ?? item.customName ?? '(未命名)';
    final displayNote =
        (item.note != null && item.note!.isNotEmpty) ? item.note : live?.note;
    final timeText = [
      if (item.arriveTime != null) item.arriveTime!,
      if (item.leaveTime != null) item.leaveTime!,
    ].join('-');

    return Dismissible(
      key: ValueKey(item.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: theme.colorScheme.error.withValues(alpha: 0.8),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async =>
          await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('删除这一项？'),
              content: Text(item.customName ?? '这一项'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除')),
              ],
            ),
          ) ??
          false,
      // 滑动删除。写失败要报出来：条目会随 stream 刷新「自己回来」，
      // 不提示的话用户只会觉得删了又出现、像见了鬼。
      onDismissed: (_) async {
        try {
          await ref.read(repoProvider).deleteItem(item.id);
        } catch (_) {
          if (context.mounted) {
            AppToast.show(context, '删除没成功，条目已恢复');
          }
        }
      },
      child: InkWell(
        // 点条目 → 编辑（改名/时段/时间/交通/住宿/备注，也能删除）
        onTap: () async {
          final ok = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => ItemEditScreen(
                tripId: tripId,
                dayIndex: item.dayIndex,
                itemId: item.id,
              ),
            ),
          );
          if (ok == true) ref.invalidate(tripItemsProvider(tripId));
        },
        child: Padding(
          padding: const EdgeInsets.only(left: 11, top: 2, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Icon(Icons.circle,
                    size: 5, color: theme.colorScheme.outline),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayName,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        if (timeText.isNotEmpty)
                          Text(timeText,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                              )),
                      ],
                    ),
                    if (item.hotelName != null)
                      Text('🏨 ${item.hotelName}',
                          style: theme.textTheme.bodySmall),
                    if (displayNote != null && displayNote.isNotEmpty)
                      Text(
                        displayNote.split('\n').first,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 景点库选择器
// ══════════════════════════════════════════════════════════════

class _LibraryPicker extends ConsumerStatefulWidget {
  const _LibraryPicker({
    required this.tripId,
    this.regionName,
  });

  final String tripId;

  /// 景点库地区名（AppBar 标题「从XX景点库选」+ 高德搜索 city 限定用）
  final String? regionName;

  @override
  ConsumerState<_LibraryPicker> createState() => _LibraryPickerState();
}

class _LibraryPickerState extends ConsumerState<_LibraryPicker> {
  String _query = '';
  String? _tagFilter;
  String? _kindFilter;

  // ══ 天 / 时段选择（入口上移到行程 AppBar 后在这里选）══
  int _selDay = 1;
  TimeBlock? _selBlock;
  List<TimeBlock> _selBlocks = [];

  // ══ 活地图 ══
  final _mapController = MapController();
  final _tileProvider = CachedTileProvider();

  /// 当前选中的本地景点（点地图标记或列表行）：
  /// 地图上黑框 + 头顶名字标签；列表自动滚到该行顶部
  String? _selectedId;

  /// 底部面板控制器：头部全域可拖 + 滑光后唤回
  final _sheetCtrl = DraggableScrollableController();
  double _sheetFraction = 0.58;

  /// 首次把点带进可见窗口只做一次（见 _focusInitialIfNeeded）
  bool _initialFocusDone = false;

  /// 高德搜索的「世代号」：只认最后一次请求的结果。
  /// 网络慢时先发的可能后返回，不校验会把旧关键词的结果盖到新关键词上。
  int _searchGen = 0;

  /// 最近一次请求加载的天号，用于丢弃过期的 _loadBlocksForDay 响应
  int _pendingDay = 1;

  /// 列表行固定高度（itemExtent），用于按下标精确滚动定位——
  /// GlobalKey.ensureVisible 对「从未构建过的屏幕外行」拿不到位置，
  /// 这就是之前「点标记概率性不联动」的根因
  static const double _rowExtent = 64.0;

  // ══ 高德搜索（和全景地图共用一套接口）══
  // 候选条目：点击 = 地图飞过去聚焦；➕ = 加进行程 + 收进景点库
  Timer? _webDebounce;
  List<GeoPoint> _webResults = [];
  bool _webSearching = false;

  /// 正在聚焦预览的高德候选（纯查看）
  GeoPoint? _webPreview;

  @override
  void initState() {
    super.initState();
    _loadBlocksForDay(1);
    _sheetCtrl.addListener(() {
      if (!mounted) return;
      final s = _sheetCtrl.size;
      // ⚠️ 只在跨过「滑光」阈值时重建。
      // 原来是无条件 setState：拖面板的每一帧都会连带重建地图和整个列表，
      // 白白掉帧。_sheetFraction 本身只是给 _focusOn 兜底用的，
      // 不重建也要保持最新，否则视野判定会用上一帧的值。
      final wasCollapsed = _sheetFraction < 0.03;
      _sheetFraction = s;
      if (wasCollapsed != (s < 0.03)) setState(() {});
    });
  }

  @override
  void dispose() {
    _mapController.dispose();
    _sheetCtrl.dispose();
    _webDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadBlocksForDay(int day) async {
    _pendingDay = day;
    final blocks = await ref.read(repoProvider).blocksOf(widget.tripId, day);
    if (!mounted) return;
    // 连点「第 1 天 / 第 2 天」时，先发的请求可能后返回：
    // 不校验就会把旧天的时段写回去，顶部选的天和列表对不上。
    if (day != _pendingDay) return;
    setState(() {
      _selDay = day;
      _selBlocks = blocks;
      if (!_selBlocks.contains(_selBlock)) {
        _selBlock = _selBlocks.isEmpty ? null : _selBlocks.first;
      }
    });
  }

  int get _webSectionCount => _query.trim().isEmpty
      ? 0
      : 1 + (_webSearching ? 1 : 0) + _webResults.length;

  /// 搜高德（城市限定为行程地区，避免同名外地店）
  Future<void> _searchWeb(String query) async {
    final q = query.trim();
    final gen = ++_searchGen;
    if (q.isEmpty) {
      if (mounted) {
        setState(() {
          _webResults = [];
          _webSearching = false;
        });
      }
      return;
    }
    setState(() => _webSearching = true);
    final res = await Geocoder().searchPlaces(q, city: widget.regionName);
    if (!mounted) return;
    // 期间用户又改了关键词 → 丢掉这次旧结果，
    // 否则列表会闪回上一个关键词的条目
    if (gen != _searchGen) return;
    setState(() {
      _webResults = res.points;
      _webSearching = false;
    });
    // 请求失败要说出来，不能让它看起来像「真的没搜到」
    if (res.error != null && mounted) AppToast.show(context, res.error!);
  }

  /// 本地景点 ➕：加入选中的天/时段，toast 后留在本页继续挑
  Future<void> _addLocalToTrip(Attraction a) async {
    if (_selBlock == null) {
      // 这一天一个时段都没有（用户把时段全删了）。给明确反馈，
      // 否则点了 ➕ 毫无动静，看着像按钮坏了。
      AppToast.show(context, '第 $_selDay 天还没有时段，先在行程里加一个时段');
      return;
    }
    final repo = ref.read(repoProvider);
    final seq = await repo.nextSeqInBlock(widget.tripId, _selDay, _selBlock);
    await repo.addItem(
      tripId: widget.tripId,
      dayIndex: _selDay,
      seq: seq,
      timeBlock: _selBlock,
      customName: a.name,
      attractionId: a.id,
      note: a.note,
    );
    if (mounted) {
      AppToast.show(
          context, '已加入第 $_selDay 天 · ${kTimeBlockLabels[_selBlock]}');
    }
  }

  /// 高德候选的 ➕：**加进行程 + 收进景点库**，一步到位。
  /// （全景地图入口的 ➕ 只收库——那是纯资料场景；这里是模块入口。）
  Future<void> _addWebToLibrary(GeoPoint spot) async {
    final kind = await showModalBottomSheet<PlaceKind>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('「${spot.showName}」收为',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Text('🍜', style: TextStyle(fontSize: 18)),
              title: const Text('吃'),
              onTap: () => Navigator.pop(ctx, PlaceKind.eat),
            ),
            ListTile(
              leading: const Text('🏛', style: TextStyle(fontSize: 18)),
              title: const Text('玩'),
              onTap: () => Navigator.pop(ctx, PlaceKind.play),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    if (_selBlock == null) {
      // 用户已经在弹窗里选完「吃/玩」了，这里再静默退出等于白选一场。
      AppToast.show(context, '第 $_selDay 天还没有时段，先在行程里加一个时段');
      return;
    }

    final repo = ref.read(repoProvider);
    final trip = await repo.getTrip(widget.tripId);
    if (trip == null) return;

    final all = await repo.attractionsOf(trip.regionId);
    final existing = all.where((a) => a.name == spot.showName).firstOrNull;
    String attractionId;
    if (existing != null) {
      attractionId = existing.id;
      if (existing.lat == null || existing.lng == null) {
        await repo.setAttractionCoords(
            existing.id, lat: spot.lat, lng: spot.lng);
      }
    } else {
      attractionId = await repo.addAttraction(
        regionId: trip.regionId,
        name: spot.showName,
        kind: kind.name,
        address: (spot.address != null && spot.address!.isNotEmpty)
            ? spot.address
            : spot.displayName,
        lat: spot.lat,
        lng: spot.lng,
      );
    }

    final seq = await repo.nextSeqInBlock(widget.tripId, _selDay, _selBlock);
    await repo.addItem(
      tripId: widget.tripId,
      dayIndex: _selDay,
      seq: seq,
      timeBlock: _selBlock,
      customName: spot.showName,
      attractionId: attractionId,
    );

    ref.invalidate(regionAttractionsProvider(trip.regionId));
    ref.invalidate(regionTagsProvider(trip.regionId));
    if (mounted) {
      AppToast.show(
          context,
          '已加入第 $_selDay 天并收进景点库'
          '（${kind == PlaceKind.eat ? "🍜 吃" : "🏛 玩"}）');
    }
  }

  /// 高德结果区的行：第 0 行是分隔标题/加载圈，其余是候选
  Widget _buildWebRow(BuildContext context, int j, Set<String> localNames) {
    if (j == 0) {
      if (_webSearching) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Center(
            child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          '地图上的结果（点条目在地图上查看，➕ 加入行程并收库）',
          style: TextStyle(
              fontSize: 11, color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    final spot = _webResults[j - 1];
    final inLibrary = localNames.contains(spot.showName);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.travel_explore, size: 18),
      title: Text(spot.showName,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      subtitle: Text(
        (spot.address != null && spot.address!.isNotEmpty)
            ? spot.address!
            : spot.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: inLibrary
          ? const Icon(Icons.check_circle, size: 18, color: Colors.green)
          : IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 20,
              icon: const Icon(Icons.add_circle),
              tooltip: '加入行程并收进景点库',
              onPressed: () => _addWebToLibrary(spot),
            ),
      // 点条目 = 地图飞过去聚焦（搜索是带你去看没看过的地方）
      onTap: () {
        setState(() => _webPreview = spot);
        // 搜到的点必须飞到可见窗口里——用 _focusOn 而不是直接 move：
        // 直接 move 会把点放在控件几何中心，也就是被面板盖住的那一半
        _focusOn(
          LatLng(spot.lat, spot.lng),
          zoom: 16,
          force: true,
        );
      },
    );
  }

  /// 按 index 精确滚动列表到该行顶部（行高固定，见 _rowExtent）
  void _scrollListToIndex(int index) {
    if (index < 0) return;
    // scrollController 在 sheet builder 里才存在，借由监听取不到——
    // 这里通过 ValueNotifier 中转：marker 场景直接用 _lastListCtrl
    final ctrl = _lastListCtrl;
    if (ctrl == null || !ctrl.hasClients) return;
    final target = (index * _rowExtent)
        .clamp(0.0, ctrl.position.maxScrollExtent);
    ctrl.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  ScrollController? _lastListCtrl;

  /// 把某个坐标点带进「**可见**地图窗口」，必要时平移（不改缩放）。
  ///
  /// ⚠️ 这是本界面**唯一**允许计算视野的地方。别再在别处自己算 effH / 位移——
  ///    之前就是三处调用点各算各的，其中一处符号写反，才出的「地图乱飞」。
  ///
  /// 关键背景：地图控件是整屏的（`Positioned.fill`），但底部选点面板会盖住
  /// 下面一大块，所以**控件几何中心并不是用户看到的中心**。flutter_map 不认
  /// 这件事（`initialCenter` / `move` / `latLngToScreenOffset` 一律按控件几何
  /// 中心算），必须在这里补偿，否则目标点会落在面板底下、看着像没反应。
  ///
  /// [fx]/[fy]：目标落在可见窗口内的相对位置（0=左/上，1=右/下）。
  /// 不传则按「从哪边来」自动取 0.8/0.2，让点停在靠近中心的位置。
  /// 已经在窗口内的点**什么都不做**，避免「点一下就跳」；
  /// 确实要强行飞过去（比如搜索结果聚焦）时传 [force] = true。
  void _focusOn(
    LatLng target, {
    double? fx,
    double? fy,
    double? zoom,
    bool force = false,
  }) {
    try {
      final cam = _mapController.camera;
      final size = cam.size;

      // 可见窗口高度 = 面板顶边以上的部分。
      // 面板占比优先实时读控制器（拖动过程中字段可能落后一帧）。
      final sheet = _sheetCtrl.isAttached ? _sheetCtrl.size : _sheetFraction;
      final effH = size.height * (1.0 - sheet);
      if (effH <= 0) return;

      final p = cam.latLngToScreenOffset(target);
      // 已经在可见窗口内 → 不动（除非调用方要求强行聚焦）
      if (!force &&
          p.dx >= 0 &&
          p.dx <= size.width &&
          p.dy >= 0 &&
          p.dy <= effH) {
        return;
      }

      final rfx = fx ?? (p.dx > size.width ? 0.8 : (p.dx < 0 ? 0.2 : 0.5));
      final rfy = fy ?? (p.dy > effH ? 0.8 : (p.dy < 0 ? 0.2 : 0.5));
      final q = Offset(rfx * size.width, (rfy * effH).clamp(0.0, effH));

      // delta = 点需要移动的位移；地图内容反向移动同样的量。
      //
      // ⚠️ 这里旧代码写的是 `size.center + (p - q)`，等于把 delta 反号，
      //    结果把点推得**更远**：越点屏幕外的条目，地图越朝反方向跑，
      //    且每次点击都翻倍发散——用户看到的就是「点一次切一次、胡乱切」。
      final delta = q - p;
      _mapController.move(
        cam.screenOffsetToLatLng(size.center(Offset.zero) - delta),
        zoom ?? cam.zoom,
      );
    } catch (_) {
      // 地图尚未挂载（首帧前）忽略
    }
  }

  /// 地图首次挂载后，把第一个有坐标的点带到**可见窗口**的正中央。
  ///
  /// 不能只靠 `MapOptions.initialCenter`：它按控件几何中心定位，而控件是整屏的
  /// （底部面板盖住一大半），于是那个点落在面板底下，用户看到的是它北边的一块
  /// 地图——这就是「地图中心没放对」。
  void _focusInitialIfNeeded(List<Attraction> all) {
    if (_initialFocusDone) return;
    final withCoords =
        all.where((a) => a.lat != null && a.lng != null).toList();
    if (withCoords.isEmpty) return;
    _initialFocusDone = true;

    final a = withCoords.first;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 落点取可见窗口正中心（0.5/0.5），与 initialZoom 保持一致
      _focusOn(LatLng(a.lat!, a.lng!), fx: 0.5, fy: 0.5, zoom: 12, force: true);
    });
  }

  /// 列表行点击 → 选中（地图标记高亮 + 该行滚到可视区顶部）
  /// 再点同一行 = 取消选中。
  void _selectLocal(Attraction a, int rowIndex, ScrollController listCtrl) {
    final deselect = a.id == _selectedId;
    setState(() {
      _selectedId = deselect ? null : a.id;
      _webPreview = null;
    });
    if (deselect) return;

    // 滚动定位：行高固定（itemExtent），按下标精确计算——
    // 不依赖行的构建状态，屏幕外多远都能一次到位
    if (listCtrl.hasClients) {
      final target = (rowIndex * _rowExtent)
          .clamp(0.0, listCtrl.position.maxScrollExtent);
      listCtrl.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }

    if (a.lat == null || a.lng == null) return;
    // 纵向落在可见窗口 0.8 处（偏下、靠近面板，视线自然）；横向按来向自动取
    _focusOn(LatLng(a.lat!, a.lng!), fy: 0.8);
  }

  @override
  Widget build(BuildContext context) {
    final tripAsync = ref.watch(tripProvider(widget.tripId));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.regionName == null
            ? '从景点库选'
            : '从${widget.regionName}景点库选'),
      ),
      body: tripAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('出错了：$e')),
        data: (trip) {
          if (trip == null) {
            return const Center(child: Text('行程不存在'));
          }
          final totalDays =
              trip.endDate.difference(trip.startDate).inDays + 1;
          final listAsync =
              ref.watch(regionAttractionsProvider(trip.regionId));

          return listAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('出错了：$e')),
            data: (attractions) {
              final tagMap =
                  ref.watch(regionTagsProvider(trip.regionId)).valueOrNull ??
                      const <String, List<String>>{};

              final allTags = <String>{
                for (final v in tagMap.values) ...v,
              }.toList()
                ..sort();

              // 标签匹配始终用默认时段名（导入时按 category 生成）
              final blockTag =
                  _selBlock == null ? null : kTimeBlockLabels[_selBlock];
              final labels = ref.watch(blockLabelsProvider).valueOrNull;
              final blockDisplay = _selBlock == null
                  ? '—'
                  : (labels?[_selBlock] ?? kTimeBlockLabels[_selBlock]!);

              var list = attractions;

              if (_kindFilter != null) {
                list = list.where((a) => a.kind == _kindFilter).toList();
              }
              if (_tagFilter != null) {
                list = list
                    .where((a) =>
                        (tagMap[a.id] ?? const []).contains(_tagFilter))
                    .toList();
              }
              if (_query.isNotEmpty) {
                final q = _query.toLowerCase();
                list = list
                    .where((a) => a.name.toLowerCase().contains(q))
                    .toList();
              }

              // 排序（筛选前后规则一致）：
              //   1. 带「早餐」等当前模块标签的排最前
              //   2. 推荐星级降序（没打星的排有星的后面）
              //   3. 没坐标的沉底
              //   4. 同级按名字
              // （选中项不再重排——改为列表滚动到该行，见 _selectLocal）
              list = [...list]..sort((a, b) {
                  int score(Attraction x) {
                    final tags = tagMap[x.id] ?? const <String>[];
                    if (blockTag != null && tags.contains(blockTag)) {
                      return 0;
                    }
                    if (tags.isNotEmpty) return 1;
                    return 2;
                  }

                  final d = score(a) - score(b);
                  if (d != 0) return d;

                  final lv = (b.recommendLevel ?? 0)
                      .compareTo(a.recommendLevel ?? 0);
                  if (lv != 0) return lv;

                  final aNoCoord = a.lat == null || a.lng == null;
                  final bNoCoord = b.lat == null || b.lng == null;
                  if (aNoCoord != bNoCoord) return aNoCoord ? 1 : -1;

                  return a.name.compareTo(b.name);
                });

              final matchedCount = blockTag == null
                  ? 0
                  : list
                      .where((a) =>
                          (tagMap[a.id] ?? const []).contains(blockTag))
                      .length;

              final localNames = {for (final a in attractions) a.name};

              // 首帧后把第一个点带进可见窗口（修正 initialCenter 按几何中心
              // 定位、被面板盖住的问题）
              _focusInitialIfNeeded(attractions);

              // ══ 布局：地图全屏铺底，搜索框+列表在可拖拽面板里 ══
              // 面板滑到底只剩小尾巴时，就是纯看地图。
              return Stack(
                children: [
                  Positioned.fill(
                    child: _PickerMiniMap(
                      attractions: list,
                      allPlaces: attractions,
                      previewId: _selectedId,
                      mapController: _mapController,
                      tileProvider: _tileProvider,
                      webSpots: _webResults,
                      webPreview: _webPreview,
                      onSelect: (a) {
                        // 点标记 = 选中/取消（与列表行联动）
                        setState(() {
                          _selectedId = a.id == _selectedId ? null : a.id;
                          _webPreview = null;
                        });
                        if (_selectedId != null) {
                          _scrollListToIndex(list.indexOf(a));
                        }
                      },
                    ),
                  ),
                  // 面板完全滑光（size==0）时显示悬浮拉手，点一下唤回
                  if (_sheetFraction < 0.03)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 14,
                      child: Center(
                        child: GestureDetector(
                          onTap: () => _sheetCtrl.animateTo(
                            0.58,
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.keyboard_arrow_up,
                                    size: 16, color: Colors.white),
                                SizedBox(width: 2),
                                Text('选点面板',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  DraggableScrollableSheet(
                    controller: _sheetCtrl,
                    initialChildSize: 0.58,
                    minChildSize: 0.0,
                    maxChildSize: 0.85,
                    snap: true,
                    snapSizes: const [0.0, 0.58],
                    builder: (context, scrollController) {
                      _lastListCtrl = scrollController;
                      return Container(
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius:
                              BorderRadius.vertical(top: Radius.circular(16)),
                          boxShadow: [
                            BoxShadow(color: Colors.black12, blurRadius: 8),
                          ],
                        ),
                        child: Material(
                          type: MaterialType.transparency,
                          child: Column(
                            children: [
                              // ⚠️ 头部（小尾巴→搜索框→标签条）整体可拖——
                              // 之前只有列表区域能拖动面板，在搜索框上滑动
                              // 没反应，面板卡在半路「滑不下去」
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragUpdate: (d) {
                                  final h = context.size!.height;
                                  final next = (_sheetCtrl.size -
                                          d.primaryDelta! / h)
                                      .clamp(0.0, 0.85);
                                  _sheetCtrl.animateTo(
                                    next,
                                    duration: Duration.zero,
                                    curve: Curves.linear,
                                  );
                                },
                                onVerticalDragEnd: (d) {
                                  final v = d.primaryVelocity ?? 0;
                                  final target = v > 120
                                      ? 0.0
                                      : (v < -120
                                          ? 0.58
                                          : (_sheetCtrl.size < 0.3
                                              ? 0.0
                                              : 0.58));
                                  _sheetCtrl.animateTo(
                                    target,
                                    duration:
                                        const Duration(milliseconds: 220),
                                    curve: Curves.easeOut,
                                  );
                                },
                                child: Column(
                                  children: [
                              // 小尾巴：滑到这里只剩它，往上一拉恢复面板
                              Container(
                                width: 36,
                                height: 4,
                                margin:
                                    const EdgeInsets.only(top: 8, bottom: 4),
                                decoration: BoxDecoration(
                                  color:
                                      Theme.of(context).colorScheme.outlineVariant,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (var d = 1; d <= totalDays; d++)
                                      ChoiceChip(
                                        label: Text('第$d天',
                                            style:
                                                const TextStyle(fontSize: 12)),
                                        selected: _selDay == d,
                                        visualDensity: VisualDensity.compact,
                                        onSelected: (_) => _loadBlocksForDay(d),
                                      ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final b in _selBlocks)
                                      ChoiceChip(
                                        label: Text(
                                            labels?[b] ?? kTimeBlockLabels[b]!,
                                            style: const TextStyle(
                                                fontSize: 12)),
                                        selected: _selBlock == b,
                                        visualDensity: VisualDensity.compact,
                                        onSelected: (_) =>
                                            setState(() => _selBlock = b),
                                      ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                                child: Row(
                                  children: [
                                    Text(
                                      '选到 · $blockDisplay'
                                      '${matchedCount > 0 ? " · $matchedCount 个匹配" : ""}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14),
                                    ),
                                    const Spacer(),
                                    Text(
                                      _query.isEmpty
                                          ? '${list.length} 个'
                                          : '${list.length} + 地图${_webResults.length} 个',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        decoration: const InputDecoration(
                                          hintText: '搜景点库和地图…',
                                          isDense: true,
                                          prefixIcon: Icon(Icons.search, size: 18),
                                          border: OutlineInputBorder(),
                                        ),
                                        onChanged: (v) {
                                          setState(() => _query = v);
                                          _webDebounce?.cancel();
                                          _webDebounce = Timer(
                                              const Duration(milliseconds: 500),
                                              () => _searchWeb(v));
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    for (final k in const ['eat', 'play'])
                                      Padding(
                                        padding: const EdgeInsets.only(left: 4),
                                        child: FilterChip(
                                          label: Text(k == 'eat' ? '吃' : '玩',
                                              style: const TextStyle(
                                                  fontSize: 12)),
                                          selected: _kindFilter == k,
                                          visualDensity: VisualDensity.compact,
                                          onSelected: (sel) => setState(
                                              () => _kindFilter = sel ? k : null),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (allTags.isNotEmpty)
                                SizedBox(
                                  height: 34,
                                  child: ListView(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12),
                                    children: [
                                      for (final t in allTags)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(right: 6),
                                          child: FilterChip(
                                            label: Text(t,
                                                style: const TextStyle(
                                                    fontSize: 11)),
                                            selected: _tagFilter == t,
                                            visualDensity:
                                                VisualDensity.compact,
                                            onSelected: (sel) => setState(
                                                () => _tagFilter =
                                                    sel ? t : null),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: (list.isEmpty && _webSectionCount == 0)
                                    ? Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(24),
                                          child: Text(
                                            attractions.isEmpty
                                                ? '这个地区的景点库还是空的。\n先去「景点库」Tab 导入候选库。'
                                                : '没有匹配的条目',
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      )
                                    : Material(
                                        // ⚠️ 这一层透明 Material 是必需的，别删。
                                        //
                                        // ListTile 的底色/高亮（tileColor /
                                        // selectedTileColor）不是自己画的，而是注册到
                                        // **最近的 Material 祖先**的墨水层上。上面那个
                                        // Material 包住了整张面板（含搜索框、标签条），
                                        // 墨水层又不受 ListView 视口裁剪——于是滚出视口的
                                        // 被选中行会把蓝色画到搜索框甚至标题栏上，
                                        // 看着像「高亮穿透、从上面掉下来」。
                                        //
                                        // 在这里隔一层：墨水层被裁到列表自己的框，
                                        // 越界即被裁掉。改动虽小但根因就在这。
                                        type: MaterialType.transparency,
                                        child: ListView.builder(
                                            controller: scrollController,
                                            itemExtent: _rowExtent,
                                            itemCount:
                                                list.length + _webSectionCount,
                                            itemBuilder: (context, i) {
                                              if (i >= list.length) {
                                                return _buildWebRow(context,
                                                    i - list.length, localNames);
                                              }
                                              final a = list[i];
                                              final dur = a.suggestDurationMin;
                                              final durText = dur == null
                                                  ? null
                                                  : '${(dur / 60).toStringAsFixed(1)}h';
                                              final tags =
                                                  tagMap[a.id] ?? const <String>[];
                                              final hit = blockTag != null &&
                                                  tags.contains(blockTag);
                                              return ListTile(
                                                  dense: true,
                                                  selected: a.id == _selectedId,
                                                  selectedTileColor:
                                                      Theme.of(context)
                                                          .colorScheme
                                                          .primaryContainer,
                                                  tileColor: hit
                                                      ? Theme.of(context)
                                                          .colorScheme
                                                          .primaryContainer
                                                          .withValues(alpha: 0.35)
                                                      : null,
                                                  leading: (a.lat != null &&
                                                          a.lng != null)
                                                      ? const Icon(
                                                          Icons.place_outlined,
                                                          size: 18)
                                                      : const Icon(
                                                          Icons.place_outlined,
                                                          size: 18,
                                                          color: Colors.grey),
                                                  title: Text(a.name),
                                                  subtitle: Text(
                                                    [
                                                      if (tags.isNotEmpty)
                                                        tags.take(3).join(' · ')
                                                      else if (a.category != null)
                                                        a.category!,
                                                      if (a.address != null)
                                                        a.address!,
                                                    ].join(' · '),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        fontSize: 11),
                                                  ),
                                                  trailing: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      if (a.recommendLevel != null)
                                                        Text(
                                                            '★' * a.recommendLevel!,
                                                            style: const TextStyle(
                                                              fontSize: 11,
                                                              color: Color(
                                                                  0xFFE8A840),
                                                            )),
                                                      if (durText != null)
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.only(
                                                                  left: 5),
                                                          child: Container(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                                    horizontal: 6,
                                                                    vertical: 2),
                                                            decoration: BoxDecoration(
                                                              color: const Color(
                                                                      0xFF7B9CB5)
                                                                  .withValues(
                                                                      alpha: 0.12),
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(4),
                                                            ),
                                                            child: Text(
                                                              durText,
                                                              style:
                                                                  const TextStyle(
                                                                fontSize: 11,
                                                                color: Color(
                                                                    0xFF5B8EC9),
                                                                fontWeight:
                                                                    FontWeight.w600,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      IconButton(
                                                        visualDensity:
                                                            VisualDensity.compact,
                                                        iconSize: 20,
                                                        icon: const Icon(
                                                            Icons.add_circle),
                                                        tooltip: '加进这个时段',
                                                        onPressed: () =>
                                                            _addLocalToTrip(a),
                                                      ),
                                                    ],
                                                  ),
                                                  // 行点击 = 选中（标记高亮 + 滚到行顶 + 视野外平移）
                                                  onTap: () => _selectLocal(
                                                      a, i, scrollController),
                                                );
                                            },
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 「和其他模块互换」：选目标天 + 目标模块
// ══════════════════════════════════════════════════════════════

class _SwapModuleSheet extends ConsumerStatefulWidget {
  const _SwapModuleSheet({
    required this.trip,
    required this.currentDay,
    required this.currentBlock,
  });

  final Trip trip;
  final int currentDay;
  final TimeBlock currentBlock;

  @override
  ConsumerState<_SwapModuleSheet> createState() => _SwapModuleSheetState();
}

class _SwapModuleSheetState extends ConsumerState<_SwapModuleSheet> {
  /// 默认目标是「另一天」。
  ///
  /// ⚠️ 这里必须夹到行程的真实天数范围内：以前直接写 `currentDay == 1 ? 2 : 1`，
  ///    单天行程会得到「第 2 天」——一个界面上不存在、也不渲染的天，
  ///    用户点一下内容就被搬进黑洞。（调用方 _swapModule 也加了守卫，
  ///    这里是第二道防线，防止别处复用时再次踩坑。）
  late int _day = _defaultTargetDay();

  List<TimeBlock> _blocks = [];
  bool _loading = true;

  int _defaultTargetDay() {
    final total = widget.trip.endDate
            .difference(widget.trip.startDate)
            .inDays +
        1;
    if (total < 2) return widget.currentDay;
    return widget.currentDay == 1 ? 2 : 1;
  }

  @override
  void initState() {
    super.initState();
    _loadBlocks();
  }

  Future<void> _loadBlocks() async {
    final blocks =
        await ref.read(repoProvider).blocksOf(widget.trip.id, _day);
    if (!mounted) return;
    setState(() {
      _blocks = blocks
          .where((b) =>
              !(_day == widget.currentDay && b == widget.currentBlock))
          .toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final totalDays =
        widget.trip.endDate.difference(widget.trip.startDate).inDays + 1;

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(
                '把「第 ${widget.currentDay} 天 · '
                '${kTimeBlockLabels[widget.currentBlock]}」和谁互换？',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var d = 1; d <= totalDays; d++)
                    ChoiceChip(
                      label: Text('第 $d 天'),
                      selected: _day == d,
                      onSelected: (_) {
                        setState(() {
                          _day = d;
                          _loading = true;
                        });
                        _loadBlocks();
                      },
                    ),
                ],
              ),
            ),
            const Divider(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_blocks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('这一天没有可互换的时段',
                    style: TextStyle(color: Colors.grey)),
              )
            else
              for (final b in _blocks)
                ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: Text(
                      '第 $_day 天 · ${kTimeBlockLabels[b] ?? b.name}'),
                  subtitle: const Text('两处内容整个对调',
                      style: TextStyle(fontSize: 11)),
                  onTap: () => Navigator.pop(
                      context, (day: _day, block: b)),
                ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 景点库选择器的半屏地图和预览条
// ══════════════════════════════════════════════════════════════

/// 选择器上半屏的小地图：显示（筛选后的）全部带坐标地点 + 高德搜索候选，
/// 点标记/点列表条目 = 选中预览。瓦片缓存与全景地图共用一套磁盘目录，秒开。
class _PickerMiniMap extends StatelessWidget {
  const _PickerMiniMap({
    required this.attractions,
    required this.previewId,
    required this.mapController,
    required this.tileProvider,
    required this.onSelect,
    this.allPlaces = const [],
    this.webSpots = const [],
    this.webPreview,
  });

  /// 地图上实际绘制的条目（**筛选后**的）
  final List<Attraction> attractions;

  /// 该地区的**全量**地点（未筛选），只用来判断「有没有东西可画」
  /// 和决定地图初始落点——不用它画标记
  final List<Attraction> allPlaces;

  final String? previewId;
  final MapController mapController;
  final CachedTileProvider tileProvider;
  final ValueChanged<Attraction> onSelect;

  /// 高德搜索候选（紫色标记，纯预览——➕ 才会加）
  final List<GeoPoint> webSpots;

  /// 正在聚焦预览的高德候选
  final GeoPoint? webPreview;

  @override
  Widget build(BuildContext context) {
    final spots =
        attractions.where((a) => a.lat != null && a.lng != null).toList();

    // ⚠️ 「有没有东西可画」必须按**全量**判定，不能用筛选后的 spots：
    //    用 spots 判定的话，用户一搜一个匹配不到的词，整张 FlutterMap 就会被
    //    换成灰底提示（瓦片、标记全没），清空关键词后再整张重建——
    //    画面闪一下、还白费一次瓦片请求。地图不该因为筛选而消失。
    final allWithCoords = (allPlaces.isEmpty ? attractions : allPlaces)
        .where((a) => a.lat != null && a.lng != null)
        .toList();

    if (allWithCoords.isEmpty && webSpots.isEmpty) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: const Text(
          '这里还没有可显示的地点\n搜一个，地图会直接带你过去',
          style: TextStyle(fontSize: 12, color: Colors.grey),
          textAlign: TextAlign.center,
        ),
      );
    }

    // 初始落点：优先当前筛选结果，其次全量里任意一个带坐标的，
    // 最后才是高德候选。（只在首次挂载生效，之后由 _focusOn 接管）
    final firstPos = spots.isNotEmpty
        ? LatLng(spots.first.lat!, spots.first.lng!)
        : (allWithCoords.isNotEmpty
            ? LatLng(allWithCoords.first.lat!, allWithCoords.first.lng!)
            : LatLng(webSpots.first.lat, webSpots.first.lng));

    return ClipRect(
      child: FlutterMap(
        mapController: mapController,
        options: MapOptions(
          initialCenter: firstPos,
          initialZoom: 12,
          minZoom: 3,
          maxZoom: 18,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
        ),
        children: [
          TileLayer(
            urlTemplate:
                'https://webrd0{s}.is.autonavi.com/appmaptile'
                '?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
            subdomains: const ['1', '2', '3', '4'],
            userAgentPackageName: 'com.zhaohongfei.travel_planner',
            maxZoom: 18,
            tileProvider: tileProvider,
            keepBuffer: 4,
            panBuffer: 2,
            tileDisplay:
                const TileDisplay.fadeIn(duration: Duration(milliseconds: 80)),
          ),
          MarkerLayer(
            markers: [
              for (final a in spots)
                Marker(
                  point: LatLng(a.lat!, a.lng!),
                  width: a.id == previewId ? 26 : 22,
                  height: a.id == previewId ? 26 : 22,
                  child: GestureDetector(
                    onTap: () => onSelect(a),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: a.kind == 'eat'
                                ? const Color(0xFFE8783A)
                                : const Color(0xFF5B8EC9),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: a.id == previewId
                                  ? Colors.black
                                  : Colors.white,
                              width: a.id == previewId ? 3 : 1.5,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                  color: Colors.black26,
                                  blurRadius: 2,
                                  offset: Offset(0, 1)),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            a.kind == 'eat'
                                ? Icons.restaurant
                                : Icons.place,
                            size: 11,
                            color: Colors.white,
                          ),
                        ),
                        // 选中的在头顶弹名字标签——只高亮不移动相机，
                        // 标签是「选中了谁」的唯一明显信号
                        if (a.id == previewId)
                          Positioned(
                            left: 13,
                            top: -26,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                a.name,
                                maxLines: 1,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              // 高德搜索候选：紫色（和全景地图的「点选库外地点」同色语言）
              for (final s in webSpots)
                Marker(
                  point: LatLng(s.lat, s.lng),
                  width: s == webPreview ? 30 : 22,
                  height: s == webPreview ? 30 : 22,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF9B7BC9),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: s == webPreview ? Colors.black : Colors.white,
                        width: s == webPreview ? 3 : 1.5,
                      ),
                      boxShadow: const [
                        BoxShadow(
                            color: Colors.black26,
                            blurRadius: 2,
                            offset: Offset(0, 1)),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.place,
                        size: 11, color: Colors.white),
                  ),
                ),
            ],
          ),
          const RichAttributionWidget(
            attributions: [TextSourceAttribution('高德地图')],
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// Tab 2 · 账目
// ══════════════════════════════════════════════════════════════

class _ExpensesTab extends ConsumerWidget {
  const _ExpensesTab({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expAsync = ref.watch(tripExpensesProvider(trip.id));

    return expAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('出错了：$e')),
      data: (list) {
        final total = list.fold<int>(0, (s, e) => s + e.amountCents);
        return Stack(
          children: [
            Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Column(
                    children: [
                      Text('已花',
                          style: Theme.of(context).textTheme.bodySmall),
                      Text(
                        '¥${centsToYuan(total)}',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text('共 ${list.length} 笔',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                Expanded(
                  child: list.isEmpty
                      ? const Center(child: Text('还没有记账'))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                          itemCount: list.length,
                          itemBuilder: (context, i) {
                            final e = list[i];
                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                dense: true,
                                leading: CircleAvatar(
                                  radius: 16,
                                  child: Text(
                                    categoryLabel(e.category).substring(0, 1),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                title: Text(e.itemName),
                                subtitle: Text(
                                  '${categoryLabel(e.category)} · ${payerLabel(e.payer)}'
                                  ' · ${e.payDate.month}月${e.payDate.day}日'
                                  '${e.isPlanned ? " · 计划" : ""}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: Text(
                                  '¥${centsToYuan(e.amountCents)}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold),
                                ),
                                onLongPress: () =>
                                    _confirmDelete(context, ref, e),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.extended(
                heroTag: 'add_expense',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      // 默认记在行程第一天：补录时不用每次点回那几天
                      builder: (_) => ExpenseEditScreen(
                        tripId: trip.id,
                        defaultDate: trip.startDate,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.add_card),
                label: const Text('记一笔'),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, Expense e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这笔？'),
        content: Text('${e.itemName}  ¥${centsToYuan(e.amountCents)}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await ref.read(repoProvider).deleteExpense(e.id);
  }
}

// ══════════════════════════════════════════════════════════════
// Tab 3 · 预算
// ══════════════════════════════════════════════════════════════

class _BudgetTab extends ConsumerWidget {
  const _BudgetTab({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportAsync = ref.watch(budgetReportProvider(trip.id));
    return reportAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('出错了：$e')),
      data: (report) => _BudgetBody(trip: trip, report: report),
    );
  }
}

class _BudgetBody extends ConsumerWidget {
  const _BudgetBody({required this.trip, required this.report});

  final Trip trip;
  final BudgetReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ratio = report.usedRatio;
    final overallLevel = report.totalBudgetCents == 0
        ? 0
        : (report.totalSpentCents > report.totalBudgetCents
            ? 2
            : (report.totalSpentCents >= report.totalBudgetCents * 0.8 ? 1 : 0));
    final levelColor = switch (overallLevel) {
      2 => Colors.red,
      1 => Colors.orange,
      _ => Colors.green,
    };

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('总预算执行',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    if (overallLevel > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: levelColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          overallLevel == 2 ? '已超支' : '接近上限',
                          style: TextStyle(
                              color: levelColor, fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (report.totalBudgetCents == 0)
                  Text('还没设预算。在下面按分类添加。',
                      style: theme.textTheme.bodyMedium)
                else ...[
                  LinearProgressIndicator(
                    value: ratio == null ? 0 : ratio.clamp(0.0, 1.0),
                    minHeight: 10,
                    color: levelColor,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('已花 ¥${centsToYuan(report.totalSpentCents)}'),
                      Text('预算 ¥${centsToYuan(report.totalBudgetCents)}'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    report.remainingCents >= 0
                        ? '剩余 ¥${centsToYuan(report.remainingCents)}'
                        : '超支 ¥${centsToYuan(-report.remainingCents)}',
                    style: TextStyle(
                        color: levelColor, fontWeight: FontWeight.bold),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('分类明细',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ...ExpenseCategory.values.map((cat) {
          final line = report.lines
              .where((l) => l.category == cat)
              .cast<BudgetLine?>()
              .firstWhere((l) => true, orElse: () => null);
          return _CategoryRow(tripId: trip.id, category: cat, line: line);
        }),
      ],
    );
  }
}

class _CategoryRow extends ConsumerWidget {
  const _CategoryRow({
    required this.tripId,
    required this.category,
    required this.line,
  });

  final String tripId;
  final ExpenseCategory category;
  final BudgetLine? line;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final budget = line?.budgetCents ?? 0;
    final spent = line?.spentCents ?? 0;
    final alert = line?.alertLevel ?? 0;
    final barColor = switch (alert) {
      2 => Colors.red,
      1 => Colors.orange,
      _ => Colors.green,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _editBudget(context, ref),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(categoryLabel(category.name),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text(
                    budget == 0
                        ? '未设预算'
                        : '¥${centsToYuan(spent)} / ¥${centsToYuan(budget)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (alert > 0) ...[
                    const SizedBox(width: 6),
                    Icon(alert == 2 ? Icons.error : Icons.warning_amber,
                        size: 16, color: barColor),
                  ],
                ],
              ),
              if (budget > 0) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: (spent / budget).clamp(0.0, 1.0),
                  minHeight: 6,
                  color: barColor,
                  backgroundColor: barColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(3),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editBudget(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController(
      text: (line?.budgetCents ?? 0) == 0
          ? ''
          : (line!.budgetCents / 100).toStringAsFixed(0),
    );
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${categoryLabel(category.name)} 预算'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: '预算金额（元）',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              // 校验后再关弹窗：格式不对就留在框里让用户改，
              // 不能把乱码静默存成 0（宽松解析的坑）
              final parsed = parseYuanInput(ctrl.text);
              if (!parsed.ok) {
                AppToast.show(ctx, '金额填数字（比如 500），留空表示不设');
                return;
              }
              Navigator.pop(ctx, parsed.cents);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null) {
      await ref.read(repoProvider).setBudget(tripId, category, result);
      // ⚠️ 必须手动失效：budgetReportProvider 只 watch 账目流，
      //    而这里写的是 budgets 表，不会触发它重算。漏了这行，
      //    保存后界面纹丝不动，看着像功能坏了。
      ref.invalidate(budgetReportProvider(tripId));
    }
    ctrl.dispose();
  }
}
