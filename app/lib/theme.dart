import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import 'state.dart';

/// 界面材质档
enum MatStyle { auto, mica, aero, glass, solid }

MatStyle currentMatStyle() => switch (Ui.material.value) {
      'mica' => MatStyle.mica,
      'aero' => MatStyle.aero,
      'glass' => MatStyle.glass,
      'solid' => MatStyle.solid,
      _ => MatStyle.auto,
    };

/// iOS 27 液态玻璃 + 澎湃 OS 4 布局 + Win11 云母 / Win7 Aero 混搭
class AppTheme {
  static ThemeData light() => _base(Brightness.light, const Color(0xFF2F7BFF));
  static ThemeData dark() => _base(Brightness.dark, const Color(0xFF4C9BFF));

  static ThemeData _base(Brightness b, Color seed) {
    final isDark = b == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorSchemeSeed: seed,
      scaffoldBackgroundColor: Colors.transparent,
      fontFamily: 'Microsoft YaHei',
      textTheme: ThemeData(brightness: b).textTheme.apply(
            bodyColor: isDark ? Colors.white : const Color(0xFF14171C),
            displayColor: isDark ? Colors.white : const Color(0xFF14171C),
          ),
    );
  }

  static BoxDecoration background(Brightness b) {
    final isDark = b == Brightness.dark;
    final s = currentMatStyle();

    // 云母 / 混搭：窗口本体走系统 Mica（flutter_acrylic 设的），
    // Flutter 这层只叠一层很淡的色调，叠厚了会把系统材质盖死
    if (s == MatStyle.auto || s == MatStyle.mica) {
      return BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  const Color(0xFF141821).withOpacity(0.30),
                  const Color(0xFF0F1218).withOpacity(0.38),
                  const Color(0xFF171C26).withOpacity(0.26),
                ]
              : [
                  const Color(0xFFF7FBFF).withOpacity(0.38),
                  const Color(0xFFFDFEFF).withOpacity(0.28),
                  const Color(0xFFEAF2FF).withOpacity(0.34),
                ],
        ),
      );
    }

    // Aero：Win7 那种更透、更蓝的薄雾玻璃
    if (s == MatStyle.aero) {
      return BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  const Color(0xFF07101E).withOpacity(0.66),
                  const Color(0xFF123055).withOpacity(0.52),
                  const Color(0xFF0A1A2E).withOpacity(0.60),
                ]
              : [
                  const Color(0xFFE8F4FF).withOpacity(0.66),
                  const Color(0xFFB9DAFF).withOpacity(0.50),
                  const Color(0xFFDCEEFF).withOpacity(0.60),
                ],
        ),
      );
    }

    if (s == MatStyle.solid) {
      return BoxDecoration(color: isDark ? const Color(0xFF15181F) : const Color(0xFFF6F8FC));
    }

    // 液态玻璃：原来那套不透明渐变，给玻璃控件当折射底
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0xFF141821), Color(0xFF0F1218), Color(0xFF171C26)]
            : const [Color(0xFFF2F7FF), Color(0xFFFBFDFF), Color(0xFFE9F2FF)],
      ),
    );
  }

  static Color blobTop(Brightness b) => b == Brightness.dark
      ? const Color(0xFF3D7BD1).withOpacity(0.20)
      : const Color(0xFF8CC0FF).withOpacity(0.40);

  static Color blobBottom(Brightness b) => b == Brightness.dark
      ? const Color(0xFF3568AE).withOpacity(0.16)
      : const Color(0xFFBFDFFF).withOpacity(0.45);
}

