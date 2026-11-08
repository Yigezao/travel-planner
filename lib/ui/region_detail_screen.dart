// ═══════════════════════════════════════════════════════════════
// 地区详情：该地区的地点清单
//
// 功能：
//   · 关键词搜索（名字/地址/备注/分类/标签都能搜）
//   · 按 吃/玩、标签、去过没去过 筛选
//   · 新增 / 点击编辑 / 删除 地点
//   · 「去过」一键标记
// ═══════════════════════════════════════════════════════════════

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/geocoder.dart';
import '../data/providers.dart';
import 'app_toast.dart';
import 'attraction_edit_screen.dart';
import 'region_map_screen.dart';

class RegionDetailScreen extends ConsumerStatefulWidget {
  const RegionDetailScreen({super.key, required this.regionId});

  final String regionId;

  @override
  ConsumerState<RegionDetailScreen> createState() =>
      _RegionDetailScreenState();
}

class _RegionDetailScreenState extends ConsumerState<RegionDetailScreen> {
  final _searchCtrl = TextEditingController();

  /// 搜索防抖：原来每个字符都触发一次全量 reload（3 连查询）
  Timer? _searchDebounce;

  /// null = 全部；否则只看「吃」或「玩」
  String? _filterKind;

  /// 选中的标签（null = 不按标签筛）
  String? _filterTag;

  /// 是否只看「还没去的」
  bool _onlyNotVisited = false;

  /// 是否只看「还没排进行程的」
  bool _onlyNotPlanned = false;
  Set<String> _plannedIds = {};

  bool _geocoding = false;

  List<Attraction> _list = [];
  Map<String, List<String>> _tagMap = {};
  List<String> _allTags = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  /// [silent] = true 时不显示加载圈，界面不闪。
  ///
  /// 用在「标记去过」这种**只改一个字段**的操作上——
  /// 原来每次都走完整加载，页面会白屏闪一下，很刺眼。
  /// 请求世代号：只认**最后一次** _reload 的结果。
  ///
  /// 输入关键词有 250ms 防抖，在防抖窗口内再点筛选 chip（或连点两个 chip）
  /// 会让两次查询并发，而先发的可能后返回 —— 旧结果盖到新条件上，
  /// 表现就是「chip 明明亮着，列表却没按它过滤」。
  int _reloadGen = 0;

