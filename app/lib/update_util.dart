import 'dart:io';

/// 自动更新的版本/时间判断。
///
/// 规则：
/// - 版本号比当前高 → 更新
/// - 版本号相同，但 Release/安装包是重新发布的（时间晚于本地基线）→ 也更新
class UpdateUtil {
  static const currentVersion = '1.1';

  static String get _baseDir {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.trim().isNotEmpty) {
      return '$appData${Platform.pathSeparator}QWGuard';
    }
    return '${Directory.systemTemp.path}${Platform.pathSeparator}QWGuard';
  }

  static String get baselinePath =>
      '$_baseDir${Platform.pathSeparator}update_baseline.txt';

  static List<int> _nums(String v) {
    final s = v.trim().toLowerCase().replaceFirst(RegExp(r'^v'), '');
    final out = <int>[];
    for (final p in s.split('.')) {
      final m = RegExp(r'^\d+').firstMatch(p);
      out.add(m == null ? 0 : int.tryParse(m.group(0)!) ?? 0);
    }
    while (out.length > 1 && out.last == 0) {
      out.removeLast();
    }
    return out;
  }

  static bool sameVersion(String a, String b) {
    final x = _nums(a);
    final y = _nums(b);
    final n = x.length > y.length ? x.length : y.length;
    for (var i = 0; i < n; i++) {
      final xi = i < x.length ? x[i] : 0;
      final yi = i < y.length ? y[i] : 0;
      if (xi != yi) return false;
    }
    return true;
  }

  /// 本地基线：安装/上次升级时写入的时间；没有就退回主程序 exe 的修改时间。
  static Future<String> readBaseline() async {
    try {
      final f = File(baselinePath);
      if (await f.exists()) {
        final s = (await f.readAsString()).trim();
        if (s.isNotEmpty) return s;
      }
    } catch (_) {}
    try {
      final t = await File(Platform.resolvedExecutable).lastModified();
      return t.toUtc().toIso8601String();
    } catch (_) {
      return '';
    }
  }

  static Future<void> writeBaseline(String stamp) async {
    try {
      final f = File(baselinePath);
      await f.parent.create(recursive: true);
      await f.writeAsString(stamp.trim(), flush: true);
    } catch (_) {}
  }

  /// 安装器成功覆盖后调用：把这次包的发布时间记为本地基线。
  /// 没传发布时间（手动安装）就用当前时间，避免刚装完又把自己升级一遍。
  static Future<void> writeInstallBaseline(String? assetTime) async {
    final s = (assetTime ?? '').trim();
    await writeBaseline(
      s.isNotEmpty ? s : DateTime.now().toUtc().toIso8601String(),
    );
  }

  static DateTime? _parse(String s) {
    if (s.trim().isEmpty) return null;
    return DateTime.tryParse(s.trim())?.toUtc();
  }

  /// 是否需要升级。同版本重发靠时间比较，不再只看版本号。
  static Future<bool> shouldUpdate(Map<String, dynamic> d) async {
    if (d['has_update'] == true) return true;

    final latest = d['latest']?.toString() ?? '';
    if (!sameVersion(latest, currentVersion)) return false;

    // Release 的 published_at 与资产 updated_at 取较晚的一个：
    // 有些重发只换安装包，有些是整个 Release 重建。
    DateTime? newest;
    for (final key in ['download_updated_at', 'published_at']) {
      final t = _parse(d[key]?.toString() ?? '');
      if (t != null && (newest == null || t.isAfter(newest))) newest = t;
    }
    if (newest == null) return false;

    final base = _parse(await readBaseline());
    if (base == null) return false;
    // 留 60 秒余量，避免安装器写盘时间和发布时间只差几秒导致来回升级。
    return newest.isAfter(base.add(const Duration(seconds: 60)));
  }
}
