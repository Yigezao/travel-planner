// ═══════════════════════════════════════════════════════════════
// 录入一站（时间线上的一个节点）
// ═══════════════════════════════════════════════════════════════

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_toast.dart';

import '../data/database.dart';
import '../data/exporter.dart';
import '../data/providers.dart';

class ItemEditScreen extends ConsumerStatefulWidget {
  const ItemEditScreen({
    super.key,
    required this.tripId,
    required this.dayIndex,
    this.timeBlock,
    this.itemId,
  });

  final String tripId;
  final int dayIndex;

  /// 从哪个时段模块进来的。为空则让用户在页面上选。
  final TimeBlock? timeBlock;

  /// 为空 = 新增；否则是编辑已有条目
  final String? itemId;

  bool get isNew => itemId == null;

  @override
  ConsumerState<ItemEditScreen> createState() => _ItemEditScreenState();
}

class _ItemEditScreenState extends ConsumerState<ItemEditScreen> {
  final _nameCtrl = TextEditingController();
  final _transportCostCtrl = TextEditingController();
  final _transportMinCtrl = TextEditingController();
  final _hotelNameCtrl = TextEditingController();
  final _hotelAddrCtrl = TextEditingController();
  final _hotelCostCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  TimeOfDay? _arrive;
  TimeOfDay? _leave;
  TransportMode? _mode;
  TimeBlock? _block;
  bool _saving = false;

  /// 这一天实际存在哪些时段（用户删过/插过之后未必是六个全的）。
  ///
  /// ⚠️ 时段选项必须来自这里，不能用 TimeBlock.values 全量——
  ///    否则用户可以把条目改到「这天已经删掉的时段」里，
  ///    保存后条目从列表里消失（数据还在，但这天不渲染那个时段）。
  List<TimeBlock> _availableBlocks = TimeBlock.values;

  @override
  void initState() {
    super.initState();
    _block = widget.timeBlock;
    _loadAvailableBlocks();
    if (!widget.isNew) _loadExisting();
  }

  Future<void> _loadAvailableBlocks() async {
    final blocks =
        await ref.read(repoProvider).blocksOf(widget.tripId, widget.dayIndex);
    if (!mounted) return;
    setState(() {
      _availableBlocks = blocks;
      // 当前时段如果不在列表里（极端情况），补进去保证仍能显示/保存
      final b = _block;
      if (b != null && !_availableBlocks.contains(b)) {
        _availableBlocks = [..._availableBlocks, b];
      }
    });
  }

  /// 编辑已有条目：把现值填进表单
  Future<void> _loadExisting() async {
    final repo = ref.read(repoProvider);
    final items = await repo.watchItems(widget.tripId).first;
    final it = items.where((x) => x.id == widget.itemId).firstOrNull;
    if (it == null || !mounted) return;

    setState(() {
      _nameCtrl.text = it.customName ?? '';
      _noteCtrl.text = it.note ?? '';
      _hotelNameCtrl.text = it.hotelName ?? '';
      _hotelAddrCtrl.text = it.hotelAddress ?? '';
      if (it.transportCostCents > 0) {
        _transportCostCtrl.text = centsToYuan(it.transportCostCents);
      }
      if (it.transportMin != null) {
        _transportMinCtrl.text = it.transportMin.toString();
      }
      if (it.hotelCostCents > 0) {
        _hotelCostCtrl.text = centsToYuan(it.hotelCostCents);
      }
      _block = it.timeBlock == null
          ? widget.timeBlock
          : TimeBlock.values
              .where((b) => b.name == it.timeBlock)
              .firstOrNull;
      // 条目当前所在的时段若不在这一天的时段清单里（历史数据），
      // 补进选项里，否则保存时会被迫换时段
      final b = _block;
      if (b != null && !_availableBlocks.contains(b)) {
        _availableBlocks = [..._availableBlocks, b];
      }
      _mode = it.transportMode == null
          ? null
          : TransportMode.values
              .where((m) => m.name == it.transportMode)
              .firstOrNull;
      _arrive = _parseTime(it.arriveTime);
      _leave = _parseTime(it.leaveTime);
    });
  }

  static TimeOfDay? _parseTime(String? s) {
    if (s == null || !s.contains(':')) return null;
    final p = s.split(':');
    final h = int.tryParse(p[0]);
    final m = int.tryParse(p.length > 1 ? p[1] : '0');
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _transportCostCtrl.dispose();
    _transportMinCtrl.dispose();
    _hotelNameCtrl.dispose();
    _hotelAddrCtrl.dispose();
    _hotelCostCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 时段名可能被用户改过（「上午」→「逛街」），在 build 开头取一次
    final labels = ref.watch(blockLabelsProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew
            ? '第 ${widget.dayIndex} 天 · 加一站'
            : '编辑这一站'),
        actions: [
          if (!widget.isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除这一站',
              onPressed: _confirmDelete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '去哪 / 做什么',
              hintText: '如：清水寺 / 机场→酒店',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.place_outlined),
            ),
          ),
          const SizedBox(height: 20),

