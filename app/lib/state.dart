import 'package:flutter/material.dart';

/// 一项动画开关的定义
class AnimDef {
  final String key;
  final String zh;
  final String en;
  final bool defaultOn;
  const AnimDef(this.key, this.zh, this.en, {this.defaultOn = true});
}

/// 全局 UI 状态
/// 动画默认全部开启，只有用户明确要求默认关闭的（悬浮窗）才关
class Ui {
  // 默认开的这些是「不烧 GPU 的」：材质、模糊、折射、Dock、页面切换、按钮回弹。
  // blur（BackdropFilter）是单帧最贵的一项：每个 LiquidGlass 都要把背景
  // 重采样一遍，一屏十几块玻璃就是十几次全屏采样，双显卡机器上系统还默认
  // 把它丢给核显 —— 这是「动画全关了 GPU 还 70%」的主要来源。
  // 默认关掉后玻璃仍是半透明渐变 + 边缘高光，只是不再糊背景。
  //
  // 另外五个都是每帧重绘整屏的：粒子（34 个粒子 × 6 层拖尾 = 200+ 次
  // drawCircle）、水纹（每次移动都新建波纹）、背景光斑（每帧 Transform）、
  // 扫光带、光追 —— 它们叠在一起就是 4060 上 90% 占用率的来源。
  // 用户想要可以在设置里逐个打开，但默认不替他把显卡烧了。
  static const List<AnimDef> anims = [
    AnimDef('glass', '液态玻璃材质', 'Liquid glass'),
    AnimDef('blur', '实时模糊', 'Live blur', defaultOn: false),
    AnimDef('refraction', '光影折射', 'Refraction', defaultOn: false),
    AnimDef('raytrace', '光追反射', 'Ray tracing', defaultOn: false),
    AnimDef('water', '水纹动画', 'Water ripple', defaultOn: false),
    AnimDef('sweep', '折射扫光带', 'Light sweep', defaultOn: false),
    AnimDef('particles', '粒子特效', 'Particles', defaultOn: false),
    AnimDef('blobs', '背景光斑漂浮', 'Floating blobs', defaultOn: false),
    AnimDef('dockSpring', 'Dock 弹簧动画', 'Dock spring'),
    AnimDef('dockGlass', 'Dock 玻璃效果', 'Dock glass'),
    AnimDef('pageTransition', '页面切换动画', 'Page transition'),
    AnimDef('buttonPress', '按钮按压回弹', 'Button press'),
    AnimDef('cardEntrance', '卡片入场动画', 'Card entrance'),
    // 呼吸型动态光效：软件内默认开启、可以手动关闭；安装/卸载过程中强制开启（那边没有开关）
    AnimDef('breathing', '呼吸型动态光效', 'Breathing glow', defaultOn: false),
  ];

  static final Map<String, ValueNotifier<bool>> _map = {
    for (final a in anims) a.key: ValueNotifier<bool>(a.defaultOn),
  };

  static ValueNotifier<bool> on(String key) => _map[key] ?? ValueNotifier<bool>(true);
  static bool isOn(String key) => _map[key]?.value ?? true;

  /// 兼容旧调用
  static ValueNotifier<bool> get glass => on('glass');
  static ValueNotifier<bool> get particles => on('particles');
  static ValueNotifier<bool> get realtimeBlur => on('blur');
  static ValueNotifier<bool> get refraction => on('refraction');

  /// 悬浮窗：默认关闭（用户明确要求）
  static final floating = ValueNotifier<bool>(false);
  static final floatMetrics = ValueNotifier<Set<String>>({'cpu', 'mem', 'gpu'});

  /// 材质风格：
  /// - auto（默认，混搭）：控件用液态玻璃，窗口背景用 Win11 云母
  /// - mica：全部走云母
  /// - aero：Win7 Aero 那种薄雾玻璃
  /// - glass：全部液态玻璃
  /// - solid：纯色最省性能
  static final material = ValueNotifier<String>('auto');

  /// 全局动画时钟：单调递增的秒数（不回绕）。
  /// 全窗口只留这一个 Ticker，画笔用 `super(repaint: Ui.tick)` 订阅它——
  /// 只走重绘、不走 widget 重建；几十个玻璃控件叠加时也不会各开一个 vsync。
  static final ValueNotifier<double> tick = ValueNotifier<double>(0);

  /// 上一帧总耗时（毫秒）：Shell 的帧回调写入，设置页显示实时流畅度
  static final ValueNotifier<double> frameMs = ValueNotifier<double>(0);

  /// 澎湃 OS 4 回弹曲线
  /// 澎湃 OS 4 的 Q 弹曲线：带明显过冲再回落，按下去像果冻
  static const spring = Cubic(0.34, 1.56, 0.64, 1.0);
  static const soft = Cubic(0.22, 1.0, 0.36, 1.0);

  /// 按开关返回时长：关掉即 0，等于瞬间完成
  static Duration dur(String key, int ms) =>
      isOn(key) ? Duration(milliseconds: ms) : Duration.zero;

  static Curve curve(String key) => isOn(key) ? spring : Curves.linear;

  /// 是否有「需要按帧驱动」的动画还开着。
  /// 这些关掉之后，没有任何 painter 需要 60fps 刷新，全局时钟就该停下来：
  /// 否则 repaint: Ui.tick 仍然每 16ms 触发一次整窗重绘，动画关了也照样烧 GPU。
  /// 注意这里不含 glass / dockGlass / pageTransition 等一次性或静态项，
  /// 它们不需要持续出帧。
  static const List<String> _perFrameKeys = [
    'blur',
    'refraction',
    'raytrace',
    'water',
    'sweep',
    'particles',
    'blobs',
    'breathing',
  ];

  static bool get perFrameActive {
    for (final k in _perFrameKeys) {
      if (_map[k]?.value ?? false) return true;
    }
    return false;
  }
}