/// 液态玻璃容器：关闭液态玻璃时退化为纯色卡片，不做模糊/折射
class LiquidGlass extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool forceGlass;
  final VoidCallback? onTap;
  /// 覆盖默认填充用的渐变（按钮这类需要品牌色，但又要保留玻璃模糊与折射）
  final Gradient? gradient;

  const LiquidGlass({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.padding = const EdgeInsets.all(18),
    this.radius = 24,
    this.forceGlass = false,
    this.onTap,
    this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final s = currentMatStyle();
    final glassLike = s == MatStyle.glass || s == MatStyle.auto;
    final aeroLike = s == MatStyle.aero;
    final micaLike = s == MatStyle.mica;
    final solidLike = s == MatStyle.solid;

    // 液态玻璃开关只管玻璃档；云母和 Aero 是系统材质，不受它影响
    final glass = glassLike && (forceGlass || Ui.glass.value);
    final blurOn = !solidLike && Ui.realtimeBlur.value;

    // iPhone 式 R 角：连续曲率，四角过渡比纯圆弧更顺
    final shape = ContinuousRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(
        color: solidLike
            ? (isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.06))
            : aeroLike
                ? Colors.white.withOpacity(isDark ? 0.28 : 0.90)
                : micaLike
                    ? (isDark ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.55))
                    : (isDark ? Colors.white.withOpacity(0.16) : Colors.white.withOpacity(0.75)),
        width: aeroLike ? 1.4 : 1.1,
      ),
    );
    final clipper = ShapeBorderClipper(shape: shape, textDirection: TextDirection.ltr);

    // 各档的填充、渐变与阴影
    Color? fill;
    Gradient? grad;
    List<BoxShadow> shadows;

    if (solidLike) {
      fill = isDark ? const Color(0xFF1B2029) : Colors.white.withOpacity(0.94);
      shadows = [
        BoxShadow(color: Colors.black.withOpacity(isDark ? 0.30 : 0.08), blurRadius: 18, offset: const Offset(0, 6)),
      ];
    } else if (aeroLike) {
      // Win7 Aero：顶部一道强白高光，中段蓝色雾面，底部收暗
      grad = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: isDark
            ? [Colors.white.withOpacity(0.16), const Color(0xFF0E2440).withOpacity(0.34), Colors.white.withOpacity(0.05)]
            : [Colors.white.withOpacity(0.94), const Color(0xFFD6EAFF).withOpacity(0.54), Colors.white.withOpacity(0.66)],
        stops: const [0.0, 0.52, 1.0],
      );
      shadows = [
        BoxShadow(color: Colors.black.withOpacity(isDark ? 0.34 : 0.10), blurRadius: 26, offset: const Offset(0, 10)),
        BoxShadow(color: Colors.white.withOpacity(isDark ? 0.10 : 0.85), blurRadius: 10, offset: const Offset(0, -4)),
      ];
    } else if (micaLike) {
      // 云母：中性偏冷的半透明面，不折射、不抢背景
      grad = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF232933).withOpacity(0.74), const Color(0xFF1A1F28).withOpacity(0.66)]
            : [Colors.white.withOpacity(0.80), const Color(0xFFF1F5FB).withOpacity(0.66)],
      );
      shadows = [
        BoxShadow(color: Colors.black.withOpacity(isDark ? 0.22 : 0.06), blurRadius: 16, offset: const Offset(0, 5)),
      ];
    } else {
      fill = glass ? null : (isDark ? const Color(0xFF1B2029) : Colors.white.withOpacity(0.92));
      grad = glass
          ? LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [Colors.white.withOpacity(0.13), Colors.white.withOpacity(0.05), const Color(0xFF2C4C7A).withOpacity(0.09)]
                  : [Colors.white.withOpacity(0.92), Colors.white.withOpacity(0.55), const Color(0xFFDCEBFF).withOpacity(0.60)],
            )
          : null;
      shadows = glass
          ? (isDark
              ? [
                  BoxShadow(color: Colors.black.withOpacity(0.40), blurRadius: 34, offset: const Offset(0, 14)),
                  BoxShadow(color: Colors.white.withOpacity(0.06), blurRadius: 14, offset: const Offset(-6, -6)),
                ]
              : [
                  BoxShadow(color: const Color(0xFF9DBBE0).withOpacity(0.28), blurRadius: 34, offset: const Offset(0, 14)),
                  BoxShadow(color: Colors.white.withOpacity(0.65), blurRadius: 18, offset: const Offset(-8, -8)),
                ])
          : [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.30 : 0.08), blurRadius: 18, offset: const Offset(0, 6))];
    }

    final tint = gradient;
    Widget box = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: ShapeDecoration(
        shape: shape,
        color: tint != null ? null : fill,
        gradient: tint ?? grad,
        shadows: shadows,
      ),
      child: child,
    );

    if (blurOn) {
      // 档位不同模糊强度不同：Aero 最重（Win7 那种糊）、云母最轻
      final double sigma = aeroLike
          ? (isDark ? 22 : 28)
          : micaLike
              ? (isDark ? 10 : 14)
              : (isDark ? 18 : 24);
      box = ClipPath(
        clipper: clipper,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: box,
        ),
      );
    }

    // 折射和光追都只挂在液态玻璃档；云母 / Aero / 纯色不做
    final wantRefraction = glass && Ui.refraction.value;
    final wantRay = glass && Ui.isOn('raytrace');
    if (wantRefraction || wantRay) {
      box = Stack(
        children: [
          box,
          if (wantRefraction)
            Positioned.fill(
              child: IgnorePointer(
                child: ClipPath(clipper: clipper, child: _Refraction(radius: radius)),
              ),
            ),
          if (wantRay)
            Positioned.fill(
              child: ClipPath(clipper: clipper, child: _RayTrace(radius: radius)),
            ),
        ],
      );
    }

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(borderRadius: BorderRadius.circular(radius), onTap: onTap, child: box),
      );
    }
    return box;
  }
}

