import 'dart:ui' as ui;

/// 液态玻璃的 ImageFilter shader。
///
/// 参考 Kyant0/AndroidLiquidGlass（Apache-2.0）的 SDF 折射/色散思路：
/// 不是把背景糊成 20px 的毛玻璃，而是保持中心清晰、只在边缘做 lens。
/// ImageFilter.shader 只有 Impeller 支持，用户明确要求保留 Impeller。
class GlassShader {
  static ui.FragmentProgram? _program;
  static bool _tried = false;

  static bool get available => _program != null;

  static Future<void> load() async {
    if (_tried) return;
    _tried = true;
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    try {
      _program = await ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');
    } catch (_) {
      // 编译/加载失败就退回普通 BackdropFilter，不能让应用起不来
      _program = null;
    }
  }

  /// 每个卡片一个 shader 实例：uniform 不同，program 共用。
  static ui.ImageFilter? filter({
    required double radius,
    required double devicePixelRatio,
  }) {
    final program = _program;
    if (program == null) return null;
    final shader = program.fragmentShader();
    // 前 2 个 float 是引擎自动写入的 u_size，这里从索引 2 开始。
    shader.setFloat(2, radius * devicePixelRatio);
    shader.setFloat(3, 16.0 * devicePixelRatio);
    shader.setFloat(4, 28.0 * devicePixelRatio);
    shader.setFloat(5, 0.35);
    shader.setFloat(6, 3.0 * devicePixelRatio);
    return ui.ImageFilter.shader(shader);
  }
}
