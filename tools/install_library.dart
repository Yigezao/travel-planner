// ═══════════════════════════════════════════════════════════════
// 把转换好的景点库**合并**进 assets/library/
//
// 用法（默认 dry-run，只报告不改）：
//   dart run tools/install_library.dart <convertedDir>
//   dart run tools/install_library.dart <convertedDir> --apply
//
// ⚠️ 为什么要合并而不是直接覆盖：
//    上游可能只发来某个城市的**部分更新**（比如样例里的南昌只有 5 条，
//    而库里已经有 35 条）。直接覆盖的话，**全新安装的用户就只剩 5 条**——
//    而已经装过 App 的老用户因为导入器是「按名字更新、不删」，看不出来。
//    这种「老用户正常、新用户缺数据」的 bug 极难发现。
//
//    合并规则：以名字为准 —— 新文件里的条目覆盖同名旧条目，
//    旧文件里独有的条目**保留**。region 级字段以新文件为准，
//    但新文件没给 notices 时保留旧的。
//
// 合并后会打印每个城市的「新增/更新/保留/总数」，便于人工核对。
//
// ⚠️⚠️ **这条保护的边界（必须知道，否则将来会当成灵异事件查）**：
//
//    它假定「新文件里没有」= 「这次没发」。所以如果上游是**故意删除**某个条目
//    （事后发现是垃圾、要撤回），**光在一批里不写它是不够的** ——
//    合并会把它**永久留住**（上游删了，这里还在）。
//
//    这正是「护栏过度」的形状：一个防「部分更新覆盖全量」的保护，
//    顺带也挡住了「主动撤回」。
//
//    当前这个风险可接受：质量闸已经移到**上游生成侧**，垃圾在产出前就被拦，
//    正常流程不会产生「需要撤回」的条目。
//
//    **真需要撤回时怎么办**：在批次里显式给出删除指令（例如
//    `{"delete": ["城市", "地点名"]}`），在这里处理。在加上之前，
//    别靠「不发它」来删 —— 那不会生效。
// ═══════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';

const String _assetsDir = 'assets/library';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tools/install_library.dart <convertedDir> [--apply]');
    exit(2);
  }
  final srcDir = Directory(args.first);
  final apply = args.contains('--apply');

  if (!srcDir.existsSync()) {
    stderr.writeln('✗ 目录不存在: ${srcDir.path}');
    exit(2);
  }

  final assets = Directory(_assetsDir);
  if (!assets.existsSync()) {
    stderr.writeln('✗ 找不到 $_assetsDir（要在工程根目录跑）');
    exit(2);
  }

  final files = srcDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  var anyChange = false;
  final lines = <String>[];

  for (final f in files) {
    final Map<String, dynamic> incoming;
    try {
      final d = jsonDecode(f.readAsStringSync());
      if (d is! Map<String, dynamic> || d['region'] is! Map) continue; // 不是库
      incoming = d;
    } catch (_) {
      continue;
    }

    final fileName = f.uri.pathSegments.last;
    final target = File('${assets.path}/$fileName');
    final cityName =
        ((incoming['region'] as Map)['name'] ?? fileName).toString();

    // ── 新城市：直接放 ──
    if (!target.existsSync()) {
      final n = _countPlaces(incoming);

      // ⚠️ 一个**没有任何地点**的新城市不该进 assets：
      //    · 用户在景点库里会看到一座空城
      //    · test/bundled_library_test.dart 的「每个地区都该有地点」会红
      //    典型来源：纯 notices 更新批次（data.jsonl 里没有该城记录）。
      //    对**已有**城市，这种批次是正常的（只更新 notices，走下面的合并分支）；
      //    但新城市必须有地点才算数。
      if (n == 0) {
        lines.add('⊘ $fileName（$cityName）**跳过**：新城市但 0 个地点'
            '（只有城市级数据，没有地点。等有地点再投）');
        continue;
      }

      lines.add('＋ $fileName（$cityName）**新城市** → 导入 $n 条');
      anyChange = true;
      if (apply) _writeAtomic(target, incoming);
      continue;
    }

    // ── 已有城市：合并 ──
    final existing = jsonDecode(target.readAsStringSync()) as Map<String, dynamic>;
    final merged = _merge(existing, incoming);
    final stat = _diff(existing, incoming);

    // ⚠️ region 级数据（notices / transport / lodging / note…）变了**也算变化**。
    //
    //    之前只按「地点增删改」决定要不要写盘 —— 于是**纯 notices 更新**
    //    （B 阶段最常见的形态：一城内容不变、只补「注意事项」）会被判成
    //    「没有变化」而**静默丢弃**。上游写了 notices，下游一个字都没进库。
    //    （这是我在这条链上修的第三处同类问题，三处都是"以为走通了"没实测。）
    final regionChanged = _regionChanged(existing, incoming);

    final tag = (stat.added == 0 && stat.updated == 0 && !regionChanged) ? '＝' : '↻';
    lines.add('$tag $fileName（$cityName） 新增 ${stat.added} · 更新 ${stat.updated} · '
        '保留 ${stat.kept} · 合并后共 ${_countPlaces(merged)} 条'
        '${regionChanged ? ' · 城市级数据已更新（notices 等）' : ''}'
        '${_countPlaces(merged) < _countPlaces(existing) ? '  ⚠️ 比原来少！' : ''}');

    if (stat.added > 0 || stat.updated > 0 || regionChanged) {
      anyChange = true;
      if (apply) _writeAtomic(target, merged);
    }
  }

  stdout.writeln(apply ? '=== 已写入 $_assetsDir ===' : '=== DRY-RUN（加 --apply 才真正写入）===');
  for (final l in lines) {
    stdout.writeln(l);
  }

  if (!anyChange) {
    stdout.writeln('（没有变化）');
  } else if (!apply) {
    stdout.writeln('\n确认无误后加 --apply 执行。');
  }

  // ── 安全闸：任何城市合并后条数变少，都值得停下来看一眼 ──
  for (final f in files) {
    final fileName = f.uri.pathSegments.last;
    final target = File('${assets.path}/$fileName');
    if (!target.existsSync()) continue;
    final a = _countPlaces(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    final b = _countPlaces(jsonDecode(target.readAsStringSync()) as Map<String, dynamic>);
    if (a > 0 && a < b) {
      stdout.writeln('⚠️ $fileName：新文件 $a 条 < 现有 $b 条 —— 合并会保留旧的，'
          '但请确认这是有意的部分更新，而不是漏抓。');
    }
  }
}

