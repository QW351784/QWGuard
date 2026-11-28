import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

import 'api.dart';
import 'state.dart';
import 'theme.dart';
import 'update_util.dart';

/// 安装 / 卸载界面
///
/// 跟主程序共用同一套 Flutter 引擎和主题，动画完全一致：
/// 液态玻璃、页面切换、呼吸型光效（这里强制开启，没有开关）。
/// 配色不跟随软件设置，而是跟随系统深浅色。
class SetupApp extends StatefulWidget {
  final bool uninstall;

  /// 自动更新：不显示向导，直接按原安装目录静默覆盖升级
  final bool silent;

  /// 自动更新传入的原安装目录；为空时仍走推荐目录
  final String? initialDir;

  /// 自动更新传入的这次发布包时间；安装成功后写成本地更新基线
  final String? assetTime;
  const SetupApp({
    super.key,
    this.uninstall = false,
    this.silent = false,
    this.initialDir,
    this.assetTime,
  });

  @override
  State<SetupApp> createState() => _SetupAppState();
}

/// 后台 isolate 的入口必须只拿可发送的原始值，不能把 State 对象一起带进去。
/// 之前闭包直接读 `this._dir`，某些 Dart 版本会报 unsendable，安装线程还没跑就失败，
/// 界面就停在 0%。这里改成顶层函数 + Map 参数。
Map<String, dynamic> _installWorker(Map<String, Object?> a) {
  return Api.installRun(
    a['src']! as String,
    a['dst']! as String,
    desktopIcon: a['desktopIcon']! as bool,
    autostart: a['autostart']! as bool,
  );
}

class _SetupAppState extends State<SetupApp> {
  bool _dark = false;
  bool _ready = false;

  /// 0 欢迎  1 选项  2 进度  3 完成
  int _step = 0;
  String _dir = 'C:\\Program Files\\QWGuard';

  /// 首次算出来的推荐路径，用来看当前是不是还被用户改过
  String _recDir = '';
  bool _desktopIcon = true;
  // 安装过程不再询问自启动，装完在设置里开（默认保持关闭，不偷偷写注册表）
  bool _autostart = false;
  bool _busy = false;
  double _prog = 0.0;
  // 校验、写入各一条细进度条，主进度条显示整体；用户之前明确要求第二条。
  double _verifyProg = 0.0;
  double _copyProg = 0.0;
  String _phase = '准备中';
  String _file = '';
  String _hint = '';
  String _result = '';

  /// 上一步到底是成功还是失败。
  /// 以前没有这个字段，完成页不管结果如何都画绿勾 +「安装完成」，
  /// 失败原因只塞进正文小字里 —— 用户只看到那四个字，以为装好了。
  bool _ok = false;

  /// 卸载的两层确认
  bool _confirm1 = false;
  bool _confirm2 = false;

  /// 密码保护开启时，卸载前还要过这一关
  bool _needPwd = false;
  String _pwdErr = '';
  final TextEditingController _pwdCtrl = TextEditingController();

  /// 安装向导自己驱动一次全局动画时钟：主程序里的 _Ticker 只在主页面启动，
  /// --setup 分支提前 return，BreathingGlow / 折射 / 扫光都拿不到 tick。
  /// 所以以前“动画全开”在安装页其实只有静态玻璃。
  final Stopwatch _clock = Stopwatch();
  Timer? _ticker;

