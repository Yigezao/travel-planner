// ═══════════════════════════════════════════════════════════════
// 交接数据的**真实导入**验收（AI1 的硬校验）
//
// 为什么需要它：`tools/jsonl_to_library.dart` 是静态检查，只能看字段长得对不对。
// 真正的问题是「App 的导入器**实际吃进去**了什么」——字段类型不对会被静默忽略、
// name 空了会被静默跳过、坐标可能没落库。这些只有**跑真实导入代码**才能发现。
//
// 所以这里调用 App 真正的 `LibraryImporter`，把每个城市的 JSON 导进一个内存库，
// 然后断言：Region 建了、条数对得上、该有坐标的有坐标、没坐标的没被写成 0、
// 标签进了 place_tags、notices 进了 regions.notices。
//
// 用法：
//   set HANDOFF_DIR=F:\...\_ai_collab\handoff\AI2_to_AI1\batch-xxx\_converted
//   flutter test test/handoff_import_test.dart
//
// 不设 HANDOFF_DIR 时自动扫描 _ai_collab\handoff\AI2_to_AI1\*\converted；
// 一个都找不到就跳过（不让日常 `flutter test` 挂掉）。
// ═══════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/data/database.dart';
import 'package:travel_planner/data/library_importer.dart';

void main() {
  final dirs = _convertedDirs();

  test('交接数据：每个城市的库都能被 App 真实导入，且内容不丢', () async {
    if (dirs.isEmpty) {
      markTestSkipped('未找到交接批次目录（设 HANDOFF_DIR 或放 _ai_collab/handoff/AI2_to_AI1/*/_converted）');
      return;
    }

    final failures = <String>[];
    var cityCount = 0;

    for (final dir in dirs) {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();

      for (final f in files) {
        // ⚠️ 按**内容**判断是不是景点库，而不是按文件名。
        //    批次目录里还躺着 manifest.json 这类元数据文件，
        //    按名字排除容易漏（我一开始就是这么挂的：manifest 被当库导入 →
        //    「文件里没有 region 段」）。
        final Map<String, dynamic> src;
        try {
          final decoded = jsonDecode(f.readAsStringSync());
          if (decoded is! Map<String, dynamic>) continue;
          if (decoded['region'] is! Map) continue; // 没有 region 段 → 不是库
          src = decoded;
        } catch (_) {
          continue; // 解析不了的元数据文件，跳过
        }

        cityCount++;
        final cityName = f.uri.pathSegments.last.replaceAll('.json', '');

        // 每个城市一个干净的内存库，互不干扰
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        try {
          final result = await const LibraryImporter().importFromJson(
            jsonEncode(src),
            db,
          );

          final expectedRegion = (src['region'] as Map)['name'] as String;
          final expectedAttrs = (src['attractions'] as List?) ?? const [];
          final expectedFoods = (src['foods'] as List?) ?? const [];
          final expectedTotal = expectedAttrs.length + expectedFoods.length;

          // ① 地区建了
          if (result.regionName != expectedRegion) {
            failures.add('[$cityName] 地区名不符：期望 $expectedRegion，实际 ${result.regionName}');
          }

          // ② 条数对得上（景点+美食都落在 attractions 表）
          if (result.total != expectedTotal) {
            failures.add('[$cityName] 条数不符：JSON 里 $expectedTotal 条，导入 ${result.total} 条'
                '（可能被静默跳过——检查 name 是否为空）');
          }

          final regionId = (await db.select(db.regions).get())
              .firstWhere((r) => r.name == expectedRegion)
              .id;
          final rows = await (db.select(db.attractions)
                ..where((t) => t.regionId.equals(regionId)))
              .get();
          final byName = {for (final r in rows) r.name: r};

          // ③ 逐条核对：坐标、门票、标签
          for (final node in [...expectedAttrs, ...expectedFoods]) {
            final n = node as Map;
            final name = (n['name'] as String?)?.trim() ?? '';
            final got = byName[name];
            if (got == null) {
              failures.add('[$cityName] 「$name」没有落库');
              continue;
            }

            // 坐标：按导入器的**真实契约**断言，不是理想化的断言
            //
            // 契约（library_importer 的 _coord）：数字直接用；
            // **0 视为无效**（0,0 是几内亚湾）→ 存 null。
            // 所以这里分三种情况，别把「0 被转成 null」误判成丢数据。
            final srcLat = n['lat'], srcLng = n['lng'];
            final srcHasPair = srcLat is num && srcLng is num;
            final srcIsZero = srcHasPair && (srcLat == 0 || srcLng == 0);

            if (srcHasPair && !srcIsZero) {
              if (got.lat == null || got.lng == null) {
                failures.add('[$cityName] 「$name」坐标丢了：JSON 有 ($srcLat,$srcLng)，库里是 null');
              } else if ((got.lat! - srcLat).abs() > 1e-6 ||
                  (got.lng! - srcLng).abs() > 1e-6) {
                failures.add('[$cityName] 「$name」坐标被改动：'
                    'JSON ($srcLat,$srcLng) → 库 (${got.lat},${got.lng})');
              }
            } else if (srcIsZero) {
              // 0 属于「无效坐标」，导入器会存 null —— 这是**正确**的
              if (got.lat != null || got.lng != null) {
                failures.add('[$cityName] 「$name」JSON 里是 0 坐标（无效），库里却出现 '
                    '(${got.lat},${got.lng})');
              }
            } else {
              // 源里没有成对坐标：库里**不能**凭空长出一个有效坐标
              if (got.lat != null && got.lng != null) {
                failures.add('[$cityName] 「$name」源里没有有效坐标，库里却有 '
                    '(${got.lat},${got.lng})（编造？）');
              }
            }

            // 门票：JSON 有数字就必须落库（0 = 免费也要落）
            if (n['ticketYuan'] is num) {
              final want = ((n['ticketYuan'] as num) * 100).round();
              if (got.ticketPriceCents != want) {
                failures.add('[$cityName] 「$name」门票不符：'
                    'JSON ${n['ticketYuan']} 元 → 期望 $want 分，实际 ${got.ticketPriceCents} 分');
              }
            }
          }

          // ④ 标签进了 place_tags
          final expectedTagged = [...expectedAttrs, ...expectedFoods]
              .where((n) => ((n as Map)['placeTags'] as List?)?.isNotEmpty ?? false)
              .length;
          if (expectedTagged > 0) {
            final tagRows = await (db.select(db.placeTags)
                  ..where((t) => t.attractionId.isIn(rows.map((r) => r.id).toList())))
                .get();
            if (tagRows.isEmpty) {
              failures.add('[$cityName] place_tags 是空的，但 JSON 里有 $expectedTagged 条带标签');
            }
          }

          // ⑤ notices 进了 regions.notices
          final expectedNotices = ((src['region'] as Map)['notices'] as List?)?.length ?? 0;
          if (expectedNotices > 0) {
            final region = (await db.select(db.regions).get())
                .firstWhere((r) => r.name == expectedRegion);
            final lines = (region.notices ?? '')
                .split('\n')
                .where((s) => s.trim().isNotEmpty)
                .length;
            if (lines != expectedNotices) {
              failures.add('[$cityName] notices 数量不符：JSON $expectedNotices 条，库里 $lines 行');
            }
          }
        } catch (e) {
          failures.add('[$cityName] 导入抛异常：$e');
        } finally {
          await db.close();
        }
      }
    }

    if (failures.isEmpty) {
      // 让结果可见（flutter test 默认只显示通过）
      // ignore: avoid_print
      print('✓ 交接验收通过：$cityCount 个城市全部真实导入成功，内容无丢失');
    } else {
      fail('交接验收失败（$cityCount 城，${failures.length} 个问题）：\n'
          '${failures.take(60).join('\n')}'
          '${failures.length > 60 ? '\n…还有 ${failures.length - 60} 个' : ''}');
    }
  });
}

/// 找要验收的目录：HANDOFF_DIR 优先；否则扫 _ai_collab\handoff\AI2_to_AI1\*\*
List<Directory> _convertedDirs() {
  final out = <Directory>[];

  final env = Platform.environment['HANDOFF_DIR'];
  if (env != null && env.isNotEmpty) {
    final d = Directory(env);
    if (d.existsSync()) out.add(d);
    return out;
  }

  // travel_planner 的上一级就是 Code，协作目录在那儿
  final collab = Directory('../_ai_collab/handoff/AI2_to_AI1');
  if (!collab.existsSync()) return out;
  for (final batch in collab.listSync().whereType<Directory>()) {
    final converted = Directory('${batch.path}/_converted');
    if (converted.existsSync()) {
      out.add(converted);
    } else {
      // 没转换过就直接用批次目录本身（AI2 可能直接给 <城市>.json）
      final hasJson = batch
          .listSync()
          .whereType<File>()
          .any((f) => f.path.endsWith('.json') && !f.path.endsWith('_report.json'));
      if (hasJson) out.add(batch);
    }
  }
  return out;
}