  Future<void> _reload({bool silent = false}) async {
    if (!mounted) return;
    final gen = ++_reloadGen;
    if (!silent) setState(() => _loading = true);
    try {
      final repo = ref.read(repoProvider);
      var list = await repo.searchAttractions(
        widget.regionId,
        query: _searchCtrl.text,
        kind: _filterKind,
        tag: _filterTag,
        onlyNotVisited: _onlyNotVisited,
      );
      if (_onlyNotPlanned) {
        _plannedIds =
            await repo.plannedAttractionIdsOfRegion(widget.regionId);
        list = list.where((a) => !_plannedIds.contains(a.id)).toList();
      }
      final tagMap = await repo.tagsOfMany(list.map((a) => a.id).toList());
      final allTags = await repo.allTagsInRegion(widget.regionId);

      // 期间又发起了新查询 → 这次的结果已经过期，直接丢掉
      if (!mounted || gen != _reloadGen) return;
      setState(() {
        _list = list;
        _tagMap = tagMap;
        _allTags = allTags;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _reloadGen) return;
      setState(() => _loading = false);
      AppToast.show(context, '加载失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final regionAsync = ref.watch(regionProvider(widget.regionId));

    return Scaffold(
      appBar: AppBar(
        title: Text(regionAsync.valueOrNull?.name ?? '景点库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.public),
            tooltip: '在地图上查看',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RegionMapScreen(
                    regionId: widget.regionId,
                    regionName: regionAsync.valueOrNull?.name,
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: _geocoding
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location),
            tooltip: '补全经纬度',
            onPressed: _geocoding ? null : _backfillCoordinates,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除这个地区',
            onPressed: _confirmDeleteRegion,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPlace,
        icon: const Icon(Icons.add),
        label: const Text('新增地点'),
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          _buildFilterBar(),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _list.isEmpty
                    ? _buildEmpty()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                        itemCount: _list.length,
                        itemBuilder: (context, i) => _PlaceCard(
                          place: _list[i],
                          tags: _tagMap[_list[i].id] ?? const [],
                          // 标记「去过」走静默刷新，避免整页闪白
                          onChanged: () => _reload(silent: true),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (_) {
          _searchDebounce?.cancel();
          _searchDebounce = Timer(const Duration(milliseconds: 250), () {
            if (mounted) _reload();
          });
        },
        decoration: InputDecoration(
          hintText: '搜名字、地址、备注、标签…',
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchCtrl.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                    _reload();
                  },
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${_list.length} 个', style: theme.textTheme.bodySmall),
              const Spacer(),
              FilterChip(
                label: const Text('只看没去的'),
                selected: _onlyNotVisited,
                visualDensity: VisualDensity.compact,
                onSelected: (v) {
                  setState(() => _onlyNotVisited = v);
                  _reload();
                },
              ),
              const SizedBox(width: 6),
              FilterChip(
                label: const Text('只看没排的'),
                selected: _onlyNotPlanned,
                visualDensity: VisualDensity.compact,
                onSelected: (v) {
                  setState(() => _onlyNotPlanned = v);
                  _reload();
                },
              ),
            ],
          ),
          const SizedBox(height: 4),

          Row(
            children: [
              for (final k in PlaceKind.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(k == PlaceKind.eat ? '🍜 吃' : '🏛 玩'),
                    selected: _filterKind == k.name,
                    visualDensity: VisualDensity.compact,
                    onSelected: (sel) {
                      setState(() => _filterKind = sel ? k.name : null);
                      _reload();
                    },
                  ),
                ),
            ],
          ),

          if (_allTags.isNotEmpty) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: const Text('标签：全部'),
                      selected: _filterTag == null,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) {
                        setState(() => _filterTag = null);
                        _reload();
                      },
                    ),
                  ),
                  for (final t in _allTags)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(t),
                        selected: _filterTag == t,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) {
                          setState(() => _filterTag = t);
                          _reload();
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    final searching = _searchCtrl.text.trim().isNotEmpty ||
        _filterKind != null ||
        _filterTag != null ||
        _onlyNotVisited ||
        _onlyNotPlanned;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(searching ? Icons.search_off : Icons.place_outlined,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(searching ? '没有匹配的地点' : '还没有地点'),
            if (searching) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() {
                    _filterKind = null;
                    _filterTag = null;
                    _onlyNotVisited = false;
                    _onlyNotPlanned = false;
                  });
                  _reload();
                },
                child: const Text('清除筛选'),
              ),
            ] else ...[
              const SizedBox(height: 8),
              const Text('点右下角「新增地点」，或导入候选库',
                  style: TextStyle(fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _addPlace() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AttractionEditScreen(regionId: widget.regionId),
      ),
    );
    if (ok == true) _reload();
  }

  /// 批量补经纬度（用 Nominatim，节流 1.1 秒/次）
  Future<void> _backfillCoordinates() async {
    final repo = ref.read(repoProvider);
    final region = await repo.getRegion(widget.regionId);
    if (region == null) return;

    final missing = await repo.attractionsMissingCoords(widget.regionId);
    if (!mounted) return;
    if (missing.isEmpty) {
      AppToast.show(context, '这个地区的地点都已有坐标了');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('补全经纬度？'),
        content: Text(
          '有 ${missing.length} 个地点还没坐标。\n\n'
          '会联网逐个查询，每个约 1 秒。查不到的会留空，不会填假坐标。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _geocoding = true);

    var ok = 0;
    final failed = <String>[];
    for (final a in missing) {
      if (!mounted) break;
      final parts = <String>[
        a.name,
        if (a.address != null && a.address!.isNotEmpty) a.address!,
        region.name,
      ];
      // 传城市名：从源头避免查到外省同名地点
      final result =
          await Geocoder().geocode(parts.join(' '), city: region.name);
      if (result.isOk) {
        await repo.setAttractionCoords(
          a.id,
          lat: result.point!.lat,
          lng: result.point!.lng,
        );
        ok++;
      } else {
        failed.add(a.name);
      }
    }

    if (!mounted) return;
    setState(() => _geocoding = false);
    await _reload();

    if (!mounted) return;
    AppToast.show(
      context,
      failed.isEmpty ? '完成：$ok 个地点已补上坐标' : '成功 $ok 个，${failed.length} 个没查到',
    );
  }

  Future<void> _confirmDeleteRegion() async {
    final repo = ref.read(repoProvider);

    // ⚠️ 先查地区下有没有行程——行程挂在地区上，删了地区行程会
    //    从首页静默消失（innerJoin 过滤掉悬空引用），看起来像丢数据。
    final tripCount = await repo.tripCountInRegion(widget.regionId);
    if (!mounted) return;
    if (tripCount > 0) {
      AppToast.show(context, '这个地区下还有 $tripCount 个行程，先删掉或转移行程再删地区');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个地区？'),
        content: const Text('该地区下的景点、标签和游玩记录都会一起删掉，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await repo.deleteRegion(widget.regionId);
    } catch (e) {
      if (mounted) AppToast.show(context, '删除失败：$e');
      return;
    }
    ref.invalidate(regionsProvider);
    if (mounted) Navigator.of(context).pop();
  }
}

// ══════════════════════════════════════════════════════════════

class _PlaceCard extends ConsumerWidget {
  const _PlaceCard({
    required this.place,
    required this.tags,
    required this.onChanged,
  });

  final Attraction place;
  final List<String> tags;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 精确比对（不能用 contains——子串匹配会把「没去过」也算成去过）
    final visited = isVisitedTags(place.tags);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final ok = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => AttractionEditScreen(
                regionId: place.regionId,
                attractionId: place.id,
              ),
            ),
          );
          if (ok == true) onChanged();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      place.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        decoration:
                            visited ? TextDecoration.lineThrough : null,
                        color: visited ? theme.colorScheme.outline : null,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await ref
                          .read(repoProvider)
                          .toggleVisited(place.id, visited: !visited);
                      // 静默刷新：只改了一个字段，不该让整页闪一下
                      onChanged();
                    },
                    icon: Icon(
                      visited
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 17,
                      color:
                          visited ? Colors.green : theme.colorScheme.outline,
                    ),
                    label: Text(
                      visited ? '去过' : '没去',
                      style: TextStyle(
                        fontSize: 12,
                        color: visited
                            ? Colors.green
                            : theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ],
              ),

              if (tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(
                    spacing: 5,
                    runSpacing: 4,
                    children: [
                      for (final t in tags.take(6))
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child:
                              Text(t, style: const TextStyle(fontSize: 11)),
                        ),
                    ],
                  ),
                ),

              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (place.category != null)
                    _Chip(place.category!, theme.colorScheme.primary),
                  if (place.recommendLevel != null)
                    _Chip('★' * place.recommendLevel!, Colors.orange),
                  if (place.suggestDurationMin != null)
                    _Chip(
                      '${(place.suggestDurationMin! / 60).toStringAsFixed(1)}h',
                      Colors.blueGrey,
                    ),
                  if (place.ticketPriceCents > 0)
                    _Chip(
                        '¥${(place.ticketPriceCents / 100).toStringAsFixed(0)}',
                        Colors.redAccent),
                  if (place.lat != null && place.lng != null)
                    const _Chip('📍', Colors.teal),
                ],
              ),

              if (place.address != null && place.address!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.location_on_outlined,
                        size: 13, color: theme.colorScheme.outline),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(place.address!,
                          style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style:
            TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
