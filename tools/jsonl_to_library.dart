// ═══════════════════════════════════════════════════════════════
// AI2 的交接数据（data.jsonl + cities.json）→ App 可直接导入的景点库 JSON
//
// 用法：
//   dart run tools/jsonl_to_library.dart <batchDir> [--out <dir>]
//
// 输入（batchDir 里）：
//   data.jsonl     必需。一行一个地点（AI2 产出）
//   cities.json    强烈建议。城市级数据（notices/transport/lodging/avoid_list）
//   manifest.json  可选。用来核对 record_count
//
// 输出（默认 <batchDir>/_converted/）：
//   <城市名>.json   每城一个，App 里「用其他应用打开」可直接导入
//   _report.json    静态校验报告（逐条错误/警告）
//   _report.md      同一份报告，给人看
//
// 退出码：0 = 无致命错误（可以导入）；1 = 有致命错误（会静默出错，必须修）
//
// ⚠️ 这个脚本只做**静态**校验。真正硬的验收在
//    `test/handoff_import_test.dart` —— 它调用 App 真正的
//    library_importer.dart 把结果导入内存数据库再断言。
//    两个都过才算合格。
// ═══════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';

// ── App 的预设标签词表（lib/ui/attraction_edit_screen.dart 的 kPresetTags）──
const Set<String> kPresetTags = {
  // 餐次
  '早餐', '午餐', '晚餐', '夜宵', '小吃',
  // 类型
  '景点', '美食', '茶饮', '甜品', '博物馆', '街区', '公园', '夜景', '拍照点',
  // 运动强度
  '运动强度低', '运动强度中', '运动强度高',
  // 其他
  '必去', '需预约', '排队久', '适合雨天', '辣',
};

/// 出现这些分类词时，推断为「吃」
const Set<String> kMealWords = {'早餐', '午餐', '晚餐', '夜宵', '小吃', '美食', '甜品', '茶饮'};

const Set<String> kConfidences = {'high', 'medium', 'low'};

// ── 校验结果 ──
class Issue {
  Issue(this.city, this.name, this.field, this.message);
  final String city;
  final String name;
  final String field;
  final String message;

  Map<String, dynamic> toJson() => {
        'city': city,
        'name': name,
        'field': field,
        'message': message,
      };
}

class CityStat {
  CityStat(this.city);
  final String city;

  /// 拼音 id（来自 city_id）。决定输出文件名 —— App 的 assets 用拼音，
  /// 因为 ASCII 文件名在任何文件系统/Gradle/资源打包里都不会出编码问题。
  String? cityId;

  int records = 0;
  int merged = 0;

  /// 被质量闸拦下的条数
  int rejected = 0;
  final List<Issue> errors = [];
  final List<Issue> warnings = [];

  /// 输出用的文件名（不含扩展名）
  String get fileName => (cityId != null && cityId!.isNotEmpty) ? cityId! : city;
}