/// 流体按钮：澎湃 OS 4 回弹曲线
class LiquidButton extends StatefulWidget {
  final String text;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool primary;

  const LiquidButton({super.key, required this.text, this.icon, this.onTap, this.primary = true});

  @override
  State<LiquidButton> createState() => _LiquidButtonState();
}

class _LiquidButtonState extends State<LiquidButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = widget.onTap != null;

    return GestureDetector(
      onTapDown: (enabled && Ui.isOn('buttonPress')) ? (_) => setState(() => _scale = 0.94) : null,
      onTapUp: enabled
          ? (_) {
              setState(() => _scale = 1.0);
              widget.onTap!();
            }
          : null,
      onTapCancel: enabled ? () => setState(() => _scale = 1.0) : null,
      child: AnimatedScale(
        scale: _scale,
        duration: Ui.dur('buttonPress', 180),
        curve: Ui.curve('buttonPress'),
        // 按钮不再是"假玻璃"：走 LiquidGlass，跟着材质档位实时模糊 + 折射 + 光追；
        // 主按钮把品牌蓝渐变覆盖上去，玻璃质感还在
        child: LiquidGlass(
          radius: 999,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
          forceGlass: true,
          gradient: widget.primary
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: enabled
                      ? const [Color(0xFF4B96FF), Color(0xFF2F7BFF), Color(0xFF1C63E0)]
                      : const [Color(0xFF7FAEF5), Color(0xFF6597E0), Color(0xFF4E7CC0)],
                )
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 18, color: widget.primary ? Colors.white : (isDark ? Colors.white : Colors.black87)),
                const SizedBox(width: 8),
              ],
              Text(
                widget.text,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: widget.primary
                      ? Colors.white.withOpacity(enabled ? 1 : 0.6)
                      : (isDark ? Colors.white.withOpacity(enabled ? 1 : 0.5) : Colors.black87.withOpacity(enabled ? 1 : 0.4)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弥散光斑
class LiquidBlob extends StatelessWidget {
  final Color color;
  final double size;

  const LiquidBlob({super.key, required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withOpacity(0.0)]),
        ),
      ),
    );
  }
}

/// 粒子层：关闭时不渲染
class ParticleLayer extends StatefulWidget {
  final int count;
  const ParticleLayer({super.key, this.count = 34});

  @override
  State<ParticleLayer> createState() => _ParticleLayerState();
}

