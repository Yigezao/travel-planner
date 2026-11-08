// 地区识别测试。
// 中文没有词边界，猜地名很容易错——这些用例确保「不确定就不猜」。

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/region_parser.dart';

void main() {
  group('匹配已有地区名（最可靠）', () {
    test('资料库有「南昌」时能认出来', () {
      expect(
        parseRegion('南昌3天2夜', knownRegions: ['南昌']),
        '南昌',
      );
    });

    test('标题里地区在中间', () {
      // 资料库里存的是「日本·关西」，标题里只写「关西」——
      // 整体不在标题里，不做模糊匹配，但后面第 2 步的独立地名表里有「关西」，
      // 所以最终还是会认出来。这正是想要的效果：不会瞎猜，但常见地区能认。
      expect(
        parseRegion('2027春节 关西 6天5夜', knownRegions: ['日本·关西']),
        '关西',
      );
      expect(
        parseRegion('2027春节 关西 6天5夜', knownRegions: ['关西']),
        '关西',
      );
    });

    test('有多个地区名时优先取长的', () {
      expect(
        parseRegion('南昌县三日游', knownRegions: ['南昌', '南昌县']),
        '南昌县',
        reason: '「南昌县」比「南昌」长，应优先',
      );
    });

    test('完全没匹配到就返回 null', () {
      expect(
        parseRegion('随便写点什么', knownRegions: ['南昌']),
        isNull,
      );
    });
  });

  group('按地名后缀猜', () {
    test('带「市」', () {
      expect(parseRegion('厦门市三日游'), '厦门市');
    });

    test('带「县」，且前面有动词', () {
      expect(parseRegion('去婺源县玩两天'), '婺源县',
          reason: '「去」是动词，不该被当成地名的一部分');
    });

    test('带国外地名', () {
      expect(parseRegion('泰国6天5夜'), '泰国');
    });

    test('关西/关东这类地区名', () {
      expect(parseRegion('关西6天5夜'), '关西');
    });
  });

  group('不瞎猜', () {
    test('只有天数没有地名', () {
      expect(parseRegion('3天2夜'), isNull);
    });

    test('空字符串', () {
      expect(parseRegion(''), isNull);
      expect(parseRegion('   '), isNull);
    });

    test('纯描述文字', () {
      expect(parseRegion('说走就走的旅行'), isNull);
    });

    test('「三天两夜」的「天」不该被当成地名一部分', () {
      final r = parseRegion('三天两夜');
      expect(r, isNull, reason: '没有真实地名，不能瞎猜');
    });
  });

  group('行程标题判断', () {
    test('像行程名', () {
      expect(looksLikeTripTitle('南昌3天2夜'), isTrue);
      expect(looksLikeTripTitle('周末两日游'), isTrue);
    });

    test('不像', () {
      expect(looksLikeTripTitle('南昌'), isFalse);
    });
  });
}
