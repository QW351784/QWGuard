import 'dart:io';
import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'api.dart';
import 'bridge.dart';
import 'i18n.dart';
import 'installer.dart';
import 'oobe.dart';
import 'pages.dart';
import 'state.dart';
import 'theme.dart';
import 'desktop_monitor.dart';
import 'floating_monitor.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 安装 / 卸载模式：跟主程序同一个二进制，靠参数分流
  if (args.contains('--setup') || args.contains('--uninstall')) {
    runApp(SetupApp(uninstall: args.contains('--uninstall')));
    return;
  }

  // 第二个引擎窗口（桌面级监控）
  if (args.isNotEmpty && args.first == 'multi_window') {
    final id = args.length > 1 ? int.tryParse(args[1]) ?? 0 : 0;
    runApp(DesktopMonitorApp(windowId: id));
    return;
  }

  final theme = await AppSettings.theme();
  I18n.lang = await AppSettings.lang();

  final sp = await SharedPreferences.getInstance();
  for (final a in Ui.anims) {
    Ui.on(a.key).value = sp.getBool('anim_${a.key}') ?? a.defaultOn;
  }
  Ui.floating.value = sp.getBool('ui_floating') ?? false;
  Ui.material.value = sp.getString('ui_material') ?? 'auto';
  final fm = sp.getStringList('float_metrics');
  if (fm != null && fm.isNotEmpty) Ui.floatMetrics.value = fm.toSet();

  if (Platform.isWindows) {
    try {
      await Window.initialize();
    } catch (_) {}

    try {
      DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
        if (call.method == 'close') {
          await DesktopMultiWindow.invokeMethod(fromWindowId, 'close');
        }
        return null;
      });
    } catch (_) {}

    // 圆角无边框窗口
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      size: Size(1260, 840),
      minimumSize: Size(1000, 660),
      center: true,
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.hidden,
      title: 'QW 电脑安全管家',
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(ToolboxApp(initialTheme: theme));
}

class ToolboxApp extends StatefulWidget {
  final ThemeOption initialTheme;
  const ToolboxApp({super.key, required this.initialTheme});

  static _ToolboxAppState? of(BuildContext context) => context.findAncestorStateOfType<_ToolboxAppState>();

  @override
  State<ToolboxApp> createState() => _ToolboxAppState();
}

class _ToolboxAppState extends State<ToolboxApp> {
  late ThemeOption _theme = widget.initialTheme;

  ThemeMode get _mode => switch (_theme) {
        ThemeOption.light => ThemeMode.light,
        ThemeOption.dark => ThemeMode.dark,
        ThemeOption.system => ThemeMode.system,
      };

  void setTheme(ThemeOption t) => setState(() => _theme = t);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QW 电脑安全管家',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _mode,
      home: const Shell(),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WindowListener {
  int _index = 0;
  bool _oobe = true;

  static const _icons = [
    Icons.memory_rounded,
    Icons.cleaning_services_rounded,
    Icons.shield_rounded,
    Icons.widgets_rounded,
    Icons.inventory_2_rounded,
  ];

  @override
  void initState() {
    super.initState();
    for (final a in Ui.anims) {
      Ui.on(a.key).addListener(_rebuild);
    }
    Ui.floating.addListener(_rebuild);
    Ui.floatMetrics.addListener(_rebuild);
    Ui.material.addListener(_rebuild);
    if (Platform.isWindows) {
      try {
        windowManager.addListener(this);
        windowManager.setPreventClose(true);
      } catch (_) {}
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _envCheck();
      await _guard();
      if (mounted) await _maybeWelcome();
    });
  }

  @override
  void dispose() {
    for (final a in Ui.anims) {
      Ui.on(a.key).removeListener(_rebuild);
    }
    Ui.floating.removeListener(_rebuild);
    Ui.floatMetrics.removeListener(_rebuild);
    Ui.material.removeListener(_rebuild);
    if (Platform.isWindows) {
      try {
        windowManager.removeListener(this);
      } catch (_) {}
    }
    super.dispose();
  }

  void _rebuild() {
    setState(() {});
    // 材质档变了（比如用户切到 Aero）要重设窗口特效，其余开关只重建界面
    _applyMaterial();
  }

  /// 关窗口：先确认，再按需验密码
  @override
  void onWindowClose() async {
    final ok = await _confirmClose();
    if (!ok) return;
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {}
  }

