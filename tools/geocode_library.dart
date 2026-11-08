// ═══════════════════════════════════════════════════════════════
// 给候选库补经纬度
//
// 用法：
//   dart run tools/geocode_library.dart <候选库.json> --key=<高德Key> [选项]
//
// 选项：
//   --city=南昌              限定查询城市（强烈建议填）
//   --adcode=360100,360400   允许的行政区编码白名单（可选，更严格）
//   --dry-run                只查不写
//   --force                  已有坐标的也重查
//
// ═══════════════════════════════════════════════════════════════
// ⚠️ 用的是「地点搜索」API 而不是「地理编码」API
//
// 这是踩坑换来的：
//   地理编码 /v3/geocode/geo 需要「结构化地址」，喂店名会返回
//   infocode 30001 ENGINE_RESPONSE_DATA_ERROR。实测「黄记糕点」
//   「梅岭风景区」全部失败，而「滕王阁 东湖区仿古街58号」能成功——
//   因为后者长得像地址。
//
//   地点搜索 /v3/place/text 用 keywords 搜 POI，才是找店名该用的接口。
//   换成它之后，之前失败的全部查到了，而且返回的 name 还能用来
//   核对是不是同一个地方。
//
// ⚠️ 坐标系：高德返回 GCJ-02，一律转成 WGS-84 后写入，
//    以便和 flutter_map(OSM) 对齐，避免整体偏移 500 米。
// ═══════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';

import 'coord_convert.dart';

// ── 配置 ──

const _api = 'https://restapi.amap.com/v3/place/text';

/// 请求间隔。高德 Web 服务默认限 3 次/秒，这里留足余量。
const _requestInterval = Duration(milliseconds: 400);

/// 被限流时的重试等待（指数退避）
const _retryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
];

DateTime? _lastRequestAt;

class _Hit {
  _Hit({
    required this.lat,
    required this.lng,
    required this.poiName,
    required this.province,
    required this.city,
    required this.district,
    required this.adcode,
    required this.address,
    required this.type,
    required this.atag,
    required this.tel,
    required this.nameSimilarity,
  });

  final double lat;
  final double lng;
  final String poiName;
  final String province;
  final String city;
  final String district;
  final String adcode;
  final String address;
  final String type;
  final String atag;
  final String tel;

  /// 返回的 POI 名和我们要查的名字有多像（0-1）
  final double nameSimilarity;
}

class _Result {
  _Result.ok(this.hit) : reason = null;
  _Result.fail(this.reason) : hit = null;

  final _Hit? hit;
  final String? reason;

  bool get isOk => hit != null;
}

class _QueryOutcome {
  _QueryOutcome(this.query, this.result);

  final String query;
  final _Result result;
}

