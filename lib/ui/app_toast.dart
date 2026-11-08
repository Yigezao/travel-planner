// ═══════════════════════════════════════════════════════════════
// 轻提示
//
// 替代 SnackBar。SnackBar 有两个问题（用户实测反馈）：
//   1. 出现在屏幕最下方，会盖住底部的内容和按钮
//   2. 停留时间长、要等它走，影响操作流畅度
//
// 这个版本：
//   · 显示在**顶部偏下**（避开 AppBar），不挡底部
//   · 淡入 + 轻微缩放，1.8 秒自动消失
//   · **完全不拦截点击**（IgnorePointer），点别处照常操作
//   · 同一条提示重复触发时只显示一条，不叠加
//
// 用法：AppToast.show(context, '已加入第 2 天 · 午餐');
// ═══════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';

class AppToast {
  AppToast._();

  static OverlayEntry? _current;
  static String? _currentMessage;

  /// 显示一条轻提示
  static void show(
    BuildContext context,
    String message, {
    IconData? icon,
    Duration duration = const Duration(milliseconds: 1800),
  }) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    // 同一条消息正在显示就不重复弹，避免连续点击时闪个不停
    if (_current != null && _currentMessage == message) return;

    _dismiss();

    final entry = OverlayEntry(
      builder: (_) => _ToastWidget(
        message: message,
        icon: icon,
        duration: duration,
        onDone: _dismiss,
      ),
    );

    _current = entry;
    _currentMessage = message;
    overlay.insert(entry);
  }

  static void _dismiss() {
    _current?.remove();
    _current = null;
    _currentMessage = null;
  }
}

class _ToastWidget extends StatefulWidget {
  const _ToastWidget({
    required this.message,
    required this.duration,
    required this.onDone,
    this.icon,
  });

  final String message;
  final IconData? icon;
  final Duration duration;
  final VoidCallback onDone;

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
    // 到时间后先播放退场动画，再通知移除
    Future<void>.delayed(widget.duration, () async {
      if (!mounted) return;
      await _ctrl.reverse();
      if (!mounted) return;
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Positioned(
      // 顶部偏下：避开 AppBar，也不挡底部的按钮和内容
      top: MediaQuery.of(context).padding.top + 76,
      left: 0,
      right: 0,
      child: IgnorePointer(
        // 关键：不拦截任何点击，提示显示期间照常可以操作
        child: FadeTransition(
          opacity: _ctrl,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1.0).animate(
              CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack),
            ),
            child: Center(
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 320),
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.inverseSurface.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.icon ?? Icons.check_circle_outline,
                        size: 18,
                        color: theme.colorScheme.onInverseSurface,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          widget.message,
                          style: TextStyle(
                            color: theme.colorScheme.onInverseSurface,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