void main(List<String> args) {
  if (args.isEmpty || args.first.startsWith('--')) {
    stderr.writeln('用法: dart run tools/jsonl_to_library.dart <batchDir> [--out <dir>]');
    exit(2);
  }

  final batchDir = Directory(args.first);
  var outDir = Directory('${batchDir.path}/_converted');
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--out') outDir = Directory(args[i + 1]);
  }

  if (!batchDir.existsSync()) {
    stderr.writeln('✗ 批次目录不存在: ${batchDir.path}');
    exit(2);
  }

  // ── 读输入 ──
  final dataFile = File('${batchDir.path}/data.jsonl');
  if (!dataFile.existsSync()) {
    stderr.writeln('✗ 缺少 data.jsonl: ${dataFile.path}');
    exit(2);
  }

  final rawRecords = _readJsonl(dataFile);
  final cities = _readCities(File('${batchDir.path}/cities.json'));
  final manifest = _readJson(File('${batchDir.path}/manifest.json'));

  // ── 分组 + 校验 ──
  final byCity = <String, List<Map<String, dynamic>>>{};
  final stats = <String, CityStat>{};
  final globalErrors = <Issue>[];

  for (final r in rawRecords) {
    final city = (r.data['city'] as String?)?.trim() ?? '';
    if (city.isEmpty) {
      globalErrors.add(Issue('(未知城市)', (r.data['name'] as String?) ?? '(无名)', 'city',
          '第 ${r.line} 行缺 city 字段'));
      continue;
    }
    byCity.putIfAbsent(city, () => []).add(r.data);
  }

  // manifest 核对
  if (manifest != null) {
    final declared = (manifest['record_count'] as num?)?.toInt();
    if (declared != null && declared != rawRecords.length) {
      globalErrors.add(Issue('(批次)', '(清单)', 'record_count',
          'manifest 声明 $declared 条，data.jsonl 实际 ${rawRecords.length} 条'));
    }
  }

  // ⚠️ outDir 必须在循环**之前**创建。
  //    如果批次里一个城市都没有（例如纯 notices 更新），循环不跑，
  //    写报告时就会因为目录不存在抛 PathNotFoundException —— 那不是「没数据」，是崩。
  outDir.createSync(recursive: true);

  // 要处理的城市 = **有地点记录的城市 ∪ cities.json 里出现的城市**。
  //
  // ⚠️⚠️ 为什么必须取并集（我在这里犯过一次「静默丢弃」）：
  //    纯 notices 更新（B 阶段只补「注意事项」、不带新地点）在 data.jsonl 里
  //    **没有该城市的任何记录**。若只遍历 byCity，这些城市的 notices 会被
  //    **静默丢掉** —— 上游做了工作，下游无声丢弃，双方都不会发现。
  //    实测复现过：只有 cities.json 的批次，产出目录是空的、notices 全丢。
  final allCities = <String>{...byCity.keys, ...cities.keys}.toList()..sort();

  for (final city in allCities) {
    final records = byCity[city] ?? const <Map<String, dynamic>>[];
    final stat = CityStat(city);
    stats[city] = stat;

    if (records.isEmpty) {
      stat.warnings.add(Issue(city, '(城市)', 'data.jsonl',
          '这个城市在 data.jsonl 里没有地点记录，只更新了城市级数据（notices 等）'));
    }

    final cityMeta = cities[city];
    if (cities.isNotEmpty && cityMeta == null) {
      stat.warnings.add(Issue(city, '(城市)', 'cities.json', 'cities.json 里没有这个城市的数据'));
    }

    // city_id：优先取 cities.json，其次取任意一条记录的
    final idFromMeta = cityMeta?['city_id']?.toString();
    final idFromRec = records
        .map((r) => r['city_id']?.toString())
        .firstWhere((x) => x != null && x.isNotEmpty, orElse: () => null);
    stat.cityId = (idFromMeta != null && idFromMeta.isNotEmpty)
        ? idFromMeta
        : idFromRec;
    if (stat.cityId == null || stat.cityId!.isEmpty) {
      stat.warnings.add(Issue(city, '(城市)', 'city_id',
          '没有 city_id：输出文件名只能用中文（建议补上，App 的 assets 用拼音更稳）'));
    }
    if (cityMeta != null) {
      final notices = (cityMeta['notices'] as List?) ?? const [];
      if (notices.length < 4) {
        stat.warnings.add(Issue(city, '(城市)', 'notices',
            'notices 只有 ${notices.length} 条，建议 4~8 条（这是用户最常看的内容）'));
      }
    }

    // 逐条校验
    final kept = <Map<String, dynamic>>[];
    final seen = <String, Map<String, dynamic>>{}; // 归一化名 → 保留的记录

    for (final r in records) {
      final name = (r['name'] as String?)?.trim() ?? '';
      if (name.isEmpty) {
        stat.errors.add(Issue(city, '(无名)', 'name', 'name 为空会被 App 静默跳过'));
        continue;
      }

      // 质量闸：明显不是旅行地点的直接拦下。
      // 必须在合并进 assets 之前拦 —— 我的合并器和 App 的导入器都是
      // 「按名更新、不删」，垃圾一旦进库就永久留下（见 _qualityReject 的说明）。
      final reject = _qualityReject(city, r);
      if (reject != null) {
        qualityRejects.add({'city': city, 'name': name, 'reason': reject});
        stat.rejected++;
        continue;
      }

      _validateRecord(city, name, r, stat);

      // 去重：同名（归一化）保留字段更全的那条
      final key = _normName(name);
      final prev = seen[key];
      if (prev != null) {
        stat.merged++;
        final better = _filledCount(r) > _filledCount(prev) ? r : prev;
        kept.removeWhere((x) => _normName((x['name'] as String? ?? '')) == key);
        kept.add(better);
        seen[key] = better;
        stat.warnings.add(Issue(city, name, 'name',
            '同名重复，已合并（保留字段更全的一条）'));
        continue;
      }
      seen[key] = r;
      kept.add(r);
    }

    stat.records = kept.length;

    // ── 组装 App 库格式 ──
    final attrs = <Map<String, dynamic>>[];
    final foods = <Map<String, dynamic>>[];
    for (final r in kept) {
      final kind = _kindOf(r);
      if (kind == 'eat') {
        foods.add(_toFood(r));
      } else {
        attrs.add(_toAttraction(r));
      }
    }

    final out = <String, dynamic>{
      '_meta': {
        'app': 'travel_planner',
        'exportType': 'candidate_library',
        'formatVersion': 1,
        'generatedAt': _today(),
        'generatedBy': 'tools/jsonl_to_library.dart（由 AI2 的 handoff 数据生成）',
        'sourceBatch': batchDir.path.split(RegExp(r'[\\/]')).last,
      },
      'region': {
        'name': city,
        if (cityMeta?['province'] != null) 'province': cityMeta!['province'],
        'country': '中国',
        if (cityMeta?['note'] != null) 'note': cityMeta!['note'],
        if (cityMeta?['transport'] != null) 'transport': cityMeta!['transport'],
        if (cityMeta?['lodging'] != null) 'lodging': cityMeta!['lodging'],
        if (cityMeta?['notices'] != null) 'notices': cityMeta!['notices'],
      },
      'attractions': attrs,
      'foods': foods,
      if (cityMeta?['avoid_list'] != null) 'avoidList': cityMeta!['avoid_list'],
      '_coordSystem': 'GCJ-02',
      '_coordNote': '坐标为 GCJ-02（高德坐标系），与 App 地图瓦片一致。不要再转 WGS-84。',
    };

    outDir.createSync(recursive: true);
    // 文件名用 city_id（拼音）——与 App 的 assets/library/ 命名一致
    _writeJsonAtomic(File('${outDir.path}/${stat.fileName}.json'), out);
  }

  // ── 报告 ──
  final totalErrors = globalErrors.length +
      stats.values.fold<int>(0, (s, x) => s + x.errors.length);
  final totalWarnings = stats.values.fold<int>(0, (s, x) => s + x.warnings.length);

  final report = <String, dynamic>{
    'batch': batchDir.path.split(RegExp(r'[\\/]')).last,
    'generated_at': DateTime.now().toIso8601String(),
    'summary': {
      'cities': stats.length,
      'records_in': rawRecords.length,
      'records_out': stats.values.fold<int>(0, (s, x) => s + x.records),
      'duplicates_merged': stats.values.fold<int>(0, (s, x) => s + x.merged),
      'quality_rejected': stats.values.fold<int>(0, (s, x) => s + x.rejected),
      'errors': totalErrors,
      'warnings': totalWarnings,
    },
    'verdict': totalErrors == 0 ? 'pass' : 'fail',
    'global_errors': globalErrors.map((e) => e.toJson()).toList(),
    'quality_rejected': qualityRejects,
    'cities': [
      for (final s in stats.values)
        {
          'city': s.city,
          'records': s.records,
          'merged': s.merged,
          'errors': s.errors.map((e) => e.toJson()).toList(),
          'warnings': s.warnings.map((e) => e.toJson()).toList(),
        }
    ],
  };

  _writeJsonAtomic(File('${outDir.path}/_report.json'), report);
  File('${outDir.path}/_report.md').writeAsStringSync(_renderMarkdown(report));

  // ── 控制台摘要 ──
  stdout.writeln('批次: ${report['batch']}');
  stdout.writeln('城市 ${report['summary']['cities']} 个 · '
      '录入 ${report['summary']['records_in']} 条 · '
      '输出 ${report['summary']['records_out']} 条 · '
      '合并重复 ${report['summary']['duplicates_merged']} 条');
  final rejected = stats.values.fold<int>(0, (s, x) => s + x.rejected);
  stdout.writeln('错误 $totalErrors · 警告 $totalWarnings'
      '${rejected > 0 ? ' · 质量闸拦下 $rejected 条（见报告）' : ''}');
  stdout.writeln('判定: ${report['verdict'] == 'pass' ? '✓ 可以导入' : '✗ 有致命错误，必须修'}');
  stdout.writeln('输出目录: ${outDir.path}');

  if (totalErrors > 0) {
    stdout.writeln('\n── 致命错误（前 25 条）──');
    for (final e in [...globalErrors, ...stats.values.expand((s) => s.errors)].take(25)) {
      stdout.writeln('  ✗ [${e.city}] ${e.name} · ${e.field}: ${e.message}');
    }
  }

  exit(totalErrors == 0 ? 0 : 1);
}