void main(List<String> args) async {
  if (args.isEmpty) {
    print('用法: dart run tools/geocode_library.dart <候选库.json> --key=高德Key');
    print('选项: --city=南昌  --adcode=360100  --dry-run  --force');
    exit(1);
  }

  final path = args.first;
  final key = _arg(args, 'key');
  final dryRun = args.contains('--dry-run');
  final force = args.contains('--force');
  final cityOverride = _arg(args, 'city');
  final adcodeWhitelist = (_arg(args, 'adcode') ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();

  if (key == null || key.isEmpty) {
    print('❌ 缺少 --key=你的高德Key');
    exit(1);
  }

  final file = File(path);
  if (!file.existsSync()) {
    print('❌ 找不到文件: $path');
    exit(1);
  }

  final root = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final regionName =
      ((root['region'] as Map?)?['name'] as String?)?.trim() ?? '';
  final city = cityOverride ?? regionName;

  print('═══ 补全经纬度 ═══');
  print('文件    : $path');
  print('地区    : $regionName');
  print('限定城市: ${city.isEmpty ? "（未限定）" : city}');
  print('白名单  : ${adcodeWhitelist.isEmpty ? "（未设置）" : adcodeWhitelist.join(", ")}');
  print('模式    : ${dryRun ? "试运行（不写文件）" : "写入文件"}');
  print('');

  final report = <Map<String, dynamic>>[];
  var ok = 0, suspicious = 0, notFound = 0, skipped = 0;

  for (final section in ['attractions', 'foods']) {
    final list = root[section];
    if (list is! List) continue;

    for (final node in list) {
      if (node is! Map) continue;
      final name = (node['name'] as String?)?.trim() ?? '';
      if (name.isEmpty) continue;

      final hasCoord = node['lat'] is num && node['lng'] is num;
      if (hasCoord && !force) {
        skipped++;
        continue;
      }

      final address = (node['address'] as String?)?.trim() ?? '';
      final outcome = await _queryWithFallback(
        key: key,
        name: name,
        address: address,
        city: city,
        adcodeWhitelist: adcodeWhitelist,
      );

      if (!outcome.result.isOk) {
        notFound++;
        report.add({
          'name': name,
          'status': '未查到',
          'query': outcome.query,
          'detail': outcome.result.reason,
        });
        stdout.write('·');
        continue;
      }

      final hit = outcome.result.hit!;

      // ── 判断这条结果可不可信 ──
      // 三个信号：
      //   1. 名字相似度 —— 太低说明搜到的不是同一个地方
      //   2. 有具体地址 —— 门牌/街道级，说明定位到实体
      //   3. 行政区在白名单内（如果设了）
      final nameOk = hit.nameSimilarity >= 0.5;
      final addrOk = hit.address.isNotEmpty;
      final trusted = nameOk && addrOk;

      node['lat'] = double.parse(hit.lat.toStringAsFixed(6));
      node['lng'] = double.parse(hit.lng.toStringAsFixed(6));
      node['_geo'] = {
        'source': '高德POI(GCJ02→WGS84)',
        'matched': hit.poiName,
        'address': hit.address,
        'province': hit.province,
        'city': hit.city,
        'district': hit.district,
        'adcode': hit.adcode,
        'poiType': hit.type,
        if (hit.atag.isNotEmpty) 'tags': hit.atag,
        if (hit.tel.isNotEmpty) 'tel': hit.tel,
        'similarity': double.parse(hit.nameSimilarity.toStringAsFixed(2)),
        'verified': DateTime.now().toIso8601String().substring(0, 10),
      };

      if (trusted) {
        ok++;
        stdout.write('.');
      } else {
        suspicious++;
        stdout.write('?');
        final why = !nameOk
            ? '搜到的名字是「${hit.poiName}」，和你记的「$name」差太多，'
                '可能不是同一个地方'
            : '返回里没有具体地址（只有「${hit.district}」这一级），'
                '定位可能不够准';
        report.add({
          'name': name,
          'status': '可疑',
          'query': outcome.query,
          'matched': hit.poiName,
          'address': hit.address,
          'coord': '${hit.lat}, ${hit.lng}',
          'similarity': hit.nameSimilarity,
          'detail': why,
        });
      }
    }
  }

  print('\n');

  if (!dryRun) {
    final backup = '$path.bak';
    await file.copy(backup);
    root['_geocodedAt'] = DateTime.now().toIso8601String();
    root['_geocodeStats'] = {
      'ok': ok,
      'suspicious': suspicious,
      'notFound': notFound,
      'skipped': skipped,
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(root),
    );
    print('✅ 已写入: $path');
    print('   备份:   $backup');
  } else {
    print('ℹ️ 试运行，文件未改动');
  }

  print('\n═══ 结果 ═══');
  print('  ✅ 可信     : $ok');
  print('  ⚠️  可疑     : $suspicious');
  print('  ❌ 未查到   : $notFound');
  print('  ⏭️  已有坐标 : $skipped');

  if (report.isNotEmpty) {
    final reportFile = File('$path.review.json');
    await reportFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    print('\n需要人工看的 ${report.length} 条:');
    print('  $reportFile');
    print('\n=== 清单 ===');
    for (final r in report) {
      final mark = r['status'] == '可疑' ? '⚠️ ' : '❌';
      print('\n$mark ${r['name']}');
      print('   查询: ${r['query']}');
      if (r['matched'] != null) print('   搜到: ${r['matched']}');
      if (r['address'] != null && (r['address'] as String).isNotEmpty) {
        print('   地址: ${r['address']}');
      }
      if (r['coord'] != null) print('   坐标: ${r['coord']}');
      print('   ${r['detail']}');
    }
  } else {
    print('\n🎉 全部可信，无需人工核对。');
  }
}

// ══════════════════════════════════════════════════════════════
// 查询
// ══════════════════════════════════════════════════════════════

Future<_QueryOutcome> _queryWithFallback({
  required String key,
  required String name,
  required String address,
  required String city,
  required Set<String> adcodeWhitelist,
}) async {
  // 候选关键词，按优先级：
  //   1. 名字（最长 20 字）+ 地址 —— 最具体
  //   2. 只用名字（最长 20 字）    —— 兜底
  //
  // ⚠️ 截断到 20 字是踩坑来的：POI 搜索的 keywords 太长反而搜不到。
  //    实测「章江晓渡 导航 南昌市妇幼保健院 最便捷」搜不到，
  //    而高德的 keywords 是用于匹配 POI 名称的，不是用来塞说明文字的。
  final shortName = _truncate(name, 20);
  final candidates = <String>[
    _cleanQuery([shortName, address].where((s) => s.isNotEmpty).join(' ')),
    _cleanQuery(shortName),
  ].where((s) => s.isNotEmpty).toSet().toList();

  _Result? last;
  for (final q in candidates) {
    final r = await _search(
      key: key,
      keywords: q,
      city: city,
      adcodeWhitelist: adcodeWhitelist,
    );
    if (r.isOk) return _QueryOutcome(q, r);
    last = r;
    if (!(r.reason ?? '').contains('DATA_ERROR')) break;
  }

  return _QueryOutcome(candidates.first, last!);
}

Future<_Result> _search({
  required String key,
  required String keywords,
  required String city,
  required Set<String> adcodeWhitelist,
  int attempt = 0,
}) async {
  await _throttle();

  final params = <String, String>{
    'key': key,
    'keywords': keywords,
    'offset': '3', // 多取几条，供挑选
    'page': '1',
    'extensions': 'base',
  };
  if (city.isNotEmpty) {
    params['city'] = city;
    // 限定只搜这个城市，防止搜到外省同名店
    params['citylimit'] = 'true';
  }

  final uri = Uri.parse(_api).replace(queryParameters: params);
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 12);

  try {
    final req = await client.getUrl(uri);
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final body = await resp.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;

    if (json['status']?.toString() != '1') {
      final info = json['info']?.toString() ?? '未知错误';
      final isRateLimit =
          info.contains('CUQPS') || info.contains('EXCEEDED_THE_LIMIT');
      if (isRateLimit && attempt < _retryDelays.length) {
        await Future<void>.delayed(_retryDelays[attempt]);
        return _search(
          key: key,
          keywords: keywords,
          city: city,
          adcodeWhitelist: adcodeWhitelist,
          attempt: attempt + 1,
        );
      }
      return _Result.fail('高德返回：$info');
    }

    final pois = json['pois'];
    if (pois is! List || pois.isEmpty) {
      return _Result.fail('高德没搜到这个地点');
    }

    // 从返回的前几条里挑最像的
    _Hit? best;
    var bestScore = -1.0;
    for (final p in pois) {
      if (p is! Map) continue;

      final adcode = (p['adcode'] ?? '').toString();
      if (adcodeWhitelist.isNotEmpty && !adcodeWhitelist.contains(adcode)) {
        continue;
      }

      final loc = (p['location'] ?? '').toString();
      final parts = loc.split(',');
      if (parts.length != 2) continue;
      final gcjLng = double.tryParse(parts[0]);
      final gcjLat = double.tryParse(parts[1]);
      if (gcjLat == null || gcjLng == null) continue;

      final poiName = (p['name'] ?? '').toString();
      final sim = _similarity(keywords, poiName);

      // 打分：名字相似度为主，有地址加分
      final addr = (p['address'] ?? '').toString();
      final score = sim + (addr.isNotEmpty ? 0.1 : 0);

      if (score > bestScore) {
        bestScore = score;
        final wgs = gcj02ToWgs84(gcjLat, gcjLng);
        best = _Hit(
          lat: wgs.lat,
          lng: wgs.lng,
          poiName: poiName,
          province: (p['pname'] ?? '').toString(),
          city: (p['cityname'] ?? '').toString(),
          district: (p['adname'] ?? '').toString(),
          adcode: adcode,
          address: addr,
          type: (p['type'] ?? '').toString(),
          atag: (p['atag'] ?? '').toString(),
          tel: (p['tel'] ?? '').toString(),
          nameSimilarity: sim,
        );
      }
    }

    if (best == null) {
      return _Result.fail('搜到的结果都不在指定范围内');
    }
    return _Result.ok(best);
  } catch (e) {
    return _Result.fail('网络错误：$e');
  } finally {
    client.close(force: true);
  }
}