  void _startAnimations() {
    _clock
      ..reset()
      ..start();
    // 30fps 足够让极光/玻璃高光动起来，GPU 占用比 60fps 直接减半。
    _ticker ??= Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!mounted) return;
      Ui.tick.value = _clock.elapsedMicroseconds / 1000000.0;
    });
  }

  @override
  void initState() {
    super.initState();
    _startAnimations();
    _init();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _clock.stop();
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _applyWindowMaterial(bool dark) async {
    if (!Platform.isWindows) return;
    try {
      await Window.setEffect(effect: WindowEffect.mica, dark: dark);
    } catch (_) {
      try {
        await Window.setEffect(effect: WindowEffect.acrylic, dark: dark);
      } catch (_) {}
    }
  }

  Future<void> _init() async {
    // 卸载必须先拿管理员权限：安装目录的 ACL 默认只给 Administrators 删除权限，
    // 普通权限下删文件只会得到「拒绝访问」。
    if (widget.uninstall) {
      final e = Api.ensureElevated();
      final d = (e['data'] as Map?)?.cast<String, dynamic>();
      if (d?['relaunching'] == true) {
        // 提权实例已经拉起，这个普通权限的窗口必须退出，否则它自己也占着文件
        await Future.delayed(const Duration(milliseconds: 500));
        exit(0);
      }
      if (d?['elevated'] != true) {
        exit(0);
      }
    }
    final t = Api.systemTheme();
    final dark = t['success'] == true && t['data'] is Map
        ? (t['data']['dark'] == true)
        : false;
    String dir = _dir;
    final forced = widget.initialDir?.trim() ?? '';
    if (forced.isNotEmpty) {
      // 覆盖升级必须装回原位置，不能按“推荐盘符”另装一份
      dir = forced;
    } else {
      final rec = Api.recommendDir();
      if (rec['success'] == true && rec['data'] is Map) {
        final p = rec['data']['path']?.toString() ?? '';
        if (p.isNotEmpty) {
          // 新版 Rust 直接返回完整安装目录（%ProgramFiles%\QWGuard）。
          // 旧 DLL 只返回盘符根，兼容时再拼一次 QWGuard。
          final lower = p.toLowerCase();
          final alreadyInstallDir = lower.endsWith('qwguard') ||
              lower.endsWith('qwguard\\') ||
              lower.endsWith('qwguard/');
          if (alreadyInstallDir || widget.uninstall) {
            dir = p;
          } else {
            final base = p.endsWith('\\') || p.endsWith('/')
                ? p
                : '$p${Platform.pathSeparator}';
            dir = '${base}QWGuard';
          }
        }
      }
      // 推荐接口失败时仍装系统程序目录；安装器已经在管理员上下文里，
      // 不再退回 LocalAppData，避免“安装、卸载、主程序全程提权”变成一半普通权限。
      if (dir == _dir) {
        final pf = Platform.environment['ProgramFiles']?.trim() ?? '';
        if (pf.isNotEmpty) {
          dir = '$pf\\QWGuard';
        }
      }
    }
    if (!mounted) return;
    // 安装窗口先上云母，再画玻璃；Mica 是 DWM 合成，不额外吃 Flutter 的全屏模糊。
    await _applyWindowMaterial(dark);
    if (!mounted) return;
    setState(() {
      _dark = dark;
      _dir = dir;
      _recDir = dir;
      _ready = true;
    });
    if (widget.silent && !widget.uninstall) {
      // 等这一帧把状态落下去再跑安装，避免在 initState 里同步 setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _doInstall();
      });
    }
  }

  /// 高级选项：自定义安装位置（主程序可以改；工具箱里的工具、运行库不允许改）
  Future<void> _pickDir() async {
    final ctrl = TextEditingController(text: _dir);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义安装位置'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: r'例如 D:\QWGuard',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final p = ctrl.text.trim();
    if (p.isEmpty) return;
    if (mounted) setState(() => _dir = p);
  }

  Future<void> _doInstall() async {
    setState(() {
      _busy = true;
      _step = 2;
      _hint = '正在复制文件…';
    });
    // 源目录 = 自己所在的目录（安装包就是个完整 Release 目录）
    final exe = Platform.resolvedExecutable;
    final src = File(exe).parent.path;
    final pre = Api.installPrecheck(src);
    if (pre['success'] != true) {
      setState(() {
        _busy = false;
        _step = 1;
        _hint = pre['message']?.toString() ?? '环境自检失败';
      });
      return;
    }
    // 解压 + 校验 170MB 是纯 CPU/磁盘活，直接在 UI isolate 里调 FFI 会把消息循环堵死，
    // Windows 就给窗口挂上「未响应」。丢到后台 isolate，进度动画继续跑。
    _prog = 0;
    _verifyProg = 0;
    _copyProg = 0;
    _phase = '正在校验安装文件';
    // 每 120ms 读一次 Rust 侧的计数器：文件数 + 当前阶段
    final timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      final p = Api.installProgress();
      if (!mounted) return;
      if (p['success'] == true && p['data'] is Map) {
        final d = p['data'] as Map;
        final total = (d['total'] as num?)?.toDouble() ?? 0;
        final copied = (d['copied'] as num?)?.toDouble() ?? 0;
        final value = total <= 0 ? 0.0 : (copied / total).clamp(0.0, 1.0);
        final phase = d['phase']?.toString() ?? _phase;
        setState(() {
          _prog = value;
          _phase = phase;
          _file = d['file']?.toString() ?? '';
          if (phase.contains('校验')) _verifyProg = value;
          if (phase.contains('写入')) _copyProg = value;
          if (phase.contains('快捷方式')) _copyProg = 1.0;
        });
      }
    });
    final srcPath = src;
    final dstPath = _dir;
    final desktopIcon = _desktopIcon;
    final autostart = _autostart;
    Map<String, dynamic> r;
    try {
      r = await Isolate.run(() => _installWorker({
            'src': srcPath,
            'dst': dstPath,
            'desktopIcon': desktopIcon,
            'autostart': autostart,
          }));
    } catch (e) {
      r = {'success': false, 'message': '安装线程异常：$e'};
    } finally {
      timer.cancel();
    }
    final ok = r['success'] == true;
    setState(() {
      _busy = false;
      _step = 3;
      _ok = ok;
      _prog = ok ? 1.0 : _prog;
      if (ok) {
        _verifyProg = 1.0;
        _copyProg = 1.0;
      }
      _result = ok
          ? '已写入 ${r['data']?['copied'] ?? 0} 个文件'
          : (r['message']?.toString() ?? '安装失败');
    });
    if (ok && !widget.uninstall) {
      // 无论手动装还是静默升级，成功后都把这次包的发布时间记下来。
      // 下次同版本重发时，发布时间晚于这个基线才会再次升级。
      await UpdateUtil.writeInstallBaseline(widget.assetTime);
    }
    if (widget.silent) {
      // 静默升级没有界面可看，失败原因写到临时文件，方便排查
      try {
        File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}qw_update_result.txt',
        ).writeAsStringSync('${ok ? 'OK' : 'FAIL'}: $_result');
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 600));
      exit(ok ? 0 : 1);
    }
  }

  /// 点「确认卸载」后先查密码状态：开了密码保护就先弹输入页
  Future<void> _beforeUninstall() async {
    final st = Api.passwordState();
    final has = st['success'] == true &&
        st['data'] is Map &&
        (st['data'] as Map)['has_password'] == true;
    if (!has) {
      await _doUninstall();
      return;
    }
    setState(() {
      _needPwd = true;
      _pwdErr = '';
    });
  }

  Future<void> _submitPwd() async {
    final r = Api.passwordVerify(_pwdCtrl.text);
    if (r['success'] == true) {
      setState(() => _needPwd = false);
      await _doUninstall(pwd: _pwdCtrl.text);
    } else {
      setState(() => _pwdErr = r['message']?.toString() ?? '密码错误');
    }
  }

  Future<void> _doUninstall({String pwd = ''}) async {
    setState(() {
      _busy = true;
      _step = 2;
      _hint = '正在清理…';
    });
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final r = Api.uninstallRun(appDir, pwd: pwd);
    final ok = r['success'] == true;
    setState(() {
      _busy = false;
      _step = 3;
      _ok = ok;
      _result = ok ? '保护已取消，安装目录与注册表已清理' : (r['message']?.toString() ?? '卸载失败');
    });
  }

  @override
  Widget build(BuildContext context) {
    // 必须用 AppTheme，不能裸 ThemeData.light()：
    // 裸的没设 fontFamily，Flutter 默认 Roboto，中文全走系统回退字体，
    // 「包」这种带「巳」的字会被画得口不封、末笔竖折走形。
    // AppTheme 里 fontFamily 是 Microsoft YaHei，字形正常。
    final theme = _dark ? AppTheme.dark() : AppTheme.light();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        // 这里是安装器自己的窗口；Scaffold 透明，下面由 Mica 和极光层托底。
        // Scaffold 再写 transparent，整个向导就会透出桌面。必须自己画底色。
        // 透明底给 DWM 的 Mica 留出通道；真正的不透明兜底画在 _body/加载层里。
        backgroundColor: Colors.transparent,
        body: _ready
            ? _body()
            : ColoredBox(
                color:
                    _dark ? const Color(0xE614171D) : const Color(0xE6F4F7FB),
                child: const Center(child: CircularProgressIndicator()),
              ),
      ),
    );
  }

  Widget _body() {
    final accent =
        widget.uninstall ? const Color(0xFFFF6B6B) : const Color(0xFF2F7BFF);

    return Stack(
      children: [
        // 底层：低透明度极光柔光。Mica 在窗口下面，这里只上色不糊屏；
        // 动画由 _InstallerBackdrop 单层驱动，不再给每张卡开 BackdropFilter。
        Positioned.fill(
          child: _InstallerBackdrop(dark: _dark, accent: accent),
        ),
        Positioned(
          top: -150,
          right: -130,
          child: BreathingGlow(color: accent, size: 430, forceOn: true),
        ),
        Positioned(
          bottom: -210,
          left: -150,
          child: BreathingGlow(
            color: accent.withOpacity(0.72),
            size: 500,
            forceOn: true,
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860, maxHeight: 560),
            child: LiquidGlass(
              radius: 34,
              forceGlass: true,
              // 只保留外层这一张玻璃的折射/高光；它的背景已经由 Mica 和极光层提供。
              // 逐卡 BackdropFilter 是上一版 GPU 高的主因，这里直接关掉。
              blur: false,
              padding: EdgeInsets.zero,
              child: SizedBox(
                height: 560,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _rail(accent),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
                        child: ClipPath(
                          clipper: const SquircleClipper(24),
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                            decoration: BoxDecoration(
                              // 柔光玻璃：磨砂白，不做第二层实时模糊。
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: _dark
                                    ? [
                                        Colors.white.withOpacity(0.08),
                                        const Color(0xFF1B2435)
                                            .withOpacity(0.22),
                                      ]
                                    : [
                                        Colors.white.withOpacity(0.66),
                                        const Color(0xFFEAF1FF)
                                            .withOpacity(0.30),
                                      ],
                              ),
                              border: Border.all(
                                color: Colors.white.withOpacity(
                                  _dark ? 0.14 : 0.34,
                                ),
                                width: 0.9,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      widget.uninstall ? '卸载向导' : '安装向导',
                                      style: TextStyle(
                                        fontSize: 11,
                                        letterSpacing: 2.2,
                                        fontWeight: FontWeight.w600,
                                        color: _dark
                                            ? Colors.white54
                                            : const Color(0xFF65708A),
                                      ),
                                    ),
                                    const Spacer(),
                                    _tinyPill(
                                      widget.uninstall
                                          ? 'UNINSTALL'
                                          : 'SETUP 1.1.0',
                                      accent,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                Expanded(
                                  child: SingleChildScrollView(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 420,
                                      ),
                                      switchInCurve: Ui.spring,
                                      switchOutCurve: Curves.easeOutCubic,
                                      child: KeyedSubtree(
                                        key: ValueKey(
                                          '$_step-${widget.uninstall}-$_confirm2',
                                        ),
                                        child: _content(accent),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _rail(Color accent) {
    final activeUninstall = widget.uninstall
        ? (_confirm2 ? 2 : (_confirm1 ? 1 : (_needPwd ? 0 : 0)))
        : -1;
    final active = widget.uninstall ? activeUninstall : _step.clamp(0, 3);
    final labels = widget.uninstall
        ? ['确认卸载', '再次确认', '完成']
        : ['欢迎', '安装选项', '写入文件', '完成'];

    return Container(
      width: 274,
      padding: const EdgeInsets.fromLTRB(24, 26, 20, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _dark
              ? [accent.withOpacity(0.20), Colors.white.withOpacity(0.015)]
              : [accent.withOpacity(0.16), Colors.white.withOpacity(0.06)],
        ),
        border: Border(
          right: BorderSide(
            color: Colors.white.withOpacity(_dark ? 0.10 : 0.42),
            width: 0.8,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.white.withOpacity(0.92), accent],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withOpacity(0.38),
                      blurRadius: 20,
                      offset: const Offset(0, 7),
                    ),
                  ],
                ),
                child: Icon(
                  widget.uninstall
                      ? Icons.delete_outline_rounded
                      : Icons.shield_rounded,
                  color: Colors.white,
                  size: 27,
                ),
              ),
              Positioned(
                right: -5,
                top: -5,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _dark ? const Color(0xFF1A2436) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.24),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    '1.1.0',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: _dark ? Colors.white70 : const Color(0xFF526078),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Text(
            'QW 安全电脑管家',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            widget.uninstall ? '把保护从这台电脑上撤掉' : '硬件、垃圾、查杀、工具，一套装齐',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.55,
              color: _dark ? Colors.white54 : const Color(0xFF6B7690),
            ),
          ),
          const SizedBox(height: 34),
          ...List.generate(labels.length, (i) {
            return _railStep(
              index: i,
              label: labels[i],
              active: i == active,
              done: i < active,
              accent: accent,
              last: i == labels.length - 1,
            );
          }),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Colors.white.withOpacity(_dark ? 0.045 : 0.24),
              border: Border.all(
                color: Colors.white.withOpacity(_dark ? 0.08 : 0.32),
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.layers_rounded, size: 14, color: accent),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'Mica 云母 + 液态玻璃\n安装版 · Windows 10 / 11 x64',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.45,
                      color: _dark ? Colors.white54 : const Color(0xFF68748E),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _railStep({
    required int index,
    required String label,
    required bool active,
    required bool done,
    required Color accent,
    required bool last,
  }) {
    final fg = active
        ? (_dark ? Colors.white : const Color(0xFF15213A))
        : (_dark ? Colors.white.withOpacity(0.48) : const Color(0xFF7B859B));
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 8 : 15),
      child: Stack(
        children: [
          Positioned(
            left: 15,
            top: 28,
            bottom: last ? 0 : -15,
            child: Container(
              width: 1,
              color: Colors.white.withOpacity(_dark ? 0.10 : 0.34),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                width: 31,
                height: 31,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active
                      ? accent.withOpacity(_dark ? 0.30 : 0.16)
                      : Colors.white.withOpacity(_dark ? 0.04 : 0.24),
                  border: Border.all(
                    color: active
                        ? accent.withOpacity(0.72)
                        : Colors.white.withOpacity(_dark ? 0.14 : 0.40),
                    width: active ? 1.2 : 0.8,
                  ),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: accent.withOpacity(0.28),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: Center(
                  child: done
                      ? Icon(Icons.check_rounded, size: 16, color: accent)
                      : Text(
                          '0${index + 1}',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: active ? accent : fg,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ),
              if (active)
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tinyPill(String text, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: accent.withOpacity(_dark ? 0.16 : 0.10),
        border: Border.all(color: accent.withOpacity(0.22), width: 0.8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          letterSpacing: 1.0,
          fontWeight: FontWeight.w700,
          color: accent,
        ),
      ),
    );
  }

  Widget _content(Color accent) {
    if (widget.uninstall) {
      if (_needPwd) return _uninstallPassword(accent);
      if (!_confirm1) return _uninstallConfirm1(accent);
      if (!_confirm2) return _uninstallConfirm2(accent);
    }
    switch (_step) {
      case 0:
        return _welcome(accent);
      case 1:
        return _options(accent);
      case 2:
        return _progressView(accent);
      default:
        return _done(accent);
    }
  }

  // ---------- 安装 ----------

  Widget _welcome(Color accent) {
    final features = <(IconData, String)>[
      (Icons.memory_rounded, '硬件检测'),
      (Icons.cleaning_services_rounded, '垃圾清理'),
      (Icons.shield_moon_rounded, '病毒查杀'),
      (Icons.inventory_2_rounded, '隔离库'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: accent.withOpacity(_dark ? 0.14 : 0.09),
            border: Border.all(color: accent.withOpacity(0.22), width: 0.8),
          ),
          child: Text(
            widget.uninstall ? 'QW GUARD · 安全卸载' : 'QW GUARD · 1.1.0',
            style: TextStyle(
              fontSize: 9.5,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          widget.uninstall ? '确定要撤掉这道保护吗？' : '把安全管家装进这台电脑',
          style: const TextStyle(
            fontSize: 27,
            height: 1.22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          widget.uninstall
              ? '卸载会移除程序、隔离库和开机启动项。配置文件会一起清掉，之后不再有实时防护。'
              : '硬件检测、垃圾清理、病毒查杀、隔离库和一整套小工具，一次装齐。装完原目录可以删掉，程序独立运行。',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.65,
            color: _dark ? Colors.white60 : const Color(0xFF58647D),
          ),
        ),
        const SizedBox(height: 22),
        if (!widget.uninstall)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in features)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white.withOpacity(_dark ? 0.055 : 0.32),
                    border: Border.all(
                      color: Colors.white.withOpacity(_dark ? 0.10 : 0.42),
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(f.$1, size: 14, color: accent),
                      const SizedBox(width: 6),
                      Text(
                        f.$2,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        if (!widget.uninstall) const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: Colors.white.withOpacity(_dark ? 0.04 : 0.26),
            border: Border.all(
              color: Colors.white.withOpacity(_dark ? 0.08 : 0.38),
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.folder_special_rounded, size: 16, color: accent),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.uninstall ? '卸载目录' : '默认安装位置',
                      style: TextStyle(
                        fontSize: 10,
                        color: _dark ? Colors.white38 : const Color(0xFF7A8498),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _dir,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, height: 1.35),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            TextButton(onPressed: () => exit(0), child: const Text('取消')),
            const Spacer(),
            LiquidButton(
              text: widget.uninstall ? '开始卸载' : '下一步',
              icon: widget.uninstall
                  ? Icons.delete_outline_rounded
                  : Icons.arrow_forward_rounded,
              onTap: () {
                if (widget.uninstall) {
                  setState(() => _confirm1 = true);
                } else {
                  setState(() => _step = 1);
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _options(Color accent) {
    final custom = _dir != _recDir;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '安装选项',
          style: TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '装到系统程序目录，安装器会先请求管理员权限；不会因为 Program Files 的 ACL 写一半失败。',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.55,
            color: _dark ? Colors.white54 : const Color(0xFF66718A),
          ),
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Text(
              '安装位置',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: _dark ? Colors.white70 : const Color(0xFF39445A),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: accent.withOpacity(_dark ? 0.14 : 0.09),
              ),
              child: Text(
                custom ? '自定义' : '推荐',
                style: TextStyle(
                  fontSize: 9.5,
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        InkWell(
          borderRadius: BorderRadius.circular(15),
          onTap: _busy ? null : _pickDir,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              gradient: LinearGradient(
                colors: _dark
                    ? [
                        Colors.white.withOpacity(0.06),
                        Colors.white.withOpacity(0.02),
                      ]
                    : [
                        Colors.white.withOpacity(0.56),
                        Colors.white.withOpacity(0.24),
                      ],
              ),
              border: Border.all(
                color: Colors.white.withOpacity(_dark ? 0.12 : 0.46),
                width: 0.9,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: accent.withOpacity(_dark ? 0.16 : 0.10),
                  ),
                  child: Icon(Icons.folder_rounded, size: 17, color: accent),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _dir,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, height: 1.35),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '更改',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: accent.withOpacity(0.85),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 9),
        Row(
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 12,
              color: _dark ? Colors.white38 : const Color(0xFF7A8499),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                '默认路径在 %ProgramFiles%\\QWGuard，安装器需要管理员权限；点路径可改到 D 盘。',
                style: TextStyle(
                  fontSize: 10,
                  height: 1.45,
                  color: _dark ? Colors.white38 : const Color(0xFF7A8499),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.fromLTRB(10, 4, 12, 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            color: Colors.white.withOpacity(_dark ? 0.035 : 0.22),
            border: Border.all(
              color: Colors.white.withOpacity(_dark ? 0.07 : 0.34),
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: const VisualDensity(
                    horizontal: -3,
                    vertical: -3,
                  ),
                  value: _desktopIcon,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _desktopIcon = v ?? false),
                  title: const Text(
                    '创建桌面快捷方式',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    '装完后从桌面一键打开',
                    style: TextStyle(
                      fontSize: 9.5,
                      color: _dark ? Colors.white38 : const Color(0xFF8892A6),
                    ),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ),
            ],
          ),
        ),
        if (_hint.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            _hint,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFFE5484D)),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            TextButton(
              onPressed: _busy ? null : () => setState(() => _step = 0),
              child: const Text('上一步'),
            ),
            const Spacer(),
            LiquidButton(
              text: '开始安装',
              icon: Icons.download_rounded,
              onTap: _busy ? null : _doInstall,
            ),
          ],
        ),
      ],
    );
  }

  Widget _progressView(Color accent) {
    final pct = (_prog * 100).clamp(0, 100).toStringAsFixed(0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              pct,
              style: TextStyle(
                fontSize: 46,
                height: 0.95,
                fontWeight: FontWeight.w800,
                color: accent,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 5),
              child: Text(
                '%',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: accent.withOpacity(0.8),
                ),
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: Colors.white.withOpacity(_dark ? 0.055 : 0.30),
                border: Border.all(
                  color: Colors.white.withOpacity(_dark ? 0.10 : 0.38),
                  width: 0.8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 8,
                    height: 8,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.uninstall ? '正在卸载' : '正在安装',
                    style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _GlowProgress(value: _prog, color: accent),
        const SizedBox(height: 8),
        _StageBar(label: '校验', value: _verifyProg, color: accent),
        const SizedBox(height: 4),
        _StageBar(label: '写入', value: _copyProg, color: accent),
        const SizedBox(height: 18),
        Text(
          _phase,
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
        ),
        if (_file.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            _file,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              color: _dark ? Colors.white54 : const Color(0xFF7A8498),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            color: Colors.white.withOpacity(_dark ? 0.04 : 0.26),
            border: Border.all(
              color: Colors.white.withOpacity(_dark ? 0.08 : 0.36),
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Icon(
                widget.uninstall
                    ? Icons.folder_delete_outlined
                    : Icons.folder_open_rounded,
                size: 15,
                color: accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${widget.uninstall ? '卸载' : '安装'}到 $_dir',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '这段时间请不要关闭窗口。进度会按文件逐个推进，不会停在 0%。',
          style: TextStyle(
            fontSize: 10,
            color: _dark ? Colors.white38 : const Color(0xFF7A8498),
          ),
        ),
      ],
    );
  }

  Widget _done(Color accent) {
    final failed = !_ok;
    final color = failed ? const Color(0xFFE5484D) : accent;
    final title = failed
        ? (widget.uninstall ? '卸载失败' : '安装失败')
        : (widget.uninstall ? '卸载完成' : '安装完成');
    final subtitle = failed
        ? '这次没有写入成功。下面是真实错误，不是猜的。'
        : (widget.uninstall ? '程序、隔离库和启动项已经清理。' : '已经装到这台电脑，桌面快捷方式也创建好了。');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withOpacity(_dark ? 0.16 : 0.10),
            border: Border.all(color: color.withOpacity(0.32), width: 1),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.22),
                blurRadius: 26,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Icon(
            failed ? Icons.close_rounded : Icons.check_rounded,
            color: color,
            size: 30,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          style: const TextStyle(
            fontSize: 27,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            height: 1.55,
            color: _dark ? Colors.white54 : const Color(0xFF66718A),
          ),
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: failed
                ? color.withOpacity(_dark ? 0.08 : 0.06)
                : Colors.white.withOpacity(_dark ? 0.04 : 0.26),
            border: Border.all(
              color: failed
                  ? color.withOpacity(0.24)
                  : Colors.white.withOpacity(_dark ? 0.08 : 0.36),
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                failed ? '错误详情' : '安装结果',
                style: TextStyle(
                  fontSize: 9.5,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: failed ? color : accent,
                ),
              ),
              const SizedBox(height: 5),
              Text(_result, style: const TextStyle(fontSize: 11, height: 1.6)),
              if (!widget.uninstall && _ok) ...[
                const SizedBox(height: 7),
                Text(
                  '安装目录：$_dir',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9.5,
                    height: 1.4,
                    color: _dark ? Colors.white38 : const Color(0xFF7A8498),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            if (!failed && !widget.uninstall)
              TextButton(onPressed: () => exit(0), child: const Text('稍后启动')),
            const Spacer(),
            failed
                ? LiquidButton(
                    text: '返回重试',
                    icon: Icons.refresh_rounded,
                    onTap: () => setState(() {
                      _step = 1;
                      _result = '';
                    }),
                  )
                : LiquidButton(
                    text: widget.uninstall ? '关闭' : '立即启动',
                    icon: widget.uninstall
                        ? Icons.close_rounded
                        : Icons.play_arrow_rounded,
                    onTap: () async {
                      if (widget.uninstall) {
                        exit(0);
                      }
                      String? exe;
                      for (final name in [
                        'QWGuard.exe',
                        'system_toolbox.exe',
                      ]) {
                        final f = File('$_dir\\$name');
                        if (f.existsSync()) {
                          exe = f.path;
                          break;
                        }
                      }
                      if (exe == null) {
                        final dir = Directory(_dir);
                        if (dir.existsSync()) {
                          for (final f in dir.listSync()) {
                            if (f is File &&
                                f.path.toLowerCase().endsWith('.exe')) {
                              exe = f.path;
                              break;
                            }
                          }
                        }
                      }
                      if (exe == null) {
                        setState(() => _result = '安装目录里找不到主程序 exe：$_dir');
                        return;
                      }
                      try {
                        await Process.start(
                          exe,
                          const [],
                          workingDirectory: _dir,
                          mode: ProcessStartMode.detached,
                        );
                      } catch (e) {
                        setState(() => _result = '启动失败：$e');
                        return;
                      }
                      exit(0);
                    },
                  ),
          ],
        ),
      ],
    );
  }

  // ---------- 卸载 ----------

  Widget _uninstallConfirm1(Color accent) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: accent, size: 24),
            const SizedBox(width: 10),
            const Text(
              '确定要卸载吗？',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          '卸载会把这套安全管家从电脑上移除，安装目录、配置和快捷方式都会清掉。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: () => exit(0), child: const Text('取消')),
            const SizedBox(width: 8),
            LiquidButton(
              text: '继续',
              icon: Icons.arrow_forward_rounded,
              onTap: () => setState(() => _confirm1 = true),
            ),
          ],
        ),
      ],
    );
  }

  Widget _uninstallPassword(Color accent) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.lock_rounded, color: accent, size: 24),
            const SizedBox(width: 10),
            const Text(
              '卸载需要密码',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          '你已经开启了密码保护。请输入密码，验证通过后才会继续卸载。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _pwdCtrl,
          autofocus: true,
          obscureText: true,
          onSubmitted: (_) => _submitPwd(),
          decoration: InputDecoration(
            hintText: '输入密码',
            errorText: _pwdErr.isEmpty ? null : _pwdErr,
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: () => exit(0), child: const Text('取消')),
            const SizedBox(width: 8),
            LiquidButton(
              text: '验证并卸载',
              icon: Icons.lock_open_rounded,
              onTap: _submitPwd,
            ),
          ],
        ),
      ],
    );
  }

  Widget _uninstallConfirm2(Color accent) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: accent, size: 26),
            const SizedBox(width: 10),
            const Text(
              '再确认一次',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          '卸载之后，这台电脑将处于危险环境之中，实时防护、病毒查杀和垃圾清理都会一并取消，不会再有人替你盯着。',
          style: TextStyle(
            fontSize: 13.5,
            height: 1.7,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          '要是只是暂时不想用，把窗口关掉就行，不必卸载。',
          style: TextStyle(fontSize: 12, height: 1.6),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => setState(() => _confirm1 = false),
              child: const Text('我再想想'),
            ),
            const SizedBox(width: 8),
            LiquidButton(
              text: '确认卸载',
              icon: Icons.delete_forever_rounded,
              primary: false,
              onTap: _beforeUninstall,
            ),
          ],
        ),
      ],
    );
  }
}

