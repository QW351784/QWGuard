import 'dart:async';

import 'package:flutter/material.dart';

import 'bridge.dart';
import 'state.dart';
import 'theme.dart';

/// 悬浮监控窗（应用内浮层，可拖动，默认关闭）
/// 真实桌面级置顶窗口需要多窗口引擎，见 README「待接入」。
class FloatingMonitor extends StatefulWidget {
  const FloatingMonitor({super.key});

  @override
  State<FloatingMonitor> createState() => _FloatingMonitorState();
}

class _FloatingMonitorState extends State<FloatingMonitor> {
  Map<String, dynamic>? _data;
  Timer? _timer;
  Offset _pos = const Offset(0, 0);
  bool _inited = false;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(milliseconds: 1600), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final r = await Native.hardwareMetricsAsync();
      if (!mounted) return;
      if (r['success'] == true && r['data'] is Map) {
        setState(() => _data = (r['data'] as Map).cast<String, dynamic>());
      }
    } catch (_) {
      // 采样失败就保持上一帧
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    if (!_inited) {
      _pos = Offset(size.width - 300, size.height - 220);
      _inited = true;
    }

    final d = _data;
    final m = Ui.floatMetrics.value;

    return Positioned(
      left: _pos.dx.clamp(8.0, size.width - 268).toDouble(),
      top: _pos.dy.clamp(8.0, size.height - 150).toDouble(),
      child: GestureDetector(
        onPanUpdate: (e) => setState(() => _pos += e.delta),
        child: LiquidGlass(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                const Icon(Icons.monitor_heart_rounded, size: 15, color: Color(0xFF2F7BFF)),
                const SizedBox(width: 6),
                const Text('QW Monitor', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                const SizedBox(width: 10),
                InkWell(
                  onTap: () => Ui.floating.value = false,
                  child: const Icon(Icons.close_rounded, size: 14),
                ),
              ]),
              if (d == null)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('读取中…', style: TextStyle(fontSize: 11)),
                )
              else ...[
                if (m.contains('cpu'))
                  _row('CPU', '${d['cpu_load']}%', d['cpu_temp'] != null ? '${d['cpu_temp']}℃' : null),
                if (m.contains('mem'))
                  _row('MEM', '${d['memory_used_gb'] ?? d['mem_used_gb']}/${d['memory_total_gb'] ?? d['mem_total_gb']}G', null),
                if (m.contains('gpu'))
                  _row(
                    'GPU',
                    _gpuShort(d),
                    d['gpu_temp'] != null ? '${d['gpu_temp']}℃' : null,
                  ),
                if (m.contains('npu') && d['npu'] != null)
                  _row('NPU', '${d['npu']}', null),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _gpuShort(Map<String, dynamic> d) {
    final gpus = (d['gpus'] as List?) ?? const [];
    if (gpus.isEmpty) return '核显';
    final g = (gpus.first as Map);
    final name = g['name']?.toString() ?? '';
    final kind = g['kind'] == 'discrete' ? '独显' : '核显';
    return '$kind ${name.length > 14 ? name.substring(0, 14) : name}';
  }

  Widget _row(String label, String value, String? temp) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 34, child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700))),
        SizedBox(
          width: 96,
          child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
        ),
        if (temp != null) Text(temp, style: const TextStyle(fontSize: 11, color: Color(0xFF2F7BFF), fontWeight: FontWeight.w700)),
      ]),
    );
  }
}
