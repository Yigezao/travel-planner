// ═══════════════════════════════════════════════════════════════
// 行程地图：把某一天要去的地方画在地图上，按顺序连线
//
// ⚠️ 坐标系处理
//
//   **数据库里存的就是 GCJ-02，和地图瓦片同一套，全程不转换。**
//
//   曾经走过弯路：数据存 WGS-84、渲染时转 GCJ-02。
//   看似等价，但只要有一处漏转，点就偏 604 米——
//   而这个偏移在屏幕上随缩放线性放大
//   （zoom 12 时 18 像素，zoom 16 时 288 像素，zoom 18 时 1152 像素），
//   表现为「越放大点越偏」，非常难查。
//
//   现在统一：录入、存储、渲染全用 GCJ-02，谁都不许再转。
//   转换函数保留在 lib/data/geocoder.dart，只给数据迁移用。
// ═══════════════════════════════════════════════════════════════

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/providers.dart';
import '../data/tile_cache.dart';
import '../data/travel_repository.dart';

/// 时段配色（和长图导出保持一致）
const Map<String, Color> _blockColors = {
  'breakfast': Color(0xFFE8A840),
  'morning': Color(0xFF5B8EC9),
  'lunch': Color(0xFFE8783A),
  'afternoon': Color(0xFF5AAA75),
  'dinner': Color(0xFF9B7BC9),
  'evening': Color(0xFF7B9CB5),
};

class DayMapScreen extends ConsumerStatefulWidget {
  const DayMapScreen({super.key, required this.tripId, this.initialDay = 1});

  final String tripId;
  final int initialDay;

  @override
  ConsumerState<DayMapScreen> createState() => _DayMapScreenState();
}

class _DayMapScreenState extends ConsumerState<DayMapScreen> {
  late int _day = widget.initialDay;
  final _mapController = MapController();

  /// 瓦片缓存实例。只在 State 里建一次（同 region_map_screen）
  final CachedTileProvider _tileProvider = CachedTileProvider();

