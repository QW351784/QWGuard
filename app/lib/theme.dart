import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import 'state.dart';

/// iOS 27 液态玻璃 + 澎湃 OS 4 布局
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

  const LiquidGlass({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.padding = const EdgeInsets.all(18),
    this.radius = 24,
    this.forceGlass = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glass = forceGlass || Ui.glass.value;
    final blur = glass && Ui.realtimeBlur.value;

    // iPhone 式 R 角：用连续曲率（squircle），四角过渡比纯圆弧更顺
    final shape = ContinuousRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(
        color: glass
            ? (isDark ? Colors.white.withOpacity(0.16) : Colors.white.withOpacity(0.75))
            : (isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06)),
        width: 1.1,
      ),
    );
    final clipper = ShapeBorderClipper(shape: shape, textDirection: TextDirection.ltr);

    Widget box = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: ShapeDecoration(
        shape: shape,
        color: glass
            ? null
            : (isDark ? const Color(0xFF1B2029) : Colors.white.withOpacity(0.92)),
        gradient: glass
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [Colors.white.withOpacity(0.13), Colors.white.withOpacity(0.05), const Color(0xFF2C4C7A).withOpacity(0.09)]
                    : [Colors.white.withOpacity(0.92), Colors.white.withOpacity(0.55), const Color(0xFFDCEBFF).withOpacity(0.60)],
              )
            : null,
        shadows: glass
            ? (isDark
                ? [
                    BoxShadow(color: Colors.black.withOpacity(0.40), blurRadius: 34, offset: const Offset(0, 14)),
                    BoxShadow(color: Colors.white.withOpacity(0.06), blurRadius: 14, offset: const Offset(-6, -6)),
                  ]
                : [
                    BoxShadow(color: const Color(0xFF9DBBE0).withOpacity(0.28), blurRadius: 34, offset: const Offset(0, 14)),
                    BoxShadow(color: Colors.white.withOpacity(0.65), blurRadius: 18, offset: const Offset(-8, -8)),
                  ])
            : [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.30 : 0.08), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: child,
    );

    if (blur) {
      box = ClipPath(
        clipper: clipper,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: isDark ? 18 : 24, sigmaY: isDark ? 18 : 24),
          child: box,
        ),
      );
    }

    if (glass && Ui.refraction.value) {
      box = Stack(
        children: [
          box,
          Positioned.fill(
            child: IgnorePointer(
              child: ClipPath(
                clipper: clipper,
                child: _Refraction(radius: radius),
              ),
            ),
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
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
          decoration: BoxDecoration(
            gradient: widget.primary
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF4B96FF), Color(0xFF2F7BFF), Color(0xFF1C63E0)],
                  )
                : null,
            color: widget.primary ? null : (isDark ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.70)),
            borderRadius: BorderRadius.circular(999),
            border: widget.primary ? null : Border.all(color: Colors.white.withOpacity(isDark ? 0.18 : 0.80), width: 1.1),
            boxShadow: widget.primary
                ? [BoxShadow(color: const Color(0xFF2F7BFF).withOpacity(enabled ? 0.42 : 0.15), blurRadius: 22, offset: const Offset(0, 9))]
                : null,
          ),
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

class _ParticleLayerState extends State<ParticleLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 22),
  )..repeat();

  final List<_P> _ps = [];

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(7);
    for (var i = 0; i < widget.count; i++) {
      _ps.add(_P(
        x: rnd.nextDouble(),
        y: rnd.nextDouble(),
        r: 1.4 + rnd.nextDouble() * 3.2,
        speed: 0.2 + rnd.nextDouble() * 0.7,
        phase: rnd.nextDouble() * math.pi * 2,
        warm: rnd.nextBool(),
      ));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Ui.particles.value) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          painter: _ParticlePainter(_ps, _c.value, isDark),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _P {
  final double x;
  final double y;
  final double r;
  final double speed;
  final double phase;
  final bool warm;
  const _P({required this.x, required this.y, required this.r, required this.speed, required this.phase, required this.warm});
}

class _ParticlePainter extends CustomPainter {
  final List<_P> ps;
  final double t;
  final bool dark;

  _ParticlePainter(this.ps, this.t, this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in ps) {
      final dy = (p.y - t * p.speed) % 1.0;
      final dx = p.x + math.sin(t * math.pi * 2 + p.phase) * 0.02;
      final pos = Offset(dx * size.width, dy * size.height);
      final base = p.warm ? const Color(0xFF5AA2FF) : const Color(0xFF9BD0FF);
      final color = base.withOpacity(dark ? 0.32 : 0.55);
      final paint = Paint()
        ..shader = RadialGradient(colors: [color, color.withOpacity(0.0)]).createShader(
          Rect.fromCircle(center: pos, radius: p.r * 3),
        );
      canvas.drawCircle(pos, p.r * 3, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter old) => old.t != t;
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

class _RefractionState extends State<_Refraction> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();

  /// 指针在卡片内的局部坐标；移出卡片置空，回退到静态高光
  Offset? _pos;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

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
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          painter: _RefractionPainter(
            t: _c.value,
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
  final double t;
  final double radius;
  final bool dark;
  final bool sweep;
  final Offset? pointer;

  _RefractionPainter({
    required this.t,
    required this.radius,
    required this.dark,
    required this.sweep,
    this.pointer,
  });

  @override
  void paint(Canvas canvas, Size size) {
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
      old.t != t || old.dark != dark || old.sweep != sweep || old.pointer != pointer;
}

/// 呼吸型动态光效
///
/// - 软件内：受设置开关控制，默认关闭
/// - 安装 / 卸载：`forceOn: true` 强制开启，那边没有开关
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

class _BreathingGlowState extends State<BreathingGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.forceOn && !Ui.isOn('breathing')) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = Curves.easeInOut.transform(_c.value);
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

class _FloatingBlobState extends State<FloatingBlob> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 20))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Ui.isOn('blobs')) {
      return LiquidBlob(color: widget.color, size: widget.size);
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final t = _c.value * math.pi * 2 + widget.phase;
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