  Future<bool> _confirmClose() async {
    if (!mounted) return false;
    final st = Api.passwordState();
    final needPwd = st['success'] == true && st['data'] is Map && st['data']['enabled'] == true;

    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => QDialog(
        icon: Icons.power_settings_new_rounded,
        title: '确定要关闭吗？',
        body: '关闭后这台电脑将处于不安全环境，实时防护和后台查杀都会停止。',
        okText: '仍然关闭',
        cancelText: '继续保护',
      ),
    );
    if (yes != true) return false;
    if (needPwd) {
      final ok = await _askPassword('关闭软件');
      if (!ok) return false;
    }
    return true;
  }

  /// 密码验证弹窗，通过返回 true
  Future<bool> _askPassword(String action) async {
    if (!mounted) return false;
    final ctrl = TextEditingController();
    var err = '';
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => QDialog(
          icon: Icons.lock_rounded,
          title: '需要验证身份',
          body: "执行「$action」需要密码。${err.isEmpty ? '' : '\n$err'}",
          okText: '验证',
          cancelText: '取消',
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(hintText: '输入密码', isDense: true),
            ),
          ),
          onOk: () {
            final r = Api.passwordVerify(ctrl.text);
            if (r['success'] == true) {
              Navigator.of(ctx).pop(true);
            } else {
              setS(() => err = r['message']?.toString() ?? '密码错误');
            }
          },
        ),
      ),
    );
    ctrl.dispose();
    return ok == true;
  }

  /// 启动自检：系统版本过低 / 只是被单独提取出来，都明说，不给白屏
  Future<void> _envCheck() async {
    final os = Api.osVersion();
    if (os['success'] == true && os['data'] is Map && os['data']['supported'] == false) {
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => QDialog(
          icon: Icons.error_outline_rounded,
          title: '系统版本过低',
          body: "${os['data']['label']}（内部版本 ${os['data']['build']}）。\n\n${os['data']['tip']}",
          okText: '知道了',
        ),
      );
      return;
    }

    final env = Api.envCheck();
    if (env['success'] == true && env['data'] is Map && env['data']['ok'] == false) {
      final installed = env['data']['installed'] == true;
      if (!installed) {
        if (!mounted) return;
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => QDialog(
            icon: Icons.folder_off_rounded,
            title: '安装错误',
            body: '检测到本程序只是被单独提取出来的文件，没有走安装流程，缺少必要组件，无法正常工作。\n'
                '缺的东西：${(env['data']['issues'] as List?)?.join('、') ?? '未知'}\n\n'
                '点确定后本程序会关闭，请先运行安装包完成安装，再从安装目录打开。',
            okText: '确定',
          ),
        );
        // 点确认直接关掉，不留下一个跑不起来的空壳
        exit(0);
      }
    }
  }

  Future<void> _guard() async {
    final st = Api.passwordState();
    if (st['success'] != true || st['data'] is! Map || st['data']['enabled'] != true) return;
    await _askPassword('打开软件');
  }

  Future<void> _maybeWelcome() async {
    final first = await AppSettings.firstRun();
    if (!mounted) return;
    if (!first) return;
    final res = await showDialog<List<Object>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => WelcomeSheet(
        initial: ToolboxApp.of(context)?._theme ?? ThemeOption.system,
        initialLang: I18n.lang,
      ),
    );
    if (res != null) {
      final t = res[0] as ThemeOption;
      final lang = res[1] as String;
      ToolboxApp.of(context)?.setTheme(t);
      if (mounted) setState(() => I18n.lang = lang);
      await _applyMaterial();
    }
  }

  /// 按材质档切窗口本体特效：
  /// 混搭 / 云母 / 液态玻璃 → 系统 Mica；Aero → Acrylic（最接近 Win7 雾面玻璃）；纯色 → Solid
  Future<void> _applyMaterial() async {
    if (!Platform.isWindows) return;
    if (!mounted) return;
    try {
      final dark = Theme.of(context).brightness == Brightness.dark;
      switch (currentMatStyle()) {
        case MatStyle.auto:
        case MatStyle.mica:
        case MatStyle.glass:
          // Win11 用 Mica；Win10 上 Mica 不生效，退回 Acrylic
          try {
            await Window.setEffect(effect: WindowEffect.mica, dark: dark);
          } catch (_) {
            await Window.setEffect(effect: WindowEffect.acrylic, dark: dark);
          }
        case MatStyle.aero:
          // 原生 Aero 玻璃，Win7/Vista 那种
          await Window.setEffect(effect: WindowEffect.aero, dark: dark);
        case MatStyle.solid:
          await Window.setEffect(effect: WindowEffect.solid);
      }
    } catch (_) {}
  }

  Widget _page() {
    switch (_index) {
      case 1:
        return const CleanPage();
      case 2:
        return const ScanPage();
      case 3:
        return const ToolsPage();
      case 4:
        return const QuarantinePage();
      case 5:
        return const SettingsPage();
      default:
        return const HardwarePage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    // 每次前台启动播一遍 OOBE；最小化还原不重播（进程没重启）
    if (_oobe) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: OobeIntro(onDone: () => setState(() => _oobe = false)),
        ),
      );
    }

    final content = Stack(
        children: [
          Positioned.fill(child: DecoratedBox(decoration: AppTheme.background(brightness))),
          Positioned.fill(child: ParticleLayer()),
          Positioned(top: -120, left: -100, child: FloatingBlob(color: AppTheme.blobTop(brightness), size: 320, phase: 0.4)),
          Positioned(bottom: -160, right: -130, child: FloatingBlob(color: AppTheme.blobBottom(brightness), size: 400, phase: 2.1)),

          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 96),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: AnimatedSwitcher(
                  duration: Ui.dur('pageTransition', 340),
                  switchInCurve: Ui.curve('pageTransition'),
                  switchOutCurve: Ui.isOn('pageTransition') ? Ui.spring : Curves.linear,
                  transitionBuilder: (child, anim) {
                    if (!Ui.isOn('pageTransition')) return child;
                    final curved = CurvedAnimation(parent: anim, curve: Ui.spring);
                    return FadeTransition(
                      opacity: curved,
                      child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(curved), child: child),
                    );
                  },
                  child: Container(
                    key: ValueKey(_index),
                    decoration: BoxDecoration(
                      color: brightness == Brightness.dark
                          ? const Color(0xFF11151D).withOpacity(Ui.glass.value ? 0.34 : 0.92)
                          : Colors.white.withOpacity(Ui.glass.value ? 0.42 : 0.94),
                      borderRadius: BorderRadius.circular(26),
                    ),
                    child: _page(),
                  ),
                ),
              ),
            ),
          ),

          // 悬浮液态玻璃 Dock
          Positioned(
            left: 0,
            right: 0,
            bottom: 22,
            child: Center(child: _Dock(index: _index, icons: _icons, onTap: (i) => setState(() => _index = i))),
          ),

          // 窗口标题栏（拖动区 + 三键）
          const Positioned(top: 0, left: 0, right: 0, child: _WindowBar()),

          // 悬浮监控窗
          if (Ui.floating.value) const FloatingMonitor(),

          // 水纹层压在最上面：收指针事件但不挡点击
          const Positioned.fill(child: WaterRipple()),
        ],
      );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: content,
      ),
    );
  }
}

