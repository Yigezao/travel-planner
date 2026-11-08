// ═══════════════════════════════════════════════════════════════
// 地区全景地图
//
// 与 day_map_screen 的区别：
//   · 那个看「某一天的动线」——点少、按顺序连线
//   · 这个看「整个地区有什么」——点多、能筛选、能加进行程
//
// 两种进入方式：
//   · 从行程详情进来 → 可把地点加入该行程的某一天
//   · 从景点库进来   → 纯浏览（tripId 为空）
//
// ⚠️ 坐标系同 day_map_screen：数据库里存的就是 GCJ-02，和瓦片同一套，
//    全程【不转换】。（本行早先写着「存 WGS-84 渲染前转 GCJ-02」，
//    那是已废弃的旧方案，方向完全相反——任何转换都会让点偏 604 米。
//    2026-09-14 订正，别再被它带偏。）
// ═══════════════════════════════════════════════════════════════

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/database.dart';
import '../data/geocoder.dart';
import '../data/providers.dart';
import '../data/tile_cache.dart';
import 'app_toast.dart';

class RegionMapScreen extends ConsumerStatefulWidget {
  const RegionMapScreen({
    super.key,
    required this.regionId,
    this.regionName,
    this.tripId,
  });

  final String regionId;
  final String? regionName;

  /// 从这个行程进来的。为空则只能浏览，不能加入行程。
  final String? tripId;

  @override
  ConsumerState<RegionMapScreen> createState() => _RegionMapScreenState();
}

class _RegionMapScreenState extends ConsumerState<RegionMapScreen> {
  final _mapController = MapController();

  /// 挂在地图控件上，用来取它自己的尺寸（诊断面板要用）
  final GlobalKey _mapKey = GlobalKey();

  /// 瓦片缓存实例。**只在 State 里建一次**——
  /// 如果在 build 里 new，每次重绘都会换一个新实例，
  /// 缓存统计会被清零、磁盘目录也会重复初始化。
  final CachedTileProvider _tileProvider = CachedTileProvider();

  List<Attraction> _all = [];

  /// 预先算好的 GCJ-02 坐标，与 _all 一一对应。
  ///
  /// 为什么缓存：wgs84ToGcj02 里有十几次三角函数运算，
  /// 33 个点 × 每帧 × 每次 setState，累积起来是明显的卡顿来源。
  /// 坐标在 _load() 时算一次就够，之后不再变。
  List<LatLng> _gcjCache = [];

  Trip? _trip;

  /// 筛选
  String? _kindFilter; // 'eat' / 'play' / null
  bool _onlyNotVisited = false;

  /// 只看没排进行程的（排行程时防止重复排同一地点）
  bool _onlyNotPlanned = false;
  Set<String> _plannedIds = {};

  // ══ 活地图：搜索 + 点选任意地点 + 收进景点库 ══

  final _searchCtrl = TextEditingController();
  final _spotNameCtrl = TextEditingController();
  bool _searching = false;

  /// 搜索结果的候选列表（空 = 没在搜索或没结果）
  List<GeoPoint> _searchResults = [];

  /// 当前选中的「库外地点」（搜索选中或点地图选中），画成紫色临时标记
  GeoPoint? _pickedSpot;

  /// 点选位置周边的 POI（卡片上「换个名字」的候选来源）
  List<GeoPoint> _nearbyCache = [];

  /// 当前地区景点库里已有的所有名字（判断搜索候选是否「已入库」）
  Set<String> _libraryNames = {};

