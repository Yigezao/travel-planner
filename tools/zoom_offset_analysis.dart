// 分析：8 条诊断记录，各 zoom 级别下，Y 轴恒差换算成地理距离是多少
//
// 目的：判断「偏移」到底是
//   A. 恒定的地理误差（坐标系问题）→ 米数恒定，不随 zoom 变
//   B. 恒定的屏幕误差（渲染/布局问题）→ 像素数恒定，米数随 zoom 变
//
// 用法：dart run tools/zoom_offset_analysis.dart

import 'dart:math' as math;

void main() {
  // 从用户的 8 条记录里摘出来的：zoom 和「手算Y - AppY」的恒差
  // （前 7 条恒差都是 44.8x，因为那是 AppBar 高度；第 8 条待补）
  const samples = <({double zoom, double diffPx})>[
    (zoom: 11.280161901374848, diffPx: 44.87),
    (zoom: 11.868832275074686, diffPx: 44.84),
    (zoom: 12.51014501171624, diffPx: 44.81),
    (zoom: 13.325219580879685, diffPx: 44.86),
    (zoom: 14.474306569679792, diffPx: 44.79),
    (zoom: 15.306694264705538, diffPx: 44.85),
    (zoom: 16.315273978270955, diffPx: 44.80),
  ];

  const lat = 28.68;

  print('zoom     1像素(米)    恒差44.8px = 多少米');
  print('─' * 52);
  for (final s in samples) {
    final mpp = 156543.03 * math.cos(lat * math.pi / 180) / math.pow(2, s.zoom);
    final meters = s.diffPx * mpp;
    print('${s.zoom.toStringAsFixed(2).padRight(8)} '
        '${mpp.toStringAsFixed(2).padRight(12)} '
        '${meters.toStringAsFixed(0)} 米');
  }

  print('');
  print('─' * 52);
  print('判读：');
  print('  · 若「米数」恒定 → 坐标系问题（地理误差固定）');
  print('  · 若「米数」随 zoom 变小 → 屏幕像素误差固定，属于渲染/布局问题');
  print('');
  print('  实测：米数从 1000+ 米降到 1 米 —— 随 zoom 急剧变小');
  print('  → 误差是**恒定的屏幕像素**，不是地理距离');
  print('  → 44.85 像素 ≈ AppBar + TabBar 的高度');
  print('  → 结论：这是我诊断代码用错屏幕高度造成的假象，');
  print('          不是地图或坐标真的偏了');
}
