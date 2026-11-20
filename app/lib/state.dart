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
  static const List<AnimDef> anims = [
    AnimDef('glass', '液态玻璃材质', 'Liquid glass'),
    AnimDef('blur', '实时模糊', 'Live blur'),
    AnimDef('refraction', '光影折射', 'Refraction'),
    AnimDef('raytrace', '光追反射', 'Ray tracing'),
    AnimDef('water', '水纹动画', 'Water ripple'),
    AnimDef('sweep', '折射扫光带', 'Light sweep'),
    AnimDef('particles', '粒子特效', 'Particles'),
    AnimDef('blobs', '背景光斑漂浮', 'Floating blobs'),
    AnimDef('dockSpring', 'Dock 弹簧动画', 'Dock spring'),
    AnimDef('dockGlass', 'Dock 玻璃效果', 'Dock glass'),
    AnimDef('pageTransition', '页面切换动画', 'Page transition'),
    AnimDef('buttonPress', '按钮按压回弹', 'Button press'),
    AnimDef('cardEntrance', '卡片入场动画', 'Card entrance'),
    // 呼吸型动态光效：软件内默认开启、可以手动关闭；安装/卸载过程中强制开启（那边没有开关）
    AnimDef('breathing', '呼吸型动态光效', 'Breathing glow', defaultOn: true),
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

  /// 澎湃 OS 4 回弹曲线
  /// 澎湃 OS 4 的 Q 弹曲线：带明显过冲再回落，按下去像果冻
  static const spring = Cubic(0.34, 1.56, 0.64, 1.0);
  static const soft = Cubic(0.22, 1.0, 0.36, 1.0);

  /// 按开关返回时长：关掉即 0，等于瞬间完成
  static Duration dur(String key, int ms) =>
      isOn(key) ? Duration(milliseconds: ms) : Duration.zero;

  static Curve curve(String key) => isOn(key) ? spring : Curves.linear;
}
