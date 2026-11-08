// ═══════════════════════════════════════════════════════════════
// 记一笔支出
//
// 三个字段是「算账」的关键，别省：
//   · 分类   —— 超支提醒按分类做
//   · 付款人 —— 事后结算谁该还谁
//   · 是否计划 —— 区分「提前订的」和「当场花的」
// ═══════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import 'app_toast.dart';
import '../data/exporter.dart';
import '../data/providers.dart';

class ExpenseEditScreen extends ConsumerStatefulWidget {
  const ExpenseEditScreen({
    super.key,
    required this.tripId,
    this.defaultDate,
  });

  final String tripId;

  /// 默认记账日期。传行程的起始日——
  /// 补录行程里的账时，不用每次都点回那几天。
  /// 为空则用今天。
  final DateTime? defaultDate;

  @override
  ConsumerState<ExpenseEditScreen> createState() => _ExpenseEditScreenState();
}

class _ExpenseEditScreenState extends ConsumerState<ExpenseEditScreen> {
  final _nameCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  /// ⚠️ 故意**不预填** '1.0'。
  ///
  /// 以前默认就是 1.0：用户选了 JPY 却忘了改，1 日元就按 1 元人民币入账，
  /// 金额直接放大 100 倍，而且没有任何提示。留空能让「没填」这件事显形
  /// ——预览区不显示折算结果、保存时也会拦下来。
  final _rateCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  ExpenseCategory _category = ExpenseCategory.food;
  Payer _payer = Payer.me;
  late DateTime _payDate = widget.defaultDate ?? DateTime.now();
  String _currency = 'CNY';
  bool _isPlanned = false;
  bool _saving = false;

  static const _currencies = ['CNY', 'JPY', 'THB', 'USD', 'EUR', 'HKD', 'KRW'];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _amountCtrl.dispose();
    _rateCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  bool get _isForeign => _currency != 'CNY';

  /// 汇率（1 外币 = ? 人民币）。未填 / 乱填 / ≤0 一律返回 null，
  /// **不用 1.0 兜底**——那会把日元放大 100 倍。
  double? get _rate {
    final v = double.tryParse(_rateCtrl.text.trim());
    if (v == null || v <= 0 || !v.isFinite) return null;
    return v;
  }

  /// 外币时显示换算成人民币的结果，避免填完不知道花了多少。
  /// 汇率没填好时返回 null，由界面提示「先填汇率」而不是给个错数字。
  int? get _finalCents {
    final raw = tryYuanToCents(_amountCtrl.text) ?? 0;
    if (!_isForeign) return raw;
    final r = _rate;
    if (r == null) return null;
    return (raw * r).round();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('记一笔')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '花在哪',
              hintText: '如：清水寺门票 / 拉面午饭 / 机票',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.shopping_bag_outlined),
            ),
          ),
          const SizedBox(height: 16),

          // ── 金额 + 币种 ──
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}), // 触发换算显示更新
                  decoration: const InputDecoration(
                    labelText: '金额',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.attach_money),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  initialValue: _currency,
                  decoration: const InputDecoration(
                    labelText: '币种',
                    border: OutlineInputBorder(),
                  ),
                  items: _currencies
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) => setState(() => _currency = v ?? 'CNY'),
                ),
              ),
            ],
          ),

          // 外币时才显示汇率字段——人民币时显示它只会让人困惑
          if (_isForeign) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _rateCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '汇率（1 $_currency = ? 人民币）',
                helperText: '按记账当天的汇率填。存下来后不会被日后汇率变化影响',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calculate_outlined, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    // 汇率没填好时不给数字，明确让用户去填 —— 给个
                    // 按 1.0 算出来的错数字比不给更糟
                    _finalCents == null
                        ? '先填上面的汇率，这里才会显示折合多少'
                        : '折合 ¥${centsToYuan(_finalCents!)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 20),
          const _Label('分类'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ExpenseCategory.values.map((c) {
              final selected = _category == c;
              return ChoiceChip(
                label: Text(categoryLabel(c.name)),
                selected: selected,
                onSelected: (_) => setState(() => _category = c),
              );
            }).toList(),
          ),

          const SizedBox(height: 20),
          const _Label('谁付的'),
          Wrap(
            spacing: 8,
            children: Payer.values.map((p) {
              final selected = _payer == p;
              return ChoiceChip(
                label: Text(payerLabel(p.name)),
                selected: selected,
                onSelected: (_) => setState(() => _payer = p),
              );
            }).toList(),
          ),

          const SizedBox(height: 20),
          const _Label('日期'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.event),
              title: Text(
                '${_payDate.year}-${_payDate.month.toString().padLeft(2, '0')}-${_payDate.day.toString().padLeft(2, '0')}',
              ),
              onTap: _pickDate,
            ),
          ),

          const SizedBox(height: 12),
          SwitchListTile(
            value: _isPlanned,
            onChanged: (v) => setState(() => _isPlanned = v),
            title: const Text('这是提前计划的支出'),
            subtitle: const Text('如机票、酒店。标记后能在预订期就发现超预算'),
            contentPadding: EdgeInsets.zero,
          ),

          const SizedBox(height: 12),
          TextField(
            controller: _noteCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
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
            label: Text(_saving ? '保存中…' : '保存'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _payDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _payDate = picked);
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast('请填写花在哪');
      return;
    }
    if (_amountCtrl.text.trim().isEmpty) {
      _toast('请填写金额');
      return;
    }
    // ⚠️ 金额必须能解析成数字且大于 0——
    //    yuanToCents 会把「abc」当 0 元存进去，用户浑然不觉
    final parsed = tryYuanToCents(_amountCtrl.text);
    if (parsed == null) {
      _toast('金额看不懂：「${_amountCtrl.text}」，请填数字');
      return;
    }
    if (parsed <= 0) {
      _toast('金额要大于 0');
      return;
    }
    // 外币必须填了有效汇率才能存。
    // 以前是 `?? 1.0` 兜底：选了 JPY 忘了改，1 日元按 1 元人民币入账，
    // 金额放大 100 倍且毫无提示。
    if (_isForeign && _rate == null) {
      _toast('请填汇率（1 $_currency 折合多少人民币），比如日元约 0.048');
      return;
    }

    setState(() => _saving = true);
    try {
      await ref.read(repoProvider).addExpense(
            tripId: widget.tripId,
            itemName: name,
            // 上面已经校验过汇率，这里 _finalCents 一定不是 null；
            // 用 ! 而不是再兜一次 1.0（兜底正是原来的 bug）
            amountCents: _finalCents!,
            category: _category,
            payer: _payer,
            payDate: _payDate,
            currency: _currency,
            exchangeRate: _isForeign ? _rate! : 1.0,
            isPlanned: _isPlanned,
            note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
          );

      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$e');
    }
  }

  void _toast(String msg) {
    AppToast.show(context, msg);
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

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