  /// 正在往景点库写入
  bool _addingSpot = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _spotNameCtrl.dispose();
    // ⚠️ MapController 必须手动释放：flutter_map 只释放它自己创建的那种
    //    （map/widget.dart:75-78 的 _controllerCreatedInternally 分支），
    //    我们是从外部传进去的，它不代管。控制器内部握着事件流、
    //    AnimationController 和 ValueNotifier，不释放则每次进出页面泄漏一份。
    //    （瓦片 provider 由 TileLayer 自己 dispose，这里再调一次是幂等兜底。）
    _mapController.dispose();
    _tileProvider.dispose();
    super.dispose();
  }

  /// 选中的标签。
  ///
  /// 语义是「**只显示带这些标签的地点**」，不是「隐藏这些标签」——
  /// 用户要的是「点公园 → 只看到公园；再点博物馆 → 公园和博物馆一起看」。
  /// 空集合 = 不按标签筛，全都显示。
  final Set<String> _selectedTags = {};

  /// 当前缩放级别。放大到 [_labelZoom] 以上就在标记旁显示地名。
  double _zoom = 12;

  /// 多少级别开始显示地名。
  /// 太小会满屏文字，太大又要放很大才显示，15 是个折中。
  static const double _labelZoom = 15;

  /// 每个坐标的标签，用于按标签隐藏
  Map<String, List<String>> _tagMap = {};

  bool _loading = true;
  String? _error;
  Attraction? _selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(repoProvider);
      final all = await repo.attractionsOf(widget.regionId);

      Trip? trip;
      if (widget.tripId != null) {
        trip = await repo.getTrip(widget.tripId!);
      }

      final withCoords = all
          .where((a) => a.lat != null && a.lng != null)
          .toList();

      // 已排进行程的地点（「只看没排的」筛选的数据源）
      _plannedIds = await repo.plannedAttractionIdsOfRegion(widget.regionId);

      // ⚠️⚠️ 直接使用数据库里的坐标，**不做任何转换**。
      //
      // 这是踩了大坑之后定下的规则（2026-09-14）：
      //
      //   数据库里存的就是 **GCJ-02**（高德坐标系），和地图瓦片一致。
      //   早先版本存的是 WGS-84，渲染时再转 GCJ-02，看似等价，实则不然——
      //   当时瓦片也是高德（GCJ-02），转完确实能对上；但那次修复
      //   「看起来偏」时我一度以为转错了，差点改坏。
      //
      //   现在统一原则：**数据坐标系 = 瓦片坐标系 = GCJ-02，全程不转换。**
      //   任何地方再加坐标转换都会让点偏 604 米。
      //
      //   换算关系（供参考）：604 米偏移在屏幕上会随缩放线性放大——
      //   zoom 12 时 18 像素，zoom 16 时 288 像素，zoom 18 时 1152 像素。
      //   这就是「越放大越偏」现象的来源。
      final gcj = withCoords.map((a) {
        return LatLng(a.lat!, a.lng!);
      }).toList();

      // 标签：用于地图上按标签显隐
      final tags = await repo.tagsOfMany(withCoords.map((a) => a.id).toList());

      // 库里已有的全部名字（搜索候选判断「已入库」用，含没坐标的）
      final names = all.map((a) => a.name).toSet();

      if (!mounted) return;
      setState(() {
        _all = withCoords;
        _gcjCache = gcj;
        _tagMap = tags;
        _libraryNames = names;
        _trip = trip;
        _loading = false;
      });
      _fitAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<Attraction> get _visible {
    var list = _all;
    if (_kindFilter != null) {
      list = list.where((a) => a.kind == _kindFilter).toList();
    }
    if (_onlyNotVisited) {
      list = list.where((a) => !_isVisited(a)).toList();
    }
    if (_onlyNotPlanned) {
      list = list.where((a) => !_plannedIds.contains(a.id)).toList();
    }
    // 选了标签就只显示命中其中之一的地点（多个标签是「或」的关系）
    if (_selectedTags.isNotEmpty) {
      list = list.where((a) {
        final tags = _tagMap[a.id] ?? const <String>[];
        return tags.any(_selectedTags.contains);
      }).toList();
    }
    return list;
  }

  /// 所有出现过的标签（用于显隐控制条）
  List<String> get _allTags {
    final s = <String>{};
    for (final v in _tagMap.values) {
      s.addAll(v);
    }
    return s.toList()..sort();
  }

  // 精确比对，别改回 contains('去过')：那是子串匹配，
  // 用户自定义的「没去过」标签会被误判成去过
  static bool _isVisited(Attraction a) => isVisitedTags(a.tags);

  void _fitAll() {
    if (_gcjCache.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _gcjCache.isEmpty) return;
      // 用缓存的坐标，不重复转换
      final pts = _gcjCache;
      if (pts.length == 1) {
        _mapController.move(pts.first, 13);
        return;
      }
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(pts),
          padding: const EdgeInsets.all(56),
        ),
      );
    });
  }

  /// 采集一份可一键复制的诊断数据。
  ///
  /// 采集的内容（都是程序能拿到的真实值，不是估算）：
  ///   · 相机状态：中心经纬度、缩放级别、可视范围
  ///   · 每个地点的：数据库坐标 → 渲染坐标 → 在屏幕上的像素位置
  ///   · 反查：屏幕中心对应的经纬度（用相机换算，用来验证换算链是否自洽）
  ///
  /// ⚠️ 拿不到的：瓦片图片里「地图内容实际画在哪」——
  ///    那是像素数据，程序读不出来。要判断这个只能靠人眼比对，
  ///    所以下面同时给出「屏幕像素位置」，你对着看就能知道差多少。
  Map<String, dynamic> _collectDiagnostics() {
    final cam = _mapController.camera;

    // ⚠️ 必须用**地图控件自己的尺寸**，不能用 MediaQuery.of(context).size。
    //
    //    上一版用了整屏尺寸，结果所有 Y 坐标系统性偏了一个 AppBar+TabBar 的高度
    //    （实测恒差 44.85 像素），把我自己带偏了一整轮。
    //    地图嵌在 Scaffold 里，可视高度 = 整屏高 - AppBar - TabBar，
    //    拿整屏高去算屏幕坐标必然是错的。
    final box = _mapKey.currentContext?.findRenderObject() as RenderBox?;
    final size = box?.size ?? MediaQuery.of(context).size;

    final places = <Map<String, dynamic>>[];
    for (final a in _all) {
      final pos = _gcjOf(a);
      // 把经纬度换算成屏幕像素，看 Flutter 认为这个点该画在哪
      String? screen;
      if (pos != null) {
        try {
          final p = cam.latLngToScreenOffset(pos);
          screen = '${p.dx.toStringAsFixed(1)}, ${p.dy.toStringAsFixed(1)}';
        } catch (_) {
          screen = '换算失败';
        }
      }
      places.add({
        'name': a.name,
        'db_lat': a.lat,
        'db_lng': a.lng,
        'render_lat': pos?.latitude,
        'render_lng': pos?.longitude,
        'screen_x_y': screen,
        '带坐标': pos != null,
      });
    }

    // 反查：屏幕中心对应的经纬度，和相机中心比对，
    // 用来验证「经纬度 ⇄ 屏幕像素」这条换算链是否自洽
    String centerRoundTrip;
    try {
      final c = cam.latLngToScreenOffset(cam.center);
      final back = cam.screenOffsetToLatLng(c);
      centerRoundTrip = '${back.latitude.toStringAsFixed(6)}, '
          '${back.longitude.toStringAsFixed(6)}';
    } catch (e) {
      centerRoundTrip = '换算失败: $e';
    }

    return {
      '采集时间': DateTime.now().toIso8601String(),
      '相机': {
        'center_lat': cam.center.latitude,
        'center_lng': cam.center.longitude,
        'zoom': cam.zoom,
        'min_zoom': cam.minZoom,
        'max_zoom': cam.maxZoom,
        'rotation_deg': cam.rotation,
      },
      '屏幕': {
        'width': size.width,
        'height': size.height,
        'device_pixel_ratio': MediaQuery.of(context).devicePixelRatio,
      },
      '换算自检': {
        '屏幕中心经纬度_往返': centerRoundTrip,
        '相机中心经纬度': '${cam.center.latitude.toStringAsFixed(6)}, '
            '${cam.center.longitude.toStringAsFixed(6)}',
        '说明': '这两行应该完全一致；不一致说明换算链本身有问题',
      },
      '瓦片统计': {
        '读磁盘': _tileProvider.hitDisk,
        '走网络': _tileProvider.fromNet,
        '失败': _tileProvider.failed,
      },
      '地点数': _all.length,
      '地点': places,
      '参考值': {
        '滕王阁_正确GCJ': '28.681332, 115.881197',
        '说明': '若某地点的 db_lat/db_lng 与正确值差 0.005 度左右（约600米），'
            '说明数据库存的还是旧 WGS-84 坐标',
      },
    };
  }

  /// 弹出诊断数据，支持一键复制
  void _showDiagnostics(BuildContext context) {
    final data = _collectDiagnostics();
    final text = const JsonEncoder.withIndent('  ').convert(data);

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('诊断数据'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                height: 1.3,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(ctx);
              AppToast.show(context, '已复制，粘贴给我即可');
            },
            child: const Text('一键复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 取某个地点预先算好的 GCJ 坐标。
  ///
  /// ⚠️ 找不到就返回 null（而不是随便给个坐标）——
  ///    之前这里回退到硬编码的南昌坐标，
  ///    结果缺坐标的点会被**静默画到南昌市中心**，用户完全看不出是错的。
  ///    宁可这个点不画，也不要画在错误的位置上。
  LatLng? _gcjOf(Attraction a) {
    final i = _all.indexWhere((x) => x.id == a.id);
    if (i < 0 || i >= _gcjCache.length) return null;
    return _gcjCache[i];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.regionName ?? _trip?.title ?? "地区"} · 全景'),
        actions: [
          IconButton(
            icon: const Icon(Icons.center_focus_strong),
            tooltip: '显示全部',
            onPressed: _fitAll,
          ),
          // 临时诊断入口：查坐标到底存的是什么值。查完就删。
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: '诊断：查看坐标与缩放',
            onPressed: () => _showDiagnostics(context),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text('加载失败：$_error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_all.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.map_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 14),
              const Text('这个地区还没有带坐标的地点'),
              const SizedBox(height: 10),
              Text(
                '去「景点库」→ 选中地区 → 点右上角 📍 补坐标',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    // ⚠️ 把「地点」和「坐标」绑成一对再过滤。
    //
    // 不能像下面这样分两个列表各过滤一遍：
    //     final gcj = visible.map(_gcjOf).whereType<LatLng>().toList();
    // 因为一旦有某个点取不到坐标，gcj 就比 visible 短一个，
    // 后面 markers 里用 gcj[i] 配 visible[i] 就会**整体错位**。
    final visible = _visible
        .map((a) => (place: a, pos: _gcjOf(a)))
        .where((e) => e.pos != null)
        .toList();

    return Stack(
      children: [
        // RepaintBoundary 把地图的重绘和外面隔开——
        // 否则拖动/缩放时，顶部的筛选条、标签条会跟着一起重绘，白白吃性能。
        RepaintBoundary(
          child: FlutterMap(
            key: _mapKey,
            mapController: _mapController,
            options: MapOptions(
              initialCenter: visible.isNotEmpty
                  ? visible.first.pos!
                  : const LatLng(28.68, 115.88),
              initialZoom: 12,
              minZoom: 3,
              maxZoom: 18,
              // 禁止旋转：双指旋转在实际用起来很干扰，只想缩放和平移
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              // 放大到一定级别时，标记旁直接显示地名，不用一个个点
              onMapEvent: (e) {
                // ⚠️ 只在**跨过「显示地名」的阈值**时重建整页。
                //
                //    原来只要缩放变化超过 0.05 就 setState：捏合缩放期间
                //    每个事件都重建整个 body —— 全部 Marker 重建
                //    （MarkerLayer 的投影缓存随之作废）、筛选条和标签集合
                //    重新分配。而 _zoom 唯一的用途就是跟 _labelZoom 比大小，
                //    所以只需要在「之前显示/现在不显示」翻转的那一瞬间重建。
                final wasShowing = _zoom >= _labelZoom;
                _zoom = e.camera.zoom;
                if (wasShowing != (_zoom >= _labelZoom)) setState(() {});
              },
              // 活地图：点任意位置 → 查周边 POI → 可收进景点库
              onTap: (_, latLng) => _handleMapTap(latLng),
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://webrd0{s}.is.autonavi.com/appmaptile'
                    '?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                subdomains: const ['1', '2', '3', '4'],
                userAgentPackageName: 'com.zhaohongfei.travel_planner',
                maxZoom: 18,

                // ══ 下面几项都是为了消除「缩放时卡白」 ══
                //
                // 卡白的机制：放大后旧瓦片被销毁、新瓦片还在下载，
                // 这 100-200ms 里那块区域就是空白。

                // ① 磁盘缓存（最关键）。
                //    flutter_map 默认只缓存在内存里，App 一关就没了，
                //    所以每次打开地图都要重新下载。落到磁盘后，
                //    第一次浏览过的区域之后再缩放都是毫秒级读本地。
                //    本质就是「边用边内置」——用得越久本地越全。
                tileProvider: _tileProvider,

                // ② 旧瓦片撑到新瓦片到位为止。
                //    放大时上一级的瓦片其实还有用（糊一点但位置对），
                //    留着它当占位图，视觉上是「先糊后清」而不是「先白后清」。
                //    设大一点，跨多级缩放时也不至于空白。
                keepBuffer: 8,

                // ③ 视口外多预取几圈，滑动/缩放更容易命中缓存
                panBuffer: 3,

                // 瓦片淡入的时长，短一点显得更跟手
                tileDisplay: const TileDisplay.fadeIn(
                  duration: Duration(milliseconds: 80),
                ),

                // ④ 加载失败的瓦片不要长期留在缓存里反复重试
                evictErrorTileStrategy: EvictErrorTileStrategy.notVisible,
              ),
              MarkerLayer(
                markers: [
                  for (final entry in visible)
                    Marker(
                      point: entry.pos!,
                      // ⚠️ 这里踩过坑：原来放大后把 width 从 30 改成 150，
                      //    同时把 alignment 也改成靠左——两个变化叠加，
                      //    圆点的落点就漂了，缩放时看着像景点在地图上滑动。
                      //
                      //    正确做法：**width 和 alignment 都不随缩放变**。
                      //    固定宽度 160 + Alignment.centerLeft，
                      //    圆点靠 Pin 内部的 padding 钉在左边缘，
                      //    多出来的宽度全在右边给文字用。
                      // ⚠️⚠️ 关键：width / height / alignment 三个一起决定
                      //       「控件中心」落在坐标点上，所以：
                      //         · 用默认的 Alignment.center（不设 alignment）
                      //         · width/height 只留圆点那么大（32）
                      //         · 文字用 Stack 绝对定位往右飘，【不参与】测量
                      //
                      // 【踩过的坑】曾经为了「圆点靠左、文字往右展开」写成：
                      //     width: 160, alignment: Alignment.centerLeft,
                      //     child: Row([SizedBox(width:14), dot, ...])
                      //   这样整个 160 宽盒子的左边缘压在坐标点上，
                      //   圆心因此跑到坐标点右边 14 像素处。
                      //   14 像素在 zoom 11 时 = 770 米（肉眼极明显），
                      //   在 zoom 18 时 = 7 米（几乎看不出）——
                      //   正好表现为「越放大越准」，害我查了好几轮。
                      width: 32,
                      height: 32,
                      child: _Pin(
                        name: entry.place.name,
                        kind: entry.place.kind,
                        visited: _isVisited(entry.place),
                        selected: _selected?.id == entry.place.id,
                        showLabel: _zoom >= _labelZoom,
                        onTap: () =>
                            setState(() => _selected = entry.place),
                      ),
                    ),
                  // 活地图：选中库外地点的紫色临时标记（入库后消失）
                  if (_pickedSpot != null)
                    Marker(
                      point:
                          LatLng(_pickedSpot!.lat, _pickedSpot!.lng),
                      width: 32,
                      height: 32,
                      child: const _PickedSpotPin(),
                    ),
                ],
              ),
              const RichAttributionWidget(
                attributions: [TextSourceAttribution('高德地图')],
              ),
            ],
          ),
        ),

        // 顶部筛选条 + 标签显隐
        Positioned(
          top: 10,
          left: 10,
          right: 10,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FilterBar(
                kindFilter: _kindFilter,
                onlyNotVisited: _onlyNotVisited,
                onlyNotPlanned: _onlyNotPlanned,
                total: _all.length,
                visible: visible.length,
                onKind: (k) => setState(() => _kindFilter = k),
                onNotVisited: (v) => setState(() => _onlyNotVisited = v),
                onNotPlanned: (v) => setState(() => _onlyNotPlanned = v),
              ),
              const SizedBox(height: 6),
              _TagToggleBar(
                tags: _allTags,
                selected: _selectedTags,
                onToggle: (t) => setState(() {
                  if (_selectedTags.contains(t)) {
                    _selectedTags.remove(t);
                  } else {
                    _selectedTags.add(t);
                  }
                }),
                onClear: () => setState(_selectedTags.clear),
              ),
              const SizedBox(height: 6),
              // 活地图搜索框：搜库里没有的地点
              _SpotSearchBar(
                controller: _searchCtrl,
                searching: _searching,
                onSubmit: _searchSpot,
              ),
              // 搜索候选
              if (_searchResults.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Card(
                    elevation: 4,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 190),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _searchResults.length,
                        itemBuilder: (context, i) {
                          final s = _searchResults[i];
                          final inLibrary =
                              _libraryNames.contains(s.showName);
                          return ListTile(
                            dense: true,
                            leading:
                                const Icon(Icons.search, size: 18),
                            title: Text(s.showName,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              (s.address != null && s.address!.isNotEmpty)
                                  ? s.address!
                                  : s.displayName,
                              style: const TextStyle(fontSize: 11),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // ➕ 只出现在「不在景点库」的候选上 = 收进景点库
                            //（加进行程在选中后点卡片上的按钮，两个动作不混）
                            trailing: inLibrary
                                ? const Icon(Icons.check_circle,
                                    size: 18, color: Colors.green)
                                : IconButton(
                                    visualDensity: VisualDensity.compact,
                                    iconSize: 20,
                                    icon: const Icon(Icons.add_circle),
                                    tooltip: '收进景点库',
                                    onPressed: () =>
                                        _quickAddFromSearch(s),
                                  ),
                            onTap: () => _pickSpot(s),
                          );
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        // 选中的地点详情
        if (_selected != null)
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: _PlaceCard(
              place: _selected!,
              visited: _isVisited(_selected!),
              trip: _trip,
              onClose: () => setState(() => _selected = null),
              onToggleVisited: () => _toggleVisited(_selected!),
              onAddToDay: _trip == null ? null : () => _addToDay(_selected!),
            ),
          ),

        // 活地图：选中的库外地点卡片（名字可改，收为吃 / 收为玩）
        if (_pickedSpot != null && _selected == null)
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: _PickedSpotCard(
              spot: _pickedSpot!,
              nameController: _spotNameCtrl,
              busy: _addingSpot,
              nearbyCount: _nearbyCache.length,
              onClose: () => setState(() => _pickedSpot = null),
              onPickNearby: _pickFromNearby,
              onAdd: (kind) => _saveSpotToLibrary(
                  _pickedSpot!, _spotNameCtrl.text.trim(), kind),
            ),
          ),
      ],
    );
  }

  Future<void> _toggleVisited(Attraction a) async {
    final repo = ref.read(repoProvider);
    final visited = _isVisited(a);

    await repo.toggleVisited(a.id, visited: !visited);

    // ⚠️ 刻意不调 _load()：
    //    _load 会把 _loading 置 true，整个页面闪一下白屏再回来。
    //    这里只重取该地点的数据，就地更新，界面不闪。
    final fresh = await repo.attractionsOf(widget.regionId);
    if (!mounted) return;

    final updated = fresh.where((x) => x.id == a.id).firstOrNull;
    if (updated == null) return;

    setState(() {
      final idx = _all.indexWhere((x) => x.id == a.id);
      if (idx >= 0) _all[idx] = updated;
      _selected = updated;
    });
  }

  Future<void> _addToDay(Attraction a) async {
    final trip = _trip;
    if (trip == null) return;

    final totalDays = trip.endDate.difference(trip.startDate).inDays + 1;
    final choice = await showModalBottomSheet<({int day, TimeBlock block})>(
      context: context,
      builder: (ctx) => _AddToDaySheet(totalDays: totalDays, placeName: a.name),
    );
    if (choice == null) return;

    final repo = ref.read(repoProvider);
    final seq = await repo.nextSeqInBlock(trip.id, choice.day, choice.block);
    await repo.addItem(
      tripId: trip.id,
      dayIndex: choice.day,
      seq: seq,
      timeBlock: choice.block,
      customName: a.name,
      attractionId: a.id,
      note: a.note,
    );

    if (!mounted) return;
    ref.invalidate(tripItemsProvider(trip.id));
    AppToast.show(
      context,
      '已加入第 ${choice.day} 天 · ${kTimeBlockLabels[choice.block]}',
    );
  }

  // ════════════════════════════════════════════════════════════
  // 活地图：搜索 / 点选 / 收进景点库
  // ════════════════════════════════════════════════════════════

  /// 搜索框提交 → 高德 POI 搜索 → 候选列表
  Future<void> _searchSpot(String text) async {
    final q = text.trim();
    if (q.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() => _searching = true);
    // 用地区名限定城市，避免「滕王阁」搜到外省同名楼
    final res = await Geocoder().searchPlaces(q, city: widget.regionName);
    if (!mounted) return;
    setState(() {
      _searchResults = res.points;
      _searching = false;
    });
    // 失败与「没搜到」必须区分开：不提示的话界面等于在骗人
    // （说是没有这个地方，其实是网络/限流问题）
    if (res.error != null && mounted) AppToast.show(context, res.error!);
  }

  /// 选中一个候选（搜索或周边清单）：地图飞过去，挂紫色临时标记
  void _pickSpot(GeoPoint spot) {
    _spotNameCtrl.text = spot.showName;
    setState(() {
      _pickedSpot = spot;
      _searchResults = [];
      _selected = null;
    });
    _mapController.move(LatLng(spot.lat, spot.lng), 16);
  }

  /// 点地图任意位置：**直接**在该点落标记 + 弹添加卡片（高德式）。
  ///
  /// 名字解析走**逆地理编码**（regeo）：高德服务端告诉你「这个点是什么」，
  /// 点「浔阳楼」名字所在的位置就会带出「浔阳楼」，零输入。
  /// regeo 没结果再退回周边 POI 搜索。
  Future<void> _handleMapTap(LatLng latLng) async {
    // 有临时卡片/搜索结果开着时，第一下只负责收起，避免误触
    if (_pickedSpot != null || _searchResults.isNotEmpty) {
      setState(() {
        _pickedSpot = null;
        _searchResults = [];
      });
      return;
    }
    setState(() => _selected = null);

    // 1) 逆地理：点哪是哪（最近 POI / 道路 / 门牌）
    var spot = await Geocoder()
        .reverseGeocode(latLng.latitude, latLng.longitude);

    // 2) regeo 没给出名字 → 退回周边搜索
    if (spot == null || (spot.name ?? '').isEmpty) {
      final spots = await Geocoder()
          .searchAround(latLng.latitude, latLng.longitude);
      if (!mounted) return;
      _nearbyCache = spots;
      final guess = spots.firstOrNull;
      spot = GeoPoint(
        lat: latLng.latitude,
        lng: latLng.longitude,
        displayName: guess?.displayName ?? spot?.displayName ?? '',
        name: guess?.showName ?? '',
        address: guess?.address ?? spot?.address,
      );
    } else {
      if (!mounted) return;
      final spots = await Geocoder()
          .searchAround(latLng.latitude, latLng.longitude);
      if (mounted) _nearbyCache = spots;
    }

    _spotNameCtrl.text = (spot.name ?? '').isEmpty ? '' : spot.name!;
    setState(() => _pickedSpot = spot);
  }

  /// 「换个名字」：点选位置的周边 POI 清单（选中即用它的名字和坐标）
  Future<void> _pickFromNearby() async {
    if (_nearbyCache.isEmpty) {
      AppToast.show(context, '这附近没查到别的有名字的地点');
      return;
    }
    final picked = await showModalBottomSheet<GeoPoint>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('这附近有什么？',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              const Divider(height: 1),
              for (final s in _nearbyCache)
                ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(s.showName),
                  subtitle: Text(
                    (s.address != null && s.address!.isNotEmpty)
                        ? s.address!
                        : s.displayName,
                    style: const TextStyle(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(ctx, s),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _pickSpot(picked);
  }

  /// 收进景点库的统一入口（点选卡片和搜索 ➕ 都走这里）。
  ///
  /// ⚠️ 顺带是「补坐标」的新路子：如果库里已有同名地点但没坐标，
  ///    在地图上选中它再收一次，坐标就补上了（不用再跑批量补坐标）。
  Future<void> _saveSpotToLibrary(
    GeoPoint spot,
    String name,
    PlaceKind kind,
  ) async {
    if (_addingSpot) return;
    if (name.isEmpty) {
      AppToast.show(context, '先给它起个名字');
      return;
    }

    setState(() => _addingSpot = true);
    try {
      final repo = ref.read(repoProvider);
      final all = await repo.attractionsOf(widget.regionId);
      final existing = all.where((a) => a.name == name).firstOrNull;

      if (existing != null) {
        if (existing.lat == null || existing.lng == null) {
          await repo.setAttractionCoords(
              existing.id, lat: spot.lat, lng: spot.lng);
          if (!mounted) return;
          AppToast.show(context, '「$name」已在库里，顺手补上了坐标');
        } else {
          if (!mounted) return;
          AppToast.show(context, '景点库里已经有「$name」了');
        }
      } else {
        await repo.addAttraction(
          regionId: widget.regionId,
          name: name,
          kind: kind.name,
          address: (spot.address != null && spot.address!.isNotEmpty)
              ? spot.address
              : spot.displayName,
          lat: spot.lat,
          lng: spot.lng,
        );
        if (!mounted) return;
        AppToast.show(
            context, '已收进景点库（${kind == PlaceKind.eat ? "🍜 吃" : "🏛 玩"}）');
      }

      // 静默刷新标记（不走 _load，避免整页闪加载圈）
      await _silentReload();
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '收藏失败：$e');
    } finally {
      if (mounted) setState(() => _addingSpot = false);
    }
  }

  /// 搜索候选的 ➕：小菜单选吃/玩，直接入库（不动行程）
  Future<void> _quickAddFromSearch(GeoPoint spot) async {
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
    await _saveSpotToLibrary(spot, spot.showName, kind);
  }

  /// 不闪屏的数据刷新（收藏入库后用）
  Future<void> _silentReload() async {
    final repo = ref.read(repoProvider);
    final all = await repo.attractionsOf(widget.regionId);
    final withCoords =
        all.where((a) => a.lat != null && a.lng != null).toList();
    final gcj = withCoords.map((a) => LatLng(a.lat!, a.lng!)).toList();
    final tags = await repo.tagsOfMany(withCoords.map((a) => a.id).toList());
    final planned =
        await repo.plannedAttractionIdsOfRegion(widget.regionId);
    if (!mounted) return;
    setState(() {
      _all = withCoords;
      _gcjCache = gcj;
      _tagMap = tags;
      _libraryNames = all.map((a) => a.name).toSet();
      _plannedIds = planned;
    });
  }
}

// ══════════════════════════════════════════════════════════════
// 地图标记
// ══════════════════════════════════════════════════════════════

/// 地图上的一个地点标记。
///
/// ⚠️ 布局约定（改之前先读）：
///    标记框宽度固定 [_MARKER_W]，对齐方式是 centerLeft ——
///    也就是**标记框的左边缘正好压在经纬度坐标上**。
///    所以内部必须用 padding 把圆点往右推，让**圆点的圆心**落在左边缘，
///    多出来的宽度全给右边的文字用。
///
///    这样无论有没有名字，圆点位置都不变，缩放时不会漂。
class _Pin extends StatelessWidget {
  const _Pin({
    required this.name,
    required this.kind,
    required this.visited,
    required this.selected,
    required this.showLabel,
    required this.onTap,
  });

  /// 圆点直径。同时也是标记框的尺寸——
  /// 框中心对齐坐标点、圆点在框里居中，圆心就正好落在坐标点上。
  static const double _dotSize = 28;

  final String name;
  final String? kind;
  final bool visited;
  final bool selected;

  /// 放大到一定级别后为 true，直接在标记旁显示名字
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 去过的变灰，没去的按吃/玩上色
    final color = visited
        ? const Color(0xFF9E9E9E)
        : (kind == 'eat' ? const Color(0xFFE8783A) : const Color(0xFF5B8EC9));

    final dot = Container(
      width: _dotSize,
      height: _dotSize,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? Colors.black : Colors.white,
          width: selected ? 3 : 2,
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(
        visited
            ? Icons.check
            : (kind == 'eat' ? Icons.restaurant : Icons.place),
        size: 15,
        color: Colors.white,
      ),
    );

    // ⚠️ 圆点必须**正好居中**在标记框里——FlutterMap 会把框的中心
    //    对齐到经纬度坐标点，圆点居中 = 圆心落在坐标点上。
    //    任何额外的偏移（padding / Row 前置间距）都会导致地图上的点偏移，
    //    而且偏得越小的缩放级别越明显。
    //
    //    文字用 Stack 绝对定位往右飘：它不参与 Stack 的尺寸测量，
    //    所以再怎么长也不会把圆点挤偏。
    if (!showLabel) {
      return GestureDetector(onTap: onTap, child: dot);
    }

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          dot,
          Positioned(
            left: _dotSize,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(5),
                boxShadow: const [
                  BoxShadow(color: Colors.black12, blurRadius: 2),
                ],
              ),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2C3E50),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 顶部筛选条
// ══════════════════════════════════════════════════════════════

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.kindFilter,
    required this.onlyNotVisited,
    required this.onlyNotPlanned,
    required this.total,
    required this.visible,
    required this.onKind,
    required this.onNotVisited,
    required this.onNotPlanned,
  });

  final String? kindFilter;
  final bool onlyNotVisited;
  final bool onlyNotPlanned;
  final int total;
  final int visible;
  final ValueChanged<String?> onKind;
  final ValueChanged<bool> onNotVisited;
  final ValueChanged<bool> onNotPlanned;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final k in const [null, 'eat', 'play'])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(switch (k) {
                          'eat' => '🍜 吃',
                          'play' => '🏛 玩',
                          _ => '全部',
                        }),
                        selected: kindFilter == k,
                        onSelected: (_) => onKind(k),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  const SizedBox(width: 4),
                  FilterChip(
                    label: const Text('只看没去的'),
                    selected: onlyNotVisited,
                    onSelected: onNotVisited,
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: const Text('只看没排的'),
                    selected: onlyNotPlanned,
                    onSelected: onNotPlanned,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: Text(
                '显示 $visible / $total 个',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 标签显隐控制条
//
// 点某个标签 = 把带这个标签的地点全部隐藏；
// 再点一下恢复。用于「先把吃过的全部收起来」这种场景。
// ══════════════════════════════════════════════════════════════

/// 地图的标签筛选条。
///
/// 样式与**景点库详情页**保持一致：第一个是「标签：全部」，后面是各标签。
/// 区别是这里**支持多选**——景点库是单选（看某一类），
/// 地图是多选叠加（同时看公园和博物馆）。
class _TagToggleBar extends StatelessWidget {
  const _TagToggleBar({
    required this.tags,
    required this.selected,
    required this.onToggle,
    required this.onClear,
  });

  final List<String> tags;

  /// 选中的标签。空 = 不筛，全都显示
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          children: [
            const Icon(Icons.label_outline, size: 15, color: Colors.grey),
            const SizedBox(width: 4),
            Expanded(
              child: SizedBox(
                height: 32,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    // 和景点库一样，第一个是「全部」
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: const Text('标签：全部'),
                        selected: selected.isEmpty,
                        visualDensity: VisualDensity.compact,
                        labelStyle: const TextStyle(fontSize: 11),
                        onSelected: (_) => onClear(),
                      ),
                    ),
                    for (final t in tags)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(t),
                          selected: selected.contains(t),
                          visualDensity: VisualDensity.compact,
                          labelStyle: const TextStyle(fontSize: 11),
                          onSelected: (_) => onToggle(t),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 选中地点的详情卡片
// ══════════════════════════════════════════════════════════════

class _PlaceCard extends StatelessWidget {
  const _PlaceCard({
    required this.place,
    required this.visited,
    required this.trip,
    required this.onClose,
    required this.onToggleVisited,
    required this.onAddToDay,
  });

  final Attraction place;
  final bool visited;
  final Trip? trip;
  final VoidCallback onClose;
  final VoidCallback onToggleVisited;
  final VoidCallback? onAddToDay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    place.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      decoration: visited ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: onClose,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (place.category != null)
                  _Chip(place.category!, theme.colorScheme.primary),
                if (place.ticketPriceCents > 0)
                  _Chip(
                    '¥${(place.ticketPriceCents / 100).toStringAsFixed(0)}',
                    Colors.redAccent,
                  ),
                if (place.suggestDurationMin != null)
                  _Chip(
                    '${(place.suggestDurationMin! / 60).toStringAsFixed(1)}h',
                    Colors.blueGrey,
                  ),
              ],
            ),
            if (place.address != null && place.address!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.location_on_outlined, size: 14),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      place.address!,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
            if (place.note != null && place.note!.isNotEmpty) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 110),
                child: SingleChildScrollView(
                  child: Text(
                    place.note!,
                    style: const TextStyle(fontSize: 12, height: 1.45),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: onToggleVisited,
                  icon: Icon(
                    visited ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 18,
                    color: visited ? Colors.green : null,
                  ),
                  label: Text(visited ? '去过了' : '标记去过'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 8),
                if (onAddToDay != null)
                  FilledButton.icon(
                    onPressed: onAddToDay,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('加进行程'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ],
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
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 活地图：搜索框 / 选中库外地点的卡片 / 临时标记
// ══════════════════════════════════════════════════════════════

class _SpotSearchBar extends StatelessWidget {
  const _SpotSearchBar({
    required this.controller,
    required this.searching,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool searching;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          onSubmitted: onSubmit,
          textAlignVertical: TextAlignVertical.center,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: '搜地图上的任何地方…',
            isDense: true,
            border: InputBorder.none,
            prefixIcon: searching
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child:
                          CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : const Icon(Icons.search, size: 20),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      controller.clear();
                      onSubmit('');
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

class _PickedSpotCard extends StatelessWidget {
  const _PickedSpotCard({
    required this.spot,
    required this.nameController,
    required this.busy,
    required this.nearbyCount,
    required this.onClose,
    required this.onPickNearby,
    required this.onAdd,
  });

  final GeoPoint spot;
  final TextEditingController nameController;
  final bool busy;

  /// 点选位置周边查到的 POI 数（>1 时显示「换个名字」）
  final int nearbyCount;
  final VoidCallback onClose;
  final VoidCallback onPickNearby;
  final ValueChanged<PlaceKind> onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final address = (spot.address != null && spot.address!.isNotEmpty)
        ? spot.address!
        : spot.displayName;

    return Card(
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: nameController,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      hintText: '这叫什么？（可改）',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                if (nearbyCount > 1)
                  TextButton(
                    onPressed: onPickNearby,
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    child: const Text('换个名字',
                        style: TextStyle(fontSize: 11)),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: onClose,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (address.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(address,
                    style:
                        const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            Row(
              children: [
                const Icon(Icons.lightbulb_outline,
                    size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text('收进景点库，以后排行程直接用：',
                      style: TextStyle(fontSize: 12)),
                ),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : () => onAdd(PlaceKind.eat),
                  icon: const Text('🍜', style: TextStyle(fontSize: 13)),
                  label: const Text('吃'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : () => onAdd(PlaceKind.play),
                  icon: const Text('🏛', style: TextStyle(fontSize: 13)),
                  label: const Text('玩'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 选中库外地点的临时标记（紫色，区别于库里已存的蓝/橙/灰）
class _PickedSpotPin extends StatelessWidget {
  const _PickedSpotPin();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF9B7BC9),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(
              color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      alignment: Alignment.center,
      child: const Icon(Icons.add_location_alt, size: 15, color: Colors.white),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// 「加入第几天、哪个时段」
// ══════════════════════════════════════════════════════════════

class _AddToDaySheet extends StatefulWidget {
  const _AddToDaySheet({required this.totalDays, required this.placeName});

  final int totalDays;
  final String placeName;

  @override
  State<_AddToDaySheet> createState() => _AddToDaySheetState();
}

class _AddToDaySheetState extends State<_AddToDaySheet> {
  /// 记住上次选的位置。
  ///
  /// 用户实测反馈：连着往行程里加地点时，每次都从「第1天·上午」开始太烦，
  /// 应该是「上次加到第2天午餐，下次再选吃的就自动到第2天晚餐」。
  /// 跨实例记忆，所以用 static。
  static int _lastDay = 1;
  static TimeBlock _lastBlock = TimeBlock.morning;

  // ⚠️ static 记忆是跨行程的：上一个行程可能有很多天，
  //    这个行程只有 3 天。不钳制的话 _day 会落在不存在的天上，
  //    点「加进去」就会把地点存到 dayIndex 超出范围——
  //    列表、导出、长图全都看不见它，纯幽灵数据。
  late int _day = _lastDay.clamp(1, widget.totalDays);
  late TimeBlock _block = _lastBlock;

  static const _orderedBlocks = [
    TimeBlock.breakfast,
    TimeBlock.morning,
    TimeBlock.lunch,
    TimeBlock.afternoon,
    TimeBlock.dinner,
    TimeBlock.evening,
  ];

  /// 选了一个时段后，自动预选「下一个」时段，方便连续添加。
  /// 最后一个时段则顺延到次日第一段（如果还有下一天）。
  void _advanceBlock() {
    final i = _orderedBlocks.indexOf(_block);
    if (i < _orderedBlocks.length - 1) {
      _block = _orderedBlocks[i + 1];
    } else if (_day < widget.totalDays) {
      _day += 1;
      _block = _orderedBlocks.first;
    }
    // 已是最后一天最后一段，就原地不动
    _lastDay = _day;
    _lastBlock = _block;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '把「${widget.placeName}」加到',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 14),
          const Text('第几天', style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var d = 1; d <= widget.totalDays; d++)
                ChoiceChip(
                  label: Text('第 $d 天'),
                  selected: _day == d,
                  onSelected: (_) => setState(() {
                    _day = d;
                    _lastDay = d;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            '哪个时段',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final b in _orderedBlocks)
                ChoiceChip(
                  label: Text(kTimeBlockLabels[b]!),
                  selected: _block == b,
                  onSelected: (_) => setState(() {
                    _block = b;
                    _lastBlock = b;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              // 记下这次的位置，并把时段往后推一格，方便连续添加
              final choice = (day: _day, block: _block);
              _advanceBlock();
              Navigator.pop(context, choice);
            },
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            child: const Text('加进去'),
          ),
          const SizedBox(height: 6),
          const Text(
            '加完会自动跳到下一时段，方便连续添加',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
