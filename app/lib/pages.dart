import 'dart:async';
import 'dart:isolate';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'bridge.dart';
import 'desktop_monitor.dart';
import 'state.dart';
import 'i18n.dart';
import 'scan_fx.dart';
import 'theme.dart';

String _size(num bytes) {
  if (bytes < 1024) return '${bytes.toInt()} B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

// ======================= 硬件检测 =======================

class HardwarePage extends StatefulWidget {
  const HardwarePage({super.key});
  @override
  State<HardwarePage> createState() => _HardwarePageState();
}

class _HardwarePageState extends State<HardwarePage> {
  Map<String, dynamic>? _data;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = Native.hardware();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res['success'] == true && res['data'] is Map) {
        _data = (res['data'] as Map).cast<String, dynamic>();
        if (_data!.isEmpty) _error = '没有读到硬件信息，稍后点「刷新」再试。';
      } else {
        final msg = res['message']?.toString().trim() ?? '';
        _error = msg.isEmpty ? '读取硬件信息失败（错误码 ${res['code'] ?? '-'}），点「刷新」重试。' : msg;
      }
    });
  }

  void _showAbout() {
    showDialog(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        Widget credit(String name, String by, String note) => Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('$by · $note',
                      style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black54)),
                ],
              ),
            );
        return AlertDialog(
          title: const Text('关于 QW 安全电脑管家'),
          content: SizedBox(
            width: 470,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('版本 1.0 · Flutter + Impeller + Rust', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 16),
                  const Text('借鉴与致谢', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  credit('Windows Defender 查杀引擎', 'Microsoft', 'MpCmdRun 命令行'),
                  credit('YARA 规则引擎（内置）', 'VirusTotal', 'BSD-3-Clause · github.com/VirusTotal/yara'),
                  credit('火绒安全 hrscan', '火绒安全', 'huorong.cn'),
                  credit('PYAS 引擎', 'PYAS 项目', '外部集成，日志回传'),
                  credit('VisualCppRedist AIO', 'abbodi1406', 'github.com/abbodi1406/vcredist'),
                  credit('DirectX Repair 增强版', 'zysoftware', 'zysoftware.top'),
                  credit('界面与底层框架', 'Flutter · Rust', 'flutter.dev / rust-lang.org'),
                  const SizedBox(height: 4),
                  Text('漏了谁、写错了谁，提 issue，我立刻补上。',
                      style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black54)),
                  const SizedBox(height: 18),
                  const Text('支持作者', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  const Text('作者制作维护不容易，爱心捐款，一杯奶茶价钱，就是作者继续维护更新的动力。',
                      style: TextStyle(fontSize: 12, height: 1.5)),
                  const SizedBox(height: 12),
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset('assets/donate_qr.png', width: 175),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text('酷安作者账号：QW123456780',
                        style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black54)),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('好')),
          ],
        );
      },
    );
  }

  Widget _aboutBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _showAbout,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.035),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
          ),
          child: Row(
            children: [
              const Icon(Icons.favorite_rounded, size: 15, color: Color(0xFF2F7BFF)),
              const SizedBox(width: 9),
              const Expanded(
                child: Text('关于 · 借鉴与致谢 · 支持作者', style: TextStyle(fontSize: 12)),
              ),
              Icon(Icons.chevron_right_rounded, size: 16, color: isDark ? Colors.white38 : Colors.black38),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final grid = <Widget>[];
    if (d != null) {
      grid.add(_MetricCard(
        icon: Icons.memory_rounded,
        title: I18n.t('cpu'),
        name: d['cpu_name']?.toString() ?? '-',
        metrics: [
          if ((d['cpu_load'] as num?) != null) (I18n.t('load'), '${d['cpu_load']}%'),
          if (d['cpu_temp'] != null) (I18n.t('temp'), '${d['cpu_temp']} ℃'),
          ('Cores', '${d['cpu_cores']}'),
        ],
      ));
      grid.add(_MetricCard(
        icon: Icons.developer_board_rounded,
        title: I18n.t('mem'),
        name: '${d['memory_used_gb']} / ${d['memory_total_gb']} GB',
        metrics: [
          (I18n.t('load'), '${((d['memory_used_gb'] as num) / (d['memory_total_gb'] as num) * 100).toStringAsFixed(0)}%'),
          if (d['gpu_temp'] != null) ('GPU ${I18n.t('temp')}', '${d['gpu_temp']} ℃'),
        ],
      ));
      for (final gpu in (d['gpus'] as List?) ?? const []) {
        final g = (gpu as Map).cast<String, dynamic>();
        grid.add(_MetricCard(
          icon: Icons.videogame_asset_rounded,
          title: I18n.t('gpu'),
          name: g['name']?.toString() ?? '-',
          metrics: [
            ('Score', '${g['score']}'),
            if (g['vram_mb'] != null && (g['vram_mb'] as num) > 0) ('VRAM', '${g['vram_mb']} MB'),
            if (d['gpu_temp'] != null) (I18n.t('temp'), '${d['gpu_temp']} ℃'),
          ],
        ));
      }
      for (final disk in (d['disks'] as List?) ?? const []) {
        final m = (disk as Map).cast<String, dynamic>();
        grid.add(_MetricCard(
          icon: Icons.storage_rounded,
          title: I18n.t('disk'),
          name: m['name']?.toString() ?? '-',
          metrics: [
            ('Free', '${m['free_gb']} GB'),
            ('Total', '${m['total_gb']} GB'),
            if (d['disk_temp'] != null) (I18n.t('temp'), '${d['disk_temp']} ℃'),
          ],
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageTitle(
            title: I18n.t('hw'),
            subtitle: I18n.lang == 'en' ? 'Live CPU, memory and disk status' : '实时读取处理器、内存与磁盘状态',
            trailing: Row(children: [
              LiquidButton(text: I18n.t('refresh'), icon: Icons.refresh_rounded, primary: false, onTap: _loading ? null : _load),
            ]),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Expanded(child: Center(child: Text(_error!)))
          else if (grid.isEmpty)
            const Expanded(child: Center(child: Text('No data')))
          else
            Expanded(
              child: GridView.count(
                crossAxisCount: MediaQuery.of(context).size.width > 1180 ? 3 : 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 1.55,
                children: [
                  for (var i = 0; i < grid.length; i++)
                    _Entrance(index: i, child: grid[i]),
                ],
              ),
            ),
          _aboutBar(),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String name;
  final List<(String, String)> metrics;

  const _MetricCard({required this.icon, required this.title, required this.name, required this.metrics});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LiquidGlass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF2F7BFF).withOpacity(isDark ? 0.22 : 0.14),
              ),
              child: Icon(icon, size: 19, color: const Color(0xFF2F7BFF)),
            ),
            const Spacer(),
            Text(title, style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.black45)),
          ]),
          const SizedBox(height: 12),
          Text(name, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25)),
          const Spacer(),
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              for (final m in metrics)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.$1, style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38)),
                    const SizedBox(height: 2),
                    Text(m.$2, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF2F7BFF))),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ======================= 系统清理 =======================

class CleanPage extends StatefulWidget {
  const CleanPage({super.key});
  @override
  State<CleanPage> createState() => _CleanPageState();
}

class _CleanPageState extends State<CleanPage> {
  List<Map<String, dynamic>> _items = [];
  final Set<String> _checked = {};
  bool _scanning = false;
  bool _busy = false;
  String? _note;
  double? _progress;
  String _stage = '正在扫描可清理项';
  String _detail = '';
  int _hits = 0;
  final List<String> _recent = [];
  final TextEditingController _cleanPath = TextEditingController();

  Future<void> _scan() => _cleanScan(mode: 'quick');

