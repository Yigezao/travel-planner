// ═══════════════════════════════════════════════════════════════
// 地点编辑：新增 / 修改 / 删除
//
// 标签是这里的核心：
//   · 一个地点可以打任意多个标签（「早餐」「水煮」「运动强度低」）
//   · 预设了一批常用标签，点一下就加，也能手打新的
//   · 标签用途：景点库筛选、全景地图筛选、
//     以及**加入某模块时优先推荐匹配该模块标签的地点**
// ═══════════════════════════════════════════════════════════════

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/exporter.dart';
import '../data/providers.dart';
import 'app_toast.dart';

/// 预设标签。分几组，方便找。
///
/// ⚠️ 「早餐」「午餐」「晚餐」这三个是**特殊**的：
///    它们和时段模块同名，加入模块时会优先匹配。
///    改这三个字的时候要同步改 region_map_screen 里的匹配逻辑。
const List<({String group, List<String> tags})> kPresetTags = [
  (
    group: '餐次',
    tags: ['早餐', '午餐', '晚餐', '夜宵', '小吃'],
  ),
  (
    group: '类型',
    tags: ['景点', '美食', '茶饮', '甜品', '博物馆', '街区', '公园', '夜景', '拍照点'],
  ),
  (
    group: '运动强度',
    tags: ['运动强度低', '运动强度中', '运动强度高'],
  ),
  (
    group: '其他',
    tags: ['必去', '需预约', '排队久', '适合雨天', '辣'],
  ),
];

class AttractionEditScreen extends ConsumerStatefulWidget {
  const AttractionEditScreen({
    super.key,
    required this.regionId,
    this.attractionId,
  });

  final String regionId;

  /// 为空 = 新增；否则是编辑
  final String? attractionId;

  bool get isNew => attractionId == null;

  @override
  ConsumerState<AttractionEditScreen> createState() =>
      _AttractionEditScreenState();
}

class _AttractionEditScreenState extends ConsumerState<AttractionEditScreen> {
  final _nameCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _ticketCtrl = TextEditingController();
  final _durationCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _tagCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();

