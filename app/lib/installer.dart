import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import 'api.dart';
import 'state.dart';
import 'theme.dart';

/// 安装 / 卸载界面
///
/// 跟主程序共用同一套 Flutter 引擎和主题，动画完全一致：
/// 液态玻璃、页面切换、呼吸型光效（这里强制开启，没有开关）。
/// 配色不跟随软件设置，而是跟随系统深浅色。
class SetupApp extends StatefulWidget {
  final bool uninstall;
  const SetupApp({super.key, this.uninstall = false});

  @override
  State<SetupApp> createState() => _SetupAppState();
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

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _pwdCtrl.dispose();
    super.dispose();
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
        return;
      }
      if (d?['elevated'] != true) {
        exit(0);
        return;
      }
    }
    final t = Api.systemTheme();
    final dark = t['success'] == true && t['data'] is Map ? (t['data']['dark'] == true) : false;
    final rec = Api.recommendDir();
    String dir = _dir;
    if (rec['success'] == true && rec['data'] is Map) {
      final p = rec['data']['path']?.toString() ?? '';
      if (p.isNotEmpty) {
        // 推荐盘符 + 固定目录名
        final base = p.endsWith('\\') || p.endsWith('/') ? p : '$p${Platform.pathSeparator}';
        dir = '$base${widget.uninstall ? '' : 'QWGuard'}';
        if (widget.uninstall) {
          dir = p;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _dark = dark;
      _dir = dir;
      _recDir = dir;
      _ready = true;
    });
  }

  double get _progress => _step == 2 ? 1.0 : 0.0;

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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
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
    final r = await Isolate.run(() => Api.installRun(
          src,
          _dir,
          desktopIcon: _desktopIcon,
          autostart: _autostart,
        ));
    final ok = r['success'] == true;
    setState(() {
      _busy = false;
      _step = 3;
      _ok = ok;
      _result = ok
          ? '已写入 ${r['data']?['copied'] ?? 0} 个文件'
          : (r['message']?.toString() ?? '安装失败');
    });
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
        // 这里是安装器自己的窗口。_setupWindow() 里没给 WindowOptions 设不透明底，
        // Scaffold 再写 transparent，整个向导就会透出桌面。必须自己画底色。
        backgroundColor: _dark ? const Color(0xFF14171D) : const Color(0xFFF4F7FB),
        body: _ready ? _body() : const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _body() {
    final accent = widget.uninstall ? const Color(0xFFFF6B6B) : const Color(0xFF2F7BFF);
    final brightness = _dark ? Brightness.dark : Brightness.light;

    return Stack(
      children: [
        Positioned.fill(child: DecoratedBox(decoration: AppTheme.background(brightness))),
        // 呼吸光效：安装/卸载强制开启
        Positioned(
          top: -140,
          right: -120,
          child: BreathingGlow(color: accent, size: 460, forceOn: true),
        ),
        Positioned(
          bottom: -180,
          left: -140,
          child: BreathingGlow(color: accent.withOpacity(0.7), size: 520, forceOn: true),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: LiquidGlass(
              radius: 28,
              padding: const EdgeInsets.all(30),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Ui.spring,
                child: KeyedSubtree(
                  key: ValueKey('$_step-${widget.uninstall}-$_confirm2'),
                  child: _content(accent),
                ),
              ),
            ),
          ),
        ),
      ],
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [accent.withOpacity(0.9), accent]),
            ),
            child: const Icon(Icons.shield_rounded, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          const Text('QW 安全电脑管家', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 18),
        const Text('安装程序会把这套安全管家装到你的电脑上：硬件检测、垃圾清理、病毒查杀、隔离库和一整套小工具。',
            style: TextStyle(fontSize: 13.5, height: 1.6)),
        const SizedBox(height: 10),
        const Text('装完之后原来的解压目录可以删掉，程序会独立运行。',
            style: TextStyle(fontSize: 12.5, height: 1.6)),
        const SizedBox(height: 26),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: () => exit(0), child: const Text('取消')),
            const SizedBox(width: 8),
            LiquidButton(text: '下一步', icon: Icons.arrow_forward_rounded, onTap: () => setState(() => _step = 1)),
          ],
        ),
      ],
    );
  }

  Widget _options(Color accent) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('安装选项', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        const Text('安装位置', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _busy ? null : _pickDir,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: _dark ? Colors.white.withOpacity(0.07) : Colors.black.withOpacity(0.04),
            ),
            child: Row(children: [
              const Icon(Icons.folder_rounded, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(_dir, style: const TextStyle(fontSize: 12.5))),
              Text(_dir == _recDir ? '推荐' : '自定义',
                  style: TextStyle(fontSize: 11, color: accent)),
              const SizedBox(width: 8),
              Text('更改', style: TextStyle(fontSize: 11.5, color: accent)),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        Text('高级选项：点上面的路径可以自定义安装位置，默认装系统盘的程序目录。',
            style: TextStyle(fontSize: 11, color: _dark ? Colors.white38 : Colors.black45)),
        const SizedBox(height: 18),
        _check('创建桌面快捷方式', _desktopIcon, (v) => setState(() => _desktopIcon = v)),
        if (_hint.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(_hint, style: TextStyle(fontSize: 11.5, color: Colors.redAccent)),
        ],
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: _busy ? null : () => setState(() => _step = 0), child: const Text('上一步')),
            const SizedBox(width: 8),
            LiquidButton(text: '开始安装', icon: Icons.download_rounded, onTap: _busy ? null : _doInstall),
          ],
        ),
      ],
    );
  }

  Widget _progressView(Color accent) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        SizedBox(
          width: 64,
          height: 64,
          child: CircularProgressIndicator(strokeWidth: 3, color: accent),
        ),
        const SizedBox(height: 22),
        Text(_hint, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text('这段时间请不要关闭窗口', style: TextStyle(fontSize: 11.5, color: _dark ? Colors.white38 : Colors.black45)),
      ],
    );
  }

  Widget _done(Color accent) {
    // 成不成功必须一眼看出来：失败是红叉 +「安装失败」，不是绿勾 +「安装完成」。
    // 之前不管结果都画绿勾，用户装坏了也以为装好了。
    final failed = !_ok;
    final color = failed ? const Color(0xFFE5484D) : accent;
    final title = failed
        ? (widget.uninstall ? '卸载失败' : '安装失败')
        : (widget.uninstall ? '卸载完成' : '安装完成');

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(failed ? Icons.error_rounded : Icons.check_circle_rounded, color: color, size: 26),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 14),
        Text(_result, style: const TextStyle(fontSize: 13, height: 1.6)),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerRight,
          child: failed
              // 失败就给「返回重试」，不给「立即启动」——
              // 装坏了还让人去启动，等于把人往坑里推
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
                  icon: widget.uninstall ? Icons.close_rounded : Icons.play_arrow_rounded,
                  onTap: () async {
                    if (widget.uninstall) {
                      exit(0);
                    }
                    // 之前这里写死 QWGuard.exe，CI 实际产出的 exe 名可能是
                    // system_toolbox.exe；文件不存在就静默 exit —— 表现就是
                    // 「点立即启动，窗口直接消失，应用没起来」。
                    // 现在按目录里真实存在的 exe 找，找不到就留在页面报错。
                    String? exe;
                    for (final name in ['QWGuard.exe', 'system_toolbox.exe']) {
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
                          if (f is File && f.path.toLowerCase().endsWith('.exe')) {
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
                      await Process.start(exe, const [],
                          workingDirectory: _dir, mode: ProcessStartMode.detached);
                    } catch (e) {
                      setState(() => _result = '启动失败：$e');
                      return;
                    }
                    exit(0);
                  },
                ),
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
        Row(children: [
          Icon(Icons.delete_outline_rounded, color: accent, size: 24),
          const SizedBox(width: 10),
          const Text('确定要卸载吗？', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 16),
        const Text('卸载会把这套安全管家从电脑上移除，安装目录、配置和快捷方式都会清掉。',
            style: TextStyle(fontSize: 13, height: 1.6)),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: () => exit(0), child: const Text('取消')),
            const SizedBox(width: 8),
            LiquidButton(text: '继续', icon: Icons.arrow_forward_rounded, onTap: () => setState(() => _confirm1 = true)),
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
        Row(children: [
          Icon(Icons.lock_rounded, color: accent, size: 24),
          const SizedBox(width: 10),
          const Text('卸载需要密码', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 16),
        const Text('你已经开启了密码保护。请输入密码，验证通过后才会继续卸载。',
            style: TextStyle(fontSize: 13, height: 1.6)),
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
            LiquidButton(text: '验证并卸载', icon: Icons.lock_open_rounded, onTap: _submitPwd),
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
        Row(children: [
          Icon(Icons.warning_amber_rounded, color: accent, size: 26),
          const SizedBox(width: 10),
          const Text('再确认一次', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 16),
        const Text('卸载之后，这台电脑将处于危险环境之中，实时防护、病毒查杀和垃圾清理都会一并取消，不会再有人替你盯着。',
            style: TextStyle(fontSize: 13.5, height: 1.7, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        const Text('要是只是暂时不想用，把窗口关掉就行，不必卸载。',
            style: TextStyle(fontSize: 12, height: 1.6)),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: () => setState(() => _confirm1 = false), child: const Text('我再想想')),
            const SizedBox(width: 8),
            LiquidButton(text: '确认卸载', icon: Icons.delete_forever_rounded, primary: false, onTap: _beforeUninstall),
          ],
        ),
      ],
    );
  }

  Widget _check(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Checkbox(value: value, onChanged: (v) => onChanged(v ?? false), visualDensity: VisualDensity.compact),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5))),
        ],
      ),
    );
  }
}
