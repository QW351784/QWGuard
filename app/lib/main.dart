import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/window_manager.dart';

import 'api.dart';
import 'glass_shader.dart';
import 'bridge.dart';
import 'i18n.dart';
import 'installer.dart';
import 'oobe.dart';
import 'pages.dart';
import 'state.dart';
import 'theme.dart';
import 'update_util.dart';
import 'desktop_monitor.dart';
import 'floating_monitor.dart';

/// 安装 / 卸载窗口的标题
///
/// 之前这两个分支进来什么都没设，窗口标题就是 flutter create 脚手架里的
/// 工程名 `system_toolbox` —— 用户截图左上角那个英文就是它，必须改成中文。
/// 把本程序登记成「高性能 GPU」
///
/// Flutter 在 Windows 上走 ANGLE → D3D11，由系统按默认策略挑显卡。
/// 双显卡机器（核显 + 独显）上默认给的是**核显** —— 界面上那些模糊、
/// 折射、合成全压在核显上，占用率直接飙到 90%，用户还以为在消耗 4060。
/// 在 HKCU 的 DirectX\UserGpuPreferences 里把本 exe 标成 GpuPreference=2
/// （2 = 高性能），系统就会把它分给独显。生效时机是下一次启动。
Future<void> _preferHighPerformanceGpu() async {
  if (!Platform.isWindows) return;
  try {
    final exe = Platform.resolvedExecutable;
    await Process.run('reg', [
      'add',
      r'HKCU\SOFTWARE\Microsoft\DirectX\UserGpuPreferences',
      '/v',
      exe,
      '/t',
      'REG_SZ',
      '/d',
      'GpuPreference=2;',
      '/f',
    ]);
  } catch (_) {}
}

Future<void> _setupWindow({bool silent = false}) async {
  if (!Platform.isWindows) return;
  try {
    await windowManager.ensureInitialized();
    // 尺寸必须显式给：以前只设了标题，用的是 flutter create 脚手架的默认
    // 1280x720，在 1080p 屏上被系统缩放后几乎铺满整块屏幕 ——
    // 一个安装向导占满全屏，看起来就像软件本体，而不是「安装器」。
    // 真软件的安装窗口一般 800-900 宽，这里定 900x620、居中、不可放大。
    const opts = WindowOptions(
      size: Size(920, 660),
      minimumSize: Size(900, 640),
      center: true,
      title: 'QW 安全电脑管家',
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      if (silent) {
        // 自动更新：不在前台露安装向导，窗口只作为 Flutter 引擎的宿主
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    });
    await windowManager.setResizable(false);
    await windowManager.setMaximizable(false);
    // 让 DWM 的 Mica 从客户区透出来；Scaffold/背景层再用低透明度柔光上色。
    try {
      await windowManager.setBackgroundColor(Colors.transparent);
    } catch (_) {}
  } catch (_) {}
}

String _argValue(List<String> args, String prefix) {
  for (final a in args) {
    if (a.startsWith(prefix)) return a.substring(prefix.length);
  }
  return '';
}

/// 从 Windows DWM 读系统强调色，作为 Material 3 的种子色实现动态取色。
/// 读不到 / 非 Windows / 颜色太灰太暗时回退品牌蓝，不影响启动。
Future<Color?> _readSystemAccent() async {
  if (!Platform.isWindows) return null;
  try {
    final r = await Process.run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\DWM',
      '/v',
      'ColorizationColor',
    ]);
    if (r.exitCode != 0) return null;
    final m = RegExp(r'0x[0-9a-fA-F]{8}').firstMatch(r.stdout.toString());
    if (m == null) return null;
    final v = int.parse(m.group(0)!.substring(2), radix: 16);
    final rgb = v & 0xFFFFFF;
    if (rgb == 0) return null;
    final c = Color(0xFF000000 | rgb);
    final hsl = HSLColor.fromColor(c);
    if (hsl.saturation < 0.18) return AppTheme.fallbackSeed;
    return hsl
        .withSaturation(hsl.saturation.clamp(0.30, 0.80).toDouble())
        .withLightness(hsl.lightness.clamp(0.38, 0.68).toDouble())
        .toColor();
  } catch (_) {
    return null;
  }
}