  String? _kind;
  final Set<String> _tags = {};
  int? _recommendLevel;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.isNew) {
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final repo = ref.read(repoProvider);
    final all = await repo.attractionsOf(widget.regionId);
    final a = all.where((x) => x.id == widget.attractionId).firstOrNull;

    if (a != null) {
      _nameCtrl.text = a.name;
      _categoryCtrl.text = a.category ?? '';
      _addressCtrl.text = a.address ?? '';
      _noteCtrl.text = a.note ?? '';
      _kind = a.kind;
      _recommendLevel = a.recommendLevel;
      if (a.ticketPriceCents > 0) {
        _ticketCtrl.text = centsToYuan(a.ticketPriceCents);
      }
      if (a.suggestDurationMin != null) {
        // 直接填分钟数，不做取整——库里本来就是分钟
        _durationCtrl.text = a.suggestDurationMin!.toString();
      }
      if (a.lat != null) _latCtrl.text = a.lat!.toString();
      if (a.lng != null) _lngCtrl.text = a.lng!.toString();

      final tags = await repo.tagsOf(a.id);
      _tags.addAll(tags);
    }

    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _categoryCtrl.dispose();
    _addressCtrl.dispose();
    _ticketCtrl.dispose();
    _durationCtrl.dispose();
    _noteCtrl.dispose();
    _tagCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? '新增地点' : '编辑地点'),
        actions: [
          if (!widget.isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: _confirmDelete,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── 名字 ──
                TextField(
                  controller: _nameCtrl,
                  autofocus: widget.isNew,
                  decoration: const InputDecoration(
                    labelText: '名字',
                    hintText: '如：小罗子汤店 / 滕王阁',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.place_outlined),
                  ),
                ),
                const SizedBox(height: 16),

                // ── 吃 / 玩 ──
                const _Label('是哪一类'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final k in PlaceKind.values)
                      ChoiceChip(
                        label: Text(k == PlaceKind.eat ? '🍜 吃' : '🏛 玩'),
                        selected: _kind == k.name,
                        onSelected: (sel) =>
                            setState(() => _kind = sel ? k.name : null),
                      ),
                  ],
                ),
                const SizedBox(height: 16),

                TextField(
                  controller: _categoryCtrl,
                  decoration: const InputDecoration(
                    labelText: '细分（可选）',
                    hintText: '如：景点 / 早餐 / 茶饮',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),

                // ── 推荐星级 ──
                const _Label('推荐星级（选填，排序和列表会显示）'),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var lv = 1; lv <= 5; lv++)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          (_recommendLevel ?? 0) >= lv
                              ? Icons.star
                              : Icons.star_border,
                          size: 26,
                          color: const Color(0xFFE8A840),
                        ),
                        // 点当前最高那颗 = 取消星级
                        onPressed: () => setState(() {
                          _recommendLevel =
                              (_recommendLevel == lv) ? null : lv;
                        }),
                      ),
                    if (_recommendLevel != null)
                      TextButton(
                        onPressed: () =>
                            setState(() => _recommendLevel = null),
                        child: const Text('清除',
                            style: TextStyle(fontSize: 12)),
                      ),
                  ],
                ),
                const SizedBox(height: 16),

                TextField(
                  controller: _addressCtrl,
                  decoration: const InputDecoration(
                    labelText: '地址',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.location_on_outlined),
                  ),
                ),
                const SizedBox(height: 16),

                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ticketCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                          labelText: '门票/人均（元）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _durationCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          // ⚠️ 单位是**分钟**，和数据库字段一致。
                          //    之前这里标「小时」但按整数存，1.5 小时的景点
                          //    会被取整成 1 小时，精度就丢了。
                          labelText: '预计游玩（分钟）',
                          hintText: '90',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ══ 标签 ══
                const _Label('标签（可多选，也能自己加）'),
                if (_tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final t in _tags.toList()..sort())
                          InputChip(
                            label: Text(t),
                            onDeleted: () => setState(() => _tags.remove(t)),
                          ),
                      ],
                    ),
                  ),
                for (final group in kPresetTags) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Text(
                      group.group,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in group.tags)
                        FilterChip(
                          label: Text(t),
                          selected: _tags.contains(t),
                          onSelected: (sel) => setState(() {
                            if (sel) {
                              _tags.add(t);
                            } else {
                              _tags.remove(t);
                            }
                          }),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _tagCtrl,
                        decoration: const InputDecoration(
                          labelText: '加一个自定义标签',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _addCustomTag(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _addCustomTag,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // ── 经纬度 ──
                const _Label('经纬度（可选，地图要用）'),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _latCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        decoration: const InputDecoration(
                          labelText: '纬度',
                          hintText: '28.68',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _lngCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        decoration: const InputDecoration(
                          labelText: '经度',
                          hintText: '115.88',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                TextField(
                  controller: _noteCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '备注',
                    hintText: '价格、避坑、怎么去…',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),

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

  void _addCustomTag() {
    final t = _tagCtrl.text.trim();
    if (t.isEmpty) return;
    setState(() {
      _tags.add(t);
      _tagCtrl.clear();
    });
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      AppToast.show(context, '请填写名字');
      return;
    }

    // ⚠️ 数字字段必须**先校验再保存**。
    //
    //    以前是直接 tryParse 然后写库：输入「28.68度」「1.5」「90分钟」时
    //    tryParse 返回 null，代码就把 null **静默写进去**——用户只是想改个
    //    地址，原有经纬度/建议时长就被清空了，提示还显示「已保存」。
    //    留空是「有意清除」，填了但格式不对则必须拦下来。
    final durationText = _durationCtrl.text.trim();
    final duration = int.tryParse(durationText);
    if (durationText.isNotEmpty && (duration == null || duration <= 0)) {
      AppToast.show(context, '建议时长填整数分钟（比如 90），或留空');
      return;
    }

    final latText = _latCtrl.text.trim();
    final lngText = _lngCtrl.text.trim();
    final lat = double.tryParse(latText);
    final lng = double.tryParse(lngText);
    if (latText.isNotEmpty && lat == null) {
      AppToast.show(context, '纬度填数字（比如 28.6813），或留空');
      return;
    }
    if (lngText.isNotEmpty && lng == null) {
      AppToast.show(context, '经度填数字（比如 115.8812），或留空');
      return;
    }

    // 门票：填了但不是数字（含负数、全角数字、乱码）要拦下，
    // 不能让宽松解析把它静默变成 0（0 在界面上的含义是「免费」）
    final ticket = parseYuanInput(_ticketCtrl.text);
    if (!ticket.ok) {
      AppToast.show(context, '门票填数字（比如 50），或留空');
      return;
    }

    setState(() => _saving = true);
    try {
      final repo = ref.read(repoProvider);

      // 单位是分钟，直接存，**不要乘 60**。
      // 这里踩过坑：输入框读出来是分钟，保存时又乘了 60，
      // 结果「2 小时」的景点存成 120 小时。
      final durationMin =
          (duration != null && duration > 0) ? duration : null;

      String? id = widget.attractionId;
      if (widget.isNew) {
        id = await repo.addAttraction(
          regionId: widget.regionId,
          name: name,
          kind: _kind,
          category: _categoryCtrl.text.trim().isEmpty
              ? null
              : _categoryCtrl.text.trim(),
          address:
              _addressCtrl.text.trim().isEmpty ? null : _addressCtrl.text.trim(),
          lat: lat,
          lng: lng,
          suggestDurationMin: durationMin,
          recommendLevel: _recommendLevel,
          ticketPriceCents: ticket.cents,
          note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
        );
      } else {
        await repo.updateAttraction(
          AttractionsCompanion(
            id: Value(id!),
            name: Value(name),
            kind: Value(_kind),
            category: Value(_categoryCtrl.text.trim().isEmpty
                ? null
                : _categoryCtrl.text.trim()),
            address: Value(_addressCtrl.text.trim().isEmpty
                ? null
                : _addressCtrl.text.trim()),
            lat: Value(lat),
            lng: Value(lng),
            suggestDurationMin: Value(durationMin),
            recommendLevel: Value(_recommendLevel),
            ticketPriceCents: Value(ticket.cents),
            note: Value(_noteCtrl.text.trim().isEmpty
                ? null
                : _noteCtrl.text.trim()),
          ),
        );
      }

      // 标签：用户手动保存的，source 记成 user——
      // 重导景点库时只清 system 标签，不会冲掉这些
      await repo.setTags(id, _tags.toList(), source: 'user');

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
        title: const Text('删除这个地点？'),
        content: Text(_nameCtrl.text.trim()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref.read(repoProvider).deleteAttraction(widget.attractionId!);
    if (!mounted) return;
    AppToast.show(context, '已删除');
    Navigator.of(context).pop(true);
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
