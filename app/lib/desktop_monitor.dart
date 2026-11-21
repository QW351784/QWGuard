import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

import 'api.dart';
import 'bridge.dart';
import 'state.dart';

/// 打开桌面级监控窗口（独立 Flutter 引擎窗口）
/// 失败时返回 false，由调用方退回应用内浮层
Future<bool> openDesktopMonitor() async {
  try {
    final window = await DesktopMultiWindow.createWindow(
      jsonEncode({'route': 'monitor', 'title': 'QW Monitor'}),
    );
    await window.setFrame(const Offset(120, 120) & const Size(300, 200));
    await window.setTitle('QW 监控');
    await window.show();
    // 交给 Rust 把该窗口设为 TOPMOST（失败不影响窗口本身）
    await Future.delayed(const Duration(milliseconds: 600));
    Api.setTopmost('QW 监控');
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> closeDesktopMonitor() async {
  try {
    final ids = await DesktopMultiWindow.getAllSubWindowIds();
    for (final id in ids) {
      await DesktopMultiWindow.invokeMethod(id, 'close');
    }
  } catch (_) {}
}

/// 子窗口内容：精简版监控面板
class DesktopMonitorApp extends StatefulWidget {
  final int windowId;
  const DesktopMonitorApp({super.key, required this.windowId});

  @override
  State<DesktopMonitorApp> createState() => _DesktopMonitorAppState();
}

class _DesktopMonitorAppState extends State<DesktopMonitorApp> {
  Map<String, dynamic>? _data;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(milliseconds: 1600), (_) => _poll());
  }

  void _poll() {
    final r = Native.hardware();
    if (!mounted) return;
    if (r['success'] == true && r['data'] is Map) {
      setState(() => _data = (r['data'] as Map).cast<String, dynamic>());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final m = Ui.floatMetrics.value;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF2F7BFF),
        scaffoldBackgroundColor: const Color(0xFF10141B),
        fontFamily: 'NotoSansSC',
      ),
      home: Scaffold(
        backgroundColor: isDark ? const Color(0xFF10141B) : const Color(0xFFF4F8FF),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.monitor_heart_rounded, size: 14, color: Color(0xFF2F7BFF)),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('QW Monitor', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
                InkWell(
                  onTap: () async {
                    try {
                      await DesktopMultiWindow.invokeMethod(widget.windowId, 'close');
                    } catch (_) {}
                  },
                  child: const Icon(Icons.close_rounded, size: 14, color: Colors.white54),
                ),
              ]),
              const SizedBox(height: 6),
              if (d == null)
                const Text('读取中…', style: TextStyle(fontSize: 11, color: Colors.white54))
              else ...[
                if (m.contains('cpu')) _row('CPU', '${d['cpu_load']}%', d['cpu_temp'] != null ? '${d['cpu_temp']}℃' : null),
                if (m.contains('mem'))
                  _row('MEM', '${d['mem_used_gb']}/${d['mem_total_gb']} GB', null),
                if (m.contains('gpu')) _row('GPU', _gpuShort(d), d['gpu_temp'] != null ? '${d['gpu_temp']}℃' : null),
                if (m.contains('npu') && d['npu'] != null) _row('NPU', '${d['npu']}', null),
                if (m.contains('temp') && d['cpu_temp'] != null) _row('TEMP', '${d['cpu_temp']}℃', null),
              ],
              const Spacer(),
              const Text('拖动窗口可移动 · 关闭点右上角', style: TextStyle(fontSize: 9, color: Colors.white30)),
            ],
          ),
        ),
      ),
    );
  }

  String _gpuShort(Map<String, dynamic> d) {
    final gpus = (d['gpus'] as List?) ?? const [];
    if (gpus.isEmpty) return '核显';
    final g = gpus.first as Map;
    final name = g['name']?.toString() ?? '';
    final kind = g['kind'] == 'discrete' ? '独显' : '核显';
    return '$kind ${name.length > 16 ? name.substring(0, 16) : name}';
  }

  Widget _row(String label, String value, String? extra) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        SizedBox(width: 38, child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white70))),
        Expanded(
          child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white)),
        ),
        if (extra != null) Text(extra, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF5AA2FF))),
      ]),
    );
  }
}
