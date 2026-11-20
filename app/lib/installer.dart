import 'dart:io';

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
  bool _desktopIcon = true;
  bool _autostart = false;
  bool _busy = false;
  String _hint = '';
  String _result = '';

  /// 卸载的两层确认
  bool _confirm1 = false;
  bool _confirm2 = false;

  @override
  void initState() {
  super.initState();
    _init();
  }

  Future<void> _init() async {
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
      _ready = true;
    });
  }

  double get _progress => _step == 2 ? 1.0 : 0.0;

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
    final r = Api.installRun(src, _dir, desktopIcon: _desktopIcon, autostart: _autostart);
    setState(() {
      _busy = false;
      _step = 3;
      _result = r['success'] == true
          ? '安装完成，已写入 ${r['data']['copied'] ?? 0} 个文件'
          : (r['message']?.toString() ?? '安装失败');
    });
  }

  Future<void> _doUninstall() async {
    setState(() {
      _busy = true;
      _step = 2;
      _hint = '正在清理…';
    });
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final r = Api.uninstallRun(appDir);
    setState(() {
      _busy = false;
      _step = 3;
      _result = r['success'] == true ? '卸载完成，保护已取消' : (r['message']?.toString() ?? '卸载失败');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = _dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: Colors.transparent,
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
          const Text('QW 电脑安全管家', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
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
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: _dark ? Colors.white.withOpacity(0.07) : Colors.black.withOpacity(0.04),
          ),
          child: Row(children: [
            const Icon(Icons.folder_rounded, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(_dir, style: const TextStyle(fontSize: 12.5))),
            Text('推荐', style: TextStyle(fontSize: 11, color: accent)),
          ]),
        ),
        const SizedBox(height: 6),
        Text('默认放在推荐盘符下；要换位置的话装完之后在设置里可以迁移。',
            style: TextStyle(fontSize: 11, color: _dark ? Colors.white38 : Colors.black45)),
        const SizedBox(height: 18),
        _check('创建桌面快捷方式', _desktopIcon, (v) => setState(() => _desktopIcon = v)),
        _check('开机自启动（关闭会在启动时提示不建议）', _autostart, (v) => setState(() => _autostart = v)),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.check_circle_rounded, color: accent, size: 26),
          const SizedBox(width: 10),
          Text(widget.uninstall ? '卸载完成' : '安装完成',
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 14),
        Text(_result, style: const TextStyle(fontSize: 13, height: 1.6)),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerRight,
          child: LiquidButton(
            text: widget.uninstall ? '关闭' : '立即启动',
            icon: widget.uninstall ? Icons.close_rounded : Icons.play_arrow_rounded,
            onTap: () {
              if (widget.uninstall) {
                exit(0);
              } else {
                final exe = '$_dir\\system_toolbox.exe';
                if (File(exe).existsSync()) {
                  Process.start(exe, [], mode: ProcessStartMode.detached);
                }
                exit(0);
              }
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
            LiquidButton(text: '确认卸载', icon: Icons.delete_forever_rounded, primary: false, onTap: _doUninstall),
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
