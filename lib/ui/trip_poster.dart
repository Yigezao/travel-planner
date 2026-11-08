// ═══════════════════════════════════════════════════════════════
// 行程长图（PNG）绘制
//
// 套用用户 mermaid 模板的配色体系：
//   暖米→杏→蓝→绿 分阶段；emoji 标题；每节点 ≤12 行。
// 结构：行程抬头 → 每天一个阶段块 → 六时段模块横排 → 地点卡片
//
// 用法：把 TripPoster 放进 OverlayEntry 渲染一帧，再用
//      RepaintBoundary 截成 PNG。见 trip_poster_exporter.dart
// ═══════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';

import '../data/database.dart';
import '../data/exporter.dart';
import '../data/travel_repository.dart';
// 只用 weatherKeyOf（日期 → 预报 Map 的 key）和 kForecastHorizonDays
import '../data/weather.dart';

/// 六个时段模块的配色（沿用 mermaid 模板的分阶段色系）
const Map<TimeBlock, _BlockStyle> _blockStyles = {
  TimeBlock.breakfast: _BlockStyle(
    bg: Color(0xFFFFF8EC),
    border: Color(0xFFE8A840),
    icon: '🍜',
  ),
  TimeBlock.morning: _BlockStyle(
    bg: Color(0xFFE8F0FF),
    border: Color(0xFF5B8EC9),
    icon: '🌅',
  ),
  TimeBlock.lunch: _BlockStyle(
    bg: Color(0xFFFFF0E6),
    border: Color(0xFFE8783A),
    icon: '🍚',
  ),
  TimeBlock.afternoon: _BlockStyle(
    bg: Color(0xFFE6F5EC),
    border: Color(0xFF5AAA75),
    icon: '☀️',
  ),
  TimeBlock.dinner: _BlockStyle(
    bg: Color(0xFFF5EEFF),
    border: Color(0xFF9B7BC9),
    icon: '🍽️',
  ),
  TimeBlock.evening: _BlockStyle(
    bg: Color(0xFFF0F4F8),
    border: Color(0xFF7B9CB5),
    icon: '🌙',
  ),
};

class _BlockStyle {
  const _BlockStyle({
    required this.bg,
    required this.border,
    required this.icon,
  });

  final Color bg;
  final Color border;
  final String icon;
}

/// 「没有时段」那一档的样式。
///
/// 行程详情页把 timeBlock 为空的条目归到「其他」并照常渲染，
/// 长图以前只遍历 TimeBlock.values、直接跳过它们 —— 结果是
/// **导出的长图比用户在 App 里看到的行程少内容**。
const _BlockStyle _otherBlockStyle = _BlockStyle(
  bg: Color(0xFFF4F4F2),
  border: Color(0xFF9E9E9E),
  icon: '📌',
);

/// 「没有时段」那一档的标题
const String _otherBlockLabel = '其他';

/// 长图最多画多少天。
///
/// ⚠️ 必须有这个上限。长图是**按天逐个渲染成 widget 再截图**的（超出 GPU
///    纹理上限还要纵向分片，每片固定等 40ms），没有任何截断的话：
///    日期选择器允许选到很远的年份，用户把返程误选成 2030/2100 时
///    `totalDays` 会变成几千甚至两万七千 → 上万次渲染 + 上千次分片，
///    主线程直接冰封、内存爆掉，只能杀进程。
///    60 天足够覆盖任何真实旅行；超出的天不画，并在图上注明。
const int _maxPosterDays = 60;

/// 每天一个颜色（头部条）
const List<Color> _dayColors = [
  Color(0xFFE8A840),
  Color(0xFF5B8EC9),
  Color(0xFF5AAA75),
  Color(0xFFE8783A),
  Color(0xFF9B7BC9),
  Color(0xFF7B9CB5),
  Color(0xFFC9B830),
];

class TripPoster extends StatelessWidget {
  const TripPoster({
    super.key,
    required this.bundle,
    this.attractions = const [],
    this.tags = const {},
    this.dayWeather = const {},
    this.weatherHorizonDays = kForecastHorizonDays,
    this.onlyDay,
  });

  final TripBundle bundle;

