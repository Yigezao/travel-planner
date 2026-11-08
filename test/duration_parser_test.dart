// 时长解析的测试。
// 这个功能会直接影响行程的起止日期，认错了比认不出更糟，
// 所以边界情况（模糊说法、超大数字、无关文字）都要覆盖。

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/duration_parser.dart';

void main() {
  group('标准写法', () {
    test('阿拉伯数字：3天2夜', () {
      final d = parseDuration('南昌 3天2夜')!;
      expect(d.days, 3);
      expect(d.nights, 2);
    });

    test('阿拉伯数字带空格：3 天 2 夜', () {
      final d = parseDuration('南昌三天两夜')!;
      expect(d.days, 3);
      expect(d.nights, 2);
    });

    test('晚 同 夜：2天1晚', () {
      final d = parseDuration('2天1晚')!;
      expect(d.days, 2);
      expect(d.nights, 1);
    });

    test('中文数字：三天两夜', () {
      final d = parseDuration('南昌三天两夜')!;
      expect(d.days, 3);
      expect(d.nights, 2);
    });

    test('中文数字用「晚」：五日四晚', () {
      final d = parseDuration('五日四晚')!;
      expect(d.days, 5);
      expect(d.nights, 4);
    });

    test('繁体：三天兩夜', () {
      final d = parseDuration('三天兩夜')!;
      expect(d.days, 3);
      expect(d.nights, 2);
    });
  });

  group('只写天数', () {
    test('4天', () {
      final d = parseDuration('云南 4天')!;
      expect(d.days, 4);
      expect(d.nights, 3, reason: '没写夜数就按 days-1 算');
    });

    test('三日游', () {
      final d = parseDuration('苏州三日游')!;
      expect(d.days, 3);
      expect(d.nights, 2);
    });

    test('两天', () {
      final d = parseDuration('周末两天')!;
      expect(d.days, 2);
      expect(d.nights, 1);
    });
  });

  group('大于十的中文数字', () {
    test('十五天', () {
      final d = parseDuration('十五天')!;
      expect(d.days, 15);
    });

    test('十二天十一夜', () {
      final d = parseDuration('十二天十一夜')!;
      expect(d.days, 12);
      expect(d.nights, 11);
    });
  });

  group('认不出就返回 null，不瞎猜', () {
    test('模糊说法：玩几天', () {
      expect(parseDuration('去南昌玩几天'), isNull);
    });

    test('一周', () {
      expect(parseDuration('大概一周'), isNull);
    });

    test('纯地名', () {
      expect(parseDuration('南昌'), isNull);
    });

    test('空字符串', () {
      expect(parseDuration(''), isNull);
      expect(parseDuration('   '), isNull);
    });

    test('数字过大（超过 60 天）', () {
      expect(parseDuration('99天'), isNull,
          reason: '99 天不像真实行程，多半是误识别');
    });
  });

  group('起止日期推算', () {
    test('3天从 10/1 开始 → 到 10/3', () {
      final d = parseDuration('3天2夜')!;
      final end = d.endDateFrom(DateTime(2026, 10, 1));
      expect(end, DateTime(2026, 10, 3));
    });

    test('1天当天来回', () {
      final d = parseDuration('1天')!;
      final end = d.endDateFrom(DateTime(2026, 10, 1));
      expect(end, DateTime(2026, 10, 1));
      expect(d.nights, 0);
    });

    test('跨月：10/30 出发 4 天 → 11/2', () {
      final d = parseDuration('4天3夜')!;
      final end = d.endDateFrom(DateTime(2026, 10, 30));
      expect(end, DateTime(2026, 11, 2));
    });
  });

  group('描述文字', () {
    test('有夜数', () {
      expect(describeDuration(const TripDuration(days: 3, nights: 2)),
          '3 天 2 夜');
    });

    test('当天来回不显示夜', () {
      expect(describeDuration(const TripDuration(days: 1, nights: 0)), '1 天');
    });
  });

  // ══════════════════════════════════════════════════════════
  // 回归：正则从任意位置起匹配，会吃掉长数字的尾巴和日期
  // ══════════════════════════════════════════════════════════
  group('不该被误识别的情况', () {
    test('标题里带日期 → 不认（「南昌2月3日」曾变成 3 天 2 夜）', () {
      expect(parseDuration('南昌2月3日'), isNull);
      expect(parseDuration('10月1日出发'), isNull);
      expect(parseDuration('南昌12月25日'), isNull);
    });

    test('长数字的尾巴 → 不认（「610天」曾变成 10 天）', () {
      expect(parseDuration('610天'), isNull);
      expect(parseDuration('1230天'), isNull);
    });

    test('小数 → 不认（「1.5天」曾变成 5 天）', () {
      expect(parseDuration('1.5天'), isNull);
    });

    test('夜数比天数还多 → 退回 days-1（「3天99夜」曾原样接受 99 夜）', () {
      final d = parseDuration('3天99夜')!;
      expect(d.days, 3);
      expect(d.nights, 2);
    });

    test('正常写法不受影响', () {
      expect(parseDuration('南昌3天2夜')!.days, 3);
      expect(parseDuration('南昌3天2夜')!.nights, 2);
      expect(parseDuration('三日游')!.days, 3);
      expect(parseDuration('3日游')!.days, 3);
      expect(parseDuration('十五天')!.days, 15);
      // 「日」在开头才算时长
      expect(parseDuration('3日')!.days, 3);
    });
  });
}