class _ParticleLayerState extends State<ParticleLayer> {
  final List<_P> _ps = [];

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(7);
    for (var i = 0; i < widget.count; i++) {
      _ps.add(_P(
        angle: rnd.nextDouble() * math.pi * 2,
        radius: 0.42 + rnd.nextDouble() * 0.72,
        speed: 0.35 + rnd.nextDouble() * 0.65,
        size: 1.2 + rnd.nextDouble() * 2.6,
        phase: rnd.nextDouble() * math.pi * 2,
        squash: 0.62 + rnd.nextDouble() * 0.38,
        warm: rnd.nextBool(),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Ui.particles.value) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _ParticlePainter(_ps, isDark),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _P {
  final double angle;   // 初始角
  final double radius;  // 归一化轨道半径
  final double speed;   // 角速度倍率
  final double size;
  final double phase;
  final double squash;  // 椭圆压扁系数
  final bool warm;
  const _P({
    required this.angle,
    required this.radius,
    required this.speed,
    required this.size,
    required this.phase,
    required this.squash,
    required this.warm,
  });
}

class _ParticlePainter extends CustomPainter {
  final List<_P> ps;
  final bool dark;

  _ParticlePainter(this.ps, this.dark) : super(repaint: Ui.tick);

  @override
  void paint(Canvas canvas, Size size) {
    final t = (Ui.tick.value / 22) % 1;
    final center = Offset(size.width * 0.5, size.height * 0.46);
    final rx = size.width * 0.54;
    final ry = size.height * 0.42;

    for (final p in ps) {
      final a = p.angle + t * math.pi * 2 * p.speed;
      // 呼吸：整圈一起胀缩，像粒子被中心吸住又松开
      final breathe = 0.70 + 0.30 * math.sin(t * math.pi * 2 + p.phase);
      final rr = p.radius * breathe;
      final pos = center + Offset(math.cos(a) * rx * rr, math.sin(a) * ry * rr * p.squash);

      final base = p.warm ? const Color(0xFF5AA2FF) : const Color(0xFF8CE3FF);
      // 亮度同步呼吸
      final lum = (0.45 + 0.55 * math.sin(t * math.pi * 2 + p.phase + 1.2)).clamp(0.15, 1.0);
      final alpha = (dark ? 0.30 : 0.52) * lum;

      // 拖尾：沿轨迹往回排，越远越淡越小，做出流线感
      for (var k = 5; k >= 1; k--) {
        final ta = a - k * 0.055 * p.speed;
        final tr = p.radius * (0.70 + 0.30 * math.sin(t * math.pi * 2 + p.phase - k * 0.06));
        final tp = center + Offset(math.cos(ta) * rx * tr, math.sin(ta) * ry * tr * p.squash);
        final fade = 1.0 - k / 6.0;
        canvas.drawCircle(
          tp,
          p.size * fade * 0.85,
          Paint()..color = base.withOpacity(alpha * fade * 0.42),
        );
      }

      // 主体：外圈光晕 + 中心亮点
      final glow = Paint()
        ..shader = RadialGradient(
          colors: [base.withOpacity(math.min(alpha * 1.6, 1.0)), base.withOpacity(0.0)],
        ).createShader(Rect.fromCircle(center: pos, radius: p.size * 3.2));
      canvas.drawCircle(pos, p.size * 3.2, glow);
      canvas.drawCircle(pos, p.size * 0.9, Paint()..color = Colors.white.withOpacity(alpha * 0.75));
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter old) => old.dark != dark;
}

/// 页面标题
class PageTitle extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;

  const PageTitle({super.key, required this.title, required this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.2)),
              const SizedBox(height: 6),
              Text(subtitle, style: TextStyle(fontSize: 13, color: isDark ? Colors.white.withOpacity(0.55) : Colors.black.withOpacity(0.50))),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}


/// 光影折射：边缘色散 + 沿边扫过的高光带（视觉模拟，非采样背景）
/// 折射层：色散 + 扫光 + 高光，全部跟着鼠标走（实时动态）
class _Refraction extends StatefulWidget {
  final double radius;
  const _Refraction({required this.radius});

  @override
  State<_Refraction> createState() => _RefractionState();
}

class _RefractionState extends State<_Refraction> {
  /// 指针在卡片内的局部坐标；移出卡片置空，回退到静态高光
  Offset? _pos;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return MouseRegion(
      onHover: (e) {
        if (!Ui.isOn('refraction')) return;
        setState(() => _pos = e.localPosition);
      },
      onExit: (_) {
        if (_pos != null) setState(() => _pos = null);
      },
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _RefractionPainter(
            radius: widget.radius,
            dark: isDark,
            sweep: Ui.isOn('sweep'),
            pointer: _pos,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _RefractionPainter extends CustomPainter {
  final double radius;
  final bool dark;
  final bool sweep;
  final Offset? pointer;

  _RefractionPainter({
    required this.radius,
    required this.dark,
    required this.sweep,
    this.pointer,
  }) : super(repaint: Ui.tick);

  @override
  void paint(Canvas canvas, Size size) {
    final t = (Ui.tick.value / 6) % 1;
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));

    // 指针位置归一化到 -1..1；没有指针就退回左上角那套静态效果
    final p = pointer ?? Offset(size.width * 0.16, size.height * 0.10);
    final nx = size.width == 0 ? 0.0 : (p.dx / size.width - 0.5) * 2.0;
    final ny = size.height == 0 ? 0.0 : (p.dy / size.height - 0.5) * 2.0;

    // 1. 边缘色散：方向随指针角度转，指针越靠边色散越明显
    final dist = math.sqrt(nx * nx + ny * ny).clamp(0.0, 1.0).toDouble();
    final amp = 0.8 + 1.4 * dist;
    var dirX = nx;
    var dirY = ny;
    if (dirX == 0 && dirY == 0) {
      dirX = 1.0;
      dirY = 0.6;
    }
    final norm = math.sqrt(dirX * dirX + dirY * dirY);
    final ux = dirX / norm;
    final uy = dirY / norm;

    final offsets = [
      (const Color(0xFFFF4D6D), Offset(ux * amp, uy * amp)),
      (const Color(0xFF4DD2FF), Offset(-ux * amp, -uy * amp)),
    ];
    for (final (color, off) in offsets) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = color.withOpacity(dark ? 0.22 : 0.28);
      canvas.save();
      canvas.translate(off.dx, off.dy);
      canvas.drawRRect(rrect, paint);
      canvas.restore();
    }

    // 1.2 动态流光边：一圈彩虹色散沿边框旋转，不碰鼠标也在流动
    //     这是"实时动态光线折射"的主体，色散按角度变化
    final flow = SweepGradient(
      startAngle: 0,
      endAngle: math.pi * 2,
      colors: [
        const Color(0xFFFF4D6D).withOpacity(0.0),
        const Color(0xFFFF4D6D).withOpacity(dark ? 0.24 : 0.34),
        const Color(0xFFB58CFF).withOpacity(dark ? 0.16 : 0.22),
        const Color(0xFF4DD2FF).withOpacity(dark ? 0.26 : 0.36),
        const Color(0xFF7BFFB2).withOpacity(0.0),
        const Color(0xFFFF4D6D).withOpacity(0.0),
      ],
      stops: const [0.0, 0.18, 0.40, 0.62, 0.84, 1.0],
      transform: GradientRotation(t * math.pi * 2),
    ).createShader(Offset.zero & size);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..shader = flow,
    );

    // 1.3 第二层反向流光，慢一档，叠出玻璃厚度
    final flow2 = SweepGradient(
      startAngle: 0,
      endAngle: math.pi * 2,
      colors: [
        Colors.white.withOpacity(0.0),
        Colors.white.withOpacity(dark ? 0.16 : 0.30),
        Colors.white.withOpacity(0.0),
      ],
      stops: const [0.0, 0.5, 1.0],
      transform: GradientRotation(-t * math.pi * 2 + 1.6),
    ).createShader(Offset.zero & size);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(2.2),
        Radius.circular(math.max(radius - 2.2, 1.0)),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..shader = flow2,
    );

    // 1.5 玻璃切面：边缘一圈极细白线，做出玻璃厚度
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(0.8),
        Radius.circular(math.max(radius - 0.8, 1.0)),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withOpacity(dark ? 0.14 : 0.55),
    );

    // 1.6 厚玻璃内高光：上沿亮、下沿压暗，iOS 27 那种立体感
    final bodyGlow = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.white.withOpacity(dark ? 0.16 : 0.40),
        Colors.white.withOpacity(0.0),
        Colors.black.withOpacity(dark ? 0.20 : 0.07),
      ],
      stops: const [0.0, 0.46, 1.0],
    ).createShader(Offset.zero & size);
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(Offset.zero & size, Paint()..shader = bodyGlow);
    canvas.restore();

    // 2. 沿对角扫过的高光带（可关）
    if (sweep) {
      final bandW = size.width * 0.42;
      final dy = t * (size.height + bandW * 2) - bandW * 2;
      final rect = Rect.fromLTWH(-bandW * 0.2, dy, bandW, bandW * 2.4);
      final shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withOpacity(0.0),
          Colors.white.withOpacity(dark ? 0.10 : 0.26),
          Colors.white.withOpacity(0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(rect);

      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawRect(rect, Paint()..shader = shader);
      canvas.restore();
    }

    // 3. 实时高光：径向光斑跟着指针，指针离开就落回左上
    final center = p;
    final r = math.max(size.width, size.height) * (pointer == null ? 0.52 : 0.40);
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withOpacity(dark ? 0.20 : 0.58),
          Colors.white.withOpacity(dark ? 0.05 : 0.16),
          Colors.white.withOpacity(0.0),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: r));
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawCircle(center, r, glow);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RefractionPainter old) =>
      old.dark != dark || old.sweep != sweep || old.pointer != pointer;
}