  /// 该地区的景点库地点。用来给行程条目补充详细信息
  /// （价格、地址、避坑备注等）——图片很宽，右边留白太多，不如把这些都放上去。
  final List<Attraction> attractions;

  /// 地点标签（attractionId → 标签列表）。
  /// ⚠️ 海报原来只读 category 字段，手打标签的景点（存 place_tags 表）
  /// 上不了长图——现在两张表都读。
  final Map<String, List<String>> tags;

  /// 逐日天气预报：`yyyy-MM-dd → '晴 25℃'`（见 data/weather.dart）。
  ///
  /// ⚠️ 长图是**在屏幕外渲染**的，取数是异步的，所以必须由调用方先取好、
  ///    再作为参数传进来——海报自己没法 await。
  ///    拿不到就是空 Map：那一天不显示天气（**不编数据**）。
  final Map<String, String> dayWeather;

  /// 这次实际能覆盖多少天（和风 7 / 高德 4）。写进「暂无天气」的说明里，
  /// 所以必须如实——见 [DayWeatherResult.horizonDays]。
  final int weatherHorizonDays;

  /// 只画某一天（单天导出图片用）。为空则画全部
  final int? onlyDay;

  /// 找出行程条目对应的景点库地点（优先 attractionId，其次按名字）
  Attraction? _match(ItineraryItem it) {
    if (it.attractionId != null) {
      final byId =
          attractions.where((a) => a.id == it.attractionId).firstOrNull;
      if (byId != null) return byId;
    }
    final name = it.customName;
    if (name == null || name.isEmpty) return null;
    return attractions.where((a) => a.name == name).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final trip = bundle.trip;
    final totalDays = trip.endDate.difference(trip.startDate).inDays + 1;

    final byDay = <int, List<ItineraryItem>>{};
    for (final it in bundle.items) {
      byDay.putIfAbsent(it.dayIndex, () => []).add(it);
    }

    final totalSpent =
        bundle.expenses.fold<int>(0, (s, e) => s + e.amountCents);

    // 单天导出时只画那一天
    final truncated = onlyDay == null && totalDays > _maxPosterDays;
    final days = onlyDay != null
        ? [onlyDay!]
        : [for (var d = 1; d <= totalDays && d <= _maxPosterDays; d++) d];

    return Container(
      width: 900,
      color: const Color(0xFFFAFAF8),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(trip, onlyDay),
          // 📌 注意事项：来自景点库 region.notices，排在第 1 天之前
          //（单天导出是发人的动线图，不带）
          if (onlyDay == null) _buildNotices(),
          const SizedBox(height: 22),
          for (final d in days) ...[
            _buildDay(d, trip.startDate.add(Duration(days: d - 1)),
                byDay[d] ?? []),
            const SizedBox(height: 16),
          ],
          if (truncated) _buildTruncatedNote(totalDays),
          // 整份行程都没有天气 → 说明原因（否则用户只会以为导出坏了）
          if (onlyDay == null && dayWeather.isEmpty) _buildNoWeatherNote(),
          // 单天导出不显示总账单（那是整个行程的）
          if (onlyDay == null) _buildFooter(totalSpent),
        ],
      ),
    );
  }

  /// 整份行程都拿不到天气时的说明。
  ///
  /// 必须说出来：天气预报只覆盖**出行前 kForecastHorizonDays 天**，
  /// 提前很久做攻略时那几天的天气**本来就不存在**（任何气象源都一样），
  /// 不是导出功能坏了。
  Widget _buildNoWeatherNote() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F7FB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF9FBBD4)),
      ),
      child: Text(
        '天气：暂时没有预报数据。\n'
        '预报只覆盖出行前 $weatherHorizonDays 天，'
        '临近出发再导一次就会自动出现。',
        style: const TextStyle(fontSize: 13, color: Color(0xFF44546A)),
      ),
    );
  }

  /// 天数被截断时的说明。
  ///
  /// 必须写在图上——否则用户只会看到「导出少了内容」，不知道该去改日期。
  Widget _buildTruncatedNote(int totalDays) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8EC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE8A840)),
      ),
      child: Text(
        '⚠️ 这份行程共 $totalDays 天，长图只画了前 $_maxPosterDays 天。\n'
        '如果日期填错了，回行程里改一下日期范围再导出。',
        style: const TextStyle(fontSize: 13, color: Color(0xFF8A6A20)),
      ),
    );
  }

  // ── 注意事项 ──
  Widget _buildNotices() {
    final raw = bundle.region.notices;
    if (raw == null || raw.trim().isEmpty) return const SizedBox.shrink();
    final items = raw
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 22),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8EC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE8A840)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '📌 注意事项',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Color(0xFF8B6E3A),
            ),
          ),
          const SizedBox(height: 6),
          for (final n in items)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '• $n',
                style: const TextStyle(
                    fontSize: 12, height: 1.4, color: Color(0xFF666666)),
              ),
            ),
        ],
      ),
    );
  }

  // ── 抬头 ──

  Widget _buildHeader(Trip trip, int? singleDay) {
    final totalDays = trip.endDate.difference(trip.startDate).inDays + 1;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFE8F0FF), Color(0xFFE6F5EC)],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF5B8EC9), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // 单天导出时标题里标清楚是第几天，避免收到图的人看不出是哪天
            singleDay == null ? trip.title : '${trip.title} · 第 $singleDay 天',
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2C3E50),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              if (singleDay == null)
                _chip('📅', '${ymd(trip.startDate)} ~ ${ymd(trip.endDate)}')
              else
                _chip(
                  '📅',
                  ymd(trip.startDate.add(Duration(days: singleDay - 1))),
                ),
              if (singleDay == null)
                _chip('🗓️', '$totalDays 天 ${trip.nights} 夜')
              else
                _chip('🗓️', '共 $totalDays 天的第 $singleDay 天'),
              if (trip.totalBudgetCents > 0 && singleDay == null)
                _chip('💰', '预算 ¥${centsToYuan(trip.totalBudgetCents)}'),
            ],
          ),
          if (trip.note != null && trip.note!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '📌 ${trip.note}',
              style: const TextStyle(fontSize: 13, color: Color(0xFF555555)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(String emoji, String text) {
    return Text(
      '$emoji $text',
      style: const TextStyle(fontSize: 14, color: Color(0xFF44546A)),
    );
  }

  // ── 一天 ──

  Widget _buildDay(int dayIndex, DateTime date, List<ItineraryItem> items) {
    final color = _dayColors[(dayIndex - 1) % _dayColors.length];
    // 这一天的天气。取不到就是 null → 后面整个不显示（不编数据）
    final weather = dayWeather[weatherKeyOf(date)];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 日期条
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Row(
              children: [
                Text(
                  '📅 第 $dayIndex 天',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  prettyDate(date),
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
                ),
                // 天气就跟在「9月25日 周五」后面（用户要求的位置）。
                // 预报拿不到就整段不显示 —— 宁可没有，不编。
                if (weather != null) ...[
                  const SizedBox(width: 10),
                  Text(
                    weather,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: color.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _buildBlocks(items),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBlocks(List<ItineraryItem> items) {
    final widgets = <Widget>[];
    for (final block in TimeBlock.values) {
      final inBlock = items.where((i) => i.timeBlock == block.name).toList()
        ..sort((a, b) => a.seq.compareTo(b.seq));
      if (inBlock.isEmpty) continue;
      widgets.add(_buildBlock(block, inBlock));
      widgets.add(const SizedBox(height: 8));
    }

    // 没有时段的条目（老数据 / 手工插入）→ 收进「其他」一档。
    // 必须补这一段：详情页会显示它们，长图不显示就成了「导出的图
    // 比看到的行程少东西」，用户根本察觉不到是导出丢的。
    final noBlock = items.where((i) => i.timeBlock == null).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    if (noBlock.isNotEmpty) {
      widgets.add(_buildBlock(null, noBlock));
      widgets.add(const SizedBox(height: 8));
    }

    return widgets;
  }

  /// block 为 null = 「其他」那一档（没有时段的条目）
  Widget _buildBlock(TimeBlock? block, List<ItineraryItem> items) {
    final style = block == null ? _otherBlockStyle : _blockStyles[block]!;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: style.border.withValues(alpha: 0.55)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧时段标签
          SizedBox(
            width: 74,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // null = 「其他」档，详情页也是这个叫法
                  '${style.icon} ${block == null ? _otherBlockLabel : kTimeBlockLabels[block]}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: style.border,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 右侧地点列表
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final it in items) _buildItem(it, style.border),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(ItineraryItem it, Color accent) {
    final timeText = [
      if (it.arriveTime != null && it.arriveTime!.isNotEmpty) it.arriveTime!,
      if (it.leaveTime != null && it.leaveTime!.isNotEmpty) it.leaveTime!,
    ].join('-');

    // 从景点库补详细信息。图片很宽，右边空间大，值得把这些都放上去。
    final a = _match(it);

    // 备注：优先用条目自己的（用户可能改过），没有再退回景点库的
    final note = (it.note != null && it.note!.isNotEmpty)
        ? it.note!
        : (a?.note ?? '');

    // 景点库里带过来的额外信息
    final priceText = (a != null && a.ticketPriceCents > 0)
        ? '¥${centsToYuan(a.ticketPriceCents)}'
        : null;
    final hourText = (a?.suggestDurationMin != null)
        ? '${(a!.suggestDurationMin! / 60).toStringAsFixed(1)}h'
        : null;
    final itemTags =
        (a != null) ? (tags[a.id] ?? const <String>[]) : const <String>[];

    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 第一行：名字 + 时间 ──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        // 关联景点库的条目用库里的实时名字
                        (it.attractionId != null && a != null)
                            ? a.name
                            : (it.customName ?? a?.name ?? '(未命名)'),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF2C3E50),
                        ),
                      ),
                    ),
                    if (timeText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            timeText,
                            style: TextStyle(
                              fontSize: 12,
                              color: accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),

                // ── 第二行：星级 / 价格 / 时长 / 分类 / 标签 ──
                if (priceText != null ||
                    hourText != null ||
                    (a?.category != null) ||
                    (a?.recommendLevel != null) ||
                    itemTags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        if (a?.recommendLevel != null) ...[
                          Text(
                            '★' * a!.recommendLevel!,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFFE8A840),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],
                        if (a?.category != null)
                          _miniChip(a!.category!, accent),
                        if (priceText != null) ...[
                          const SizedBox(width: 5),
                          _miniChip(priceText, const Color(0xFFD06060)),
                        ],
                        if (hourText != null) ...[
                          const SizedBox(width: 5),
                          _miniChip(hourText, const Color(0xFF7B9CB5)),
                        ],
                        // 手打标签（place_tags）也上长图，取前 3 个
                        for (final t in itemTags.take(3)) ...[
                          const SizedBox(width: 5),
                          _miniChip(t, const Color(0xFF5AAA75)),
                        ],
                      ],
                    ),
                  ),

                // ── 地址 ──
                if (a?.address != null && a!.address!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '📍 ${a.address}',
                      style: const TextStyle(
                          fontSize: 11.5, color: Color(0xFF888888)),
                    ),
                  ),

                // ── 备注全文（不再只取第一行）──
                if (note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      note,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF666666),
                        height: 1.4,
                      ),
                    ),
                  ),

                // ── 住宿 ──
                if (it.hotelName != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '🏨 ${it.hotelName}'
                      '${it.hotelAddress != null ? '（${it.hotelAddress}）' : ''}'
                      '${it.hotelCostCents > 0 ? ' · ¥${centsToYuan(it.hotelCostCents)}' : ''}',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF8B6E3A)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 小标签（价格、时长、分类）
  Widget _miniChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 10.5, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  // ── 页脚 ──

  Widget _buildFooter(int totalSpent) {
    if (bundle.expenses.isEmpty && bundle.budgets.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFDE8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFC9B830)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '💰 花费汇总',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Color(0xFF8B7A1A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '合计 ¥${centsToYuan(totalSpent)}'
            '${bundle.trip.totalBudgetCents > 0 ? ' / 预算 ¥${centsToYuan(bundle.trip.totalBudgetCents)}' : ''}',
            style: const TextStyle(fontSize: 14, color: Color(0xFF555555)),
          ),
          if (bundle.expenses.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: bundle.expenses
                  .take(12)
                  .map((e) => Text(
                        '${e.itemName} ¥${centsToYuan(e.amountCents)}',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF777777)),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}
