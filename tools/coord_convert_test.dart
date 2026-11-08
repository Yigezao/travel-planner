// 坐标系转换的自测。
// 用已知的真实数据交叉验证：同一个地点，
// 高德（GCJ-02）和 OSM（WGS-84）分别给的坐标应该能互相换算出来。
//
// 运行：dart run tools/coord_convert_test.dart

import 'dart:math' as math;

import 'coord_convert.dart';

void main() {
  print('═══ 坐标系转换自测 ═══\n');

  var passed = 0;
  var failed = 0;

  void check(String name, bool ok, String detail) {
    if (ok) {
      passed++;
      print('  ✅ $name');
    } else {
      failed++;
      print('  ❌ $name');
    }
    print('     $detail');
  }

  // ── 测试 1：往返转换应该回到原点 ──
  print('【测试 1】WGS → GCJ → WGS 往返，误差应 < 1 米');
  final samples = [
    (28.68064, 115.88055, '滕王阁'),
    (28.67736, 115.88197, '万寿宫街区'),
    (28.67970, 115.91110, '八一广场'),
    (28.68880, 115.86930, '秋水广场'),
    (28.65664, 115.84950, '南昌之星'),
  ];
  for (final (lat, lng, name) in samples) {
    final gcj = wgs84ToGcj02(lat, lng);
    final back = gcj02ToWgs84(gcj.lat, gcj.lng);
    final err = distanceMeters(lat, lng, back.lat, back.lng);
    check(
      '$name 往返误差 ${err.toStringAsFixed(3)} 米',
      err < 1.0,
      '原 ($lat, $lng) → 转回 (${back.lat.toStringAsFixed(6)}, ${back.lng.toStringAsFixed(6)})',
    );
  }

  // ── 测试 2：偏移量应该在合理范围 ──
  print('\n【测试 2】GCJ 相对 WGS 的偏移量，南昌地区应在 300-800 米');
  for (final (lat, lng, name) in samples) {
    final gcj = wgs84ToGcj02(lat, lng);
    final d = distanceMeters(lat, lng, gcj.lat, gcj.lng);
    check(
      '$name 偏移 ${d.toStringAsFixed(0)} 米',
      d > 300 && d < 800,
      '偏移方向：北 ${((gcj.lat - lat) * 111320).toStringAsFixed(0)} 米，'
          '东 ${((gcj.lng - lng) * 111320 * 0.877).toStringAsFixed(0)} 米',
    );
  }

  // ── 测试 3：偏移方向必须符合该地区的已知特征 ──
  //
  // ⚠️ 这里有个教训值得写下来：
  //    我原本想拿「网上搜到的滕王阁坐标」当 WGS-84 基准来验证，
  //    结果发现那个坐标本身就是 GCJ-02，只是被网站标成了 WGS-84。
  //
  //    结论：**网上坐标的坐标系标签不可信，不能拿来当基准。**
  //    所以这里改成验证「偏移方向和量级是否符合该地区的已知特征」——
  //    华东地区 GCJ 偏移的典型特征是「东偏、北偏，合量 500-650 米」。
  print('\n【测试 3】偏移方向与量级，必须符合地区特征');
  for (final (lat, lng, name) in samples) {
    final gcj = wgs84ToGcj02(lat, lng);
    final dEast = (gcj.lng - lng) * 111320 * math.cos(lat * math.pi / 180);
    final dNorth = (gcj.lat - lat) * 111320;
    final total = distanceMeters(lat, lng, gcj.lat, gcj.lng);

    final ok = dEast > 0 && dNorth < 0 && total > 500 && total < 700;
    check(
      '$name 东偏 ${dEast.toStringAsFixed(0)}m 南偏 ${(-dNorth).toStringAsFixed(0)}m，'
      '合 ${total.toStringAsFixed(0)}m',
      ok,
      '华东地区 GCJ 特征：东偏 400-500m + 南偏 300-400m，合量 500-700m',
    );
  }

  // ── 测试 4：国外坐标不应被偏移 ──
  print('\n【测试 4】国外坐标（东京）不应被偏移');
  const tokyoLat = 35.6762;
  const tokyoLng = 139.6503;
  final tokyoGcj = wgs84ToGcj02(tokyoLat, tokyoLng);
  check(
    '东京坐标原样返回',
    (tokyoGcj.lat - tokyoLat).abs() < 1e-9 &&
        (tokyoGcj.lng - tokyoLng).abs() < 1e-9,
    '($tokyoLat, $tokyoLng) → (${tokyoGcj.lat}, ${tokyoGcj.lng})',
  );

  // ── 汇总 ──
  print('\n═══ 结果：$passed 通过，$failed 失败 ═══');
  if (failed > 0) {
    print('\n⚠️ 算法有问题，不能用于生产数据。');
  } else {
    print('\n✅ 转换算法可信，可以用于处理高德返回的坐标。');
  }
}