/// 整个主程序、安装向导、卸载器都以管理员运行。
/// 不靠 exe 清单（mt.exe 合并清单在 CI 上会 LNK1327），而是运行时判断后 UAC 重开自己。
Future<void> _ensureAdminMode(List<String> args) async {
  if (!Platform.isWindows) return;
  if (args.contains('--elevated')) {
    // 已经是被 UAC 拉起来的那一份，仍然不是管理员就只能报错，避免无限重开。
    if (!Api.isElevatedNow()) {
      final p =
          File('${Platform.environment['TEMP'] ?? '.'}\\qwguard-elevate.txt');
      try {
        p.writeAsStringSync('UAC 提权失败：新进程仍不是管理员。');
      } catch (_) {}
      exit(1);
    }
    return;
  }
  if (Api.isElevatedNow()) return;

  final exe = Platform.resolvedExecutable;
  final next = <String>[...args, '--elevated'];
  String q(String v) => "'${v.replaceAll("'", "''")}'";
  final argList = next.map(q).join(',');
  final script =
      "Start-Process -FilePath ${q(exe)} -ArgumentList @($argList) -Verb RunAs";
  try {
    final r = await Process.run(
      'powershell',
      ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', script],
    );
    if (r.exitCode != 0) {
      final p =
          File('${Platform.environment['TEMP'] ?? '.'}\\qwguard-elevate.txt');
      p.writeAsStringSync('UAC 被取消或启动失败：${r.stderr}');
    }
  } catch (e) {
    final p =
        File('${Platform.environment['TEMP'] ?? '.'}\\qwguard-elevate.txt');
    try {
      p.writeAsStringSync('UAC 启动异常：$e');
    } catch (_) {}
  }
  exit(0);
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await _ensureAdminMode(args);
  // 安装向导也要走 Mica：必须在任何窗口分支之前初始化 Acrylic 桥。
  // 之前这行放在主程序分支后面，--setup 提前 return，安装窗口永远没有窗口级云母。
  if (Platform.isWindows) {
    try {
      await Window.initialize();
    } catch (_) {}
  }
  await _preferHighPerformanceGpu();
  final accent = await _readSystemAccent();
  if (accent != null) AppTheme.setSeed(accent);

  // 安装 / 卸载模式：跟主程序同一个二进制，靠参数分流
  if (args.contains('--setup') || args.contains('--uninstall')) {
    final silent = args.contains('--silent');
    final dirArg = args.firstWhere(
      (a) => a.startsWith('--dir='),
      orElse: () => '',
    );
    await _setupWindow(silent: silent);
    runApp(
      SetupApp(
        uninstall: args.contains('--uninstall'),
        silent: silent,
        initialDir: dirArg.isEmpty ? null : dirArg.substring('--dir='.length),
        assetTime: _argValue(args, '--asset-time='),
      ),
    );
    return;
  }

  // 同一份二进制按「文件名」分流：
  //   QWGuard-Setup.exe      → 安装向导
  //   QWGuard-Uninstall.exe  → 卸载向导
  // 这样装包 / 卸包都是独立的 exe，用户双击就进对应界面，
  // 不用带参数、不用记命令行，也共用同一套 Flutter 引擎和玻璃动画。
  if (Platform.isWindows) {
    final exeName = Platform.resolvedExecutable
        .split(Platform.pathSeparator)
        .last
        .toLowerCase();
    if (exeName.contains('setup')) {
      final silent = args.contains('--silent');
      final dirArg = args.firstWhere(
        (a) => a.startsWith('--dir='),
        orElse: () => '',
      );
      await _setupWindow(silent: silent);
      runApp(
        SetupApp(
          uninstall: false,
          silent: silent,
          initialDir: dirArg.isEmpty ? null : dirArg.substring('--dir='.length),
          assetTime: _argValue(args, '--asset-time='),
        ),
      );
      return;
    }
    if (exeName.contains('uninstall')) {
      runApp(const SetupApp(uninstall: true));
      return;
    }
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
      // 之前是 Colors.transparent —— 透明窗口会让 DWM 每帧把整窗重新合成一遍，
      // 这是 4060 上空闲还占 40% 的主要来源，而且核显机器根本扛不住。
      // 圆角交给 Windows 11 自己裁（无边框窗口系统会给 DWMWCP_ROUND），
      // 代价是 Win10 上角是直角 —— 拿圆角换掉整窗合成，值得。
      backgroundColor: Color(0xFF14171D),
      titleBarStyle: TitleBarStyle.hidden,
      title: 'QW 安全电脑管家',
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  await GlassShader.load();
  runApp(ToolboxApp(initialTheme: theme));
  WidgetsBinding.instance.addPostFrameCallback((_) => _autoUpdateCheck());
}

/// 启动后在后台检查一次更新：有新版就直接下载安装包并以静默模式拉起安装器。
/// 不在前台弹窗，也不打断用户当前操作；安装器窗口会被隐藏。
Future<void> _autoUpdateCheck() async {
  if (!Platform.isWindows) return;
  try {
    final sp = await SharedPreferences.getInstance();
    final repo = sp.getString('github_repo') ?? 'QW351784/QWGuard';
    if (repo.trim().isEmpty) return;
    final sec = Api.securitySettings();
    final silent = sec['success'] == true && sec['data'] is Map
        ? (sec['data'] as Map)['silent_update'] != false
        : true;
    if (!silent) return;
    final r = Api.update(repo.trim(), UpdateUtil.currentVersion);
    if (r['success'] != true || r['data'] is! Map) return;
    final d = (r['data'] as Map).cast<String, dynamic>();
    final url = d['download_url']?.toString() ?? '';
    // 版本更高，或同版本但 Release/资产是重新发布的，都走升级
    if (!await UpdateUtil.shouldUpdate(d) || url.isEmpty) return;
    final dst = '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'QWGuard-update-${DateTime.now().millisecondsSinceEpoch}.exe';
    final dl = Api.downloadUpdate(url, dst);
    if (dl['success'] != true) return;
    final installDir = File(Platform.resolvedExecutable).parent.path;
    final assetTime = d['download_updated_at']?.toString() ??
        d['published_at']?.toString() ??
        '';
    await Process.start(
        dst,
        [
          '--silent',
          '--dir=$installDir',
          '--asset-time=$assetTime',
        ],
        mode: ProcessStartMode.detached);
    // 给安装器留出解包时间，然后退出主程序，避免它占着要替换的 exe/dll。
    await Future.delayed(const Duration(seconds: 3));
    exit(0);
  } catch (_) {
    // 更新失败不影响正常启动；下次启动会再试。
  }
}

class ToolboxApp extends StatefulWidget {
  final ThemeOption initialTheme;
  const ToolboxApp({super.key, required this.initialTheme});

  static _ToolboxAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<_ToolboxAppState>();

  @override
  State<ToolboxApp> createState() => _ToolboxAppState();
}

class _ToolboxAppState extends State<ToolboxApp> with WidgetsBindingObserver {
  late ThemeOption _theme = widget.initialTheme;
  Timer? _smartTimer;

  /// 给设置页读取当前主题用（_ToolboxAppState 是私有类型，但成员可以公开访问）
  ThemeOption get theme => _theme;

  /// 白天 06:00–18:00 算浅色，其余算深色。
  /// 不按系统深色开关走：用户明确要「白天浅色、晚上深色」的时间调度。
  bool get _isDayTime {
    final h = DateTime.now().hour;
    return h >= 6 && h < 18;
  }

  ThemeMode get _mode => switch (_theme) {
        ThemeOption.light => ThemeMode.light,
        ThemeOption.dark => ThemeMode.dark,
        ThemeOption.system => ThemeMode.system,
        ThemeOption.smart => _isDayTime ? ThemeMode.light : ThemeMode.dark,
      };

  @override
  void initState() {
    super.initState();
    Ui.theme.value = _theme;
    Ui.theme.addListener(_onThemeChanged);
    WidgetsBinding.instance.addObserver(this);
    _armSmartTimer();
  }

  @override
  void dispose() {
    Ui.theme.removeListener(_onThemeChanged);
    _smartTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onThemeChanged() {
    final t = Ui.theme.value;
    if (t == _theme) return;
    setState(() => _theme = t);
    _armSmartTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 睡眠唤醒后 Timer 可能被延后，恢复时立刻按当前时间重算一次
    if (state == AppLifecycleState.resumed &&
        _theme == ThemeOption.smart &&
        mounted) {
      setState(() {});
    }
  }

  /// 只在 06:00 / 18:00 两个边界唤醒，不做每分钟轮询
  void _armSmartTimer() {
    _smartTimer?.cancel();
    final now = DateTime.now();
    DateTime next;
    if (now.hour < 6) {
      next = DateTime(now.year, now.month, now.day, 6);
    } else if (now.hour < 18) {
      next = DateTime(now.year, now.month, now.day, 18);
    } else {
      next = DateTime(now.year, now.month, now.day + 1, 6);
    }
    final wait = next.difference(now) + const Duration(seconds: 1);
    _smartTimer = Timer(wait, () {
      _armSmartTimer();
      if (mounted && _theme == ThemeOption.smart) setState(() {});
    });
  }

  void setTheme(ThemeOption t) {
    if (Ui.theme.value == t) return;
    Ui.theme.value = t; // 监听器统一负责 setState 与重新排智能调度
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QW 安全电脑管家',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _mode,
      // 再兜一层：任何没有 Material 祖先的文本也不会继承到装饰线。
      builder: (context, child) => DefaultTextStyle.merge(
        style: const TextStyle(
          decoration: TextDecoration.none,
          decorationColor: Colors.transparent,
        ),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const Shell(),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell>
    with WindowListener, TrayListener, TickerProviderStateMixin {
  int _index = 0;
  bool _oobe = true;
  Timer? _tickerTimer;

  /// OOBE 交棒给主界面的那一段，照 HyperCeiler 的 provision 动画抄的参数：
  /// enter_home_anim：缩放 1.3 → 1.0、619ms、spring(damping 0.65, response 0.55s)；
  /// alpha 0 → 1、230ms、延迟 60ms、sine in-out。
  /// 这就是「新手设置完进入桌面」的观感：桌面从近处弹回落定，不是淡入。
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 619),
  );

  /// Tab 切换的入场动效：保留 IndexedStack 里的页面状态，只动整页的透明/位移/缩放。
  late final AnimationController _pageAnim = AnimationController(
    vsync: this,
    value: 1.0,
    duration: const Duration(milliseconds: 320),
  );

  /// 墙钟时钟：只在启动时归零，之后一直往前走。
  /// 用它而不是 Ticker 的 elapsed，是因为窗口最小化 / 失焦 / 被系统挂起时
  /// 引擎会停发帧，Ticker 也跟着停，恢复后画面等于"停在那"。
  final Stopwatch _clock = Stopwatch();

  /// 帧耗时发布的限速表（防止每帧写 notifier 造成自我驱动循环）
  final Stopwatch _framePubClock = Stopwatch();

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
    // 全局唯一动画时钟：60 秒一轮，所有动态层共用
    // 单调递增的秒数，不回绕：回绕会让 22s/14s 这种非整除周期在接缝处跳一帧
    _clock.start();
    // 开机就把安装目录里的 exe/dll 占住：运行期间 Explorer 删不掉，
    // 官方卸载器（先 taskkill 再清理）不受影响。
    Api.selfProtect();
    // 关键：这里不能再用 createTicker —— Ticker 一旦 start()，引擎就会持续按
    // 刷新率出帧、整窗重绘，回调里 return 也拦不住。这正是「动画全关、界面换成
    // 纯文本，GPU 仍 70%」的根因。改成普通定时器：没人监听就彻底不出帧。
    _syncTicker();

    // 这里原来还有一个 250ms 的「心跳定时器」，无条件把 Ui.tick 往前推。
    // 它的本意是「窗口挂起恢复后相位别错」，代价却是每 250ms 触发一次
    // 所有 repaint: Ui.tick 的画笔重绘 + 所有 AnimatedBuilder 重建，
    // 等于动画关掉之后每秒还在整窗重画四次。这就是 4060 上仍占 40% 的主因之一。
    // 恢复相位已经由 onWindowRestore / onWindowFocus 里的 _resumeAnim() 一次性处理，
    // 不需要常驻心跳，直接去掉。
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
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
        trayManager.addListener(this);
        _initTray();
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
    _pageAnim.dispose();
    _reveal.dispose();
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    _clock.stop();
    _tickerTimer?.cancel();
    for (final a in Ui.anims) {
      Ui.on(a.key).removeListener(_rebuild);
    }
    Ui.floating.removeListener(_rebuild);
    Ui.floatMetrics.removeListener(_rebuild);
    Ui.material.removeListener(_rebuild);
    if (Platform.isWindows) {
      try {
        windowManager.removeListener(this);
        trayManager.removeListener(this);
      } catch (_) {}
    }
    super.dispose();
  }

  /// 按需启停全局时钟。
  /// 之前是一个常驻的 16ms Timer：哪怕所有按帧动画都关着，它也每秒唤醒 60 次，
  /// 白白把事件循环叫醒、顺带把整窗推着重绘。现在只有真开着按帧动画时才启动，
  /// 其余时候彻底停摆 —— 静止时应当一帧都不出。
  void _syncTicker() {
    // 窗口失焦/最小化时直接停掉全局时钟：用户在别的程序里干活，
    // 管家不该还在后台每 16ms 重绘呼吸光/光斑。
    final need = Ui.perFrameActive && !_animPaused;
    if (need && _tickerTimer == null) {
      _tickerTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
        if (!Ui.tick.hasListeners) return;
        Ui.tick.value = _clock.elapsedMicroseconds / 1000000.0;
      });
    } else if (!need && _tickerTimer != null) {
      _tickerTimer!.cancel();
      _tickerTimer = null;
    }
  }

  void _switchPage(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _pageAnim.duration = Ui.dur('pageTransition', 320);
    _pageAnim.forward(from: 0);
  }

  void _rebuild() {
    _syncTicker();
    setState(() {});
    // 材质档变了（比如用户切到 Aero）要重设窗口特效，其余开关只重建界面
    _applyMaterial();
  }

  /// 帧回调：把每帧总耗时（build+raster）喂给 Ui.frameMs，设置页显示。
  ///
  /// 这里以前是**每帧无条件写一次**，而设置页挂在 IndexedStack 里永不销毁，
  /// 页面里的 ValueListenableBuilder 收到通知就重建 → 重建又请求下一帧 →
  /// 下一帧再写一次，自我驱动成 60fps 死循环。动画全关、界面换成纯文本都停
  /// 不下来，4060 上空闲 40% 的主因就是它。
  /// 现在：只在设置页可见时发布，且限速 2.5 次/秒、量化到 0.1ms。
  void _onFrameTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) return;
    if (_index != 5) return; // 只有设置页（IndexedStack 第 6 个）显示这个读数
    if (_framePubClock.isRunning && _framePubClock.elapsedMilliseconds < 400) {
      return;
    }
    _framePubClock
      ..reset()
      ..start();
    final ms = timings.last.totalSpan.inMicroseconds / 1000.0;
    final q = (ms * 10).roundToDouble() / 10.0;
    if ((q - Ui.frameMs.value).abs() > 0.05) Ui.frameMs.value = q;
  }

  // ===== 窗口事件：失焦/最小化停帧，恢复/聚焦时对齐时钟继续 =====
  bool _animPaused = false;

  @override
  void onWindowMinimize() {
    _animPaused = true;
    _syncTicker();
  }

  @override
  void onWindowBlur() {
    _animPaused = true;
    _syncTicker();
  }

  @override
  void onWindowRestore() {
    _animPaused = false;
    _resumeAnim();
    _syncTicker();
  }

  @override
  void onWindowFocus() {
    _animPaused = false;
    _resumeAnim();
    _syncTicker();
  }

  void _resumeAnim() {
    final v = _clock.elapsedMicroseconds / 1000000.0;
    if ((v - Ui.tick.value).abs() > 0.001) Ui.tick.value = v;
    if (mounted) setState(() {});
  }

  bool _trayReady = false;
  bool _quitAsked = false;

  /// 托盘：图标、悬停名、右键菜单。名字一律中文，不露英文 exe 名
  Future<void> _initTray() async {
    if (_trayReady) return;
    try {
      await trayManager.setIcon('assets/tray.ico');
      await trayManager.setToolTip('QW 安全电脑管家');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: '打开主界面'),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: '退出 QW 安全电脑管家'),
          ],
        ),
      );
      _trayReady = true;
    } catch (_) {}
  }

  /// 关窗口：只收进托盘，进程和后台防护继续跑 —— 不弹确认、不退出
  @override
  void onWindowClose() async {
    if (_quitAsked) return;
    try {
      await windowManager.hide();
    } catch (_) {}
  }

  Future<void> _showFromTray() async {
    try {
      await windowManager.show();
      await windowManager.focus();
      _resumeAnim();
      // 等窗口真的可见再往下走。紧接着就 showDialog 时，如果窗口还没完成
      // 显示，弹框会挂到一个尚未可见的 surface 上，用户仍然看不到。
      await Future<void>.delayed(const Duration(milliseconds: 120));
    } catch (_) {}
  }

  /// 托盘菜单里点「退出」。
  /// 注意：点退出时窗口是 hide() 状态，必须先把窗口叫出来，
  /// 否则 showDialog 会渲染在那个不可见的窗口上 —— 用户看不到框、
  /// 没处可点，await 永远挂着，表现就是「点退出没反应、托盘一直在」。
  Future<void> _quitApp() async {
    await _showFromTray();
    if (!mounted) return;

    // 退出必须提示：退出后防护全停，这台电脑就不再受保护
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => QDialog(
        icon: Icons.power_settings_new_rounded,
        title: '确定要退出吗？',
        body: '退出后实时防护和后台查杀都会停止，这台电脑将不再受保护。',
        okText: '仍然退出',
        cancelText: '继续保护',
        // 用户要求：仍然退出在左，继续保护在右
        swapActions: true,
      ),
    );
    if (yes != true) return;

    final st = Api.passwordState();
    final needPwd = st['success'] == true &&
        st['data'] is Map &&
        st['data']['enabled'] == true;
    if (needPwd) {
      final ok = await _askPassword('退出软件');
      if (!ok) return;
    }

    _quitAsked = true;
    try {
      await trayManager.destroy();
    } catch (_) {}
    // 退出前先淡出。之前窗口是「啪」一下直接消失，没有任何过渡，
    // 看着像崩了而不是退出。逐帧降不透明度，约 220ms 走完。
    try {
      for (var i = 10; i >= 0; i--) {
        await windowManager.setOpacity(i / 10.0);
        await Future<void>.delayed(const Duration(milliseconds: 22));
      }
    } catch (_) {}
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {}
    // 兜底：destroy() 偶发卡在窗口线程上不返回，加个强制结束
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }

  @override
  void onTrayIconMouseDown() => _showFromTray();

  @override
  void onTrayIconRightMouseDown() {
    try {
      trayManager.popUpContextMenu();
    } catch (_) {}
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') _showFromTray();
    if (menuItem.key == 'exit') _quitApp();
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
              decoration: const InputDecoration(
                hintText: '输入密码',
                isDense: true,
              ),
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
    if (os['success'] == true &&
        os['data'] is Map &&
        os['data']['supported'] == false) {
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => QDialog(
          icon: Icons.error_outline_rounded,
          title: '系统版本过低',
          body:
              "${os['data']['label']}（内部版本 ${os['data']['build']}）。\n\n${os['data']['tip']}",
          okText: '知道了',
        ),
      );
      return;
    }

    final env = Api.envCheck();
    // 只有「真的缺文件」才拦。没有安装记录（免安装解压版）不算错误，
    // 以前拿 installed==false 就弹框退出，导致 portable 包根本打不开。
    if (env['success'] == true &&
        env['data'] is Map &&
        env['data']['ok'] == false) {
      final issues = (env['data']['issues'] as List?)?.join('、') ?? '未知';
      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => QDialog(
          icon: Icons.folder_off_rounded,
          title: '缺少必要文件',
          body: '程序目录里少了运行所需的文件，无法启动。\n'
              '缺的东西：$issues\n\n'
              '请重新解压完整压缩包，或运行安装包重新安装。',
          okText: '确定',
        ),
      );
      // 文件都不齐，留着也跑不起来
      exit(0);
    }
  }

  Future<void> _guard() async {
    final st = Api.passwordState();
    if (st['success'] != true ||
        st['data'] is! Map ||
        st['data']['enabled'] != true) return;
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

  /// 上一次真正下发的窗口特效。材质开关来回点时不重复调 DWM，
  /// 否则每切一次都会重建一次合成表面，看起来就是「云母闪一下」。
  String? _lastEffect;

  /// 按材质档切窗口本体特效：
  /// 混搭 / 云母 / 液态玻璃 → 系统 Mica；Aero → Acrylic（最接近 Win7 雾面玻璃）；纯色 → Solid
  Future<void> _applyMaterial() async {
    if (!Platform.isWindows) return;
    if (!mounted) return;
    try {
      final dark = Theme.of(context).brightness == Brightness.dark;
      final key = '${currentMatStyle().name}-$dark';
      if (_lastEffect == key) return;
      switch (currentMatStyle()) {
        case MatStyle.auto:
          // 智能搭配：窗口走系统级云母（Win11 Mica / Win10 Acrylic），
          // 卡片只贴半透明玻璃面，模糊由 DWM 提供，Flutter 侧不再逐卡 BackdropFilter。
          try {
            await Window.setEffect(effect: WindowEffect.mica, dark: dark);
          } catch (_) {
            await Window.setEffect(effect: WindowEffect.acrylic, dark: dark);
          }
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
      _lastEffect = key;
      // Mica / Acrylic 的实现会重设窗口样式，把我们之前设的无边框覆盖掉，
      // 结果原生标题栏（标题文字 + 三键）和我们自绘的那条同时出现 ——
      // 这就是截图里「标题栏和界面重叠」的另一半原因。这里补一刀。
      try {
        await windowManager.setAsFrameless();
      } catch (_) {}
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    // 每次前台启动播一遍 OOBE；最小化还原不重播（进程没重启）
    if (_oobe) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: ClipPath(
          // 之前这里用 ClipRRect（真圆弧），和主界面 SquircleClipper 的 squircle
          // 曲线不是同一条，切换时能看出角部在变形。统一成 squircle。
          clipper: SquircleClipper(24),
          child: DecoratedBox(
            // OobeIntro 自己不带底色，外层又是透明 Scaffold，
            // 不给它铺底整页就是透的
            decoration: AppTheme.background(brightness),
            child: OobeIntro(
              onDone: () {
                setState(() => _oobe = false);
                _reveal.forward(from: 0);
              },
            ),
          ),
        ),
      );
    }

    final content = Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: DecoratedBox(decoration: AppTheme.background(brightness)),
          ),
        ),
        Positioned.fill(
          child: ValueListenableBuilder<bool>(
            valueListenable: Ui.on('aurora'),
            builder: (_, on, __) => on
                ? const IgnorePointer(child: AuroraFlow())
                : const SizedBox.shrink(),
          ),
        ),
        Positioned.fill(child: ParticleLayer()),
        Positioned(
          top: -120,
          left: -100,
          child: FloatingBlob(
            color: AppTheme.blobTop(brightness),
            size: 320,
            phase: 0.4,
          ),
        ),
        Positioned(
          bottom: -160,
          right: -130,
          child: FloatingBlob(
            color: AppTheme.blobBottom(brightness),
            size: 400,
            phase: 2.1,
          ),
        ),

        Positioned.fill(
          child: RepaintBoundary(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 54, 18, 96),
              child: ClipPath(
                // 同心圆角：外框 24，内边距 18，内层就该是 24-18=6。
                // 之前写 26 —— 比外层还大，四个角直接被外层裁成直角，
                // 这就是「角部看着别扭」的另一半原因。
                clipper: SquircleClipper(6),
                child: Container(
                  decoration: BoxDecoration(
                    color: brightness == Brightness.dark
                        ? const Color(0xFF11151D)
                            .withOpacity(Ui.glass.value ? 0.34 : 0.92)
                        : Colors.white.withOpacity(
                            Ui.glass.value ? 0.42 : 0.94,
                          ),
                  ),
                  // 用 IndexedStack 而不是 AnimatedSwitcher：切页时旧页不再被销毁，
                  // 扫描进度、清理进度、已读到的硬件信息都留在原页面。
                  // 之前切到「工具合集」扫描就停、切回来进度归零，就是 AnimatedSwitcher
                  // 把页面 dispose 掉了。
                  child: AnimatedBuilder(
                    animation: _pageAnim,
                    child: IndexedStack(
                      index: _index,
                      children: const [
                        HardwarePage(),
                        CleanPage(),
                        ScanPage(),
                        ToolsPage(),
                        QuarantinePage(),
                        SettingsPage(),
                      ],
                    ),
                    builder: (_, child) {
                      final v = Curves.easeOutCubic.transform(_pageAnim.value);
                      return Opacity(
                        opacity: 0.72 + 0.28 * v,
                        child: Transform.translate(
                          offset: Offset(0, 16 * (1 - v)),
                          child: Transform.scale(
                            scale: 0.985 + 0.015 * v,
                            child: child,
                          ),
                        ),
                      );
                    },
                  ),
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
          child: Center(
            child: RepaintBoundary(
              child: _Dock(index: _index, icons: _icons, onTap: _switchPage),
            ),
          ),
        ),

        // 窗口标题栏（拖动区 + 三键）
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: RepaintBoundary(child: const _WindowBar()),
        ),

        // 悬浮监控窗
        if (Ui.floating.value) const FloatingMonitor(),

        // OOBE 交接的白光：从中心扩散到整屏，和主界面的缩放/去虚化同步
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _reveal,
              builder: (_, __) {
                if (_reveal.isCompleted) return const SizedBox.shrink();
                final t = Curves.easeOutQuint.transform(_reveal.value);
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: 0.06 + 1.25 * t,
                      colors: [
                        Colors.white.withOpacity(0.30 * (1 - t)),
                        Colors.white.withOpacity(0.0),
                      ],
                      stops: const [0.0, 1.0],
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        // 水纹层压在最上面：收指针事件但不挡点击
        const Positioned.fill(child: WaterRipple()),
      ],
    );

    // 窗口现在是不透明底（0xFF14171D），外层再套 ClipPath 裁圆角的话，
    // 被裁掉的四个角会露出窗口底色 —— 浅色主题下就是四块深色缺口，
    // 这就是「角没适配好」的真正原因。圆角交给 Windows 自己裁（Win11 会给
    // DWMWCP_ROUND），Flutter 这层不再重复裁。
    // 动画结束就返回原样的 child，不再保留任何 saveLayer ——
    // 否则 ImageFiltered 会一直挂在整棵树上，静态界面也要多画一层。
    final shown = AnimatedBuilder(
      animation: _reveal,
      builder: (_, child) {
        if (_reveal.isCompleted) return child!;
        final v = const _SpringCurve().transform(_reveal.value);
        // alpha：60ms 起、230ms 到 1，对应原版 startOffset=60 + duration=230
        final a = const Interval(
          60 / 619,
          290 / 619,
          curve: Curves.easeInOutSine,
        ).transform(_reveal.value);
        return Opacity(
          opacity: a,
          child: Transform.scale(scale: 1.3 - 0.3 * v, child: child),
        );
      },
      child: content,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => Ui.burst(e.localPosition),
        child: shown,
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
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 14),
          ),
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
                    'QW 安全电脑管家',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
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
            ? (isDark
                ? const Color(0xFF1A1F29).withOpacity(0.55)
                : Colors.white.withOpacity(0.62))
            : (isDark ? const Color(0xFF1B2029) : Colors.white),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.white.withOpacity(
            glass ? (isDark ? 0.16 : 0.80) : 0.10,
          ),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(
              glass ? (isDark ? 0.42 : 0.14) : 0.10,
            ),
            blurRadius: glass ? 30 : 14,
            offset: const Offset(0, 10),
          ),
          if (glass)
            BoxShadow(
              color: Colors.white.withOpacity(isDark ? 0.06 : 0.55),
              blurRadius: 12,
              offset: const Offset(-5, -5),
            ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < icons.length; i++) ...[
            _DockItem(
              icon: icons[i],
              label: [
                I18n.t('hw'),
                I18n.t('clean'),
                I18n.t('scan'),
                I18n.t('tools'),
                '隔离库',
              ][i],
              selected: index == i,
              onTap: () => onTap(i),
            ),
            const SizedBox(width: 4),
          ],
          Container(
            width: 1,
            height: 24,
            color: isDark ? Colors.white24 : Colors.black12,
            margin: const EdgeInsets.symmetric(horizontal: 6),
          ),
          _DockItem(
            icon: Icons.settings_rounded,
            label: I18n.t('settings'),
            selected: index == 5,
            onTap: () => onTap(5),
          ),
        ],
      ),
    );

    if (!glass) return bar;

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: Ui.realtimeBlur.value
            ? ImageFilter.blur(sigmaX: 22, sigmaY: 22)
            : ImageFilter.blur(sigmaX: 0, sigmaY: 0),
        child: bar,
      ),
    );
  }
}