/// 呼吸型动态光效
///
/// - 软件内：受设置开关控制，默认关闭
/// - 安装 / 卸载：`forceOn: true` 强制开启，那边没有开关
/// 光追反射层：光线打到玻璃表面后的镜面反射、多次内反射、焦散聚光、
/// 表面微观起伏高光。纯 Canvas 近似，不吃 GPU 光追硬件。
class _RayTrace extends StatefulWidget {
  final double radius;
  const _RayTrace({required this.radius});

  @override
  State<_RayTrace> createState() => _RayTraceState();
}

class _RayTraceState extends State<_RayTrace> {

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 只有大块玻璃才开光追：设置页那种列表每行都是一个 LiquidGlass，
    // 几十个 painter 一起跑会拖帧，小块直接不挂
    return LayoutBuilder(
      builder: (ctx, c) {
        if (c.maxWidth < 420 || c.maxHeight < 200) return const SizedBox.shrink();
        return IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _RayTracePainter(radius: widget.radius, dark: isDark),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

class _RayTracePainter extends CustomPainter {
  final double radius;
  final bool dark;

  _RayTracePainter({required this.radius, required this.dark}) : super(repaint: Ui.tick);

  @override
  void paint(Canvas canvas, Size size) {
    final t = (Ui.tick.value / 14) % 1;
    if (size.isEmpty) return;
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    final w = size.width;
    final h = size.height;

    canvas.save();
    canvas.clipRRect(rrect);

    // ① 多次内反射：同一条反射线按 1/2/3 倍间距重复，透明度逐次衰减
    //    入射角随 t 缓慢摆动，看起来像光源在动
    final theta = 0.55 + 0.18 * math.sin(t * math.pi * 2);
    final dx = math.cos(theta);
    final dy = math.sin(theta);
    for (var k = 1; k <= 3; k++) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withOpacity((dark ? 0.10 : 0.30) / k);
      final off = k * 7.0;
      canvas.drawLine(Offset(off * dx, off * dy), Offset(w - off, h * 0.52 + off * dy), p);
    }

    // ② 镜面高光扫过：一道窄亮带斜着穿过整块玻璃
    final s = (t * 2.0) % 1.0;
    final sx = -w * 0.4 + s * (w * 1.8);
    canvas.save();
    canvas.translate(sx, 0);
    canvas.rotate(-0.35);
    final rectB = Rect.fromLTWH(-46, -h, 92, h * 3);
    final band = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withOpacity(0.0),
          Colors.white.withOpacity(dark ? 0.11 : 0.30),
          Colors.white.withOpacity(0.0),
        ],
      ).createShader(rectB);
    canvas.drawRect(rectB, band);
    canvas.restore();

    // ③ 焦散聚光：光穿过玻璃在角上汇成亮斑，两颗沿椭圆轨道游走
    for (var i = 0; i < 2; i++) {
      final p = (t + i * 0.5) % 1.0;
      final cx = (i == 0 ? 0.12 : 0.88) * w + math.sin(p * math.pi * 2) * w * 0.06;
      final cy = (i == 0 ? 0.16 : 0.84) * h + math.cos(p * math.pi * 2) * h * 0.05;
      final r = math.min(w, h) * 0.17;
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            (dark ? const Color(0xFF9BE7FF) : Colors.white).withOpacity(dark ? 0.20 : 0.52),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
      canvas.drawCircle(Offset(cx, cy), r, paint);
    }

    // ④ 表面微观起伏：极低透明度斜纹整体平移，模拟玻璃面反射的细碎起伏
    final hatch = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white.withOpacity(dark ? 0.030 : 0.075);
    const step = 7.0;
    final shift = (t * step * 2) % step;
    for (var x = -h; x < w + h; x += step) {
      canvas.drawLine(Offset(x + shift, 0), Offset(x + shift - h * 0.6, h), hatch);
    }

    // ⑤ 菲涅耳边缘：掠射角处反射更强，绕着边框转
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..shader = SweepGradient(
        colors: [
          Colors.white.withOpacity(0.0),
          Colors.white.withOpacity(dark ? 0.12 : 0.34),
          Colors.white.withOpacity(0.0),
          Colors.white.withOpacity(dark ? 0.10 : 0.26),
          Colors.white.withOpacity(0.0),
        ],
        stops: const [0.0, 0.12, 0.45, 0.82, 1.0],
        transform: GradientRotation(t * math.pi * 2),
      ).createShader(Offset.zero & size);
    canvas.drawRRect(rrect, edge);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RayTracePainter old) => old.dark != dark || old.radius != radius;
}

