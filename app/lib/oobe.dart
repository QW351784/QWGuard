import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 启动 / 完成引导后的入场动画。
///
/// 参考澎湃 OS 开机完成那一下的观感：光环先聚、logo 定住、
/// 然后整幅画面收进中心并炸开一圈白光，桌面从虚化里落定 ——
/// 不是「往上挪一点然后淡出」那种普通转场。
class OobeIntro extends StatefulWidget {
  final VoidCallback onDone;
  const OobeIntro({super.key, required this.onDone});

  @override
  State<OobeIntro> createState() => _OobeIntroState();
}

class _OobeIntroState extends State<OobeIntro> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) widget.onDone();
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    const accent = Color(0xFF2F7BFF);

    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = _c.value;

        final glowT = Curves.easeOutCubic.transform(Interval(0.0, 0.50).transform(t));
        final logoT = Interval(0.12, 0.55).transform(t);
        final logoScale = 0.86 + 0.14 * Curves.easeOutBack.transform(logoT);
        final textT = Curves.easeOutCubic.transform(Interval(0.34, 0.72).transform(t));
        final outT = Interval(0.80, 1.0).transform(t);
        final collapse = Curves.easeInCubic.transform(outT);
        final flash = Interval(0.86, 1.0).transform(t);

        return ColoredBox(
          color: dark ? const Color(0xFF0F1218) : const Color(0xFFF7FAFF),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: (glowT * (1 - collapse)).clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 1.0 - 0.55 * collapse,
                  child: Container(
                    width: 220 + 340 * glowT,
                    height: 220 + 340 * glowT,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          accent.withOpacity(0.28),
                          accent.withOpacity(0.06),
                          accent.withOpacity(0.0),
                        ],
                        stops: const [0.0, 0.45, 1.0],
                      ),
                    ),
                  ),
                ),
              ),

              Opacity(
                opacity: (1.0 - collapse * collapse * 0.92).clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 1.0 - 0.38 * collapse,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.scale(
                        scale: logoScale,
                        child: SizedBox(
                          width: 112,
                          height: 112,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Transform.rotate(
                                angle: t * math.pi * 2.0,
                                child: CustomPaint(
                                  size: const Size(112, 112),
                                  painter: _RingPainter(
                                    color: accent.withOpacity(dark ? 0.34 : 0.40),
                                  ),
                                ),
                              ),
                              Container(
                                width: 84,
                                height: 84,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [Color(0xFF5AA0FF), Color(0xFF2F7BFF)],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: accent.withOpacity(0.40),
                                      blurRadius: 34,
                                      spreadRadius: 2,
                                      offset: const Offset(0, 12),
                                    ),
                                  ],
                                ),
                                child: const Icon(Icons.shield_rounded, color: Colors.white, size: 42),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 26),
                      Opacity(
                        opacity: textT,
                        child: Transform.translate(
                          offset: Offset(0, 12 * (1 - textT)),
                          child: Text(
                            'QW 安全电脑管家',
                            style: TextStyle(
                              fontSize: 25,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2 + 6.0 * (1 - textT),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Opacity(
                        opacity: textT * 0.7,
                        child: Transform.translate(
                          offset: Offset(0, 12 * (1 - textT)),
                          child: Text(
                            '正在准备你的安全环境',
                            style: TextStyle(
                              fontSize: 12.5,
                              letterSpacing: 2.4,
                              color: dark ? Colors.white38 : Colors.black38,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              if (flash > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          radius: 0.10 + 1.45 * Curves.easeOutQuart.transform(flash),
                          colors: [
                            Colors.white.withOpacity(0.62 * (1 - flash)),
                            Colors.white.withOpacity(0.0),
                          ],
                          stops: const [0.0, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 两段弧的细环：不像整圈描边那样死板，转动时能看出方向
class _RingPainter extends CustomPainter {
  final Color color;
  _RingPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final r = size.width / 2 - 1.0;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..shader = SweepGradient(
        colors: [color, color.withOpacity(0.0), color.withOpacity(0.0), color],
        stops: const [0.0, 0.30, 0.72, 1.0],
        transform: const GradientRotation(-0.6),
      ).createShader(rect);
    for (final start in [0.0, math.pi]) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: r), start, math.pi * 1.5, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.color != color;
}
