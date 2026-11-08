// ═══════════════════════════════════════════════════════════════
// 新建行程
//
// 注意：「几夜」不让用户填，由日期自动算。
// 手填会和日期对不上，是数据不一致的常见来源。
// ═══════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/duration_parser.dart';
import '../data/exporter.dart';
import '../data/providers.dart';
import '../data/region_parser.dart';
import 'app_toast.dart';
import 'trip_detail_screen.dart';

class TripCreateScreen extends ConsumerStatefulWidget {
  const TripCreateScreen({super.key});

  @override
  ConsumerState<TripCreateScreen> createState() => _TripCreateScreenState();
}

class _TripCreateScreenState extends ConsumerState<TripCreateScreen> {
  final _titleCtrl = TextEditingController();
  final _regionCtrl = TextEditingController();
  final _budgetCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  /// 默认从今天开始、3 天 2 夜。
  ///
  /// 演变过程：
  ///   · 最初默认 30 天后、6 天 5 夜 —— 用户每次都要手改
  ///   · 2026-09-14 改成今天起、6 天 5 夜
  ///   · 2026-09-14 再改成今天起、**3 天 2 夜**（周末短途更常见）
  ///
  /// 只取日期部分（时分秒归零），否则「今天」会被算成
  /// 「今天此刻之后的日期」，跨天判定会出偏差。
  DateTime _startDate = _today();

  /// +2 天 = 3 天 2 夜
  DateTime _endDate = _today().add(const Duration(days: 2));

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }
  bool _saving = false;

  /// 用户是否手动改过日期。改过就不再被标题覆盖，避免打架。
  bool _datesTouchedByUser = false;

  /// 景点库里已有的地区名 —— 用来识别标题里的地区
  List<String> _knownRegions = [];

  @override
  void initState() {
    super.initState();
    _loadKnownRegions();
  }

  Future<void> _loadKnownRegions() async {
    try {
      final names = await ref.read(repoProvider).allRegionNames();
      if (mounted) setState(() => _knownRegions = names);
    } catch (_) {
      // 拿不到就算了，地区识别会退化成按后缀猜
    }
  }

  /// 标题变化时，做两件静默推断：
  ///   1. 从「3天2夜」推出日期区间
  ///   2. 从「南昌3天2夜」认出地区名
  ///
  /// 刻意不弹提示——用户要求内部做了什么不用展示。
  /// 填出来的值就在页面上，用户看得见也随时能改。
  void _maybeApplyDuration(String text) {
    // ── 1. 时长 → 日期 ──
    final d = parseDuration(text);
    if (d != null && !_datesTouchedByUser) {
      setState(() => _endDate = d.endDateFrom(_startDate));
    }

    // ── 2. 地区名 ──
    // 用户已经填过地区就不覆盖（可能他手动写了更具体的）
    if (_regionCtrl.text.trim().isEmpty) {
      final guess = parseRegion(text, knownRegions: _knownRegions);
      if (guess != null && guess != _regionCtrl.text) {
        setState(() => _regionCtrl.text = guess);
      }
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _regionCtrl.dispose();
    _budgetCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  /// 天数 = 日期差 + 1（含首尾两天）；夜数 = 日期差
  int get _days => _endDate.difference(_startDate).inDays + 1;
  int get _nights => _endDate.difference(_startDate).inDays;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新建行程')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleCtrl,
            onChanged: _maybeApplyDuration,
            decoration: const InputDecoration(
              labelText: '行程名称',
              hintText: '如：南昌 3 天 2 夜',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.title),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _regionCtrl,
            decoration: const InputDecoration(
              labelText: '地区',
              hintText: '如：日本·关西 / 云南·大理',
              helperText: '同一地区共享一份景点库，下次再来直接复用',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.place_outlined),
            ),
          ),
          const SizedBox(height: 20),

          // ── 日期区间 ──
          const _SectionLabel('出行日期'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.flight_takeoff),
              title: const Text('出发'),
              trailing: Text(_ymd(_startDate)),
              onTap: () => _pickDate(isStart: true),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.flight_land),
              title: const Text('返程'),
              trailing: Text(_ymd(_endDate)),
              onTap: () => _pickDate(isStart: false),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 8),
                Text(
                  '共 $_days 天 $_nights 夜（自动计算）',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          TextField(
            controller: _budgetCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '总预算（元）',
              hintText: '如：8000',
              helperText: '可留空，之后在行程里按分类细化预算',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.account_balance_wallet_outlined),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _noteCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
              hintText: '如：看樱花季，注意避开黄金周',
              border: OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(_saving ? '保存中…' : '创建行程'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart ? _startDate : _endDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      // ⚠️ 上限收敛到今天 + 5 年。
      //    原来是 DateTime(2100)：手一滑把返程选到 2100 年，行程天数会变成
      //    两万七千，长图、时长解析、按天循环全都跟着遭殃。
      //    5 年足够规划任何真实行程。
      lastDate: DateTime(DateTime.now().year + 5, 12, 31),
    );
    if (picked == null) return;

    setState(() {
      // 用户一旦手动选了日期，就不再让标题里的时长覆盖它，
      // 否则「改完日期回头补个标题」会把日期顶掉，很恼人。
      _datesTouchedByUser = true;

      if (isStart) {
        _startDate = picked;
        // 出发日不能晚于返程日，自动纠正
        if (_endDate.isBefore(_startDate)) {
          _endDate = _startDate;
        }
      } else {
        _endDate = picked;
        if (_endDate.isBefore(_startDate)) {
          _startDate = _endDate;
        }
      }
    });
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    final region = _regionCtrl.text.trim();

    if (title.isEmpty) {
      _toast('请填写行程名称');
      return;
    }
    if (region.isEmpty) {
      _toast('请填写地区');
      return;
    }
    // 预算填了但不是数字（含负数/全角/乱码）要拦下，
    // 否则宽松解析会静默存成 0 或负数
    final budget = parseYuanInput(_budgetCtrl.text);
    if (!budget.ok) {
      _toast('预算填数字（比如 3000），或留空');
      return;
    }

    setState(() => _saving = true);
    try {
      final repo = ref.read(repoProvider);
      final tripId = await repo.createTrip(
        title: title,
        regionName: region,
        startDate: _startDate,
        endDate: _endDate,
        totalBudgetCents: budget.cents,
        note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      );

      if (!mounted) return;
      // 用 pushReplacement：建完不该能「返回」到创建页
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => TripDetailScreen(tripId: tripId)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('创建失败：$e');
    }
  }

  void _toast(String msg) {
    AppToast.show(context, msg);
  }

  static String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}
