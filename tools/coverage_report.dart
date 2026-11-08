// ═══════════════════════════════════════════════════════════════
// 景点库覆盖度报告
//
// 用法：dart run tools/coverage_report.dart [--md <输出路径>]
//
// 用途：收工验收要回答两个问题——
//   1. 51 个目标城市是不是**每个都有数据**？（还缺哪些）
//   2. 每个城市的库够不够用？（多少地点、多少有坐标、notices 够不够）
//
// 只读 assets/library/，不改任何东西。
// ═══════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';

/// 51 个目标城市（权威 id，与 _ai_collab 里发给 AI2 的表一致）
const Map<String, String> kTargetCities = {
  'beijing': '北京', 'shanghai': '上海', 'chengdu': '成都', 'chongqing': '重庆',
  'guangzhou': '广州', 'hangzhou': '杭州', 'xian': '西安', 'nanjing': '南京',
  'wuhan': '武汉', 'changsha': '长沙', 'shenzhen': '深圳', 'qingdao': '青岛',
  'xiamen': '厦门', 'kunming': '昆明', 'haerbin': '哈尔滨', 'suzhou': '苏州',
  'luoyang': '洛阳', 'zhengzhou': '郑州', 'tianjin': '天津', 'haikou': '海口',
  'sanya': '三亚', 'guilin': '桂林', 'zhangjiajie': '张家界',
  'xishuangbanna': '西双版纳', 'dali': '大理', 'jingdezhen': '景德镇',
  'shangrao': '上饶', 'dunhuang': '敦煌', 'lanzhou': '兰州',
  'huhehaote': '呼和浩特', 'wulumuqi': '乌鲁木齐', 'lasa': '拉萨',
  'guiyang': '贵阳', 'nanning': '南宁', 'fuzhou': '福州', 'dalian': '大连',
  'shenyang': '沈阳', 'changchun': '长春', 'qinhuangdao': '秦皇岛',
  'kaifeng': '开封', 'xuzhou': '徐州', 'huzhou': '湖州', 'huangshan': '黄山',
  'taian': '泰安', 'datong': '大同', 'handan': '邯郸', 'weihai': '威海',
  'zhuhai': '珠海', 'shantou': '汕头', 'quanzhou': '泉州', 'wenzhou': '温州',
};

/// 已内置、不在 51 城目标里的（早期就有的）
const List<String> kExtraCities = ['nanchang', 'huizhou'];

class CityCoverage {
  String id = '';
  String name = '';
  int places = 0;
  int withCoord = 0;
  int notices = 0;
  int withWarnings = 0;
  int withAddress = 0;
  int withSources = 0;
  List<String> issues = [];
}