class _WindowBar extends StatelessWidget {
  const _WindowBar();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget btn(IconData icon, VoidCallback onTap) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(padding: const EdgeInsets.all(8), child: Icon(icon, size: 14)),
        );

    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) {
                if (Platform.isWindows) windowManager.startDragging();
              },
              onDoubleTap: () async {
                if (!Platform.isWindows) return;
                if (await windowManager.isMaximized()) {
                  windowManager.unmaximize();
                } else {
                  windowManager.maximize();
                }
              },
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(
                    'QW 电脑安全管家',
                    style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38),
                  ),
                ),
              ),
            ),
          ),
          if (Platform.isWindows) ...[
            btn(Icons.remove_rounded, () => windowManager.minimize()),
            btn(Icons.crop_square_rounded, () async {
              if (await windowManager.isMaximized()) {
                windowManager.unmaximize();
              } else {
                windowManager.maximize();
              }
            }),
            btn(Icons.close_rounded, () => windowManager.close()),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _Dock extends StatelessWidget {
  final int index;
  final List<IconData> icons;
  final ValueChanged<int> onTap;

  const _Dock({required this.index, required this.icons, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glass = Ui.glass.value && Ui.isOn('dockGlass');

    final bar = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: glass
            ? (isDark ? const Color(0xFF1A1F29).withOpacity(0.55) : Colors.white.withOpacity(0.62))
            : (isDark ? const Color(0xFF1B2029) : Colors.white),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(glass ? (isDark ? 0.16 : 0.80) : 0.10), width: 1.1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(glass ? (isDark ? 0.42 : 0.14) : 0.10),
            blurRadius: glass ? 30 : 14,
            offset: const Offset(0, 10),
          ),
          if (glass) BoxShadow(color: Colors.white.withOpacity(isDark ? 0.06 : 0.55), blurRadius: 12, offset: const Offset(-5, -5)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < icons.length; i++) ...[
            _DockItem(
              icon: icons[i],
              label: [I18n.t('hw'), I18n.t('clean'), I18n.t('scan'), I18n.t('tools'), '隔离库'][i],
              selected: index == i,
              onTap: () => onTap(i),
            ),
            const SizedBox(width: 4),
          ],
          Container(width: 1, height: 24, color: isDark ? Colors.white24 : Colors.black12, margin: const EdgeInsets.symmetric(horizontal: 6)),
          _DockItem(icon: Icons.settings_rounded, label: I18n.t('settings'), selected: index == 5, onTap: () => onTap(5)),
        ],
      ),
    );

    if (!glass) return bar;

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(filter: Ui.realtimeBlur.value ? ImageFilter.blur(sigmaX: 22, sigmaY: 22) : ImageFilter.blur(sigmaX: 0, sigmaY: 0), child: bar),
    );
  }
}

class _DockItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DockItem({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  State<_DockItem> createState() => _DockItemState();
}

class _DockItemState extends State<_DockItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = widget.selected ? const Color(0xFF2F7BFF) : (isDark ? Colors.white70 : Colors.black54);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Ui.dur('dockSpring', 220),
          curve: Ui.curve('dockSpring'),
          padding: EdgeInsets.symmetric(horizontal: widget.selected || _hover ? 14 : 10, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: widget.selected
                ? const Color(0xFF2F7BFF).withOpacity(isDark ? 0.24 : 0.13)
                : (_hover ? (isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04)) : Colors.transparent),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 19, color: fg),
              if (widget.selected || _hover) ...[
                const SizedBox(width: 7),
                Text(widget.label, style: TextStyle(fontSize: 12.5, fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500, color: fg)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