  /// 清理扫描统一执行器：三模式 + 后台 isolate + 文件名滚动
  Future<void> _cleanScan({String mode = 'quick', String path = ''}) async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _note = null;
      _progress = null;
      _hits = 0;
      _recent.clear();
      _stage = mode == 'full'
          ? '全盘清理扫描'
          : mode == 'custom'
              ? '指定位置清理扫描'
              : '快速清理扫描';
      _detail = '';
    });

    final future = Isolate.run(() => Api.cleanupScanMode(mode, path));
    var last = '';
    final ticker = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted) return;
      final d = (Api.cleanupProgress()['data'] as Map?)?.cast<String, dynamic>();
      if (d == null) return;
      final cur = d['current']?.toString() ?? '';
      setState(() {
        final files = (d['files'] as num?)?.toInt() ?? 0;
        final bytes = (d['bytes'] as num?)?.toInt() ?? 0;
        _hits = files;
        _detail = '已扫 $files 个文件 · ${_size(bytes)}';
        if (cur.isNotEmpty && cur != last) {
          last = cur;
          _recent.add(cur);
          if (_recent.length > 7) _recent.removeAt(0);
        }
      });
    });

    Map<String, dynamic> res;
    try {
      res = await future;
    } finally {
      ticker.cancel();
    }
    if (!mounted) return;
    setState(() {
      _scanning = false;
      if (res['success'] == true) {
        final data = (res['data'] as Map).cast<String, dynamic>();
        _items = ((data['items'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _checked
          ..clear()
          ..addAll(_items.where((e) => e['default_checked'] == true).map((e) => e['path'].toString()));
      } else {
        _note = res['message']?.toString();
      }
    });
  }

  Future<void> _run({required bool dryRun}) async {
    final paths = _checked.toList();
    if (paths.isEmpty) return;
    if (!dryRun) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(I18n.lang == 'en' ? 'Delete these files?' : '确认删除这些文件？'),
          content: Text(I18n.lang == 'en' ? '${paths.length} items, cannot be undone.' : '共 ${paths.length} 项，删除后不可恢复。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(I18n.lang == 'en' ? 'Cancel' : '取消')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: Text(I18n.lang == 'en' ? 'Confirm' : '确认')),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _busy = true);
    final res = Native.executeCleanup(paths, dryRun: dryRun);
    if (!mounted) return;
    setState(() => _busy = false);
    final data = res['data'];
    if (data is Map) {
      final freed = data['freed_bytes'] ?? 0;
      final n = data['deleted_files'] ?? 0;
      setState(() => _note = '${dryRun ? 'Dry run' : 'Done'}: $n files / ${_size(freed as num)}');
      if (!dryRun) _scan();
    } else {
      setState(() => _note = res['message']?.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final total = _items.fold<num>(0, (s, e) => s + ((e['size_bytes'] as num?) ?? 0));

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageTitle(
            title: I18n.t('clean'),
            subtitle: I18n.lang == 'en' ? 'Scan → select → confirm, three steps before deletion' : '扫描 → 勾选 → 二次确认，三步才删除',
            trailing: LiquidButton(text: '快速清理', icon: Icons.bolt_rounded, primary: false,
                onTap: _scanning ? null : () => _cleanScan(mode: 'quick')),
          ),
          const SizedBox(height: 12),
          Row(children: [
            LiquidButton(text: '全盘清理', icon: Icons.storage_rounded, primary: false,
                onTap: _scanning ? null : () => _cleanScan(mode: 'full')),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _cleanPath,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '要清理的目录，比如 D:\\Downloads',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            LiquidButton(text: '指定位置清理', icon: Icons.folder_open_rounded, primary: false,
                onTap: _scanning
                    ? null
                    : () {
                        final t = _cleanPath.text.trim();
                        if (t.isNotEmpty) _cleanScan(mode: 'custom', path: t);
                      }),
          ]),
          const SizedBox(height: 16),
          Expanded(
            child: _scanning
                ? Center(
                    child: ScanFx(
                      stage: _stage,
                      detail: _detail,
                      progress: _progress,
                      hits: _hits,
                      size: 180,
                    ),
                  )
                : _items.isEmpty
                    ? Center(child: Text(I18n.t('empty'), style: TextStyle(color: isDark ? Colors.white54 : Colors.black45)))
                    : ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final it = _items[i];
                          final path = it['path'].toString();
                          final on = _checked.contains(path);
                          return LiquidGlass(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            radius: 26,
                            onTap: () => setState(() => on ? _checked.remove(path) : _checked.add(path)),
                            child: Row(children: [
                              Checkbox(value: on, onChanged: (v) => setState(() => v! ? _checked.add(path) : _checked.remove(path))),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      Text(it['category'].toString(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                                    ]),
                                    const SizedBox(height: 3),
                                    Text(path, maxLines: 1, overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(_size((it['size_bytes'] as num?) ?? 0),
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF2F7BFF))),
                            ]),
                          );
                        },
                      ),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Text('${I18n.t('total')}: ${_size(total)}',
                style: TextStyle(fontSize: 13, color: isDark ? Colors.white60 : Colors.black54)),
            const Spacer(),
            if (_note != null) ...[
              Flexible(child: Text(_note!, style: const TextStyle(fontSize: 12, color: Color(0xFF2F7BFF)), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 12),
            ],
            LiquidButton(text: I18n.t('preview'), icon: Icons.science_rounded, primary: false, onTap: (_busy || _checked.isEmpty) ? null : () => _run(dryRun: true)),
            const SizedBox(width: 10),
            LiquidButton(text: I18n.t('doClean'), icon: Icons.cleaning_services_rounded, onTap: (_busy || _checked.isEmpty) ? null : () => _run(dryRun: false)),
          ]),
        ],
      ),
    );
  }
}

/// 子引擎中文名：界面上统一挂在「QW 引擎」名下
const engineZh = {
  'signature': '特征库',
  'heuristic': '启发式',
  'defender': '系统 Defender',
  'yara': 'YARA',
  'huorong': '火绒',
  'pyas': 'PYAS',
};