/// 安装页底层：Mica 上方的低透明度极光。只画一层渐变 + 3 个径向光斑，
/// 不做 BackdropFilter；动画时每帧只重绘这一层，卡片和文字不跟着重画。
class _InstallerBackdrop extends StatefulWidget {
  final bool dark;
  final Color accent;
  const _InstallerBackdrop({required this.dark, required this.accent});

  @override
  State<_InstallerBackdrop> createState() => _InstallerBackdropState();
}

class _InstallerBackdropState extends State<_InstallerBackdrop> {
  // 不用 AnimationController：它按 vsync 每帧推进，等于强制 60fps。
  // 这里用 30fps 定时器推相位，极光仍然连续，但重绘次数减半。
  Timer? _timer;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!mounted) return;
      setState(() => _t = (_t + 33 / 22000) % 1.0);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _InstallerBackdropPainter(
          t: _t,
          dark: widget.dark,
          accent: widget.accent,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _InstallerBackdropPainter extends CustomPainter {
  final double t;
  final bool dark;
  final Color accent;
  _InstallerBackdropPainter({
    required this.t,
    required this.dark,
    required this.accent,
  });

  void _blob(Canvas canvas, Offset center, double radius, Color color) {
    final shader = RadialGradient(
      colors: [color, color.withOpacity(0.0)],
      stops: const [0.0, 1.0],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, Paint()..shader = shader);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: dark
          ? [
              const Color(0xD9070B16),
              const Color(0xD9111C31),
              const Color(0xD91B1327),
            ]
          : [
              const Color(0xDDF7FAFF),
              const Color(0xDDE7EFFF),
              const Color(0xDDF6EEFF),
            ],
      stops: const [0.0, 0.54, 1.0],
    ).createShader(rect);
    canvas.drawRect(rect, Paint()..shader = bg);

    final tau = math.pi * 2;
    final drift = t * tau;
    final a = 0.20 + 0.08 * math.sin(drift * 0.7);
    final b = 0.16 + 0.06 * math.cos(drift * 0.55);

    _blob(
      canvas,
      Offset(
        size.width * 0.74 + math.sin(drift) * 34,
        size.height * 0.18 + math.cos(drift * 0.8) * 24,
      ),
      size.width * 0.54,
      accent.withOpacity(dark ? a : a + 0.08),
    );
    _blob(
      canvas,
      Offset(
        size.width * 0.16 + math.cos(drift * 0.6) * 30,
        size.height * 0.76 + math.sin(drift * 0.9) * 28,
      ),
      size.width * 0.50,
      (dark ? const Color(0xFF8C5CFF) : const Color(0xFFB69CFF)).withOpacity(
        dark ? b : b + 0.06,
      ),
    );
    _blob(
      canvas,
      Offset(
        size.width * 0.52 + math.sin(drift * 0.45) * 44,
        size.height * 0.55,
      ),
      size.width * 0.42,
      (dark ? const Color(0xFF35D6FF) : const Color(0xFF8DE4FF)).withOpacity(
        dark ? 0.08 : 0.10,
      ),
    );

    // 顶部一道很淡的收光，让 Mica 的边沿有“玻璃压上去”的层次。
    final top = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.white.withOpacity(dark ? 0.06 : 0.26),
        Colors.transparent,
      ],
    ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.34));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * 0.34),
      Paint()..shader = top,
    );
  }

  @override
  bool shouldRepaint(covariant _InstallerBackdropPainter old) =>
      old.t != t || old.dark != dark || old.accent != accent;
}

