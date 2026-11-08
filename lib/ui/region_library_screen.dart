// ═══════════════════════════════════════════════════════════════
// 景点景点库：地区列表
//
// 这里是「层1 共享景点库」的入口。
// 地区下的景点跨行程复用，去过没去过在这里累积。
// ═══════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import 'app_toast.dart';
import '../data/library_importer.dart';
import '../data/providers.dart';
import 'region_detail_screen.dart';

class RegionLibraryScreen extends ConsumerStatefulWidget {
  const RegionLibraryScreen({super.key});

  @override
  ConsumerState<RegionLibraryScreen> createState() =>
      _RegionLibraryScreenState();
}

class _RegionLibraryScreenState extends ConsumerState<RegionLibraryScreen> {
  bool _importing = false;

  @override
  Widget build(BuildContext context) {
    final regionsAsync = ref.watch(regionsProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _pickAndImport,
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.file_download_outlined),
        label: Text(_importing ? '导入中…' : '导入景点库'),
      ),
      body: regionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('出错了：$e')),
        data: (regions) {
          if (regions.isEmpty) return const _EmptyLibrary();
          // 有数据后就不再显示导入提示了——用户已经知道怎么用
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
            itemCount: regions.length,
            itemBuilder: (context, i) => _RegionCard(region: regions[i]),
          );
        },
      ),
    );
  }

  Future<void> _pickAndImport() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;

    final path = picked.files.single.path;
    if (path == null) {
      _toast('读不到文件路径');
      return;
    }

    setState(() => _importing = true);
    try {
      final db = ref.read(databaseProvider);
      final result = await const LibraryImporter()
          .importFromFile(File(path), db);

      if (!mounted) return;
      ref.invalidate(regionsProvider);
      _toast(
        '导入成功：${result.regionName}\n'
        '新增 ${result.attractionCount + result.foodCount} 个'
        '${result.updatedCount > 0 ? ' · 更新 ${result.updatedCount} 个' : ''}'
        '${result.skipped > 0 ? ' · 跳过 ${result.skipped} 条无名字的' : ''}',
      );
    } on FormatException catch (e) {
      if (!mounted) return;
      _toast('文件格式不对：${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _toast(String msg) {
    AppToast.show(context, msg);
  }
}

class _RegionCard extends ConsumerWidget {
  const _RegionCard({required this.region});

  final Region region;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => RegionDetailScreen(regionId: region.id),
            ),
          );
        },
        // 卡片上只显示「📍 南昌　中国」，不放备注。
        //
        // 备注里是导入时拼的交通/住宿/避雷几段，直接取第一行会显示成
        // 孤零零的「【交通】」，很怪。完整备注在点进去的详情页里能看。
        //
        // ⚠️ 但要**保持原来的卡片高度**：内容少了卡片跟着变矮会显得瘪。
        //    用 minHeight 撑住，有备注没备注都一个高度。
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                const Icon(Icons.place_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    region.name,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(region.country, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.map_outlined,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text('景点库还是空的',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '把整理好的候选库.json 导入进来，\n'
              '以后来同一个地方玩，直接看「哪些去过、哪些没去」',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