// ======================= 病毒查杀 =======================

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _pathCtrl = TextEditingController();

  final List<Map<String, dynamic>> _results = [];
  bool _busy = false;
  int _wlCount = 0;
  Map<String, dynamic> _rules = {};
  // 扫描动效的实时数据（每次轮询刷新）
  double? _progress;
  String _stage = '正在启动查杀引擎';
  String _detail = '';
  int _hits = 0;
  int _scanned = 0;
  final List<String> _recent = [];

  @override
  void initState() {
    super.initState();
    _loadWl();
    _loadRules();
  }

  void _loadRules() {
    final r = Api.rulesStatus();
    final d = r['data'];
    if (d is Map && mounted) {
      setState(() => _rules = Map<String, dynamic>.from(d));
    }
  }

  void _loadWl() {
    final r = Api.whitelist();
    if (r['success'] == true && r['data'] is Map) {
      _wlCount = ((r['data']['items'] as List?) ?? const []).length;
    }
    if (mounted) setState(() {});
  }

  void _wl(bool add) {
    final p = _pathCtrl.text.trim();
    if (p.isEmpty) return;
    final r = add ? Api.whitelistAdd(p) : Api.whitelistRemove(p);
    if (!mounted) return;
    setState(() {
      _wlCount = ((r['data'] is Map ? r['data']['count'] : _wlCount) as num?)?.toInt() ?? _wlCount;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['message']?.toString() ?? '')));
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  /// 统一扫描执行器：任务丢后台 isolate，主线程 150ms 轮询进度 + 文件名滚动
  /// 外部引擎：把扫描路径里的目标交给火绒 / PYAS，立刻回话，不冻结界面
  Future<void> _runExternal(String engine) async {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty) {
      _alert(context, '还没填路径', '先在上面的「扫描路径」里填文件或文件夹，再点 $engine。');
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _stage = engine == 'huorong' ? '正在交给火绒' : '正在交给 PYAS';
      _detail = path;
      _progress = null;
    });
    Map<String, dynamic> r;
    try {
      r = engine == 'huorong' ? Native.scanHuorong(path) : Native.scanPyas(path);
    } catch (e) {
      r = {'success': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final okd = r['success'] == true;
    final note = (r['data'] is Map ? (r['data'] as Map)['note'] : null)?.toString() ?? '';
    _alert(
      context,
      okd ? (engine == 'huorong' ? '已交给火绒' : 'PYAS 已返回') : '${engine} 调用失败',
      okd ? (note.isNotEmpty ? note : '已把目标交给外部引擎，结论以对方界面为准。') : (r['message']?.toString() ?? '未知错误'),
    );
  }

  Future<void> _runScan(
    Future<Map<String, dynamic>> Function() task,
    String stage,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _results.clear();
      _progress = 0;
      _hits = 0;
      _recent.clear();
      _stage = stage;
      _detail = '';
    });

    final future = task();
    var last = '';
    final ticker = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted) return;
      final d = (Native.scanProgress()['data'] as Map?)?.cast<String, dynamic>();
      if (d == null) return;
      final cur = d['current']?.toString() ?? '';
      final total = (d['total'] as num?)?.toInt() ?? 0;
      final done = (d['done'] as num?)?.toInt() ?? 0;
      setState(() {
        // 流式扫描没有总数，就别假造百分比
        _progress = total > 0 ? done / total : null;
        _scanned = done;
        _hits = (d['hits'] as num?)?.toInt() ?? 0;
        final scope = d['scope']?.toString() ?? '';
        if (scope.isNotEmpty) _stage = '$scope中';
        if (cur.isNotEmpty && cur != last) {
          last = cur;
          _recent.add(cur);
          if (_recent.length > 7) _recent.removeAt(0);
        }
      });
    });

    Map<String, dynamic> r;
    try {
      r = await future;
    } finally {
      ticker.cancel();
    }
    if (!mounted) return;

    if (r['success'] == true && r['data'] is Map) {
      final d = (r['data'] as Map).cast<String, dynamic>();
      final list = ((d['engines'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      final files = (d['files'] as num?)?.toInt() ?? 0;
      final scope = d['scope']?.toString() ?? stage;
      final threats = list.expand((m) => (m['threats'] as List?) ?? const <dynamic>[]).toList();
      final infected = d['infected'] == true;
      final canceled = d['canceled'] == true;
      setState(() {
        if (list.isEmpty) {
          _results.add({
            'engine': 'QW 安全电脑管家 · 查杀引擎',
            'ok': true,
            'message': d['empty'] == true ? '没有可扫描的文件' : '已跳过（白名单）',
            'infected': false,
            'threats': const [],
          });
        } else {
          _results.add({
            'engine': 'QW 安全电脑管家 · 查杀引擎',
            'ok': true,
            'message': '$scope · 扫描 $files 个文件'
                '${canceled ? " · 已中止" : ""}'
                '${infected ? " · 发现 ${threats.length} 项威胁" : " · 未发现威胁"}',
            'infected': infected,
            'threats': threats,
          });
        }
        _busy = false;
      });
      if (infected && !canceled) {
        await _handleThreats(scope, threats);
      }
      return;
    }

    setState(() {
      _busy = false;
      _results.add({
        'engine': 'QW 安全电脑管家 · 查杀引擎',
        'ok': false,
        'message': r['message']?.toString() ?? '失败',
        'infected': false,
        'threats': const [],
      });
    });
  }

  Future<void> _scanQuick() =>
      _runScan(() => Isolate.run(() => Api.scanByMode('quick', '')), '快速扫描');

  Future<void> _scanFull() =>
      _runScan(() => Isolate.run(() => Api.scanByMode('full', '')), '全盘扫描');

  Future<void> _scanUsb() =>
      _runScan(() => Isolate.run(() => Api.scanByMode('usb', '')), 'U 盘扫描');

  Future<void> _scanCustom() async {
    final t = _pathCtrl.text.trim();
    if (t.isEmpty) return;
    await _runScan(() => Isolate.run(() => Api.scanByMode('custom', t)), '指定位置扫描');
  }

  void _cancelScan() {
    Api.scanCancel();
    if (mounted) setState(() => _stage = '正在停止…');
  }

  Widget _rulesCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hashes = (_rules['hashes'] as num?)?.toInt() ?? 0;
    final names = (_rules['names'] as num?)?.toInt() ?? 0;
    final yara = _rules['yara'] == true;
    return LiquidGlass(
      radius: 26,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.dataset_rounded, size: 18),
            const SizedBox(width: 8),
            const Text('QW 引擎 · 病毒库',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(
              onPressed: _loadRules,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('刷新', style: TextStyle(fontSize: 12)),
            ),
          ]),
          Text('哈希 $hashes 条 · 文件名规则 $names 条 · 内置 YARA ${yara ? '就绪' : '缺失'}',
              style: TextStyle(
                  fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(
              onPressed: _importHashes,
              icon: const Icon(Icons.file_open_rounded, size: 16),
              label: const Text('导入哈希文件', style: TextStyle(fontSize: 12)),
            ),
          ]),
        ],
      ),
    );
  }

  Future<void> _importHashes() async {
    final ctrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入哈希文件', style: TextStyle(fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('选一个 txt，一行一个 SHA-256（64 位十六进制），# 开头是注释',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 10),
          TextField(
            controller: ctrl,
            decoration: const InputDecoration(
                hintText: r'C:\Users\me\hashes.txt', isDense: true),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('导入')),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    final r = Api.rulesImport(path);
    if (r['success'] == true) {
      final a = (r['data']?['added'] as num?)?.toInt() ?? 0;
      final t = (r['data']?['total'] as num?)?.toInt() ?? 0;
      _toastScan('已导入：新增 $a 条，库内共 $t 条');
    } else {
      _toastScan(r['message']?.toString() ?? '导入失败');
    }
    _loadRules();
  }

  void _alert(BuildContext ctx, String title, String msg) {
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(_), child: const Text('知道了')),
        ],
      ),
    );
  }

  void _toastScan(String m) {
    if (m.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _handleThreats(String scope, List<dynamic> threats) async {
    // 取第一条命中记录里的真实文件路径（"路径 · 描述"），拿它去隔离/弹窗
    var target = scope;
    if (threats.isNotEmpty) {
      final s0 = threats.first.toString();
      final i = s0.indexOf(' · ');
      if (i > 0) target = s0.substring(0, i);
    }
    if (!mounted) return;
    if (!_results.any((r) => r['infected'] == true)) return;

    final sec = Api.securitySettings();
    final action = (sec['success'] == true && sec['data'] is Map)
        ? (sec['data']['virus_action']?.toString() ?? 'ask')
        : 'ask';

    if (action == 'record') {
      _toastScan('已记录这条威胁，没有动文件');
      return;
    }
    if (action == 'auto') {
      final r = Api.quarantineAdd(target, 'multi', '查杀命中，自动隔离');
      _toastScan(r['success'] == true
          ? '已自动移入隔离库，原目录里看不到它了'
          : (r['message']?.toString() ?? '隔离失败'));
      return;
    }
    await _virusDialog(target);
  }

  /// 发现病毒的弹窗：立即处理 / 展开详情（仅允许一次、加信任区）
  Future<void> _virusDialog(String target) async {
    var expanded = false;
    final act = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: LiquidGlass(
              radius: 30,
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.gpp_maybe_rounded, color: Colors.redAccent, size: 26),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('发现威胁',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Text(target,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final r in _results.where((e) => e['infected'] == true))
                      Chip(
                        label: Text('${r['engine']}',
                            style: const TextStyle(fontSize: 10)),
                        visualDensity: VisualDensity.compact,
                      ),
                  ]),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () => setS(() => expanded = !expanded),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(expanded ? '收起详情' : '展开详情',
                          style: const TextStyle(fontSize: 11.5)),
                      Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                          size: 16),
                    ]),
                  ),
                  if (expanded)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Column(children: [
                        _wideBtn('仅允许这一次', Icons.check_rounded,
                            () => Navigator.of(ctx).pop('once')),
                        const SizedBox(height: 8),
                        _wideBtn('把这个文件放进信任区（以后不再扫它）',
                            Icons.shield_rounded, () => Navigator.of(ctx).pop('trust')),
                      ]),
                    ),
                  const SizedBox(height: 18),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                        onPressed: () => Navigator.of(ctx).pop('later'),
                        child: const Text('稍后')),
                    const SizedBox(width: 8),
                    LiquidButton(
                      text: '立即处理',
                      icon: Icons.security_rounded,
                      onTap: () => Navigator.of(ctx).pop('handle'),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (!mounted) return;
    switch (act) {
      case 'handle':
        final r = Api.quarantineAdd(target, 'multi', '用户选择立即处理');
        _toastScan(r['success'] == true
            ? '已移入隔离库，原目录里看不到它了，要还原去隔离库点恢复'
            : (r['message']?.toString() ?? '处理失败'));
        break;
      case 'once':
        _toastScan('已放行这一次');
        break;
      case 'trust':
        Api.whitelistAdd(target);
        _toastScan('已加入信任区，以后不再扫它');
        break;
      default:
        break;
    }
  }

  Widget _wideBtn(String text, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
        ),
        child: Row(children: [
          Icon(icon, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageTitle(
            title: I18n.t('scan'),
            subtitle: I18n.lang == 'en' ? 'Built-in engines scan, external tools launch in one click' : '内置引擎扫描，外部工具可一键唤起',
          ),
          const SizedBox(height: 16),
          LiquidGlass(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('QW 安全电脑管家 · 查杀引擎',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('四个子引擎合并工作：特征库 · 启发式 · Defender · YARA —— 全部内置，无需另装',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                const SizedBox(height: 10),
                _rulesCard(),
                const SizedBox(height: 14),
                Text(I18n.t('path'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(
                  controller: _pathCtrl,
                  decoration: InputDecoration(
                    hintText: I18n.lang == 'en' ? 'e.g. C:\\Users\\me\\Downloads' : '例如 C:\\Users\\me\\Downloads',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Text('${I18n.t('whitelist')} ($_wlCount)', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 10),
                  LiquidButton(text: I18n.t('add'), icon: Icons.playlist_add_rounded, primary: false, onTap: () => _wl(true)),
                  const SizedBox(width: 8),
                  LiquidButton(text: I18n.t('remove'), icon: Icons.playlist_remove_rounded, primary: false, onTap: () => _wl(false)),
                  const Spacer(),
                  Text(I18n.t('external'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  LiquidButton(text: '快速扫描', icon: Icons.bolt_rounded,
                      onTap: _busy ? null : _scanQuick),
                  const SizedBox(width: 8),
                  LiquidButton(text: '全盘扫描', icon: Icons.storage_rounded, primary: false,
                      onTap: _busy ? null : _scanFull),
                  const SizedBox(width: 8),
                  LiquidButton(text: 'U 盘扫描', icon: Icons.usb_rounded, primary: false,
                      onTap: _busy ? null : _scanUsb),
                  const SizedBox(width: 8),
                  LiquidButton(text: '指定位置扫描', icon: Icons.folder_open_rounded, primary: false,
                      onTap: _busy ? null : _scanCustom),
                  const Spacer(),
                  if (_busy)
                    LiquidButton(text: '停止', icon: Icons.stop_circle_rounded, primary: false,
                        onTap: _cancelScan),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  const Spacer(),
                  LiquidButton(text: '火绒 hrscan', icon: Icons.security_rounded, primary: false,
                      onTap: () => _runExternal('huorong')),
                  const SizedBox(width: 10),
                  LiquidButton(text: 'PYAS', icon: Icons.security_rounded, primary: false,
                      onTap: () => _runExternal('pyas')),
                ]),
              ]),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: _busy
                ? Center(
                    // 页面上下都排满时给的高度不够，雷达会被直接裁掉一半。
                    // scaleDown 让它按可用高度等比缩小，永远完整显示。
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: ScanFx(
                        stage: _stage,
                        detail: _detail,
                        recent: _recent,
                        progress: _progress,
                        hits: _hits,
                        scanned: _scanned,
                      ),
                    ),
                  )
                : _results.isEmpty
                    ? Center(child: Text(I18n.t('empty'), style: TextStyle(color: isDark ? Colors.white54 : Colors.black45)))
                    : ListView.separated(
                        itemCount: _results.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final r = _results[i];
                          final ok = r['ok'] == true;
                          final infected = r['infected'] == true;
                          final color = !ok ? Colors.orange : (infected ? const Color(0xFFFF453A) : const Color(0xFF34C759));
                          return LiquidGlass(
                            padding: const EdgeInsets.all(14),
                            radius: 26,
                            child: Row(children: [
                              Icon(infected ? Icons.warning_rounded : (ok ? Icons.verified_rounded : Icons.info_rounded),
                                  color: color, size: 22),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(r['engine'].toString(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 3),
                                  Text(
                                    ok
                                        ? (infected
                                            ? (I18n.lang == 'en' ? 'Threat found' : '发现威胁')
                                            : (I18n.lang == 'en' ? 'No threat' : '未发现威胁'))
                                        : r['message'].toString(),
                                    style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.black54),
                                  ),
                                ]),
                              ),
                            ]),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ======================= 工具合集 =======================

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  final TextEditingController _search = TextEditingController();
  String _kw = '';

  /// 工具清单：界面上一律带「QW 安全电脑管家」前缀
  static const List<(String, IconData, String)> _tools = [
    ('启动项管理', Icons.toggle_on_rounded, '查看和管理开机启动的程序'),
    ('进程管理', Icons.bar_chart_rounded, '看谁在吃 CPU 和内存'),
    ('网络诊断', Icons.wifi_rounded, '测连通性、看端口占用'),
    ('磁盘分析', Icons.pie_chart_rounded, '哪些目录最占地方'),
    ('文件粉碎机', Icons.delete_forever_rounded, '先解除占用，再三遍覆写'),
    ('注册表清理', Icons.settings_rounded, '清无效项，动手前先备份'),
    ('去除快捷方式小箭头', Icons.shortcut_rounded, '可逆，再点一次恢复'),
    ('显示文件后缀', Icons.text_fields_rounded, '可逆，再点一次隐藏'),
    ('环境自检', Icons.verified_rounded, '检查本机环境是否完整'),
    ('运行库补全', Icons.build_circle_rounded, '查 VC++ / DirectX 缺什么，一键补齐'),
  ];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<(String, IconData, String)> get _filtered {
    if (_kw.trim().isEmpty) return _tools;
    final k = _kw.trim().toLowerCase();
    return _tools
        .where((t) => t.$1.toLowerCase().contains(k) || t.$3.toLowerCase().contains(k))
        .toList();
  }

  void _toast(BuildContext context, String msg) {
    if (msg.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _run(BuildContext context, String name) async {
    switch (name) {
      case '去除快捷方式小箭头':
        final on = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('QW 安全电脑管家 · 快捷方式小箭头'),
            content: const Text('去掉桌面快捷方式左下角的小箭头，随时可以恢复系统默认。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('恢复默认')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('去掉箭头')),
            ],
          ),
        );
        if (on == null) return;
        final r = Api.shortcutArrow(on);
        _toast(context, r['message']?.toString() ?? '');
        break;
      case '显示文件后缀':
        final show = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('QW 安全电脑管家 · 文件后缀显示'),
            content: const Text('让资源管理器把所有文件的扩展名都显示出来，随时可以恢复隐藏。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('恢复隐藏')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('显示全部')),
            ],
          ),
        );
        if (show == null) return;
        final r = Api.fileExtShow(show);
        _toast(context, r['message']?.toString() ?? '');
        break;
      case '文件粉碎机':
        await _shredder(context);
        break;
      case '环境自检':
        final r = Api.envCheck();
        _toast(
            context,
            r['success'] == true
                ? (r['data']['ok'] == true
                    ? '环境正常'
                    : '环境异常：${(r['data']['issues'] as List?)?.join('、') ?? ''}')
                : (r['message']?.toString() ?? '自检失败'));
        break;
      case '运行库补全':
        await _runtime(context);
        break;
      default:
        _toast(context, 'QW 安全电脑管家 · $name 正在接入');
    }
  }

  Future<void> _shredder(BuildContext context) async {
    final ctrl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => QDialog(
        icon: Icons.delete_forever_rounded,
        title: 'QW 安全电脑管家 · 文件粉碎机',
        body: '把要粉碎的文件或文件夹路径粘进来，一行一个。\n'
            '会先尝试解除占用，再三遍覆写（0x00 / 0xFF / 伪随机），最后删除。',
        okText: '下一步',
        cancelText: '取消',
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: DropTarget(
            onDrop: (detail) {
              final ps = <String>[];
              for (final it in detail.items) {
                final p = switch (it) {
                  DropFileItem() => it.localPath,
                  DropDirectoryItem() => it.localPath,
                  _ => null,
                };
                if (p != null && p.isNotEmpty) ps.add(p);
              }
              if (ps.isNotEmpty) ctrl.text = ps.join('\n');
            },
            child: TextField(
              controller: ctrl,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: '一行一个路径，也可以直接把文件 / 文件夹拖进来',
                isDense: true,
              ),
            ),
          ),
        ),
        onOk: () => Navigator.of(ctx).pop(true),
      ),
    );
    if (go != true) {
      ctrl.dispose();
      return;
    }
    final paths = ctrl.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    ctrl.dispose();
    if (paths.isEmpty || !context.mounted) return;

    final sure = await showDialog<bool>(
      context: context,
      builder: (_) => QDialog(
        icon: Icons.warning_amber_rounded,
        title: '粉碎后很难恢复',
        body: '粉碎会覆写文件内容。即便拿专业的数据恢复工具来，也很难把它捞回来。\n\n'
            '确定要粉碎这 ${paths.length} 项吗？',
        okText: '确定',
        cancelText: '取消',
      ),
    );
    if (sure != true || !context.mounted) return;

    final r = Api.shredderRun(paths);
    _toast(
        context,
        r['success'] == true
            ? '已粉碎 ${r['data']['files']} 个文件，释放 ${_size((r['data']['bytes'] as num?) ?? 0)}'
            : (r['message']?.toString() ?? '粉碎失败'));
  }

  /// 运行库补全：先扫、再确认、再后台修，进度靠定时轮询
  Future<void> _runtime(BuildContext context) async {
    // 先亮扫描动效（扫描是同步 FFI，丢后台跑），扫完再弹结果
    final overlay = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: LiquidGlass(
          radius: 28,
          padding: const EdgeInsets.all(26),
          child: const ScanFx(
            stage: '正在扫描运行库',
            detail: '核对 VC++ 运行时可再发行包 / DirectX 组件',
            size: 168,
          ),
        ),
      ),
    );
    final scan = await Isolate.run(() => Api.runtimeScan());
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await overlay;
    if (scan['success'] != true) {
      _toast(context, scan['message']?.toString() ?? '扫描失败');
      return;
    }
    final data = (scan['data'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final items = ((data['items'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final missing =
        ((data['missing'] as List?) ?? const []).map((e) => e.toString()).toList();

    final tr = Api.runtimeTools();
    final tdata = (tr['data'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final vcInfo = (tdata['vcredist'] as Map?)?.cast<String, dynamic>();
    final dxInfo = (tdata['dxrepair'] as Map?)?.cast<String, dynamic>();

    final buf = StringBuffer();
    for (final it in items) {
      buf.writeln('${it['ok'] == true ? '[有]' : '[缺]'}  ${it['name']}');
    }

    // 第二重：DirectX Repair 自带清单的比对结果
    final dx32 = ((data['dx_data_32'] as List?) ?? const []).map((e) => e.toString()).toList();
    final dx64 = ((data['dx_data_64'] as List?) ?? const []).map((e) => e.toString()).toList();
    final dxCnt = (data['dx_data_missing'] as num?)?.toInt() ?? 0;
    final dxReady = data['dx_data_ready'] == true;
    final dxLine = !dxReady
        ? 'DirectX Repair 清单比对：数据包不在，跳过这一重'
        : (dxCnt == 0
            ? 'DirectX Repair 清单比对：组件齐全'
            : 'DirectX Repair 清单比对：缺 $dxCnt 个（32 位 ${dx32.length} / 64 位 ${dx64.length}）');

    final body = '本机情况：\n$buf\n'
        '${missing.isEmpty ? '一项都不缺。' : '缺 ${missing.length} 项：${missing.join('、')}'}\n\n'
        '$dxLine\n\n'
        '内置修复组件：随包自带，${(vcInfo?['verified'] == true && dxInfo?['verified'] == true) ? '校验通过' : '校验中'}，'
        '缺什么补什么，不重复安装。';

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => QDialog(
        icon: Icons.build_circle_rounded,
        title: 'QW 安全电脑管家 · 运行库补全',
        body: body,
        okText: '开始修复',
        cancelText: '先不修',
        onOk: () => Navigator.of(ctx).pop(true),
      ),
    );
    if (go != true || !context.mounted) return;

    const dxKeys = ['dx9', 'xinput', 'd3dcompiler'];
    final needDx = items.any((i) => i['ok'] != true && dxKeys.contains(i['key']));
    final needVc = items.any((i) => i['ok'] != true && !dxKeys.contains(i['key']));
    final mode = (needVc && needDx) ? 'all' : (needDx ? 'dx' : 'vc');

    final started = Api.runtimeFix(mode);
    if (started['success'] != true) {
      if (context.mounted) {
        _toast(context, started['message']?.toString() ?? '启动失败');
      }
      return;
    }
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        Timer? timer;
        var stage = '正在准备…';
        var tail = '';
        var done = false;
        var good = false;

        return StatefulBuilder(
          builder: (ctx2, setSt) {
            void poll() {
              final s = Api.runtimeStatus();
              if (s['success'] != true) return;
              final d = (s['data'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
              final running = d['running'] == true;
              final finished = d['finished'] == true;
              final okRun = d['success'] == true;
              final tool = d['tool']?.toString() ?? '';
              final code = d['exit_code'];
              if (!ctx2.mounted) return;
              setSt(() {
                if (running) {
                  stage = tool.isEmpty ? '正在准备…' : '正在跑 $tool';
                } else if (finished) {
                  stage = okRun ? '修复完成' : '跑完了，退出码 $code';
                }
                tail = d['log_tail']?.toString() ?? tail;
                done = finished;
                good = okRun;
              });
              if (finished) {
                timer?.cancel();
                timer = null;
              }
            }

            timer ??= Timer.periodic(const Duration(seconds: 1), (_) => poll());

            return QDialog(
              icon: done
                  ? (good ? Icons.check_circle_rounded : Icons.info_rounded)
                  : Icons.hourglass_bottom_rounded,
              title: 'QW 安全电脑管家 · 运行库补全',
              body: done
                  ? (good
                      ? '补全流程跑完了，建议重启一次让新装上的运行库生效。'
                      : '流程跑完了但退出码不是 0，多半是没给管理员权限，或者被别的安全软件拦了。')
                  : '$stage\n\n这一步交给内置工具自己做，不用管它。',
              child: tail.trim().isEmpty
                  ? const SizedBox.shrink()
                  : Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 120),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: Theme.of(ctx2).brightness == Brightness.dark
                            ? Colors.white.withOpacity(0.05)
                            : Colors.black.withOpacity(0.04),
                      ),
                      child: SingleChildScrollView(
                        child: Text(tail,
                            style: const TextStyle(
                                fontSize: 10.5, fontFamily: 'Consolas', height: 1.4)),
                      ),
                    ),
              okText: done ? '知道了' : '收起',
              cancelText: done ? '关闭' : null,
              onOk: () {
                timer?.cancel();
                Navigator.of(ctx2).pop();
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final list = _filtered;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageTitle(
            title: I18n.t('tools'),
            subtitle: I18n.lang == 'en' ? 'More utilities will be added' : '系统小工具按需接入，全部带 QW 前缀',
          ),
          const SizedBox(height: 14),
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04),
            ),
            child: Row(children: [
              Icon(Icons.search_rounded, size: 18, color: isDark ? Colors.white38 : Colors.black38),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: '搜工具名或用途',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 12.5),
                  onChanged: (v) => setState(() => _kw = v),
                ),
              ),
              if (_kw.isNotEmpty)
                InkWell(
                  onTap: () {
                    _search.clear();
                    setState(() => _kw = '');
                  },
                  child: const Icon(Icons.close_rounded, size: 16),
                ),
            ]),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text('没找到这个工具',
                        style: TextStyle(
                            fontSize: 12.5, color: isDark ? Colors.white38 : Colors.black45)))
                : GridView.count(
                    crossAxisCount: MediaQuery.of(context).size.width > 1180 ? 4 : 3,
                    mainAxisSpacing: 13,
                    crossAxisSpacing: 13,
                    childAspectRatio: 1.12,
                    children: [
                      for (final t in list)
                        LiquidGlass(
                          onTap: () => _run(context, t.$1),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const LinearGradient(
                                      colors: [Color(0xFF4B96FF), Color(0xFF2F7BFF)]),
                                  boxShadow: [
                                    BoxShadow(
                                        color: const Color(0xFF2F7BFF).withOpacity(0.32),
                                        blurRadius: 15,
                                        offset: const Offset(0, 7))
                                  ],
                                ),
                                child: Icon(t.$2, color: Colors.white, size: 22),
                              ),
                              const SizedBox(height: 10),
                              Text('QW 安全电脑管家 · ${t.$1}',
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12, fontWeight: FontWeight.w600, height: 1.35)),
                              const SizedBox(height: 4),
                              Text(t.$3,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 10,
                                      height: 1.3,
                                      color: isDark ? Colors.white38 : Colors.black45)),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text('新功能陆续推送，敬请期待',
                style: TextStyle(
                    fontSize: 11, color: isDark ? Colors.white30 : Colors.black.withOpacity(0.3))),
          ),
        ],
      ),
    );
  }
}