// ══════════════════════════════════════════════════════════════
// 质量闸（低价值条目过滤）
//
// ⚠️ 为什么必须在**合并进 assets 之前**拦：
//    我的合并安装器和 App 的导入器都是「按名更新、**不删**」——
//    一条垃圾数据一旦进库，后续批次里没有它也不会被删掉，**永久留在用户面前**。
//    所以这里是把关的唯一时机。
//
// 只拦「明显不是旅行地点」的，宁可漏拦不可错杀：
//   1. 通用全国连锁（旅行资料库里是噪声）
//   2. 名字是宣传语/文本碎片（"中国最美乡村""随便走走很美很松"）
//   3. 名字带城市名前缀（"泰安市泰山" —— 高德 POI 的冗余命名）
// 被拦下的会列进报告，AI2 可以申诉/修正。
// ══════════════════════════════════════════════════════════════

/// 全国连锁：旅行资料库里没有价值（本地特色店才是）
const List<String> _chainKeywords = [
  '兰州拉面', '沙县小吃', '华莱士', '肯德基', '麦当劳', '德克士', '汉堡王',
  '正新鸡排', '黄焖鸡', '张亮麻辣烫', '杨国福', '绝味鸭脖', '巴比馒头',
  '真功夫', '永和豆浆', '蜜雪冰城', 'coco', 'coco都可', '一点点', '益禾堂',
  '书亦烧仙草', '茶百道', '古茗', '沪上阿姨', '甜啦啦', '瑞幸', '星巴克',
  '全家便利店', '罗森', '美宜佳', '7-11', '红旗连锁',
];

