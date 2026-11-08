// ═══════════════════════════════════════════════════════════════
// 给候选库打多标签
//
// 用法：dart run tools/tag_library.dart <候选库.json>
//
// 标签分四组（与 App 的 kPresetTags 对齐）：
//   餐次：早餐 / 午餐 / 晚餐 / 夜宵 / 小吃
//   类型：景点 / 美食 / 茶饮 / 甜品 / 博物馆 / 街区 / 公园 / 夜景 / 拍照点
//   运动强度：低 / 中 / 高
//   其他：必去 / 需预约 / 排队久 / 适合雨天 / 辣
//
// ⚠️ 分类靠关键词匹配，不是万能的。跑完会列出每个地点的标签，
//    人工扫一眼有问题的再改。
// ═══════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';

/// 关键词 → 标签。命中即打。
///
/// ⚠️ 教训：**关键词不要用单字**。
///    第一版写了「汤」「茶」「饼」这种单字，结果：
///      · 小罗子汤店 → 被打上「甜品」（因为「汤」命中）
///      · 杨大娘粽子 → 被打上「地标」（地址里的「八一馆站」命中「八一」）
///    单字误命中率极高，全部改成长度 ≥2 的词组。
///    另外**不要在地址里匹配**——地址是定位信息，不是内容描述。
const List<({String tag, List<String> keywords})> _rules = [
  // ── 餐次 ──
  (tag: '早餐', keywords: ['早餐', '拌粉', '汤店', '早市', '瓦罐汤', '早点']),
  (tag: '午餐', keywords: ['午餐', '午饭']),
  (tag: '晚餐', keywords: ['晚餐', '晚饭']),
  (tag: '夜宵', keywords: ['夜宵', '烧烤', '宵夜']),

  // ── 类型 ──
  (tag: '茶饮', keywords: ['奶茶', '茶饮', '饮品']),
  (tag: '茶馆', keywords: ['茶馆']),
  (
    tag: '甜品',
    keywords: ['甜品', '糕点', '绿豆饼', '汉堡', '冰沙', '冰淇淋']
  ),
  (tag: '水煮', keywords: ['水煮', '油炸']),
  (
    tag: '小吃',
    keywords: ['小吃', '粽子', '烧饼', '臭豆腐', '糊羹', '米饼', '发糕']
  ),

  (tag: '博物馆', keywords: ['博物馆', '纪念馆', '美术馆']),
  // ⚠️ 不要用「美食街」做关键词：
  //    「大士院早市」的备注里写了「大士院美食街」，会被误标成街区。
  //    它其实是早市，不是街区。只认明确的街区名。
  (tag: '街区', keywords: ['历史文化街区', '步行街', '老街区']),
  (tag: '公园', keywords: ['公园', '风景区']),
  (tag: '广场', keywords: ['广场']),
  (tag: '夜景', keywords: ['夜景', '喷泉', '摩天轮', '灯光秀']),
  (tag: '拍照点', keywords: ['拍照', '机位', '打卡']),
  (tag: '地标', keywords: ['滕王阁', '省级博物馆']),

  // ── 运动强度 ──
  (
    tag: '运动强度高',
    keywords: ['滕王阁', '摩天轮', '风景区', '景区', '步道', '登山', '机位']
  ),
  (tag: '运动强度低', keywords: ['早市', '茶馆', '奶茶', '茶饮', '甜品']),

  // ── 其他 ──
  (tag: '需预约', keywords: ['预约', '闭馆', '周一闭馆']),
  (tag: '排队久', keywords: ['排队', '网红']),
  (tag: '辣', keywords: ['辣', '水煮', '烧烤']),
  (tag: '适合雨天', keywords: ['博物馆', '纪念馆', '美术馆', '茶馆']),
];

/// 是不是吃的。
///
/// 不看 category（很多条目没填），而是看数据本身的特征：
///   · 在 foods 段里的 → 一定是吃的
///   · 有 eat 字段（吃什么）→ 一定是吃的
///   · category 里带餐饮类词 → 是吃的
bool _isFood(Map node, bool inFoodsSection) {
  if (inFoodsSection) return true;
  if (node['eat'] is List && (node['eat'] as List).isNotEmpty) return true;
  if (node['priceYuan'] != null) return true;

  final cat = (node['category'] as String?) ?? '';
  const foodWords = [
    '美食', '吃', '早餐', '午餐', '晚餐', '夜宵', '小吃',
    '水煮', '茶饮', '甜品', '正餐', '糕点', '粉', '面',
  ];
  return foodWords.any(cat.contains);
}

void main(List<String> args) async {
  if (args.isEmpty) {
    print('用法: dart run tools/tag_library.dart <候选库.json>');
    exit(1);
  }

  final path = args.first;
  final file = File(path);
  if (!file.existsSync()) {
    print('❌ 找不到文件: $path');
    exit(1);
  }

  final root = jsonDecode(await file.readAsString()) as Map<String, dynamic>;

  var total = 0;
  final summary = <String, int>{};

  void process(List list, bool inFoodsSection) {
    for (final node in list) {
      if (node is! Map) continue;
      final name = (node['name'] as String?)?.trim() ?? '';
      final highlight = (node['highlight'] as String?) ?? '';
      final eat = (node['eat'] is List)
          ? (node['eat'] as List).join(' ')
          : '';
      final note = '${node['note'] ?? ''}';
      final cat = (node['category'] as String?) ?? '';

      // 用来匹配的文本。**刻意不含 address** ——
      // 地址是定位信息，里面会出现「八一馆站」这种不相关的词，会造成误判。
      final haystack = '$name $cat $highlight $eat $note';

      // 基础标签：吃 / 玩
      final isFood = _isFood(node, inFoodsSection);
      final tags = <String>{isFood ? '美食' : '景点'};

      for (final rule in _rules) {
        if (rule.keywords.any(haystack.contains)) {
          tags.add(rule.tag);
        }
      }

      // 「必去」保留
      if (node['mustGo'] == true) tags.add('必去');

      // 排序：类型在前，运动强度在后，读起来顺
      final ordered = tags.toList()
        ..sort((a, b) {
          int w(String t) {
            if (t == '景点' || t == '美食') return 0;
            if (t.startsWith('运动强度')) return 2;
            return 1;
          }

          final d = w(a) - w(b);
          return d != 0 ? d : a.compareTo(b);
        });

      node['placeTags'] = ordered;
      total++;
      for (final t in ordered) {
        summary[t] = (summary[t] ?? 0) + 1;
      }

      print('  ${name.padRight(22)} ${ordered.join(' / ')}');
    }
  }

  print('═══ 打标签 ═══\n');
  for (final key in ['attractions', 'foods']) {
    final list = root[key];
    if (list is List) {
      print('【$key】');
      process(list, key == 'foods');
      print('');
    }
  }

  // 备份 + 写回
  final backup = '$path.bak';
  await file.copy(backup);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(root),
  );

  print('✅ 已写入: $path');
  print('   备份:   $backup');
  print('\n共计 $total 个地点');
  print('\n标签使用统计：');
  final sorted = summary.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sorted) {
    print('  ${e.key.padRight(12)} ${e.value}');
  }
}
