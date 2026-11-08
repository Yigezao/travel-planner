// ═══════════════════════════════════════════════════════════════
// 首页：两个 Tab
//   行程   —— 具体某次出行（层2）
//   景点库 —— 地区的景点/美食清单（层1，跨行程复用）
// ═══════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/exporter.dart';
import '../data/providers.dart';
import '../data/trip_poster_exporter.dart';
import '../data/weather.dart';
import 'app_toast.dart';
import 'region_library_screen.dart';
import 'trip_create_screen.dart';
import 'trip_detail_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我们的旅行'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '行程', icon: Icon(Icons.luggage_outlined)),
            Tab(text: '景点库', icon: Icon(Icons.map_outlined)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _TripsTab(),
          _LibraryTab(),
        ],
      ),
    );
  }
}

/// 景点库 Tab：直接复用 RegionLibraryScreen（它自带 Scaffold 和导入按钮）
class _LibraryTab extends StatelessWidget {
  const _LibraryTab();

  @override
  Widget build(BuildContext context) => const RegionLibraryScreen();
}

class _TripsTab extends ConsumerWidget {
  const _TripsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tripsAsync = ref.watch(tripsProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TripCreateScreen()),
          );
        },
        icon: const Icon(Icons.add),
        label: const Text('新建行程'),
      ),
      body: tripsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('出错了：$e')),
        data: (trips) {
          if (trips.isEmpty) return const _EmptyState();
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
            itemCount: trips.length,
            itemBuilder: (context, i) {
              final (trip, regionName) = trips[i];
              return _TripCard(trip: trip, regionName: regionName);
            },
          );
        },
      ),
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.trip, required this.regionName});

  final Trip trip;
  final String regionName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = trip.endDate.difference(trip.startDate).inDays + 1;
    final dateText =
        '${_ymd(trip.startDate)} - ${_ymd(trip.endDate)}';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TripDetailScreen(tripId: trip.id),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      trip.title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  _StatusChip(status: trip.status),
                  // 导出菜单就放在行程名称这一行（用户要求）
                  _ExportMenu(trip: trip),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.place_outlined, size: 16),
                  const SizedBox(width: 4),
                  Text(regionName, style: theme.textTheme.bodyMedium),
                  const SizedBox(width: 16),
                  const Icon(Icons.event_outlined, size: 16),
                  const SizedBox(width: 4),
                  Text('$days 天 ${trip.nights} 夜',
                      style: theme.textTheme.bodyMedium),
                ],
              ),
              const SizedBox(height: 6),
              Text(dateText, style: theme.textTheme.bodySmall),
              if (trip.totalBudgetCents > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '预算 ¥${centsToYuan(trip.totalBudgetCents)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// 行程卡片上的导出菜单
class _ExportMenu extends ConsumerStatefulWidget {
  const _ExportMenu({required this.trip});

  final Trip trip;

  @override
  ConsumerState<_ExportMenu> createState() => _ExportMenuState();
}

class _ExportMenuState extends ConsumerState<_ExportMenu> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return PopupMenuButton<String>(
      icon: const Icon(Icons.ios_share, size: 20),
      tooltip: '导出',
      onSelected: _handle,
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'trip',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.send_outlined, size: 20),
            title: Text('导出文件'),
            subtitle: Text('分享给好友，对方打开即导入', style: TextStyle(fontSize: 11)),
          ),
        ),
        PopupMenuItem(
          value: 'image_save',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.save_alt, size: 20),
            title: Text('长图存相册'),
            subtitle: Text('保存到手机图库', style: TextStyle(fontSize: 11)),
          ),
        ),
        PopupMenuItem(
          value: 'image_share',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.image_outlined, size: 20),
            title: Text('长图分享'),
            subtitle: Text('发给微信/QQ 好友', style: TextStyle(fontSize: 11)),
          ),
        ),
        PopupMenuItem(
          value: 'md',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.description_outlined, size: 20),
            title: Text('导出 Markdown'),
            subtitle: Text('可以自己改的文本', style: TextStyle(fontSize: 11)),
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, size: 20, color: Colors.red),
            title: Text('删除行程', style: TextStyle(color: Colors.red)),
            subtitle: Text('连同账目一起删掉', style: TextStyle(fontSize: 11)),
          ),
        ),
      ],
    );
  }

  Future<void> _handle(String action) async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final bundle = await repo.loadBundle(widget.trip.id);
      if (bundle == null) {
        // 行程在菜单打开期间被删掉了（或数据异常）。
        // 静默 return 会让用户以为「点了没反应」——说清楚并刷新列表。
        if (mounted) AppToast.show(context, '这个行程已经不在了');
        ref.invalidate(tripsProvider);
        return;
      }
      // 景点库地点：长图里补充地址/价格/完整备注 + 手打标签
      final attractions = await repo.attractionsOf(bundle.region.id);
      final tags =
          await repo.tagsOfMany(attractions.map((a) => a.id).toList());
      // 逐日天气。**必须在这里取好再传进去**——长图是在屏幕外渲染的，
      // 它自己没法 await。拿不到就是空 Map：那天不显示天气，
      // 长图会自行说明「预报只覆盖出行前 N 天」。
      // horizonDays 是**实际**覆盖天数（和风 7 / 高德 4），如实传下去。
      final weather = await fetchDayWeather(bundle.region.name);

      switch (action) {
        case 'trip':
          await const TripExporter().exportTripFile(bundle);
        case 'md':
          await const TripExporter().exportAndShare(bundle);
        case 'delete':
          if (!mounted) return;
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('删除这个行程？'),
              content: Text(
                '「${widget.trip.title}」的行程安排、账目、预算都会被删掉，无法恢复。\n\n'
                '（景点库里的景点不受影响）',
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
                  child: const Text('删除'),
                ),
              ],
            ),
          );
          if (ok != true) return;
          await repo.deleteTrip(widget.trip.id);
          ref.invalidate(tripsProvider);
          if (mounted) AppToast.show(context, '已删除');
        case 'image_save':
          if (!mounted) return;
          // 用 Overlay 而不是 context：稍后要 await 权限，避免跨 await 用 context
          final overlayForSave = Overlay.of(context);
          await const TripPosterExporter().saveToGallery(
              overlayForSave, bundle,
              attractions: attractions,
              tags: tags,
              dayWeather: weather.days,
              weatherHorizonDays: weather.horizonDays > 0
                  ? weather.horizonDays
                  : kForecastHorizonDays);
          if (!mounted) return;
          AppToast.show(
            context,
            Platform.isAndroid || Platform.isIOS
                ? '已保存到相册'
                : '已保存到下载文件夹',
          );
        case 'image_share':
          if (!mounted) return;
          final overlayForShare = Overlay.of(context);
          await const TripPosterExporter().renderAndShare(
            overlayForShare,
            bundle,
            attractions: attractions,
            tags: tags,
            dayWeather: weather.days,
            weatherHorizonDays: weather.horizonDays > 0
                ? weather.horizonDays
                : kForecastHorizonDays,
          );
      }
    } on GalleryPermissionDenied {
      if (!mounted) return;
      AppToast.show(context, '没有相册权限。请到系统设置里允许本 App 访问相册');
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      'ongoing' => (Colors.orange, '出行中'),
      'finished' => (Colors.green, '已结束'),
      _ => (Colors.blueGrey, '规划中'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.luggage_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text('还没有行程', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '点右下角「新建行程」开始规划',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