/// 名字里出现这些词 → 是宣传语/文本碎片，不是地点名
///
/// ⚠️ 选词标准：**它作为店名一部分出现的概率要极低**。
///    我在这条规则上误杀过两次，都是因为词太常见：
///      · 单字「巨」 → 会命中「巨鹿路」
///      · 「超级」  → 命中真实店铺「蒙物超级工厂」（呼和浩特）
///    所以：不用单字、不用常见组合词。宁可漏拦（下游还有别的检查），
///    不可错杀（一个真实地点被丢掉，用户是看不见的）。
const List<String> _sloganMarkers = [
  '最美', '很美', '超美', '太美', '很松', '攻略', '必去', '必吃',
  '值得', '好玩', '打卡', '出片', '太绝', 'yyds', '哇塞',
];

/// 看起来像「地点」的后缀（有这些字就不太可能是宣传语）
const String _placeSuffix =
    '店馆楼园寺山街路村镇桥塔宫院场城湖湾岛泉洞谷峰岭关门坊铺摊行号'
    '港站口巷弄里塘庄寨寺祠庙堂阁亭台厦苑圃榭';

/// 去掉括号里的附加说明，得到「核心店名」。
///
/// ⚠️ 必须先去括号再判长度：`小平夫妻（蛋黄肉粽/皮蛋肉粽）` 一共 16 字，
///    但核心就是「小平夫妻」4 字，是一家**真实存在的南昌小吃店**。
///    我第一版没去括号，把它当成「像句子」误杀了。
String _coreName(String name) =>
    name.replaceAll(RegExp(r'[（(][^）)]*[）)]'), '').trim();