/// 带光效的进度条：底色玻璃槽 + 已写入部分的渐变 + 一道循环扫过的高光
/// 第二条/第三条细进度：校验阶段和写入阶段各自独立，主条仍是整体。
class _StageBar extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  const _StageBar(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0).toDouble();
    return Row(
      children: [
        SizedBox(
          width: 26,
          child: Text(
            label,
            style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: v,
              minHeight: 3,
              backgroundColor: Colors.white.withOpacity(0.20),
              valueColor:
                  AlwaysStoppedAnimation<Color>(color.withOpacity(0.75)),
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 30,
          child: Text(
            '${(v * 100).toStringAsFixed(0)}%',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _GlowProgress extends StatefulWidget {
  final double value;
  final Color color;
  const _GlowProgress({required this.value, required this.color});
  @override
  State<_GlowProgress> createState() => _GlowProgressState();
}

class _GlowProgressState extends State<_GlowProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 12,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          painter: _GlowBarPainter(
            value: widget.value.clamp(0.0, 1.0),
            color: widget.color,
            t: _c.value,
            dark: dark,
          ),
        ),
      ),
    );
  }
}

class _GlowBarPainter extends CustomPainter {
  final double value;
  final Color color;
  final double t;
  final bool dark;
  _GlowBarPainter({
    required this.value,
    required this.color,
    required this.t,
    required this.dark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(6),
    );
    // 槽：半透明，能透出背后的玻璃
    canvas.drawRRect(
      r,
      Paint()
        ..color = dark
            ? Colors.white.withOpacity(0.10)
            : Colors.black.withOpacity(0.08),
    );
    if (value <= 0) return;
    final w = size.width * value;
    final fill = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, w, size.height),
      const Radius.circular(6),
    );
    canvas.save();
    canvas.clipRRect(fill);
    final g = LinearGradient(
      colors: [color.withOpacity(0.65), color, color.withOpacity(0.75)],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    ).createShader(Offset.zero & size);
    canvas.drawRRect(fill, Paint()..shader = g);
    // 循环扫光：一条 60px 宽的斜向白光，只在已写入的区间里走
    final bandX = -80 + (size.width + 160) * t;
    final band = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withOpacity(0.0),
          Colors.white.withOpacity(0.55),
          Colors.white.withOpacity(0.0),
        ],
      ).createShader(Rect.fromLTWH(bandX, 0, 60, size.height))
      ..blendMode = BlendMode.plus;
    canvas.drawRect(Rect.fromLTWH(bandX, 0, 60, size.height), band);
    canvas.restore();
    // Windows 11 那种“光从左边一路推进去”的感觉：
    // 三道小光条在已写入区间里循环流动，前缘再聚一团焦光。
    for (var i = 0; i < 3; i++) {
      final p = ((t * 1.15 + i / 3) % 1.0);
      final x = p * w;
      final streak = Paint()
        ..blendMode = BlendMode.plus
        ..shader = LinearGradient(
          colors: [
            Colors.white.withOpacity(0),
            Colors.white.withOpacity(0.38),
            Colors.white.withOpacity(0),
          ],
        ).createShader(Rect.fromLTWH(x - 18, 0, 36, size.height));
      canvas.drawRect(Rect.fromLTWH(x - 18, 1, 36, size.height - 2), streak);
    }
    // 光线折射：贴着填充边缘的红/青色散，1px 就够，多了就脏
    canvas.drawLine(
      Offset(0.5, 2),
      Offset(0.5, size.height - 2),
      Paint()
        ..color = const Color(0xFFFF5A5A).withOpacity(0.35)
        ..blendMode = BlendMode.plus,
    );
    canvas.drawLine(
      Offset(w - 1, 2),
      Offset(w - 1, size.height - 2),
      Paint()
        ..color = const Color(0xFF5AD8FF).withOpacity(0.35)
        ..blendMode = BlendMode.plus,
    );
    // 光线聚中：前缘一团白热光核
    if (value < 0.995) {
      final focus = Offset(w - 1, size.height / 2);
      canvas.drawCircle(
        focus,
        15,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: [
              Colors.white.withOpacity(0.55),
              color.withOpacity(0.18),
              Colors.transparent,
            ],
          ).createShader(Rect.fromCircle(center: focus, radius: 15)),
      );
      canvas.drawCircle(
        focus,
        2.6,
        Paint()..color = Colors.white.withOpacity(0.9),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GlowBarPainter old) =>
      old.value != value ||
      old.t != t ||
      old.color != color ||
      old.dark != dark;
}
