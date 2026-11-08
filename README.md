# Travel Planner · 出行规划 App

> 面向真实使用的行程规划工具：把「选目的地 → 排行程 → 记花费 → 生成海报」串成一条完整链路。
>
> Flutter + Dart 实现，`lib/` 约 2.7 万行；数据层自带本地景点库与坐标转换工具链。

## 功能

- **行程编排**：按天拆分行程，支持景点拖拽排序、时间与时长解析
- **景点库**：内置按城市组织的景点数据，支持导入、打标签、覆盖率检查
- **地图与坐标**：WGS84 ↔ GCJ-02 坐标互转，地图偏移校正与缩放适配
- **消费记录**：按行程/类别记账，自动汇总预算
- **分享海报**：一键生成行程海报，可导出图片

## 目录结构

```text
lib/
├── main.dart                    入口与全局状态
└── ui/
    ├── home_screen.dart         首页：行程列表
    ├── trip_create_screen.dart  新建行程
    ├── trip_detail_screen.dart  行程详情（核心页）
    ├── trip_edit_sheet.dart     行程项编辑
    ├── attraction_edit_screen.dart  景点编辑
    ├── expense_edit_screen.dart 消费记账
    ├── item_edit_sheet.dart     通用条目编辑
    ├── day_map_screen.dart      当日地图
    ├── region_library_screen.dart   景点库
    ├── region_detail_screen.dart    城市/区域详情
    ├── region_map_screen.dart       区域地图
    ├── trip_poster.dart         海报生成
    └── app_toast.dart           轻提示

tools/                            # 数据准备工具链
├── coord_convert.dart           WGS84 / GCJ-02 互转
├── convert_coords_to_gcj.dart   批量坐标转换
├── geocode_library.dart         地理编码补全
├── jsonl_to_library.dart        JSONL → 景点库
├── tag_library.dart             批量打标签
├── coverage_report.dart         覆盖率报表
└── zoom_offset_analysis.dart    地图缩放偏移分析
```

## 运行

```bash
flutter pub get
flutter run
```

## 说明

- 本仓库不含应用图标、内置城市数据与个人行程数据，相关资源需自行提供。
- 坐标转换遵循国内地图坐标系（GCJ-02）规范，仅用于本地展示场景。