/// 返回 null 表示通过；否则返回拦下的理由
String? _qualityReject(String city, Map<String, dynamic> r) {
  final name = (r['name'] as String? ?? '').trim();
  if (name.isEmpty) return null; // 空名由别处处理

  final lower = name.toLowerCase();

  // 1. 通用连锁
  for (final k in _chainKeywords) {
    if (lower.contains(k.toLowerCase())) return '通用全国连锁（旅行资料库里是噪声）：$name';
  }

  // 2. 宣传语/文本碎片
  for (final m in _sloganMarkers) {
    if (name.contains(m)) return '名字像宣传语/文本碎片，不是地点名：$name';
  }

  // 3. 名字带城市名前缀且过长（"泰安市泰山"）
  if (name.startsWith(city) && name.length > city.length && name.length > 4) {
    // 但要放过合理的（如「北京烤鸭」是菜名、「北京路」是路名）
    final rest = name.substring(city.length);
    final looksLikeGeneric =
        rest.length <= 3 && !rest.contains(RegExp('[$_placeSuffix]'));
    if (looksLikeGeneric) return '名字重复了城市名、像高德 POI 冗余命名：$name';
  }

  // 4. 核心名过长且没有任何地点后缀 → 极可能是句子
  //    用核心名（去括号）判断，阈值放到 14 字，宁可漏拦不可错杀
  final core = _coreName(name);
  if (core.length > 14 && !core.contains(RegExp('[$_placeSuffix]'))) {
    return '核心名过长且不含地点后缀，像句子：$name';
  }

  return null;
}

/// 命中的过滤规则 → 被拦下的条目（进报告，供 AI2 申诉）
final List<Map<String, String>> qualityRejects = [];

// ══════════════════════════════════════════════════════════════
// 校验
// ══════════════════════════════════════════════════════════════