/// 统计新文件相对旧文件的增删改。
///
/// 语义定清楚（之前写得含糊，导致「南昌 6 条其实是更新却报了 0」）：
///   added   = 新文件里、旧文件里没有的名字
///   updated = 两边都有的名字（会被新数据覆盖）
///   kept    = 旧文件里、新文件里没有的名字（**合并时保留**）
({int added, int updated, int kept}) _diff(
  Map<String, dynamic> old,
  Map<String, dynamic> neu,
) {
  final oldNames = _namesOf(old);
  final newNames = _namesOf(neu);
  return (
    added: newNames.difference(oldNames).length,
    updated: newNames.intersection(oldNames).length,
    kept: oldNames.difference(newNames).length,
  );
}

/// region 级字段有没有真的变化。
///
/// 只比「新文件里给了的字段」——新文件没给的会被 `_merge` 保留成旧值，
/// 所以不算变化（与合并规则保持一致）。
bool _regionChanged(Map<String, dynamic> old, Map<String, dynamic> neu) {
  final a = (old['region'] as Map?) ?? const {};
  final b = (neu['region'] as Map?) ?? const {};
  for (final k in [
    'name', 'country', 'province', 'note', 'notices', 'transport', 'lodging',
  ]) {
    final nb = b[k];
    if (nb == null) continue; // 新文件没给 → 合并时保留旧的 → 不算变化
    if (jsonEncode(nb) != jsonEncode(a[k])) return true;
  }
  // avoidList 同理
  final na = neu['avoidList'];
  if (na != null && jsonEncode(na) != jsonEncode(old['avoidList'])) return true;
  return false;
}

Set<String> _namesOf(Map<String, dynamic> m) {
  final out = <String>{};
  for (final seg in ['attractions', 'foods']) {
    for (final x in (m[seg] as List?) ?? const []) {
      if (x is Map) out.add(_norm(x['name']));
    }
  }
  return out;
}

/// 合并两个库：按地点名去重，新覆盖旧，旧独有保留
Map<String, dynamic> _merge(Map<String, dynamic> old, Map<String, dynamic> neu) {
  final out = <String, dynamic>{};

  // ── region：新文件优先，但新文件缺 notices 时留旧的 ──
  final oldRegion = (old['region'] as Map?) ?? const {};
  final newRegion = (neu['region'] as Map?) ?? const {};
  final region = <String, dynamic>{...oldRegion, ...newRegion};
  if ((newRegion['notices'] as List?)?.isEmpty ?? true) {
    if (oldRegion['notices'] != null) region['notices'] = oldRegion['notices'];
  }
  out['region'] = region;

  out['_meta'] = neu['_meta'] ?? old['_meta'];
  out['_coordSystem'] = neu['_coordSystem'] ?? old['_coordSystem'] ?? 'GCJ-02';
  out['_coordNote'] = neu['_coordNote'] ??
      old['_coordNote'] ??
      '坐标为 GCJ-02（高德坐标系），与 App 地图瓦片一致。不要再转 WGS-84。';

  // ── 地点：按名字合并 ──
  for (final seg in ['attractions', 'foods']) {
    final byName = <String, Map<String, dynamic>>{};
    for (final x in (old[seg] as List?) ?? const []) {
      if (x is Map) byName[_norm(x['name'])] = Map<String, dynamic>.from(x);
    }
    for (final x in (neu[seg] as List?) ?? const []) {
      if (x is Map) {
        final k = _norm(x['name']);
        // 新条目覆盖同名旧条目，但**旧条目里已有、新条目没给的字段要保留**
        // （否则一次部分更新会把上次补好的坐标/地址抹掉）
        final prev = byName[k];
        final merged = <String, dynamic>{...?prev};
        x.forEach((key, value) {
          if (value != null) merged[key] = value;
        });
        byName[k] = merged;
      }
    }
    out[seg] = byName.values.toList();
  }

  // avoidList：新的有就用新的，否则留旧的
  if ((neu['avoidList'] as List?)?.isNotEmpty ?? false) {
    out['avoidList'] = neu['avoidList'];
  } else if (old['avoidList'] != null) {
    out['avoidList'] = old['avoidList'];
  }

  return out;
}



int _countPlaces(Map<String, dynamic> m) =>
    ((m['attractions'] as List?)?.length ?? 0) +
    ((m['foods'] as List?)?.length ?? 0);

String _norm(Object? s) =>
    (s?.toString() ?? '').replaceAll(RegExp(r'\s+'), '').trim();

void _writeAtomic(File target, Object data) {
  final tmp = File('${target.path}.tmp');
  tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  tmp.renameSync(target.path);
}
