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

/// 苹果式连续曲率圆角（squircle）的路径
///
/// 不用 Flutter 的 ContinuousRectangleBorder：
/// 它的 getOuterPath 在大半径时控制点比例固定，画出来角部偏「方」，
/// 而且视觉半径和 BorderRadius.circular 不一致 —— 同样填 24，
/// 用它的卡片角看起来比别处小一圈，这就是「R 角一直不对」的原因。
///
/// 这里直接用三次贝塞尔，控制点系数取 0.45
/// （普通圆弧是 0.5523：系数越小，角越「鼓」、曲率过渡越长，
///  越接近 iOS 图标那种连续曲率；系数大就是普通圆角）。
/// 四角用同一个函数算，所以四个角严格一致，不会出现左下角漏成直角。
Path squirclePath(Rect r, double radius) {
  // 半径不能超过短边的一半，否则会自交
  final rr = math.max(0.0, math.min(radius, math.min(r.width, r.height) / 2));
  const c = 0.45;
  final l = r.left;
  final t = r.top;
  final rt = r.right;
  final b = r.bottom;
  final p = Path()
    ..moveTo(l + rr, t)
    ..lineTo(rt - rr, t)
    ..cubicTo(rt - rr * c, t, rt, t + rr * c, rt, t + rr)
    ..lineTo(rt, b - rr)
    ..cubicTo(rt, b - rr * c, rt - rr * c, b, rt - rr, b)
    ..lineTo(l + rr, b)
    ..cubicTo(l + rr * c, b, l, b - rr * c, l, b - rr)
    ..lineTo(l, t + rr)
    ..cubicTo(l, t + rr * c, l + rr * c, t, l + rr, t)
    ..close();
  return p;
}

/// 用 squirclePath 裁形状
class SquircleClipper extends CustomClipper<Path> {
  final double radius;
  const SquircleClipper(this.radius);

  @override
  Path getClip(Size size) => squirclePath(Offset.zero & size, radius);