  List<DayMapPoint> _points = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// ⚠️ `MapController` 必须**手动**释放。
  ///
  /// 已核对 flutter_map 8.3.2 源码（`map/widget.dart:75-78`）：
  /// 它只释放**自己创建**的控制器（`_controllerCreatedInternally` 那个分支），
  /// 从外部传进去的不代管。而控制器内部握着事件流 controller、一个用本 State
  /// 的 vsync 建的 AnimationController、以及若干 ValueNotifier。
  /// 不释放则每次进出这个页面泄漏一份——表现为来回看几次地图后越来越卡。
  ///
  /// （瓦片 provider 不用我们操心：`TileLayer` 自己会调 `tileProvider.dispose()`
  ///   —— `tile_layer.dart:517`。这里顺手再调一次只是幂等兜底，我们的实现
  ///   只是关掉共享 HttpClient 并把字段置空。）
  @override
  void dispose() {
    _mapController.dispose();
    _tileProvider.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final pts = await ref
          .read(repoProvider)
          .dayMapPoints(widget.tripId, _day);
      if (!mounted) return;
      setState(() {
        _points = pts;
        _loading = false;
      });
      _fitBounds();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 把视野自动缩放到能装下当天所有点。
  ///
  /// ⚠️ 整个包在 try 里：fitCamera / move 在特定情况下会抛异常
  ///    （比如点太少、地图还没完成首帧布局），
  ///    异常抛出去会让整个 TabBarView 渲染失败 → 整页空白。
  ///    这里失败就退化成「不自动缩放」，地图本体还能正常看。
  void _fitBounds() {
    if (_points.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        // 直接使用数据库坐标（GCJ-02），不转换——和 marker 用的是同一套
        final pts = _points.map((p) => LatLng(p.lat, p.lng)).toList();

        if (pts.length == 1) {
          _mapController.move(pts.first, 15);
          return;
        }

        final bounds = LatLngBounds.fromPoints(pts);
        _mapController.fitCamera(
          CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(60)),
        );
      } catch (e) {
        // 自动缩放失败不影响看地图，中心已经由 initialCenter 定好了
        // ignore: avoid_print
        print('[day_map] fitBounds 失败: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tripAsync = ref.watch(tripProvider(widget.tripId));

    return tripAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('出错了：$e'))),
      data: (trip) {
        if (trip == null) {
          return const Scaffold(body: Center(child: Text('行程不存在')));
        }
        final totalDays = trip.endDate.difference(trip.startDate).inDays + 1;

        return Scaffold(
          appBar: AppBar(
            title: Text('第 $_day 天 · 地图'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: '刷新',
                onPressed: _load,
              ),
              // 诊断（临时）：查为什么地图空白
              IconButton(
                icon: const Icon(Icons.bug_report_outlined),
                tooltip: '诊断',
                onPressed: () => _showDiagnostics(context),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(46),
              child: SizedBox(
                height: 46,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  itemCount: totalDays,
                  itemBuilder: (context, i) {
                    final d = i + 1;
                    return Padding(
                      padding: const EdgeInsets.only(
                        right: 6,
                        top: 4,
                        bottom: 6,
                      ),
                      child: ChoiceChip(
                        label: Text('第 $d 天'),
                        selected: _day == d,
                        onSelected: (_) {
                          setState(() => _day = d);
                          _load();
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          body: _buildBody(),
        );
      },
    );
  }

  /// 诊断（临时）：一键复制，方便定位「地图为什么空白」
  void _showDiagnostics(BuildContext context) {
    final cam = _mapController.camera;
    final data = {
      '第几天': _day,
      '加载中': _loading,
      '错误': _error,
      '地点数': _points.length,
      '相机': {
        'center_lat': cam.center.latitude,
        'center_lng': cam.center.longitude,
        'zoom': cam.zoom,
      },
      '瓦片': {
        '读磁盘': _tileProvider.hitDisk,
        '走网络': _tileProvider.fromNet,
        '失败': _tileProvider.failed,
        '缓存目录': _tileProvider.dirPath,
        '落盘失败原因': _tileProvider.lastWriteError,
      },
      '地点明细': _points
          .map((p) => {
                'name': p.name,
                'timeBlock': p.timeBlock,
                'lat': p.lat,
                'lng': p.lng,
              })
          .toList(),
    };
    final text = const JsonEncoder.withIndent('  ').convert(data);

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('单天地图诊断'),
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制')),
              );
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

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
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
    if (_points.isEmpty) {
      return _EmptyDayMap(day: _day);
    }

    // ⚠️ 直接用数据库里的坐标，**不转换**。
    // 数据存的就是 GCJ-02，和高德瓦片一致（见 region_map_screen 的说明）。
    final gcjPoints = _points.map((p) => LatLng(p.lat, p.lng)).toList();

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: gcjPoints.first,
            initialZoom: 14,
            minZoom: 3,
            maxZoom: 18,
            // 禁止旋转：双指旋转地图在实际用起来很干扰，
            // 只想缩放和平移。保持正北朝上更好认方向。
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            // 高德矢量路网瓦片
            TileLayer(
              urlTemplate:
                  'https://webrd0{s}.is.autonavi.com/appmaptile'
                  '?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
              subdomains: const ['1', '2', '3', '4'],
              userAgentPackageName: 'com.zhaohongfei.travel_planner',
              maxZoom: 18,
              // 详见 region_map_screen 里的说明，三项配合消除卡白：
              //   ① 磁盘缓存 —— 浏览过一次就永久本地，本质是「边用边内置」
              //   ② keepBuffer —— 旧瓦片撑到新瓦片到位，先糊后清
              //   ③ panBuffer  —— 视口外多预取几圈
              // ⚠️ 用 State 里的实例，别在这里 new——
              //    在 build 里 new 会每次重绘都换一个新 provider，
              //    缓存统计被清零、磁盘目录重复初始化。
              tileProvider: _tileProvider,
              keepBuffer: 8,
              panBuffer: 3,
              tileDisplay: const TileDisplay.fadeIn(
                duration: Duration(milliseconds: 80),
              ),
              evictErrorTileStrategy: EvictErrorTileStrategy.notVisible,
            ),
            // 连线：按行程顺序
            if (gcjPoints.length > 1)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: gcjPoints,
                    strokeWidth: 3.5,
                    color: const Color(0xFF5B8EC9).withValues(alpha: 0.75),
                  ),
                ],
              ),
            // 标记：小圆点（序号在点里）+ 右侧一行小字名字。
            // 名字用 Stack 绝对定位往右飘，不参与尺寸测量——
            // 再长也不会把圆点挤偏（region_map_screen 同款方案），
            // 也不会盖住地图上印的地名（只有一行 11px 小字）。
            // 同时遍历两个列表，避免 _points 和 gcjPoints 长度不一致时索引越界。
            MarkerLayer(
              markers: [
                for (var i = 0; i < gcjPoints.length && i < _points.length; i++)
                  Marker(
                    point: gcjPoints[i],
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        _NumberedMarker(
                          index: i + 1,
                          color: _blockColors[_points[i].timeBlock] ??
                              const Color(0xFF7B9CB5),
                        ),
                        Positioned(
                          left: 38,
                          top: 7,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(5),
                              boxShadow: const [
                                BoxShadow(
                                    color: Colors.black12, blurRadius: 2),
                              ],
                            ),
                            child: Text(
                              '${i + 1} · ${_points[i].name}',
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
                  ),
              ],
            ),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('高德地图'),
                TextSourceAttribution('OpenStreetMap contributors'),
              ],
            ),
          ],
        ),

      ],
    );
  }
}

/// 带序号的圆形标记
class _NumberedMarker extends StatelessWidget {
  const _NumberedMarker({required this.index, required this.color});

  final int index;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$index',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _EmptyDayMap extends StatelessWidget {
  const _EmptyDayMap({required this.day});

  final int day;

  @override
  Widget build(BuildContext context) {
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
            Text(
              '第 $day 天还没有可显示的地点',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Text(
              '两种情况会导致这里空白：\n\n'
              '1. 这一天还没安排行程\n'
              '2. 安排的地点还没有经纬度\n\n'
              '去「景点库」→ 选中地区 → 点右上角 📍 补坐标',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