// ======================= 新手引导弹窗 =======================

// ======================= 隔离库 =======================

class QuarantinePage extends StatefulWidget {
  const QuarantinePage({super.key});

  @override
  State<QuarantinePage> createState() => _QuarantinePageState();
}

class _QuarantinePageState extends State<QuarantinePage> {
  List<Map<String, dynamic>> _items = [];
  final Set<String> _sel = {};
  final TextEditingController _search = TextEditingController();
  String _kw = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = Api.quarantineList();
    if (!mounted) return;
    setState(() {
      _items = r['success'] == true && r['data'] is Map
          ? ((r['data']['items'] as List?) ?? const [])
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList()
          : [];
      _sel.removeWhere((id) => !_items.any((i) => i['id'] == id));
    });
  }

  List<Map<String, dynamic>> get _filtered {
    if (_kw.trim().isEmpty) return _items;
    final k = _kw.trim().toLowerCase();
    return _items.where((i) {
      final n = i['name']?.toString().toLowerCase() ?? '';
      final o = i['origin']?.toString().toLowerCase() ?? '';
      return n.contains(k) || o.contains(k);
    }).toList();
  }

  void _toast(String msg) {
    if (msg.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _restore(String id) async {
    final r = Api.quarantineRestore(id);
    await _load();
    if (mounted) {
      _toast(r['success'] == true
          ? '已恢复：${r['data']['restored_to'] ?? ''}'
          : (r['message']?.toString() ?? '恢复失败'));
    }
  }

  Future<void> _delete(String id) async {
    final r = Api.quarantineDelete(id);
    await _load();
    if (mounted) _toast(r['success'] == true ? '已彻底删除' : (r['message']?.toString() ?? '删除失败'));
  }

  Future<void> _clear() async {
    if (_items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => QDialog(
        icon: Icons.delete_sweep_rounded,
        title: '清空隔离库',
        body: '清空之后这些文件就彻底没了，专业数据恢复也捞不回来。\n\n'
            '一共 ${_items.length} 项，${_size(_total)}。确定吗？',
        okText: '清空',
        cancelText: '取消',
      ),
    );
    if (ok != true) return;
    final r = Api.quarantineClear();
    await _load();
    if (mounted) _toast(r['success'] == true ? '隔离库已清空' : '清空失败');
  }

  int get _total => _items.fold(0, (a, b) => a + ((b['size'] as num?)?.toInt() ?? 0));

  String _time(num? t) {
    if (t == null || t == 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(t.toInt() * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final list = _filtered;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageTitle(
            title: '隔离库',
            subtitle: '查到的威胁都关在这里，不会自动删，随时能放回去',
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04),
                ),
                child: Row(children: [
                  Icon(Icons.search_rounded, size: 17, color: isDark ? Colors.white38 : Colors.black38),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _search,
                      decoration: const InputDecoration(
                          hintText: '搜文件名或原路径', border: InputBorder.none, isDense: true),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (v) => setState(() => _kw = v),
                    ),
                  ),
                  if (_kw.isNotEmpty)
                    InkWell(
                      onTap: () {
                        _search.clear();
                        setState(() => _kw = '');
                      },
                      child: const Icon(Icons.close_rounded, size: 15),
                    ),
                ]),
              ),
            ),
            const SizedBox(width: 10),
            Text('${_items.length} 项 · ${_size(_total)}',
                style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54)),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '刷新',
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            TextButton(
              onPressed: () => setState(() {
                final ids = list.map((e) => e['id'].toString()).toSet();
                if (_sel.containsAll(ids) && ids.isNotEmpty) {
                  _sel.removeAll(ids);
                } else {
                  _sel.addAll(ids);
                }
              }),
              child: Text(_sel.isEmpty ? '全选' : '反选'),
            ),
            TextButton(
              onPressed: _sel.isEmpty
                  ? null
                  : () async {
                      for (final id in _sel.toList()) {
                        Api.quarantineDelete(id);
                      }
                      await _load();
                      if (mounted) _toast('已删除选中的 ${_sel.length} 项');
                    },
              child: const Text('删除选中'),
            ),
            const Spacer(),
            TextButton(
              onPressed: _items.isEmpty ? null : _clear,
              child: const Text('一键清除', style: TextStyle(color: Colors.redAccent)),
            ),
          ]),
          const SizedBox(height: 4),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.inbox_rounded,
                          size: 38, color: isDark ? Colors.white24 : Colors.black26),
                      const SizedBox(height: 10),
                      Text('隔离库是空的',
                          style: TextStyle(
                              fontSize: 12.5, color: isDark ? Colors.white38 : Colors.black45)),
                      const SizedBox(height: 4),
                      Text('查到病毒后会自动收进来，原目录里就看不到那个文件了',
                          style: TextStyle(
                              fontSize: 10.5, color: isDark ? Colors.white24 : Colors.black26)),
                    ]),
                  )
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => SizedBox(height: 8),
                    itemBuilder: (ctx, i) {
                      final it = list[i];
                      final id = it['id'].toString();
                      final checked = _sel.contains(id);
                      return LiquidGlass(
                        radius: 20,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(children: [
                          Checkbox(
                            value: checked,
                            visualDensity: VisualDensity.compact,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _sel.add(id);
                              } else {
                                _sel.remove(id);
                              }
                            }),
                          ),
                          const SizedBox(width: 2),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${it['name'] ?? ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12.5, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text('${it['origin'] ?? ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: isDark ? Colors.white38 : Colors.black45)),
                              const SizedBox(height: 2),
                              Text(
                                  '${_size((it['size'] as num?)?.toInt() ?? 0)} · ${_time(it['time'] as num?)} · ${it['engine'] ?? ''}',
                                  style: TextStyle(
                                      fontSize: 9.5,
                                      color: isDark ? Colors.white24 : Colors.black38)),
                            ]),
                          ),
                          TextButton(
                            onPressed: () => _restore(id),
                            child: const Text('恢复', style: TextStyle(fontSize: 12)),
                          ),
                          TextButton(
                            onPressed: () => _delete(id),
                            child: const Text('清除',
                                style: TextStyle(fontSize: 12, color: Colors.redAccent)),
                          ),
                        ]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}