          // ── 时段模块 ──
          // 选项 = 这天实际存在的时段（删过/插过就不是六个了）
          const _Label('时段'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _availableBlocks.map((b) {
              final selected = _block == b;
              return ChoiceChip(
                label: Text(labels?[b] ?? kTimeBlockLabels[b]!),
                selected: selected,
                onSelected: (_) => setState(() => _block = b),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),

          // ── 时间（可选）──
          const _Label('时间（可选，不填也行）'),
          Row(
            children: [
              Expanded(
                child: _TimeField(
                  label: '到达',
                  value: _arrive,
                  onPick: () => _pickTime(isArrive: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TimeField(
                  label: '离开',
                  value: _leave,
                  onPick: () => _pickTime(isArrive: false),
                ),
              ),
            ],
          ),
          if (_arrive != null || _leave != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() {
                  _arrive = null;
                  _leave = null;
                }),
                child: const Text('清空时间'),
              ),
            ),
          const SizedBox(height: 12),

          // ── 交通 ──
          const _Label('交通'),
          DropdownButtonFormField<TransportMode>(
            initialValue: _mode,
            decoration: const InputDecoration(
              labelText: '怎么去',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.directions_transit),
            ),
            items: TransportMode.values
                .map((m) => DropdownMenuItem(
                      value: m,
                      child: Text(transportLabel(m.name)),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _mode = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _transportCostCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: '花费（元）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _transportMinCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '耗时（分钟）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── 住宿 ──
          const _Label('住宿（当天最后一站再填）'),
          TextField(
            controller: _hotelNameCtrl,
            decoration: const InputDecoration(
              labelText: '酒店名',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.hotel),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hotelAddrCtrl,
            decoration: const InputDecoration(
              labelText: '地址',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hotelCostCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '住宿花费（元）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),

          TextField(
            controller: _noteCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
              hintText: '如：需要提前预约 / 周三闭馆',
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
            label: Text(_saving ? '保存中…' : '保存这一站'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickTime({required bool isArrive}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isArrive
          ? (_arrive ?? const TimeOfDay(hour: 9, minute: 0))
          : (_leave ?? const TimeOfDay(hour: 11, minute: 0)),
    );
    if (picked == null) return;
    setState(() {
      if (isArrive) {
        _arrive = picked;
      } else {
        _leave = picked;
      }
    });
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      AppToast.show(context, '请填写去哪 / 做什么');
      return;
    }

    // ⚠️ 金额、耗时先校验再保存。
    //    以前宽松解析会把这些静默变成 0：输入「-50」存成 -5000 分、
    //    输入「abc」或全角数字存成 0 元，用户以为存上了。
    final transportCost = parseYuanInput(_transportCostCtrl.text);
    if (!transportCost.ok) {
      AppToast.show(context, '交通花费填数字（比如 30），或留空');
      return;
    }
    final hotelCost = parseYuanInput(_hotelCostCtrl.text);
    if (!hotelCost.ok) {
      AppToast.show(context, '住宿花费填数字（比如 250），或留空');
      return;
    }
    final transportMinText = _transportMinCtrl.text.trim();
    final transportMin = int.tryParse(transportMinText);
    if (transportMinText.isNotEmpty &&
        (transportMin == null || transportMin < 0)) {
      AppToast.show(context, '交通耗时填整数分钟（比如 25），或留空');
      return;
    }

    setState(() => _saving = true);
    try {
      final repo = ref.read(repoProvider);

      if (widget.isNew) {
        // 新增：序号接着该模块已有的往下排
        final seq = await repo.nextSeqInBlock(
            widget.tripId, widget.dayIndex, _block);

        await repo.addItem(
          tripId: widget.tripId,
          dayIndex: widget.dayIndex,
          seq: seq,
          timeBlock: _block,
          customName: name,
          arriveTime: _arrive == null ? null : _fmt(_arrive!),
          leaveTime: _leave == null ? null : _fmt(_leave!),
          transportMode: _mode,
          transportCostCents: transportCost.cents,
          transportMin: transportMin,
          hotelName: _hotelNameCtrl.text.trim().isEmpty
              ? null
              : _hotelNameCtrl.text.trim(),
          hotelAddress: _hotelAddrCtrl.text.trim().isEmpty
              ? null
              : _hotelAddrCtrl.text.trim(),
          hotelCostCents: hotelCost.cents,
          note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
        );
      } else {
        // 编辑：只更新内容，不动 seq（保持排序稳定）
        await repo.updateItem(
          widget.itemId!,
          ItineraryItemsCompanion(
            timeBlock: Value(_block?.name),
            customName: Value(name),
            arriveTime: Value(_arrive == null ? null : _fmt(_arrive!)),
            leaveTime: Value(_leave == null ? null : _fmt(_leave!)),
            transportMode: Value(_mode?.name),
            transportCostCents: Value(transportCost.cents),
            transportMin: Value(transportMin),
            hotelName: Value(_hotelNameCtrl.text.trim().isEmpty
                ? null
                : _hotelNameCtrl.text.trim()),
            hotelAddress: Value(_hotelAddrCtrl.text.trim().isEmpty
                ? null
                : _hotelAddrCtrl.text.trim()),
            hotelCostCents: Value(hotelCost.cents),
            note: Value(
                _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim()),
          ),
        );
      }

      if (!mounted) return;
      AppToast.show(context, widget.isNew ? '已添加' : '已保存');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.show(context, '保存失败：$e');
    }
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这一站？'),
        content: Text(_nameCtrl.text.trim()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref.read(repoProvider).deleteItem(widget.itemId!);
    if (!mounted) return;
    AppToast.show(context, '已删除');
    Navigator.of(context).pop(true);
  }

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.value,
    required this.onPick,
  });

  final String label;
  final TimeOfDay? value;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPick,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.schedule),
        ),
        child: Text(
          value == null
              ? '未选'
              : '${value!.hour.toString().padLeft(2, '0')}:${value!.minute.toString().padLeft(2, '0')}',
        ),
      ),
    );
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