/// 逐条校验。**这里每一条都对应一个真实的「会静默出错」的场景**。
void _validateRecord(String city, String name, Map<String, dynamic> r, CityStat stat) {
  void err(String f, String m) => stat.errors.add(Issue(city, name, f, m));
  void warn(String f, String m) => stat.warnings.add(Issue(city, name, f, m));

  // ── 门票：最阴的一个 ──
  final ticket = r['ticket_yuan'];
  if (ticket is String) {
    err('ticket_yuan',
        '是字符串「$ticket」。App 解析失败会当成 0 → 界面显示「免费」= 编造。请用数字或 null');
  } else if (ticket is! num && ticket != null) {
    err('ticket_yuan', '类型不对（${ticket.runtimeType}），必须是数字或 null');
  }

  // ── 建议时长：必须是整数 ──
  final dur = r['suggested_duration'];
  if (dur != null) {
    if (dur is! int) {
      err('suggested_duration',
          '是 ${dur.runtimeType}（$dur）。App 只认整数分钟，写 150.0 会被忽略');
    } else if (dur <= 0 || dur > 24 * 60) {
      err('suggested_duration', '数值不合理：$dur 分钟');
    }
  }

  // ── 推荐等级：1~5 的整数 ──
  final lv = r['recommend_level'];
  if (lv != null && (lv is! int || lv < 1 || lv > 5)) {
    err('recommend_level', '必须是 1~5 的整数，实际是 $lv');
  }

  // ── 坐标 ──
  final lat = r['lat'], lng = r['lng'];
  if ((lat == null) != (lng == null)) {
    err('lat/lng', '只给了一个（lat=$lat lng=$lng），必须成对或都留空');
  } else if (lat != null && lng != null) {
    if (lat is! num || lng is! num) {
      err('lat/lng', '必须是数字（lat=${lat.runtimeType} lng=${lng.runtimeType}）');
    } else {
      if (lat == 0 || lng == 0) {
        err('lat/lng', '0 是无效坐标（几内亚湾），App 会当没坐标。留空即可');
      }
      if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
        err('lat/lng', '超出经纬度范围：$lat, $lng');
      }
    }
  }

  // ── confidence ──
  final conf = r['confidence'];
  if (conf != null && (conf is! String || !kConfidences.contains(conf))) {
    warn('confidence', '只认 high/medium/low，实际是「$conf」');
  }
  if (conf == null) warn('confidence', '没给 confidence');

  // ── kind ──
  final kind = r['kind'];
  if (kind != null && kind != 'play' && kind != 'eat') {
    err('kind', '只能是 play/eat，实际是「$kind」');
  }

  // ── tags ──
  final tags = r['tags'];
  if (tags == null || (tags is List && tags.isEmpty)) {
    warn('tags', '没有标签：不参与筛选，也不会被时段智能匹配');
  } else if (tags is! List) {
    err('tags', '必须是数组，实际是 ${tags.runtimeType}');
  } else {
    for (final t in tags) {
      if (t is! String) {
        err('tags', '有非字符串元素：$t');
      } else if (!kPresetTags.contains(t)) {
        warn('tags', '「$t」不在 App 预设词表里（能导入，但不参与筛选/智能匹配）');
      }
    }
  }

  // ── 其它建议字段 ──
  if ((r['address'] as String?)?.trim().isEmpty ?? true) {
    warn('address', '没有地址：App 里看不到地址，也没法导航');
  }
  final srcs = r['source_urls'];
  if (srcs == null || (srcs is List && srcs.isEmpty)) {
    warn('source_urls', '没有来源链接：无法溯源核实');
  } else if (srcs is! List) {
    err('source_urls', '必须是数组');
  }
  final warns = r['warnings'];
  if (warns == null || (warns is List && warns.isEmpty)) {
    warn('warnings', '没有 warnings：营业时间/预约/闭馆这些「去了才发现」的坑是最值钱的信息');
  } else if (warns is! List) {
    err('warnings', '必须是数组');
  }
  if ((r['category'] as String?)?.trim().isEmpty ?? true) {
    warn('category', '没有 category');
  }
}

// ══════════════════════════════════════════════════════════════
// 字段映射（AI2 的字段 → App 的字段名）
// ══════════════════════════════════════════════════════════════

bool _isEat(Map<String, dynamic> r) {
  final k = r['kind'];
  if (k == 'eat') return true;
  if (k == 'play') return false;
  // 没给 kind 就按分类词推断
  final cat = (r['category'] as String?) ?? '';
  if (kMealWords.contains(cat)) return true;
  final tags = (r['tags'] as List?) ?? const [];
  return tags.any((t) => kMealWords.contains(t));
}

String _kindOf(Map<String, dynamic> r) => _isEat(r) ? 'eat' : 'play';