/// 水纹层：指针按下 / 划过时在玻璃上溅起同心水波，越往外越淡
class _Ripple {
  final Offset pos;
  final int startMs;
  final double strength;
  _Ripple(this.pos, this.startMs, this.strength);
}

class WaterRipple extends StatefulWidget {
  final int maxRipples;
  const WaterRipple({super.key, this.maxRipples = 10});

  @override
  State<WaterRipple> createState() => _WaterRippleState();
}

class _WaterRippleState extends State<WaterRipple> {
  final List<_Ripple> _rs = [];
  Offset? _last;

  void _spawn(Offset p, double strength) {
    final now = DateTime.now().microsecondsSinceEpoch;
    _rs.add(_Ripple(p, now, strength));
    if (_rs.length > widget.maxRipples) _rs.removeAt(0);
  }

  @override
  Widget build(BuildContext context) {
    if (!Ui.isOn('water')) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Listener(
      // translucent：收得到指针事件，但不抢下层控件的点击
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _last = e.position;
        _spawn(e.position, 1.0);
      },
      onPointerMove: (e) {
        final l = _last;
        if (l == null) {
          _last = e.position;
          return;
        }
        if ((e.position - l).distance < 34) return;
        _last = e.position;
        _spawn(e.position, 0.42);
      },
      child: IgnorePointer(
        child: RepaintBoundary(
          child: SizedBox.expand(
            child: CustomPaint(
              painter: _RipplePainter(rs: _rs, dark: isDark),
              size: Size.infinite,
            ),
          ),
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  final List<_Ripple> rs;
  final bool dark;

  _RipplePainter({required this.rs, required this.dark}) : super(repaint: Ui.tick);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final nowMs = DateTime.now().microsecondsSinceEpoch;
    rs.removeWhere((r) => nowMs - r.startMs > 2400000);
    final base = math.min(size.width, size.height);
    for (final r in rs) {
      final age = (nowMs - r.startMs) / 1000000.0; // 秒
      if (age < 0 || age > 2.4) continue;
      final p = age / 2.4;
      // 双环：主波 + 落后一点的尾波
      for (var k = 0; k < 2; k++) {
        final pk = (p - k * 0.14).clamp(0.0, 1.0).toDouble();
        if (pk <= 0) continue;
        final radius = 6 + pk * base * 0.62;
        final alpha = (1.0 - pk) * (1.0 - pk) * (dark ? 0.34 : 0.62) * r.strength;
        if (alpha <= 0.004) continue;
        canvas.drawCircle(
          r.pos,
          radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (1.8 - k * 0.7) * (1.0 - pk * 0.4)
            ..color = (dark ? const Color(0xFF9BE7FF) : Colors.white).withOpacity(alpha)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.3),
        );
      }
      // 落点高光，按下去那一下最亮
      final coreA = (1.0 - p) * (1.0 - p) * (dark ? 0.30 : 0.55) * r.strength;
      if (coreA > 0.01) {
        canvas.drawCircle(
          r.pos,
          2.2 + (1 - p) * 3.0,
          Paint()..color = Colors.white.withOpacity(coreA),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter old) => old.dark != dark;
}

class BreathingGlow extends StatefulWidget {
  final Color color;
  final double size;
  final bool forceOn;

  const BreathingGlow({
    super.key,
    required this.color,
    this.size = 420,
    this.forceOn = false,
  });

  @override
  State<BreathingGlow> createState() => _BreathingGlowState();
}

class _BreathingGlowState extends State<BreathingGlow> {
  @override
  Widget build(BuildContext context) {
    if (!widget.forceOn && !Ui.isOn('breathing')) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Ui.tick,
        builder: (_, __) {
          // 4.6 秒一个来回：0→1→0 呼吸
          final raw = (Ui.tick.value / 4.6) % 1;
          final half = raw <= 0.5 ? raw * 2 : (1.0 - raw) * 2;
          final t = Curves.easeInOut.transform(half);
          final scale = 0.88 + 0.22 * t;
          final opacity = 0.16 + 0.24 * t;
          return Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: opacity,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      widget.color.withOpacity(0.55),
                      widget.color.withOpacity(0.18),
                      widget.color.withOpacity(0.0),
                    ],
                    stops: const [0.0, 0.42, 1.0],
                  ),
                ),
              ),
            ),
          );
      },
    ),
  );
  }
}


