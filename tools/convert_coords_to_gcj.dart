// ═══════════════════════════════════════════════════════════════
// 把候选库里的坐标从 WGS-84 转成 GCJ-02
//
// 背景：全项目统一用 GCJ-02（和地图瓦片一致），见
//      `lib/ui/region_map_screen.dart` 里 `_load()` 的说明。
//      早先存的是 WGS-84，得转过来。
//
// 用法：dart run tools/convert_coords_to_gcj.dart <候选库.json>
//
// ⚠️ 会先备份成 .bak，重复执行不会重复转换（会问你要不要继续）。
// ═══════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';

import 'coord_convert.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('用法: dart run tools/convert_coords_to_gcj.dart <候选库.json>');
    exit(1);
  }

  final path = args.first;
  final file = File(path);
  if (!file.existsSync()) {
    print('❌ 找不到文件: $path');
    exit(1);
  }

  final root = jsonDecode(await file.readAsString()) as Map<String, dynamic>;

  // 防重复转换：看有没有转换过的标记
  if (root['_coordSystem'] == 'GCJ-02') {
    print('⚠️ 这个文件已经标注为 GCJ-02，可能已经转过了。');
    print('   再转一次会让坐标偏 604 米。');
    print('   确实要转就手动把 _coordSystem 字段删掉再跑。');
    exit(1);
  }

  var count = 0;
  final samples = <String>[];

  void process(List list) {
    for (final node in list) {
      if (node is! Map) continue;
      final lat = node['lat'];
      final lng = node['lng'];
      if (lat is! num || lng is! num) continue;

      final g = wgs84ToGcj02(lat.toDouble(), lng.toDouble());

      if (samples.length < 3) {
        samples.add('  ${node['name']}\n'
            '    WGS84: ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}\n'
            '    GCJ02: ${g.lat.toStringAsFixed(6)}, ${g.lng.toStringAsFixed(6)}');
      }

      node['lat'] = double.parse(g.lat.toStringAsFixed(6));
      node['lng'] = double.parse(g.lng.toStringAsFixed(6));

      // 在 _geo 里记一下坐标系，以后好查
      final geo = node['_geo'];
      if (geo is Map) {
        geo['coordSystem'] = 'GCJ-02';
      }

      count++;
    }
  }

  for (final key in ['attractions', 'foods']) {
    final list = root[key];
    if (list is List) process(list);
  }

  root['_coordSystem'] = 'GCJ-02';
  root['_coordNote'] =
      '坐标为 GCJ-02（高德坐标系），与 App 地图瓦片一致。不要再转 WGS-84。';

  print('═══ 坐标转换 WGS-84 → GCJ-02 ═══\n');
  print('样例（前 3 个）：');
  for (final s in samples) {
    print(s);
  }
  print('');

  final backup = '$path.bak';
  await file.copy(backup);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(root),
  );

  print('✅ 转换了 $count 个地点的坐标');
  print('   已写入: $path');
  print('   备份:   $backup');
}