/// 两边共有的字段
Map<String, dynamic> _common(Map<String, dynamic> r) {
  final tips = <String>[];
  for (final t in (r['tips'] as List?) ?? const []) {
    if (t is String && t.trim().isNotEmpty) tips.add(t.trim());
  }
  // 最佳季节对用户有用，塞进 tips 里显示
  final season = (r['best_season'] as String?)?.trim();
  if (season != null && season.isNotEmpty) tips.add('最佳季节：$season');

  return {
    'name': (r['name'] as String).trim(),
    if (r['category'] != null) 'category': r['category'],
    // 顶层 address —— 必须是顶层，App 只读这里（惠州 38 条栽在这）
    if (r['address'] != null) 'address': r['address'],
    if (r['district'] != null) 'district': r['district'],
    if (r['lat'] != null) 'lat': r['lat'],
    if (r['lng'] != null) 'lng': r['lng'],
    if (r['description'] != null) 'highlight': r['description'],
    if (r['opening_hours'] != null) 'openTime': r['opening_hours'],
    if (r['suggested_duration'] != null) 'suggestDurationMin': r['suggested_duration'],
    if (r['recommend_level'] != null) 'recommendLevel': r['recommend_level'],
    if (r['transport'] != null) 'metro': r['transport'],
    if (r['confidence'] != null) 'confidence': r['confidence'],
    if (r['collected_at'] != null) 'verified': r['collected_at'],
    if (tips.isNotEmpty) 'tips': tips,
    if ((r['warnings'] as List?)?.isNotEmpty ?? false) 'warnings': r['warnings'],
    if ((r['source_urls'] as List?)?.isNotEmpty ?? false) 'sources': r['source_urls'],
    // 标签：tags 就是 App 的 placeTags
    if ((r['tags'] as List?)?.isNotEmpty ?? false) 'placeTags': r['tags'],
    // 以下 App 不读，留作溯源（导入器会忽略未知字段）
    if (r['aliases'] != null) 'aliases': r['aliases'],
    if (r['city_id'] != null) 'cityId': r['city_id'],
    if (r['source_name'] != null) 'sourceName': r['source_name'],
    if ((r['images'] as List?)?.isNotEmpty ?? false) 'images': r['images'],
    // missing_fields 是**给我们自己看的账**（哪些城市补得不够），不进用户界面：
    // 用户不需要知道「这个字段我们没查到」，他只需要看到「没写价格」这个事实。
    // 原样带过去，便于日后统计。
    if ((r['missing_fields'] as List?)?.isNotEmpty ?? false)
      'missingFields': r['missing_fields'],
    if (r['raw'] != null) 'raw': r['raw'],
  };
}

Map<String, dynamic> _toAttraction(Map<String, dynamic> r) {
  final out = _common(r);
  if (r['ticket_yuan'] != null) out['ticketYuan'] = r['ticket_yuan'];
  if (r['ticket_note'] != null) out['ticketNote'] = r['ticket_note'];
  return out;
}

Map<String, dynamic> _toFood(Map<String, dynamic> r) {
  final out = _common(r);
  // 美食：eat（吃什么）+ priceYuan（字符串价格）
  if ((r['eat'] as List?)?.isNotEmpty ?? false) out['eat'] = r['eat'];
  if (r['price_yuan'] != null) out['priceYuan'] = r['price_yuan'];
  // 有些源会把价格写在 ticket_yuan（数字）里，兜一下
  if (out['priceYuan'] == null && r['ticket_yuan'] is num) {
    final v = r['ticket_yuan'] as num;
    out['priceYuan'] = v == 0 ? '免费' : '人均 $v 元';
  }
  return out;
}

// ══════════════════════════════════════════════════════════════
// 工具
// ══════════════════════════════════════════════════════════════

String _normName(String s) => s.replaceAll(RegExp(r'\s+'), '').trim();

int _filledCount(Map<String, dynamic> r) =>
    r.entries.where((e) => e.value != null).length;

