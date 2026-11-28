import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'state.dart';

/// 扫描页实时数据。放在 ValueNotifier 里，进度刷新只重建 ScanFx，
/// 不用 setState 把整页（列表、按钮、输入框）全重建一遍。
class ScanFxData {
  final String stage;
  final String detail;
  final List<String> recent;
  final double? progress;
  final int hits;
  final int scanned;

  const ScanFxData({
    required this.stage,
    this.detail = '',
    this.recent = const [],
    this.progress,
    this.hits = 0,
    this.scanned = 0,
  });
}

/// 监听 ScanFxData 的薄壳，只重建扫描动效本身。
class ScanFxLive extends StatelessWidget {
  final ValueListenable<ScanFxData> data;
  final double size;
  const ScanFxLive({super.key, required this.data, this.size = 180});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ScanFxData>(
      valueListenable: data,
      builder: (_, d, __) => ScanFx(
        stage: d.stage,
        detail: d.detail,
        recent: d.recent,
        progress: d.progress,
        hits: d.hits,
        scanned: d.scanned,
        size: size,
      ),
    );
  }
}

/// 扫描动效 —— 360 安全卫士 / 火绒那一路风格，但做成澎湃 OS 4 的克制版：
/// 双层反向旋转弧 + 绕圈扫掠光束 + 刻度脉冲 + 呼吸光晕 + 中心盾牌 + 进度环。
///
/// 全部挂在 [Ui.tick] 上只重绘不重建，窗口最小化/失焦也一直在动。
class ScanFx extends StatelessWidget {
  /// 当前阶段文字，如「正在扫描 C:\Users\...」
  final String stage;

  /// 副文本：当前文件名 / 当前子引擎
  final String detail;

  /// 文件名滚动列表（最新在最后），360 / 火绒那种疯狂往下刷的效果
  final List<String> recent;

  /// 0..1；null 表示不确定进度（只转圈）
  final double? progress;

  /// 已命中数
  final int hits;

  /// 已扫描文件数（流式扫描没有总数，就靠这个体现进度）
  final int scanned;

  final double size;

  const ScanFx({
    super.key,
    required this.stage,
    this.detail = '',
    this.recent = const [],
    this.progress,
    this.hits = 0,
    this.scanned = 0,
    this.size = 196,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const blue = Color(0xFF2F7BFF);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepaintBoundary(
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _ScanFxPainter(dark: isDark, progress: progress),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          stage,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 104,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var i = 0; i < recent.length; i++)
                  Opacity(
                    opacity: (0.16 + 0.84 * ((i + 1) / recent.length)).clamp(0.0, 1.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.6, horizontal: 22),
                      child: SizedBox(
                        width: double.infinity,
                        child: Text(
                          recent[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10.5,
                            height: 1.15,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ] else if (detail.isNotEmpty) ...[
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),
        ],
        const SizedBox(height: 7),
        Text(
          progress == null
              ? (scanned > 0
                  ? '已扫 $scanned 个文件${hits > 0 ? " · 已发现 $hits 项" : ""}'
                  : '扫描中…')
              : '${(progress! * 100).clamp(0, 100).toStringAsFixed(1)}%'
                  '${scanned > 0 ? " · 已扫 $scanned 个文件" : ""}'
                  '${hits > 0 ? " · 已发现 $hits 项" : ""}',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: blue,
          ),
        ),
      ],
    );
  }
}

class _ScanFxPainter extends CustomPainter {
  _ScanFxPainter({required this.dark, this.progress}) : super(repaint: Ui.tick);

  final bool dark;
  final double? progress;

  static const _blue = Color(0xFF2F7BFF);
  static const _light = Color(0xFF7FB4FF);

  @override
  void paint(Canvas canvas, Size size) {
    final t = Ui.tick.value;
    final center = size.center(Offset.zero);
    final base = size.shortestSide / 2 - 16;
    if (base <= 8) return;

    _halo(canvas, center, base, t);
    _ring(canvas, center, base);
    _ticks(canvas, center, base, t);
    _arc(canvas, center, base, t * 1.55, 0.55, 3.2, _blue);
    _arc(canvas, center, base - 7, -t * 2.35, 0.42, 2.2, _light);
    _sweep(canvas, center, base, t);
    _progress(canvas, center, base);
    _shield(canvas, center, base, t);
  }

