// 验证：用 flutter_map 的算法手算「地点应该画在屏幕哪个像素」，
// 和 App 诊断面板给的 screen_x_y 对比。
//
// 如果两者一致 → 换算链没问题，偏移出在别处
// 如果不一致   → flutter_map 的换算本身有问题
//
// 用法：dart run tools/verify_screen_pos.dart

import 'dart:math' as math;

/// Web Mercator：经纬度 → 世界像素坐标（zoom 级别下的绝对值）
double worldX(double lng, double zoom) {
  return (lng + 180.0) / 360.0 * math.pow(2, zoom) * 256;
}

double worldY(double lat, double zoom) {
  final r = lat * math.pi / 180.0;
  final m = math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi;
  return (1.0 - m) / 2.0 * math.pow(2, zoom) * 256;
}

void main() {
  // ── 第一条诊断记录（zoom 11.28）──
  const camLat = 28.707604132910916;
  const camLng = 115.81493456271299;
  const zoom = 11.280161901374848;
  const screenW = 360.0;
  const screenH = 748.0;

  // 从 App 诊断数据里抄几个点
  const cases = <({String name, double lat, double lng, double appX, double appY})>[
    (name: '滕王阁', lat: 28.681332, lng: 115.881197, appX: 297.2, appY: 382.1),
    (name: '八一广场', lat: 28.673856, lng: 115.904477, appX: 338.4, appY: 397.2),
    (name: '秋水广场', lat: 28.685675, lng: 115.864475, appX: 267.6, appY: 373.4),
    (name: '南昌之星', lat: 28.656183, lng: 115.850719, appX: 243.3, appY: 432.8),
    (name: '梅岭风景区', lat: 28.802491, lng: 115.765156, appX: 92.0, appY: 137.8),
  ];

  final camX = worldX(camLng, zoom);
  final camY = worldY(camLat, zoom);

  print('相机世界像素: (${camX.toStringAsFixed(1)}, ${camY.toStringAsFixed(1)})');
  print('');
  print('${"地点".padRight(14)} ${"手算屏幕位置".padRight(22)} '
      '${"App 给的".padRight(22)} 差值');
  print('─' * 74);

  var maxDiff = 0.0;
  for (final c in cases) {
    final px = worldX(c.lng, zoom);
    final py = worldY(c.lat, zoom);

    // 列表/地图坐标 → 屏幕坐标：
    // 屏幕中心是相机中心，加上相对位移
    final sx = screenW / 2 + (px - camX);
    final sy = screenH / 2 + (py - camY);

    final dx = (sx - c.appX).abs();
    final dy = (sy - c.appY).abs();
    if (dx > maxDiff) maxDiff = dx;
    if (dy > maxDiff) maxDiff = dy;

    print('${c.name.padRight(14)} '
        '(${sx.toStringAsFixed(1)}, ${sy.toStringAsFixed(1)})'.padRight(22) +
        '(${c.appX}, ${c.appY})'.padRight(22) +
        '(${dx.toStringAsFixed(2)}, ${dy.toStringAsFixed(2)})');
  }

  print('─' * 74);
  print('');
  if (maxDiff < 1.0) {
    print('✅ 换算链完全一致（最大差 ${maxDiff.toStringAsFixed(2)} 像素）');
    print('   → flutter_map 算的位置是对的');
    print('   → 偏移出在「标记实际画在哪个像素」这一环');
  } else {
    print('❌ 换算链不一致（最大差 ${maxDiff.toStringAsFixed(1)} 像素）');
    print('   → flutter_map 的 latLngToScreenOffset 本身有问题');
  }
}