String _today() {
  final d = DateTime.now();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _Raw {
  _Raw(this.line, this.data);
  final int line;
  final Map<String, dynamic> data;
}

List<_Raw> _readJsonl(File f) {
  final out = <_Raw>[];
  final lines = f.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trim();
    if (t.isEmpty) continue;
    try {
      final v = jsonDecode(t);
      if (v is Map<String, dynamic>) {
        out.add(_Raw(i + 1, v));
      } else {
        stderr.writeln('⚠ 第 ${i + 1} 行不是 JSON 对象，已跳过');
      }
    } catch (e) {
      stderr.writeln('⚠ 第 ${i + 1} 行 JSON 解析失败，已跳过：$e');
    }
  }
  return out;
}

Map<String, dynamic>? _readJson(File f) {
  if (!f.existsSync()) return null;
  try {
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// cities.json → {城市名: 城市对象}
Map<String, Map<String, dynamic>> _readCities(File f) {
  final m = _readJson(f);
  if (m == null) return {};
  final list = m['cities'];
  if (list is! List) return {};
  final out = <String, Map<String, dynamic>>{};
  for (final c in list) {
    if (c is Map<String, dynamic>) {
      final name = (c['city'] as String?)?.trim();
      if (name != null && name.isNotEmpty) out[name] = c;
    }
  }
  return out;
}

/// 原子写：先 .tmp 再 rename（协议要求，防止对方读到半截文件）
void _writeJsonAtomic(File target, Object data) {
  final tmp = File('${target.path}.tmp');
  tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  tmp.renameSync(target.path);
}

String _renderMarkdown(Map<String, dynamic> report) {
  final b = StringBuffer();
  final s = report['summary'] as Map;
  b.writeln('# 交接数据静态校验报告');
  b.writeln();
  b.writeln('- 批次: `${report['batch']}`');
  b.writeln('- 生成: ${report['generated_at']}');
  b.writeln('- 判定: **${report['verdict'] == 'pass' ? '✓ 通过' : '✗ 不通过'}**');
  b.writeln();
  b.writeln('| 城市 | 条数 | 合并重复 | 错误 | 警告 |');
  b.writeln('|---|---|---|---|---|');
  for (final c in (report['cities'] as List)) {
    b.writeln('| ${c['city']} | ${c['records']} | ${c['merged']} | '
        '${(c['errors'] as List).length} | ${(c['warnings'] as List).length} |');
  }
  b.writeln();
  b.writeln('合计：录入 ${s['records_in']} 条 → 输出 ${s['records_out']} 条，'
      '错误 ${s['errors']}，警告 ${s['warnings']}');
  b.writeln();

  void section(String title, List items) {
    if (items.isEmpty) return;
    b.writeln('## $title');
    b.writeln();
    for (final x in items) {
      b.writeln('- `[${x['city']}] ${x['name']}` · **${x['field']}** — ${x['message']}');
    }
    b.writeln();
  }

  final rejects = (report['quality_rejected'] as List?) ?? const [];
  if (rejects.isNotEmpty) {
    b.writeln('## 质量闸拦下的条目（${rejects.length} 条，**已从输出中剔除**）');
    b.writeln();
    b.writeln('> 这些不是格式错误，是「明显不是旅行地点」（通用连锁 / 宣传语 / 高德冗余命名）。');
    b.writeln('> **必须在合并进 assets 前拦**：合并器与 App 导入器都是「按名更新、不删」，');
    b.writeln('> 垃圾一旦进库就永久留下。若你认为某条该保留，回消息说明，我改规则重跑。');
    b.writeln();
    for (final x in rejects) {
      b.writeln('- `[${x['city']}] ${x['name']}` — ${x['reason']}');
    }
    b.writeln();
  }

  section('致命错误（必须修，否则 App 会静默出错）', report['global_errors'] as List);
  for (final c in (report['cities'] as List)) {
    section('【${c['city']}】致命错误', c['errors'] as List);
  }
  for (final c in (report['cities'] as List)) {
    section('【${c['city']}】警告', c['warnings'] as List);
  }
  return b.toString();
}