  /// 呼吸光晕
  void _halo(Canvas canvas, Offset c, double r, double t) {
    final breathe = 0.5 + 0.5 * math.sin(t * 1.25);
    canvas.drawCircle(
      c,
      r * (0.92 + 0.10 * breathe),
      Paint()
        ..shader = RadialGradient(
          colors: [
            _blue.withOpacity(dark ? 0.15 : 0.11),
            _blue.withOpacity(0.0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r * 1.06)),
    );
  }

  /// 底环
  void _ring(Canvas canvas, Offset c, double r) {
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = (dark ? Colors.white : Colors.black).withOpacity(0.08),
    );
  }

  /// 刻度脉冲
  void _ticks(Canvas canvas, Offset c, double r, double t) {
    for (var i = 0; i < 36; i++) {
      final a = i * math.pi / 18 + t * 0.28;
      final pulse = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * 2.4 + i * 0.55));
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        c + dir * (r - 9),
        c + dir * (r - 4 - 2 * pulse),
        Paint()
          ..color = _blue.withOpacity(0.20 * pulse)
          ..strokeWidth = 1,
      );
    }
  }

  /// 旋转弧
  void _arc(Canvas canvas, Offset c, double r, double start, double sweep,
      double width, Color color) {
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..color = color.withOpacity(0.9),
    );
  }

  /// 绕圈扫掠光束
  void _sweep(Canvas canvas, Offset c, double r, double t) {
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = SweepGradient(
          colors: [
            _blue.withOpacity(0.0),
            _blue.withOpacity(dark ? 0.24 : 0.17),
            _blue.withOpacity(0.0),
          ],
          stops: const [0.0, 0.10, 0.26],
          transform: GradientRotation(t * 2.1),
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
  }

  /// 进度环
  void _progress(Canvas canvas, Offset c, double r) {
    final p = progress;
    if (p == null) return;
    final rr = r + 9;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: rr),
      -math.pi / 2,
      2 * math.pi * p.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..shader = const SweepGradient(
          colors: [Color(0xFF4B96FF), Color(0xFF1C63E0)],
        ).createShader(Rect.fromCircle(center: c, radius: rr)),
    );
  }

  /// 中心盾牌 + 呼吸描边
  void _shield(Canvas canvas, Offset c, double r, double t) {
    final s = r * 0.36;
    final path = Path()
      ..moveTo(c.dx, c.dy - s * 1.15)
      ..lineTo(c.dx + s * 0.86, c.dy - s * 0.62)
      ..lineTo(c.dx + s * 0.86, c.dy + s * 0.22)
      ..quadraticBezierTo(c.dx + s * 0.86, c.dy + s * 0.92, c.dx, c.dy + s * 1.18)
      ..quadraticBezierTo(c.dx - s * 0.86, c.dy + s * 0.92, c.dx - s * 0.86, c.dy + s * 0.22)
      ..lineTo(c.dx - s * 0.86, c.dy - s * 0.62)
      ..close();

    final rect = Rect.fromCircle(center: c, radius: s * 1.3);
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF5AA6FF), Color(0xFF2F7BFF), Color(0xFF1B5FD0)],
        ).createShader(rect),
    );
    // 顶部高光
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withOpacity(0.52), Colors.white.withOpacity(0.0)],
        ).createShader(rect),
    );

    // 对勾
    canvas.drawPath(
      Path()
        ..moveTo(c.dx - s * 0.40, c.dy + s * 0.02)
        ..lineTo(c.dx - s * 0.08, c.dy + s * 0.38)
        ..lineTo(c.dx + s * 0.46, c.dy - s * 0.34),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.16
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 呼吸描边
    final pulse = 0.5 + 0.5 * math.sin(t * 2.2);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _light.withOpacity(0.20 + 0.30 * pulse),
    );
  }

  @override
  bool shouldRepaint(covariant _ScanFxPainter old) =>
      old.progress != progress || old.dark != dark;
}
