// ═══════════════════════════════════════════════════════════════
// 修改行程信息
//
// 支持改：名称 / 出发返程日期 / 总预算 / 备注 / 状态
//
// ⚠️ 日期缩短时会删掉超出范围的天的内容（并提前告知用户）。
//    不这么做的话会留下「看不见但还在」的孤儿数据，
//    以后再把日期改长，它们会突然冒出来，很困惑。
// ═══════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/exporter.dart';
import '../data/providers.dart';
import 'app_toast.dart';

Future<bool> showTripEditSheet(
  BuildContext context,
  WidgetRef ref,
  Trip trip,
) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _TripEditSheet(trip: trip),
  );
  return result ?? false;
}

class _TripEditSheet extends ConsumerStatefulWidget {
  const _TripEditSheet({required this.trip});

  final Trip trip;

  @override
  ConsumerState<_TripEditSheet> createState() => _TripEditSheetState();
}

class _TripEditSheetState extends ConsumerState<_TripEditSheet> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _budgetCtrl;
  late final TextEditingController _noteCtrl;

  late DateTime _start;
  late DateTime _end;
  late String _status;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final t = widget.trip;
    _titleCtrl = TextEditingController(text: t.title);
    _budgetCtrl = TextEditingController(
      text: t.totalBudgetCents == 0 ? '' : centsToYuan(t.totalBudgetCents),
    );
    _noteCtrl = TextEditingController(text: t.note ?? '');
    _start = t.startDate;
    _end = t.endDate;
    _status = t.status;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _budgetCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  int get _days => _end.difference(_start).inDays + 1;
  int get _nights => _end.difference(_start).inDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text('修改行程',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            const SizedBox(height: 16),

            // ── 名称 ──
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: '行程名称',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // ── 日期 ──
            const Text('日期',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _DateTile(
                    label: '出发',
                    date: _start,
                    onTap: () => _pickDate(isStart: true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DateTile(
                    label: '返程',
                    date: _end,
                    onTap: () => _pickDate(isStart: false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '共 $_days 天 $_nights 夜（自动算）',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),

            // 缩短日期时提前警告会删内容
            if (_days < _originalDays)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    '⚠️ 原来 $_originalDays 天，现在改成 $_days 天。\n'
                    '第 ${_days + 1} 天及之后的安排会被删掉。',
                    style: const TextStyle(fontSize: 12, color: Colors.red),
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // ── 总预算 ──
            TextField(
              controller: _budgetCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: '总预算（元）',
                hintText: '可留空',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // ── 状态 ──
            const Text('状态',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final s in TripStatus.values)
                  ChoiceChip(
                    label: Text(switch (s) {
                      TripStatus.planning => '规划中',
                      TripStatus.ongoing => '出行中',
                      TripStatus.finished => '已结束',
                    }),
                    selected: _status == s.name,
                    onSelected: (_) => setState(() => _status = s.name),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // ── 备注 ──
            TextField(
              controller: _noteCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '备注',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),

            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(_saving ? '保存中…' : '保存'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ],
        ),
      ),
    );
  }

  int get _originalDays => widget.trip.endDate
          .difference(widget.trip.startDate)
          .inDays +
      1;

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _start : _end,
      firstDate: DateTime(2020),
      // 上限同 trip_create_screen：防止手滑选到 2100 年让行程变成两万七千天
      lastDate: DateTime(DateTime.now().year + 5, 12, 31),
    );
    if (picked == null) return;

    setState(() {
      if (isStart) {
        _start = picked;
        if (_end.isBefore(_start)) _end = _start;
      } else {
        _end = picked;
        if (_end.isBefore(_start)) _start = _end;
      }
    });
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      AppToast.show(context, '名称不能为空');
      return;
    }
    // 预算校验：填了但不是数字要拦下（宽松解析会静默存成 0 或负数）
    final budget = parseYuanInput(_budgetCtrl.text);
    if (!budget.ok) {
      AppToast.show(context, '预算填数字（比如 3000），或留空');
      return;
    }

    // 缩短日期时再确认一次——这个操作会删数据
    if (_days < _originalDays) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认缩短行程？'),
          content: Text(
            '第 ${_days + 1} 天及之后的安排会被删除，无法恢复。',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('确认缩短'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _saving = true);
    try {
      final r = await ref.read(repoProvider).updateTripWithDateGuard(
            tripId: widget.trip.id,
            title: title,
            startDate: _start,
            endDate: _end,
            totalBudgetCents: budget.cents,
            note: _noteCtrl.text.trim(),
            status: _status,
          );

      if (!mounted) return;
      AppToast.show(
        context,
        r.removed > 0 ? '已保存（${r.removed} 项超出范围的安排被删掉）' : '已保存',
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.show(context, '保存失败：$e');
    }
  }
}

class _DateTile extends StatelessWidget {
  const _DateTile({
    required this.label,
    required this.date,
    required this.onTap,
  });

  final String label;
  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        child: Text(ymd(date)),
      ),
    );
  }
}