void main(List<String> args) {
  final dir = Directory('assets/library');
  if (!dir.existsSync()) {
    stderr.writeln('✗ 找不到 assets/library（要在工程根目录跑）');
    exit(2);
  }

  final rows = <CityCoverage>[];
  final present = <String>{};

  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.json')) continue;
    final id = f.uri.pathSegments.last.replaceAll('.json', '');
    present.add(id);

    final CityCoverage c = CityCoverage()..id = id;
    try {
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final region = (m['region'] as Map?) ?? const {};
      c.name = (region['name'] ?? id).toString();
      final items = [
        ...(m['attractions'] as List? ?? const []),
        ...(m['foods'] as List? ?? const []),
      ];
      c.places = items.length;
      c.notices = ((region['notices'] as List?) ?? const []).length;
      for (final x in items) {
        if (x is! Map) continue;
        if (x['lat'] != null && x['lng'] != null) c.withCoord++;
        if ((x['warnings'] as List?)?.isNotEmpty ?? false) c.withWarnings++;
        if ((x['address'] as String?)?.isNotEmpty ?? false) c.withAddress++;
        if ((x['sources'] as List?)?.isNotEmpty ?? false) c.withSources++;
      }
    } catch (e) {
      c.issues.add('JSON 解析失败：$e');
    }

    // 质量提示（不是硬错误，但值得知道）
    if (c.places < 10) c.issues.add('地点只有 ${c.places} 个，偏少');
    if (c.notices < 4) c.issues.add('notices 只有 ${c.notices} 条（建议 4~8）');
    if (c.places > 0 && c.withCoord < c.places) {
      c.issues.add('${c.places - c.withCoord} 个地点没有坐标');
    }
    if (c.places > 0 && c.withWarnings < c.places ~/ 4) {
      c.issues.add('只有 ${c.withWarnings}/${c.places} 条有 warnings（避坑信息偏少）');
    }
    // 坐标覆盖为 0 单独标出来：一整座城一个坐标都没有，通常是
    // **地理编码那一步整段没跑**（而不是「都查不到」）——这是流水线 bug，值得单独报
    if (c.places > 0 && c.withCoord == 0) {
      c.issues.add('⚠️ 整城 0 个坐标 —— 像是地理编码没跑，而不是查不到');
    }
    rows.add(c);
  }

  rows.sort((a, b) => a.id.compareTo(b.id));

  final missing = kTargetCities.keys.where((id) => !present.contains(id)).toList();
  final totalPlaces = rows.fold<int>(0, (s, c) => s + c.places);
  final totalNotices = rows.fold<int>(0, (s, c) => s + c.notices);

  // ── 控制台 ──
  stdout.writeln('═══ 景点库覆盖度 ═══');
  stdout.writeln('目标 ${kTargetCities.length} 城 · 已内置 ${present.length} 个库 · '
      '地点合计 $totalPlaces · notices 合计 $totalNotices');
  if (missing.isEmpty) {
    stdout.writeln('✓ 51 城全部有数据');
  } else {
    stdout.writeln('✗ 还缺 ${missing.length} 城：'
        '${missing.map((id) => '${kTargetCities[id]}($id)').join('、')}');
  }
  final withIssues = rows.where((c) => c.issues.isNotEmpty).toList();
  if (withIssues.isNotEmpty) {
    stdout.writeln('⚠️ ${withIssues.length} 个库有质量提示：');
    for (final c in withIssues) {
      stdout.writeln('  ${c.name}(${c.id}): ${c.issues.join('；')}');
    }
  }

  // ── Markdown（给最终报告引用）──
  final mdIndex = args.indexOf('--md');
  if (mdIndex >= 0 && mdIndex + 1 < args.length) {
    final b = StringBuffer();
    b.writeln('# 景点库覆盖度报告');
    b.writeln();
    b.writeln('生成: ${DateTime.now().toIso8601String()}');
    b.writeln();
    b.writeln('- 目标城市：**${kTargetCities.length}**');
    b.writeln('- 已内置库：**${present.length}**（含早期已有的 ${kExtraCities.join('、')}）');
    b.writeln('- 地点合计：**$totalPlaces**');
    b.writeln('- notices 合计：**$totalNotices**');
    b.writeln('- 缺失城市：**${missing.isEmpty ? '无' : missing.map((id) => kTargetCities[id]).join('、')}**');
    b.writeln();
    b.writeln('| 城市 | id | 地点 | 有坐标 | notices | 有warnings | 有地址 |');
    b.writeln('|---|---|---|---|---|---|---|');
    for (final c in rows) {
      b.writeln('| ${c.name} | `${c.id}` | ${c.places} | ${c.withCoord} | '
          '${c.notices} | ${c.withWarnings} | ${c.withAddress} |');
    }
    if (withIssues.isNotEmpty) {
      b.writeln();
      b.writeln('## 质量提示');
      b.writeln();
      for (final c in withIssues) {
        b.writeln('- **${c.name}**（`${c.id}`）：${c.issues.join('；')}');
      }
    }
    final out = File(args[mdIndex + 1]);
    out.parent.createSync(recursive: true);
    final tmp = File('${out.path}.tmp');
    tmp.writeAsStringSync(b.toString());
    tmp.renameSync(out.path);
    stdout.writeln('报告已写: ${out.path}');
  }
}