class _DockItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DockItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_DockItem> createState() => _DockItemState();
}

class _DockItemState extends State<_DockItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = widget.selected
        ? const Color(0xFF2F7BFF)
        : (isDark ? Colors.white70 : Colors.black54);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Ui.dur('dockSpring', 220),
          curve: Ui.curve('dockSpring'),
          padding: EdgeInsets.symmetric(
            horizontal: widget.selected || _hover ? 14 : 10,
            vertical: 9,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: widget.selected
                ? const Color(0xFF2F7BFF).withOpacity(isDark ? 0.24 : 0.13)
                : (_hover
                    ? (isDark
                        ? Colors.white.withOpacity(0.06)
                        : Colors.black.withOpacity(0.04))
                    : Colors.transparent),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 19, color: fg),
              if (widget.selected || _hover) ...[
                const SizedBox(width: 7),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight:
                        widget.selected ? FontWeight.w700 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// HyperCeiler provision 的 enter_home spring：damping 0.65 / response 0.55s。
/// Android 的 response 是弹簧周期量级，这里换算成 Flutter 的 stiffness。
/// 归一化到 0→1，允许轻微过冲（原版就是弹一下再落定）。
class _SpringCurve extends Curve {
  const _SpringCurve();
  static final SpringDescription _desc = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 130,
    ratio: 0.65,
  );
  @override
  double transform(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    final sim = SpringSimulation(_desc, 0, 1, 0);
    final end = sim.x(0.619);
    return sim.x(t * 0.619) / (end == 0 ? 1 : end);
  }
}