  @override
  bool shouldReclip(covariant SquircleClipper old) => old.radius != radius;
}

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
      fontFamily: 'NotoSansSC',
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

    // iPhone 式 R 角：四角统一走 squirclePath。
    // 不用 ContinuousRectangleBorder —— 它在大半径下角部偏方，
    // 视觉半径比 BorderRadius.circular 小一圈，四角还可能漏一条边，
    // 这正是「R 角一直不对」的根源。
    final clipper = SquircleClipper(radius);

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
      // 玻璃档的填充必须够透，否则 BackdropFilter 模糊了背景也透不出来 —
      // 之前是 0.92 / 0.55 / 0.60 三层白，叠完等于一张白纸，所以才「质感差」。
      // 现在压到 0.62 / 0.24 / 0.30，背景的彩色光斑能透上来，
      // 亮的层次靠的是边缘反射，不是靠把面填白。
      grad = glass
          ? LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [Colors.white.withOpacity(0.46), Colors.white.withOpacity(0.24), const Color(0xFF3A5E96).withOpacity(0.32)]
                  : [Colors.white.withOpacity(0.86), Colors.white.withOpacity(0.52), const Color(0xFFE8F2FF).withOpacity(0.60)],
              stops: const [0.0, 0.55, 1.0],
            )
          : null;
      // 玻璃档阴影分三层，全部中性灰，不掺蓝：
      //   ① 接触阴影：很小很近，给「贴住背景」的落地感
      //   ② 中距离：主体投影
      //   ③ 环境遮蔽：大而散，模拟周围环境的暗部
      // 以前是「一层彩色大阴影」，玻璃才会显得像塑料板浮在半空。
      shadows = glass
          ? (isDark
              ? [
                  BoxShadow(color: Colors.black.withOpacity(0.20), blurRadius: 3, offset: const Offset(0, 1)),
                  BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 14, offset: const Offset(0, 6)),
                  BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 38, offset: const Offset(0, 16)),
                ]
              : [
                  BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 3, offset: const Offset(0, 1)),
                  BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 14, offset: const Offset(0, 6)),
                  BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 38, offset: const Offset(0, 16)),
                ])
          : [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.30 : 0.08), blurRadius: 18, offset: const Offset(0, 6))];
    }

    final tint = gradient;
    // 圆角必须靠 ClipPath 裁，不能用 ShapeDecoration 直接画。
    // ShapeDecoration 对 ContinuousRectangleBorder 的四角路径支持不完整，
    // 左上 / 右上 / 右下是圆的、左下角会漏成直角 —— 截图里那个缺口就是它。
    // 阴影挂在外层（不被裁），背景挂在内层（被裁），两边都正常。
    Widget box = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(boxShadow: shadows),
      child: ClipPath(
        clipper: clipper,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: tint != null ? null : fill,
            gradient: tint ?? grad,
          ),
          child: child,
        ),
      ),
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
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 形状必须跟 LiquidGlass 外层完全一致：外层用的是 ContinuousRectangleBorder
    // （苹果式连续曲率 squircle），这里若用 RRect 普通圆角，
    // 高光描边就会跟卡片边缘对不齐，四角出现错位毛刺 —— 也就是「圆角处理不行」。
    // 跟 LiquidGlass 用同一个 squirclePath，四角和边缘才能严丝合缝
    final path = squirclePath(Offset.zero & size, radius);
    final innerPath = squirclePath(
      (Offset.zero & size).deflate(0.6),
      math.max(radius - 1.2, 1.0),
    );

    // 指针位置归一化到 -1..1；没有指针就退回左上角那套静态效果
    final p = pointer ?? Offset(size.width * 0.16, size.height * 0.10);
    final nx = size.width == 0 ? 0.0 : (p.dx / size.width - 0.5) * 2.0;
    final ny = size.height == 0 ? 0.0 : (p.dy / size.height - 0.5) * 2.0;

    // 1. 边缘色散：真玻璃的色散只在边缘极窄的一线，而且要非常淡。
    //    以前 2.0px 宽 + 0.28 透明度会看起来像「彩色描边」，那是塑料感。
    final dist = math.sqrt(nx * nx + ny * ny).clamp(0.0, 1.0).toDouble();
    final amp = 0.35 + 0.55 * dist;
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
        ..strokeWidth = 1.0
        ..color = color.withOpacity(dark ? 0.07 : 0.08);
      canvas.save();
      canvas.translate(off.dx, off.dy);
      canvas.drawPath(path, paint);
      canvas.restore();
    }

    // 1.2 镜面描边：苹果液态玻璃只有「白色高光」这一道边，
    //     角度固定从左上打来，上沿最亮、两侧渐弱、下沿最暗。
    //     这里不用彩虹 SweepGradient —— 整圈彩光旋转是廉价感的最大来源，
    //     真玻璃不会自己发出彩色光，它只反射环境。
    final specular = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: dark
          ? [
              Colors.white.withOpacity(0.52),
              Colors.white.withOpacity(0.16),
              Colors.white.withOpacity(0.04),
              Colors.white.withOpacity(0.22),
            ]
          : [
              Colors.white.withOpacity(0.98),
              Colors.white.withOpacity(0.52),
              Colors.white.withOpacity(0.16),
              Colors.white.withOpacity(0.72),
            ],
      stops: const [0.0, 0.34, 0.66, 1.0],
    ).createShader(Offset.zero & size);
    canvas.drawPath(
      innerPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..shader = specular,
    );

    // 1.5 玻璃切面：边缘一圈极细白线，做出玻璃厚度。
    // 这里原来用 RRect（普通圆弧），跟外层的 squircle 对不上，
    // 四个角会出现「圆弧盖在 squircle 上」的错位毛刺 —— 也换成 squirclePath。
    canvas.drawPath(
      squirclePath((Offset.zero & size).deflate(0.8), math.max(radius - 0.8, 1.0)),
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
    canvas.clipPath(path);
    canvas.drawRect(Offset.zero & size, Paint()..shader = bodyGlow);
    canvas.restore();

    // 2. 指针柔光：范围压到短边的 40% 以内，且中心透明度很低。
    //
    //    以前这里是 `r = max(w,h) * 0.52` + `drawCircle`，
    //    780 宽的卡片上等于画一个直径 800 的实心圆，透出来就是一块灰斑 ——
    //    截图里「安装选项左上那个圆」「开始安装右下那个圆」就是它。
    //    真玻璃的亮来自边缘反射，不是中间一团光。
    if (pointer != null) {
      final r = math.min(size.width, size.height) * 0.40;
      final glow = Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withOpacity(dark ? 0.07 : 0.14),
            Colors.white.withOpacity(0.0),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: pointer!, radius: r));
      canvas.save();
      canvas.clipPath(path);
      canvas.drawCircle(pointer!, r, glow);
      canvas.restore();
    }
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

  _RayTracePainter({required this.radius, required this.dark});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 这里只留一道边缘反射。
    //
    // 原来有 5 层：多次内反射的直线、扫过去的高光带、
    // 两颗沿椭圆游走的焦散光斑、整片细斜纹、绕边旋转的菲涅耳。
    // 你截图里的「两个圆点」就是那两颗焦散，
    // 「那点线段」是内反射的 drawLine，满屏细纹是 hatch 斜纹。
    // 苹果玻璃表面是干净的，这些只会让画面显脏，全部删掉。
    final path = squirclePath(Offset.zero & size, radius);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withOpacity(dark ? 0.16 : 0.50),
          Colors.white.withOpacity(dark ? 0.05 : 0.14),
          Colors.white.withOpacity(0.0),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, edge);
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
    // RepaintBoundary 包住：呼吸光每帧自己重绘，不能把整页带着一起重绘。
    // 之前缺这层，两个光斑每帧驱动整个 Stack 重新布局 + 重绘 ——
    // 这是「动画发涩、玻璃显得糙」的直接原因。
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Ui.tick,
          builder: (_, __) {
            // 6.5 秒一个来回，幅度收到 0.94→1.06、透明度 0.10→0.24。
            // 之前是 4.6 秒、0.88→1.10、0.16→0.40 —— 更像手电筒在闪，
            // 不像玻璃内部的光在慢慢呼吸。
            final raw = (Ui.tick.value / 6.5) % 1;
            final half = raw <= 0.5 ? raw * 2 : (1.0 - raw) * 2;
            final t = Curves.easeInOutSine.transform(half);
            final scale = 0.94 + 0.12 * t;
            final opacity = 0.10 + 0.14 * t;
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
                        widget.color.withOpacity(0.50),
                        widget.color.withOpacity(0.15),
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