/// 背景光斑：开启「光斑漂浮」时缓慢正弦漂移，关闭则完全静止
class FloatingBlob extends StatefulWidget {
  final Color color;
  final double size;
  final double phase;
  const FloatingBlob({super.key, required this.color, required this.size, this.phase = 0});

  @override
  State<FloatingBlob> createState() => _FloatingBlobState();
}

class _FloatingBlobState extends State<FloatingBlob> {

  @override
  Widget build(BuildContext context) {
    if (!Ui.isOn('blobs')) {
      return LiquidBlob(color: widget.color, size: widget.size);
    }
    return AnimatedBuilder(
      animation: Ui.tick,
      builder: (_, child) {
        final t = (Ui.tick.value / 20) * math.pi * 2 + widget.phase;
        return Transform.translate(
          offset: Offset(math.sin(t) * 22, math.cos(t * 1.2) * 16),
          child: child,
        );
      },
      child: LiquidBlob(color: widget.color, size: widget.size),
    );
  }
}

/// 统一风格的确认 / 提示弹窗
class QDialog extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String okText;
  final String? cancelText;
  final Widget? child;
  final VoidCallback? onOk;

  const QDialog({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.okText = '好',
    this.cancelText,
    this.child,
    this.onOk,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: LiquidGlass(
          radius: 24,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 22, color: const Color(0xFF2F7BFF)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 12),
              Text(body,
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.65,
                      color: isDark ? Colors.white70 : Colors.black87)),
              if (child != null) child!,
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (cancelText != null) ...[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(cancelText!),
                    ),
                    const SizedBox(width: 6),
                  ],
                  LiquidButton(
                    text: okText,
                    onTap: () {
                      if (onOk != null) {
                        onOk!();
                      } else {
                        Navigator.of(context).pop(true);
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