class WelcomeSheet extends StatefulWidget {
  final ThemeOption initial;
  final String initialLang;

  const WelcomeSheet({super.key, required this.initial, this.initialLang = 'zh'});

  @override
  State<WelcomeSheet> createState() => _WelcomeSheetState();
}

class _WelcomeSheetState extends State<WelcomeSheet> {
  late ThemeOption _theme = widget.initial;
  late String _lang = widget.initialLang;
  late String _material = Ui.material.value;
  late final Map<String, bool> _anim = {for (final a in Ui.anims) a.key: Ui.isOn(a.key)};

  final PageController _pc = PageController();
  int _page = 0;

  /// 五档材质：默认混搭（控件玻璃 + 背景云母）
  static const _materials = [
    ('auto', '智能混搭（默认）', '按钮和选项用液态玻璃，窗口背景用 Win11 云母，各管一块', Icons.auto_awesome_rounded),
    ('mica', 'Windows 11 云母', '整窗云母，中性冷调，最贴近系统原生观感', Icons.blur_on_rounded),
    ('aero', 'Windows 7 Aero', '薄雾玻璃加顶部强高光，老 Aero 那种通透感', Icons.wb_sunny_rounded),
    ('glass', '液态玻璃', 'iOS 27 液态玻璃，边缘色散、流动折射、玻璃厚度高光', Icons.water_drop_rounded),
    ('solid', '纯色', '不透明实色，最省性能', Icons.square_rounded),
  ];

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_page + delta).clamp(0, 2);
    _pc.animateToPage(next, duration: const Duration(milliseconds: 420), curve: Ui.spring);
    setState(() => _page = next);
  }

  Future<void> _finish() async {
    Ui.material.value = _material;
    for (final e in _anim.entries) {
      Ui.on(e.key).value = e.value;
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setString('ui_material', _material);
    for (final e in _anim.entries) {
      await sp.setBool('anim_${e.key}', e.value);
    }
    await AppSettings.saveTheme(_theme);
    await AppSettings.saveLang(_lang);
    await AppSettings.markFirstRunDone();
    if (mounted) Navigator.of(context).pop([_theme, _lang]);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: LiquidGlass(
          radius: 34,
          padding: const EdgeInsets.fromLTRB(26, 22, 26, 16),
          child: SizedBox(
            height: 560,
            child: Column(
              children: [
                Row(children: [
                  Expanded(
                    child: Text(I18n.t('welcome'),
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                  ),
                  Text('${_page + 1}/3',
                      style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white38 : Colors.black38)),
                ]),
                const SizedBox(height: 10),
                // 三段式进度条，切换时也跟着动
                Row(children: [
                  for (var i = 0; i < 3; i++) ...[
                    Expanded(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 260),
                        height: 3.5,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(99),
                          color: i <= _page
                              ? const Color(0xFF2F7BFF)
                              : (isDark ? Colors.white12 : Colors.black12),
                        ),
                      ),
                    ),
                    if (i < 2) const SizedBox(width: 5),
                  ],
                ]),
                const SizedBox(height: 16),
                Expanded(
                  child: PageView(
                    controller: _pc,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (i) => setState(() => _page = i),
                    children: [_matPage(isDark), _animPage(isDark), _themePage(isDark)],
                  ),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  if (_page > 0)
                    TextButton(
                      onPressed: () => _go(-1),
                      child: Text(I18n.lang == 'en' ? 'Back' : '上一步'),
                    )
                  else
                    const SizedBox(width: 64),
                  const Spacer(),
                  LiquidButton(
                    text: _page == 2
                        ? I18n.t('confirm')
                        : (I18n.lang == 'en' ? 'Next' : '下一步'),
                    icon: _page == 2 ? Icons.check_rounded : Icons.arrow_forward_rounded,
                    onTap: _page == 2 ? _finish : () => _go(1),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _matPage(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('界面材质', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 5),
        Text('默认走混搭：按钮和选项是液态玻璃，窗口背景是 Win11 云母。想要整窗全玻璃或者 Win7 那种 Aero 观感，再手动切。',
            style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white38 : Colors.black45)),
        const SizedBox(height: 12),
        for (final m in _materials)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: LiquidGlass(
              radius: 22,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              onTap: () => setState(() => _material = m.$1),
              child: Row(children: [
                Icon(m.$4, size: 19, color: _material == m.$1 ? const Color(0xFF2F7BFF) : null),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(m.$2, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(m.$3, style: TextStyle(fontSize: 10.5, color: isDark ? Colors.white38 : Colors.black45)),
                  ]),
                ),
                Icon(
                  _material == m.$1 ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  size: 18,
                  color: const Color(0xFF2F7BFF),
                ),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _animPage(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('动画效果', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 5),
        Text('每一项都能单独关，关掉后对应效果立即停止，配置会记住。',
            style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white38 : Colors.black45)),
        const SizedBox(height: 6),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final a in Ui.anims)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(I18n.lang == 'en' ? a.en : a.zh,
                      style: const TextStyle(fontSize: 12.5)),
                  value: _anim[a.key] ?? a.defaultOn,
                  onChanged: (v) => setState(() => _anim[a.key] = v),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _themePage(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(I18n.t('pickTheme'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        // 顺序：跟随系统 → 浅色 → 深色。
        // 「跟随系统」是 Windows 11 的默认习惯，原来排在第三，
        // 想用它得先翻过两个不想要的选项。
        _opt(I18n.t('system'), ThemeOption.system),
        const SizedBox(height: 9),
        _opt(I18n.t('light'), ThemeOption.light),
        const SizedBox(height: 9),
        _opt(I18n.t('dark'), ThemeOption.dark),
        const SizedBox(height: 16),
        Row(children: [
          Text('${I18n.t('language')}:', style: const TextStyle(fontSize: 12.5)),
          const SizedBox(width: 8),
          // 写全称，不用「简 / 繁 / EN」这种缩写 —— 用户第一眼要能看懂是什么语言
          ChoiceChip(label: const Text('简体中文'), selected: _lang == 'zh', onSelected: (_) => setState(() => _lang = 'zh')),
          const SizedBox(width: 6),
          ChoiceChip(label: const Text('繁體中文'), selected: _lang == 'hant', onSelected: (_) => setState(() => _lang = 'hant')),
          const SizedBox(width: 6),
          ChoiceChip(label: const Text('English'), selected: _lang == 'en', onSelected: (_) => setState(() => _lang = 'en')),
        ]),
      ],
    );
  }

  Widget _opt(String text, ThemeOption v) {
    final on = _theme == v;
    return LiquidGlass(
      radius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      onTap: () => setState(() => _theme = v),
      child: Row(children: [
        Text(text, style: const TextStyle(fontSize: 14)),
        const Spacer(),
        Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
            size: 19, color: const Color(0xFF2F7BFF)),
      ]),
    );
  }
}


// ======================= 设置 =======================

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _gpuMode = 'auto';
  bool _autoStart = false;
  String _repo = '';
  String _current = '1.0';
  String _updateMsg = '';
  List<String> _wl = [];
  String _runtimeMsg = '';
  String _installMsg = '';
  String _usbMsg = '';
  String _cpuMsg = '';
  bool _desktopFloat = false;
  String _renderMsg = '';
  List<Map<String, dynamic>> _gpus = [];
  String _virusAction = 'ask';
  int _cleanInterval = 60;
  int _scanInterval = 60;
  bool _idleOnly = true;
  bool _pwdEnabled = false;
  bool _silentUpdate = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final sp = await SharedPreferences.getInstance();
    final cfg = Api.settings();
    final wl = Api.whitelist();
    final cpu = Api.cpuProfile();
    if (!mounted) return;
    setState(() {
      _autoStart = sp.getBool('autostart') ?? false;
      _repo = sp.getString('github_repo') ?? '';
      _current = sp.getString('app_version') ?? '1.0';
      _desktopFloat = sp.getBool('ui_desktop_float') ?? false;
      final g = Api.gpu();
      if (g['success'] == true && g['data'] is Map) {
        _gpus = ((g['data']['gpus'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
      }
      if (cfg['success'] == true && cfg['data'] is Map) {
        _gpuMode = (cfg['data']['gpu_mode']?.toString() ?? 'auto');
      }
      if (wl['success'] == true && wl['data'] is Map) {
        _wl = ((wl['data']['items'] as List?) ?? const []).map((e) => e.toString()).toList();
      }
      if (cpu['success'] == true && cpu['data'] is Map) {
        _cpuMsg = '${cpu['data']['cores']} 核 · ${cpu['data']['note'] ?? ''}';
      }
      final sec = Api.securitySettings();
      if (sec['success'] == true && sec['data'] is Map) {
        final d = sec['data'];
        _virusAction = d['virus_action']?.toString() ?? 'ask';
        _cleanInterval = (d['clean_interval_min'] as num?)?.toInt() ?? 60;
        _scanInterval = (d['scan_interval_min'] as num?)?.toInt() ?? 60;
        _idleOnly = d['idle_only'] == true;
        _pwdEnabled = d['pwd_enabled'] == true;
        _silentUpdate = d['silent_update'] != false;
      }
    });
  }

  Future<void> _setGlass(bool v) async {
    Ui.glass.value = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('ui_glass', v);
    if (Platform.isWindows) {
      try {
        await Window.setEffect(
          effect: currentMatStyle() == MatStyle.solid ? WindowEffect.solid : WindowEffect.mica,
        );
      } catch (_) {}
    }
  }

  Future<void> _saveBool(String key, bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(key, v);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageTitle(
            title: I18n.t('settings'),
            subtitle: I18n.lang == 'en' ? 'Appearance, performance, updates and security' : '界面材质、性能、更新与安全项',
          ),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(children: [
              _section('外观与动画'),
              _perfRow(),
              _materialRow(),
              for (final a in Ui.anims) _animRow(a),
              _langRow(),
              _section('悬浮监控'),
              _switchRow(Icons.picture_in_picture_alt_rounded, I18n.t('floatingWindow'), Ui.floating.value, (v) {
                setState(() => Ui.floating.value = v);
                _saveBool('ui_floating', v);
              }),
              _metricRow(),
              _switchRow(Icons.open_in_new_rounded, '桌面级悬浮窗（独立置顶窗口）', _desktopFloat, (v) async {
                setState(() => _desktopFloat = v);
                _saveBool('ui_desktop_float', v);
                if (v) {
                  final ok = await openDesktopMonitor();
                  if (!ok && context.mounted) {
                    _alert(context, '无法创建独立窗口', '当前环境不支持多窗口引擎，已退回应用内浮层。');
                  }
                } else {
                  await closeDesktopMonitor();
                }
              }),
              _section(I18n.t('graphicsMode')),
              _gpuInfoRow(),
              _choiceRow(['auto', 'discrete', 'integrated']),
              if (_renderMsg.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text(_renderMsg, style: const TextStyle(fontSize: 11, color: Color(0xFF2F7BFF))),
                ),
              _actionRow(Icons.bolt_rounded, I18n.t('cpuSchedule'), _cpuMsg, () async {
                final r = Api.cpuProfile();
                setState(() => _cpuMsg = r['success'] == true ? '${r['data']['cores']} 核 · ${r['data']['note']}' : '不可用');
              }),
              _section(I18n.t('scan')),
              _virusActionRow(),
              _actionRow(Icons.inventory_2_rounded, '隔离库', '病毒收在这里，可恢复可清除', () async {
                final r = Api.quarantineList();
                final items = r['success'] == true && r['data'] is Map
                    ? ((r['data']['items'] as List?) ?? const [])
                    : const [];
                if (!context.mounted) return;
                _alert(context, '隔离库',
                    items.isEmpty ? '还没关进去过东西。' : '共 ${items.length} 项。到左侧「隔离库」页可以看详情、恢复或清除。');
              }),
              _actionRow(Icons.playlist_add_check_rounded, I18n.t('whitelist'), '共 ${_wl.length} 项', () async {
                final r = Api.whitelist();
                if (r['success'] == true) {
                  setState(() => _wl = ((r['data']['items'] as List?) ?? const []).map((e) => e.toString()).toList());
                }
                if (context.mounted) _showList(context, I18n.t('whitelist'), _wl, (p) async {
                  Api.whitelistRemove(p);
                  final rr = Api.whitelist();
                  setState(() => _wl = ((rr['data']['items'] as List?) ?? const []).map((e) => e.toString()).toList());
                });
              }),
              _actionRow(Icons.usb_rounded, I18n.t('usbCheck'), _usbMsg, () async {
                final r = Api.usb();
                if (r['success'] == true) {
                  final d = r['data'];
                  final risky = d['risky_count'] ?? 0;
                  final drives = (d['drives'] as List?) ?? const [];
                  setState(() => _usbMsg = drives.isEmpty ? '未发现 U 盘' : '${drives.length} 个设备 · 风险 $risky');
                  if (context.mounted && risky > 0) {
                    _alert(context, 'U 盘风险', '检测到 autorun.inf，建议先扫描再打开。');
                  }
                }
              }),
              _section(I18n.t('tools')),
              // 运行库补全已经从设置页移走：工具页里本来就有一整张卡片
              // （带扫描 → 确认 → 后台补齐的完整流程）。设置页这里只留一条
              // 「点一下看缺什么」的残废版，同一功能两个入口，用户反而找不到。
              _actionRow(Icons.storage_rounded, I18n.t('installRec'), _installMsg, () async {
                final r = Api.recommendDir();
                setState(() => _installMsg = r['success'] == true ? '${r['data']['reason']}' : '${r['message']}');
              }),
              _section(I18n.t('update')),
              _repoRow(),
              _actionRow(Icons.system_update_rounded, I18n.t('update'), _updateMsg, _checkUpdate),
              _section('后台任务'),
              _actionRow(Icons.cleaning_services_rounded, '垃圾清理频率', _intervalText(_cleanInterval), () async {
                await _pickInterval('垃圾清理频率', _cleanInterval, 'clean_interval_min',
                    (v) => setState(() => _cleanInterval = v));
              }),
              _actionRow(Icons.shield_rounded, '病毒查杀频率', _intervalText(_scanInterval), () async {
                await _pickInterval('病毒查杀频率', _scanInterval, 'scan_interval_min',
                    (v) => setState(() => _scanInterval = v));
              }),
              _switchRow(Icons.hourglass_bottom_rounded, '只在系统空闲时运行', _idleOnly, (v) async {
                setState(() => _idleOnly = v);
                Api.securitySet('idle_only', v);
              }),
              _actionRow(Icons.play_circle_rounded, '立即执行一轮', '不等时间，马上扫一遍', () async {
                final r = Api.bgRunOnce();
                if (context.mounted) {
                  _alert(context, '执行完成',
                      r['success'] == true ? '释放 ${_size((r['data']['freed'] as num?) ?? 0)}，删除 ${r['data']['deleted'] ?? 0} 个文件，命中 ${r['data']['found'] ?? 0} 项' : '${r['message']}');
                }
              }),
              _section('安全'),
              _switchRow(Icons.system_update_alt_rounded, '发现新版本时静默安装', _silentUpdate, (v) async {
                if (!v) {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => QDialog(
                      icon: Icons.system_update_alt_rounded,
                      title: '关闭静默更新',
                      body: '关闭后将无法体验新功能，也不会自动修补漏洞。确定要关闭吗？',
                      okText: '确定关闭',
                      cancelText: '保持开启',
                    ),
                  );
                  if (ok != true) return;
                }
                setState(() => _silentUpdate = v);
                Api.securitySet('silent_update', v);
              }),
              _switchRow(Icons.lock_rounded, '密码保护', _pwdEnabled, (v) async {
                if (v) {
                  final pwd = await _askNewPassword();
                  if (pwd == null) return;
                  final r = Api.passwordSet(pwd);
                  if (r['success'] != true) {
                    if (context.mounted) _alert(context, '设置失败', '${r['message']}');
                    return;
                  }
                  setState(() => _pwdEnabled = true);
                } else {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => QDialog(
                      icon: Icons.lock_open_rounded,
                      title: '关闭密码保护',
                      body: '关掉之后，退出后台、关闭自启动、关闭软件都不再需要验证身份。确定吗？',
                      okText: '确定关闭',
                      cancelText: '取消',
                    ),
                  );
                  if (ok != true) return;
                  Api.passwordClear();
                  setState(() => _pwdEnabled = false);
                }
              }),
              _section(I18n.t('autostart')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(I18n.t('autostart')),
                subtitle: Text(
                  Platform.isWindows
                      ? '开机登录后自动拉起后台防护：在注册表 HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run 下登记 QWGuard。关闭后该项会被删除，开机不再自动防护。'
                      : '开机登录后自动拉起后台防护：在 ~/.config/autostart 写一个 QWGuard 启动项。',
                  style: const TextStyle(fontSize: 11),
                ),
                value: _autoStart,
                onChanged: (v) async {
                  if (!v) {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (_) => QDialog(
                        icon: Icons.power_off_rounded,
                        title: '不建议关闭自启动',
                        body: '关掉之后，开机不会自动进入防护状态，这段时间电脑是不设防的，安全性会下降。\n\n确定要关闭吗？',
                        okText: '仍然关闭',
                        cancelText: '保持开启',
                      ),
                    );
                    if (ok != true) return;
                    if (_pwdEnabled) {
                      final pass = await _askPasswordFor('关闭自启动');
                      if (!pass) return;
                    }
                  }
                  final r = Api.autostartSet('QWGuard', Platform.resolvedExecutable, v);
                  setState(() => _autoStart = v);
                  _saveBool('autostart', v);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['message']?.toString() ?? '')));
                  }
                },
              ),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  I18n.lang == 'en' ? 'Uninstall removes install dir and HKCU entries.' : '卸载时会清理安装目录与 HKCU 注册表项，避免残留。',
                  style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38),
                ),
              ),
              const SizedBox(height: 30),
            ]),
          ),
        ],
      ),
    );
  }

  String _intervalText(int m) {
    if (m <= 0) return '关闭';
    if (m < 1440) return '${m ~/ 60} 小时';
    return '${m ~/ 1440} 天';
  }

  /// 发现病毒时的处理方式：自动 / 询问 / 仅记录
  Widget _virusActionRow() {
    const opts = [
      ('auto', '自动处理', '查到直接进隔离库'),
      ('ask', '询问我', '弹窗让你决定（默认）'),
      ('record', '仅记录', '只记一笔，不动文件'),
    ];
    final cur = opts.firstWhere((o) => o.$1 == _virusAction, orElse: () => opts[1]);
    return _actionRow(Icons.notifications_active_rounded, '发现病毒时', cur.$2, () async {
      final r = await showDialog<String>(
        context: context,
        builder: (_) => SimpleDialog(
          title: const Text('发现病毒时'),
          children: [
            for (final o in opts)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(o.$1),
                child: Row(children: [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(o.$2, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(o.$3, style: const TextStyle(fontSize: 11)),
                  ]),
                  const Spacer(),
                  if (_virusAction == o.$1) const Icon(Icons.check_rounded, size: 18),
                ]),
              ),
          ],
        ),
      );
      if (r == null) return;
      setState(() => _virusAction = r);
      Api.securitySet('virus_action', r);
    });
  }

  /// 选频率：1/2/4/6/8/12 小时，1~5 天，关闭（关闭要二级确认）
  Future<void> _pickInterval(String title, int cur, String key, ValueChanged<int> done) async {
    const opts = [
      (60, '1 小时'), (120, '2 小时'), (240, '4 小时'), (360, '6 小时'),
      (480, '8 小时'), (720, '12 小时'),
      (1440, '1 天'), (2880, '2 天'), (4320, '3 天'), (5760, '4 天'), (7200, '5 天'),
      (-1, '自定义…'),
      (0, '关闭'),
    ];
    final r = await showDialog<int>(
      context: context,
      builder: (_) => SimpleDialog(
        title: Text(title),
        children: [
          for (final o in opts)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(o.$1),
              child: Row(children: [
                Text(o.$2),
                const Spacer(),
                if (cur == o.$1) const Icon(Icons.check_rounded, size: 18),
              ]),
            ),
        ],
      ),
    );
    if (r == null) return;
    if (r == -1) {
      // 自定义间隔：只让填分钟数，30 = 半小时、1440 = 1 天
      final ctrl = TextEditingController(text: cur > 0 ? '$cur' : '');
      final v = await showDialog<int>(
        context: context,
        builder: (ctx) => QDialog(
          icon: Icons.timer_rounded,
          title: '$title · 自定义',
          body: '填间隔分钟数。例：30 = 半小时一次，1440 = 一天一次，最小 5 分钟。',
          okText: '确定',
          cancelText: '取消',
          child: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: '例如 45'),
          ),
          onOk: () => Navigator.of(ctx).pop(int.tryParse(ctrl.text.trim())),
        ),
      );
      ctrl.dispose();
      if (v == null) return;
      if (v < 5) {
        if (mounted) _alert(context, '间隔太短', '最少 5 分钟，太频繁会一直占着磁盘。');
        return;
      }
      setState(() => done(v));
      Api.securitySet(key, v);
      return;
    }
    if (r == 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => QDialog(
          icon: Icons.hourglass_disabled_rounded,
          title: '确定要关闭吗？',
          body: '关闭之后就不会再自动清理和查杀，垃圾会慢慢攒起来，病毒也没人盯着，安全性会下降。',
          okText: '仍然关闭',
          cancelText: '保持开启',
        ),
      );
      if (ok != true) return;
      if (_pwdEnabled) {
        final pass = await _askPasswordFor('关闭后台任务');
        if (!pass) return;
      }
    }
    setState(() => done(r));
    Api.securitySet(key, r);
  }

  Future<String?> _askNewPassword() async {
    final a = TextEditingController();
    final b = TextEditingController();
    var err = '';
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => QDialog(
          icon: Icons.lock_rounded,
          title: '设置密码',
          body: err.isEmpty ? '设置之后，退出后台再打开、关闭自启动、关闭软件都要验证。' : err,
          okText: '保存',
          cancelText: '取消',
          child: Column(children: [
            TextField(
                controller: a,
                obscureText: true,
                decoration: const InputDecoration(hintText: '输入密码', isDense: true)),
            const SizedBox(height: 8),
            TextField(
                controller: b,
                obscureText: true,
                decoration: const InputDecoration(hintText: '再输一次', isDense: true)),
          ]),
          onOk: () {
            if (a.text.length < 4) {
              setS(() => err = '至少 4 位');
              return;
            }
            if (a.text != b.text) {
              setS(() => err = '两次输入不一致');
              return;
            }
            Navigator.of(ctx).pop(a.text);
          },
        ),
      ),
    );
    a.dispose();
    b.dispose();
    return res;
  }

  Future<bool> _askPasswordFor(String action) async {
    final ctrl = TextEditingController();
    var err = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => QDialog(
          icon: Icons.lock_rounded,
          title: '需要验证身份',
          body: '执行「$action」需要密码。${err.isEmpty ? '' : '\n$err'}',
          okText: '验证',
          cancelText: '取消',
          child: TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(hintText: '输入密码', isDense: true)),
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

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(t, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
      );

  static const _animIcons = {
    'glass': Icons.auto_awesome_rounded,
    'blur': Icons.blur_linear_rounded,
    'refraction': Icons.water_rounded,
    'raytrace': Icons.flare_rounded,
    'water': Icons.tsunami_rounded,
    'sweep': Icons.waves_rounded,
    'particles': Icons.blur_on_rounded,
    'blobs': Icons.circle_outlined,
    'dockSpring': Icons.animation_rounded,
    'pageTransition': Icons.swap_horiz_rounded,
    'buttonPress': Icons.touch_app_rounded,
    'cardEntrance': Icons.view_carousel_rounded,
  };

  /// 实时帧耗时：把帧总耗时摊开给用户看
  Widget _perfRow() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LiquidGlass(
        radius: 26,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.speed_rounded, size: 20),
            const SizedBox(width: 12),
            const Expanded(child: Text('实时帧耗时', style: TextStyle(fontSize: 14))),
            ValueListenableBuilder<double>(
              valueListenable: Ui.frameMs,
              builder: (_, ms, __) {
                final fps = ms <= 0 ? 0.0 : 1000 / ms;
                return Text(
                  ms <= 0 ? '—' : '${ms.toStringAsFixed(1)} ms · ${fps.toStringAsFixed(0)} FPS',
                  style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black54),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 设置页的材质入口：点开选五档
  Widget _materialRow() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = switch (Ui.material.value) {
      'mica' => 'Windows 11 云母',
      'aero' => 'Windows 7 Aero',
      'glass' => '液态玻璃',
      'solid' => '纯色',
      _ => '智能混搭',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LiquidGlass(
        radius: 26,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        onTap: _pickMaterial,
        child: Row(
          children: [
            const Icon(Icons.palette_rounded, size: 20),
            const SizedBox(width: 12),
            const Expanded(child: Text('界面材质', style: TextStyle(fontSize: 14))),
            Text(label,
                style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white70 : Colors.black54)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, size: 18),
          ],
        ),
      ),
    );
  }

  Future<void> _pickMaterial() async {
    final cur = Ui.material.value;
    const opts = <(String, String, String)>[
      ('auto', '智能混搭（默认）', '控件液态玻璃 + 窗口背景云母'),
      ('mica', 'Windows 11 云母', '整窗云母，中性冷调'),
      ('aero', 'Windows 7 Aero', '薄雾玻璃加顶部强高光'),
      ('glass', '液态玻璃', '边缘色散、流动折射、厚度高光'),
      ('solid', '纯色', '不透明实色，最省性能'),
    ];
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('界面材质', style: TextStyle(fontSize: 16)),
        contentPadding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in opts)
              ListTile(
                dense: true,
                leading: Icon(
                  o.$1 == cur ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  size: 18,
                  color: const Color(0xFF2F7BFF),
                ),
                title: Text(o.$2, style: const TextStyle(fontSize: 13)),
                subtitle: Text(o.$3, style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.of(ctx).pop(o.$1),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() => Ui.material.value = picked);
    final sp = await SharedPreferences.getInstance();
    await sp.setString('ui_material', picked);
  }

  Widget _animRow(AnimDef a) {
    final label = I18n.lang == 'en' ? a.en : a.zh;
    final icon = _animIcons[a.key] ?? Icons.animation_rounded;
    return _switchRow(icon, label, Ui.isOn(a.key), (v) async {
      setState(() => Ui.on(a.key).value = v);
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('anim_${a.key}', v);
      if (a.key == 'glass') {
        await sp.setBool('ui_glass', v);
        if (Platform.isWindows) {
          try {
            await Window.setEffect(
              effect: currentMatStyle() == MatStyle.solid ? WindowEffect.solid : WindowEffect.mica,
            );
          } catch (_) {}
        }
      }
    });
  }

  Widget _switchRow(IconData icon, String title, bool value, ValueChanged<bool> onChanged) {
    return LiquidGlass(
      radius: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: Icon(icon, size: 20),
        title: Text(title, style: const TextStyle(fontSize: 14)),
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  Widget _actionRow(IconData icon, String title, String subtitle, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LiquidGlass(
        radius: 26,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: onTap,
        child: Row(children: [
          Icon(icon, size: 20, color: const Color(0xFF2F7BFF)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              if (subtitle.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                ),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, size: 18),
        ]),
      ),
    );
  }

  Future<void> _applyGpu(String m) async {
    setState(() => _gpuMode = m);
    Api.setSetting('gpu_mode', m);
    final r = Api.applyGpuPreference(m);
    if (!mounted) return;
    setState(() {
      if (r['success'] == true && r['data'] is Map) {
        final d = (r['data'] as Map).cast<String, dynamic>();
        _renderMsg = '已指向 ${d['gpu']}（${d['kind'] == 'discrete' ? '独显' : '核显'}）· 重启生效';
      } else {
        _renderMsg = r['message']?.toString() ?? '设置失败';
      }
    });
  }

  Widget _gpuInfoRow() {
    if (_gpus.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text('未检测到显卡信息', style: TextStyle(fontSize: 11, color: Theme.of(context).brightness == Brightness.dark ? Colors.white38 : Colors.black38)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final g in _gpus)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF2F7BFF).withOpacity(0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '[${g['vendor']}] ${g['name']} · ${g['kind'] == 'discrete' ? '独显' : '核显'}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF2F7BFF)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _choiceRow(List<String> modes) {
    final labels = {
      'auto': I18n.t('auto'),
      'discrete': I18n.t('discrete'),
      'integrated': I18n.t('integrated'),
    };
    return LiquidGlass(
      radius: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(children: [
        const Icon(Icons.videogame_asset_rounded, size: 20, color: Color(0xFF2F7BFF)),
        const SizedBox(width: 12),
        for (final m in modes) ...[
          ChoiceChip(
            label: Text(labels[m]!),
            selected: _gpuMode == m,
            onSelected: (_) => _applyGpu(m),
          ),
          const SizedBox(width: 8),
        ],
      ]),
    );
  }


  Widget _metricRow() {
    const opts = {'cpu': 'CPU', 'mem': '内存', 'gpu': 'GPU', 'npu': 'NPU', 'temp': '温度'};
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LiquidGlass(
        radius: 26,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            const Icon(Icons.tune_rounded, size: 18, color: Color(0xFF2F7BFF)),
            for (final e in opts.entries)
              FilterChip(
                label: Text(e.value),
                selected: Ui.floatMetrics.value.contains(e.key),
                onSelected: (v) async {
                  final set = {...Ui.floatMetrics.value};
                  v ? set.add(e.key) : set.remove(e.key);
                  Ui.floatMetrics.value = set;
                  final sp = await SharedPreferences.getInstance();
                  await sp.setStringList('float_metrics', set.toList());
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _langRow() {
    return LiquidGlass(
      radius: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(children: [
        const Icon(Icons.translate_rounded, size: 20, color: Color(0xFF2F7BFF)),
        const SizedBox(width: 12),
        const Text('简体 / 繁體 / English', style: TextStyle(fontSize: 13)),
        const Spacer(),
        for (final l in ['zh', 'hant', 'en']) ...[
          ChoiceChip(
            label: Text({'zh': '简体中文', 'hant': '繁體中文', 'en': 'English'}[l]!),
            selected: I18n.lang == l,
            onSelected: (_) async {
              setState(() => I18n.lang = l);
              await AppSettings.saveLang(l);
            },
          ),
          const SizedBox(width: 6),
        ],
      ]),
    );
  }

  Widget _repoRow() {
    final ctrl = TextEditingController(text: _repo);
    return LiquidGlass(
      radius: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(children: [
        const Icon(Icons.link_rounded, size: 20, color: Color(0xFF2F7BFF)),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: ctrl,
            decoration: const InputDecoration(hintText: 'owner/repo', isDense: true),
            onChanged: (v) => _repo = v.trim(),
            onSubmitted: (v) async {
              final sp = await SharedPreferences.getInstance();
              await sp.setString('github_repo', v.trim());
            },
          ),
        ),
      ]),
    );
  }

  Future<void> _checkUpdate() async {
    if (_repo.isEmpty) {
      setState(() => _updateMsg = '请先填写 GitHub 仓库 owner/repo');
      return;
    }
    setState(() => _updateMsg = '检查中…');
    final r = Api.update(_repo, _current);
    if (!mounted) return;
    if (r['success'] == true) {
      final d = r['data'];
      setState(() => _updateMsg = d['has_update'] == true
          ? '${I18n.t('hasUpdate')}: ${d['latest']}'
          : I18n.t('noUpdate'));
    } else {
      setState(() => _updateMsg = r['message']?.toString() ?? '失败');
    }
  }

  void _showList(BuildContext context, String title, List<String> items, Future<void> Function(String) onRemove) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: items.isEmpty
              ? const Text('空')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final i in items)
                      ListTile(
                        dense: true,
                        title: Text(i, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () async {
                            await onRemove(i);
                            if (context.mounted) Navigator.pop(context);
                          },
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  void _alert(BuildContext context, String title, String msg) {
    showDialog(context: context, builder: (_) => AlertDialog(title: Text(title), content: Text(msg), actions: [
      TextButton(onPressed: () => Navigator.pop(_), child: const Text('OK')),
    ]));
  }
}


/// 卡片入场：关闭动画时直接显示
class _Entrance extends StatefulWidget {
  final int index;
  final Widget child;
  const _Entrance({required this.index, required this.child});

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Ui.isOn('cardEntrance') ? const Duration(milliseconds: 420) : Duration.zero,
  );

  @override
  void initState() {
    super.initState();
    if (!Ui.isOn('cardEntrance')) {
      _c.value = 1;
    } else {
      Future.delayed(Duration(milliseconds: 60 * widget.index), () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Ui.isOn('cardEntrance')) return widget.child;
    final curved = CurvedAnimation(parent: _c, curve: Ui.spring);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.12), end: Offset.zero).animate(curved),
        child: widget.child,
      ),
    );
  }
}
