import 'package:flutter/material.dart';

import 'theme.dart';

/// 首次启动的入场动画：仿澎湃 OS 4 新机开机的观感
///
/// 光晕先在中间扩散 → logo 从 0.7 缩放淡入 → 标题和副标题依次浮现 →
/// 整体上移淡出，把界面交出去。整段 1.8 秒，播完自动调 onDone。
class OobeIntro extends StatefulWidget {
  final VoidCallback onDone;
  const OobeIntro({super.key, required this.onDone});

  @override
  State<OobeIntro> createState() => _OobeIntroState();
}

class _OobeIntroState extends State<OobeIntro> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
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

        // 光晕：0~0.55 扩散
        final glowT = Interval(0.0, 0.55).transform(t);
        // logo：0.18~0.62 缩放淡入
        final logoT = Curves.easeOutBack.transform(Interval(0.18, 0.62).transform(t));
        // 文字：0.42~0.82 上浮淡入
        final textT = Curves.easeOutCubic.transform(Interval(0.42, 0.82).transform(t));
        // 收尾：0.82~1.0 整体淡出并轻微上移
        final outT = Interval(0.82, 1.0).transform(t);

        return Opacity(
          opacity: 1.0 - outT,
          child: Transform.translate(
            offset: Offset(0, -18 * outT),
            child: Container(
              color: dark ? const Color(0xFF0F1218) : const Color(0xFFF7FAFF),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 扩散光晕
                  Opacity(
                    opacity: glowT * (1 - outT),
                    child: Container(
                      width: 220 + 320 * glowT,
                      height: 220 + 320 * glowT,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            accent.withOpacity(0.30),
                            accent.withOpacity(0.08),
                            accent.withOpacity(0.0),
                          ],
                          stops: const [0.0, 0.45, 1.0],
                        ),
                      ),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.scale(
                        scale: 0.70 + 0.30 * logoT,
                        child: Opacity(
                          opacity: logoT,
                          child: Container(
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
                                  color: accent.withOpacity(0.42),
                                  blurRadius: 34,
                                  spreadRadius: 2,
                                  offset: const Offset(0, 12),
                                ),
                              ],
                            ),
                            child: const Icon(Icons.shield_rounded, color: Colors.white, size: 42),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Opacity(
                        opacity: textT,
                        child: Transform.translate(
                          offset: Offset(0, 10 * (1 - textT)),
                          child: const Text(
                            'QW 电脑安全管家',
                            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700, letterSpacing: 1.2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Opacity(
                        opacity: textT * 0.7,
                        child: Transform.translate(
                          offset: Offset(0, 10 * (1 - textT)),
                          child: Text(
                            '正在准备你的安全环境',
                            style: TextStyle(
                              fontSize: 12.5,
                              letterSpacing: 2.0,
                              color: dark ? Colors.white38 : Colors.black38,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