// ══════════════════════════════════════════════════════════════
// 辅助
// ══════════════════════════════════════════════════════════════

/// 名字相似度（0-1）。
/// 用「公共字符占比」近似，够区分「完全一样」和「八竿子打不着」了。
double _similarity(String a, String b) {
  final sa = a.replaceAll(RegExp(r'\s'), '');
  final sb = b.replaceAll(RegExp(r'\s'), '');
  if (sa.isEmpty || sb.isEmpty) return 0;

  final setA = sa.split('').toSet();
  final setB = sb.split('').toSet();
  final common = setA.intersection(setB).length;
  final shorter = setA.length < setB.length ? setA.length : setB.length;

  return common / shorter;
}

/// 按字符截断（中文按字算）
String _truncate(String s, int max) {
  final t = s.trim();
  return t.length <= max ? t : t.substring(0, max);
}

/// 清洗查询串
String _cleanQuery(String s) {
  return s
      .replaceAll(RegExp(r'[（(][^）)]*[）)]'), ' ')
      .replaceAll(RegExp(r'[「」“”"\x27]'), ' ')
      .replaceAll(RegExp(r'[/｜|、>→]'), ' ')
      .replaceAll('　', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String? _arg(List<String> args, String name) {
  final prefix = '--$name=';
  for (final a in args) {
    if (a.startsWith(prefix)) return a.substring(prefix.length);
  }
  return null;
}

/// 请求节流：两次请求之间保证间隔 _requestInterval
Future<void> _throttle() async {
  final now = DateTime.now();
  if (_lastRequestAt != null) {
    final elapsed = now.difference(_lastRequestAt!);
    if (elapsed < _requestInterval) {
      await Future<void>.delayed(_requestInterval - elapsed);
    }
  }
  _lastRequestAt = DateTime.now();
}
