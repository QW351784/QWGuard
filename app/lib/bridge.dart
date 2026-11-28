import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

typedef _IntFn = ffi.Int32 Function();
typedef _BufFn = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _StrBufFn = ffi.Int32 Function(
    ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _DartIntFn = int Function();
typedef _DartBufFn = int Function(ffi.Pointer<ffi.Uint8>, int);
typedef _DartStrBufFn = int Function(
    ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, int);

/// Rust 底层桥
class Native {
  static ffi.DynamicLibrary? _lib;
  static String? loadError;

  static ffi.DynamicLibrary? get lib {
    if (_lib != null) return _lib;
    try {
      // 用 exe 同目录的绝对路径加载：引擎扫描跑在后台 isolate 里，
      // 相对名在 isolate 中可能解析不到，绝对路径最稳
      final dir = File(Platform.resolvedExecutable).parent.path;
      if (Platform.isWindows) {
        final abs = File('$dir/toolkit_native.dll');
        _lib = ffi.DynamicLibrary.open(
            abs.existsSync() ? abs.path : 'toolkit_native.dll');
      } else if (Platform.isLinux) {
        final abs = File('$dir/libtoolkit_native.so');
        _lib = ffi.DynamicLibrary.open(
            abs.existsSync() ? abs.path : 'libtoolkit_native.so');
      } else if (Platform.isMacOS) {
        final abs = File('$dir/libtoolkit_native.dylib');
        _lib = ffi.DynamicLibrary.open(
            abs.existsSync() ? abs.path : 'libtoolkit_native.dylib');
      }
    } catch (e) {
      loadError = e.toString();
    }
    return _lib;
  }

  static Map<String, dynamic>? _callBuf(String fn, {int cap = 16384}) {
    final l = lib;
    if (l == null)
      return {
        'success': false,
        'message': loadError ?? 'native library missing'
      };
    final f = l.lookupFunction<_BufFn, _DartBufFn>(fn);
    final buf = calloc<ffi.Uint8>(cap);
    try {
      final ret = f(buf, cap);
      final raw = buf.cast<ffi.Char>();
      if (ret < 0 && ret != -1) {
        final text = raw.cast<Utf8>().toDartString();
        if (text.trim().isNotEmpty)
          return jsonDecode(text) as Map<String, dynamic>;
      }
      final text = raw.cast<Utf8>().toDartString();
      if (text.trim().isEmpty) {
        return {'success': false, 'code': ret, 'message': 'empty response'};
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    } finally {
      calloc.free(buf);
    }
  }

  static bool ping() {
    final l = lib;
    if (l == null) return false;
    try {
      return l.lookupFunction<_IntFn, _DartIntFn>('ping')() == 20261119;
    } catch (_) {
      return false;
    }
  }

  /// 当前进程是否管理员。主程序启动时先问它；不是就 UAC 重开。
  static bool isElevatedNow() {
    final l = lib;
    if (l == null) return false;
    try {
      return l.lookupFunction<_IntFn, _DartIntFn>('is_elevated_now')() == 1;
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic> hardware() =>
      _callBuf('get_hardware_info', cap: 65536) ?? <String, dynamic>{};

  /// 监控窗口专用轻量硬件指标：静态信息 Rust 进程内缓存，不枚举磁盘；温度按 5 秒缓存。
  static Map<String, dynamic> hardwareMetrics() =>
      _callBuf('get_hardware_metrics', cap: 65536) ?? <String, dynamic>{};
  static Future<Map<String, dynamic>> hardwareMetricsAsync() =>
      Isolate.run(() => hardwareMetrics());

  /// 硬件信息（后台版）
  /// get_hardware_info 内部要起 PowerShell 跑 Get-CimInstance，实测量级是秒。
  /// 直接在 UI isolate 上同步调用，窗口会先白屏再「未响应」——用户看到的就是
  /// 「一打开就没响应 + 硬件检测空白」。放 isolate 里跑，UI 线程全程不受阻。
  static Future<Map<String, dynamic>> hardwareAsync() => Isolate.run(
      () => _callBuf('get_hardware_info', cap: 65536) ?? <String, dynamic>{});

  /// 规则库状态：哈希条数 / 文件名条数 / 内置 YARA 是否就绪
  static Map<String, dynamic> rulesStatus() =>
      _callBuf('rules_status', cap: 8192) ?? <String, dynamic>{};

  /// 查杀实时进度（前端 200ms 轮一次）
  static Map<String, dynamic> scanProgress() =>
      _callBuf('scan_progress', cap: 4096) ?? <String, dynamic>{};

  /// 从本地 txt 导入 SHA-256 黑名单
  static Map<String, dynamic> rulesImport(String path) =>
      _str1('rules_import', path);

  static Map<String, dynamic> _str1(String fn, String arg) {
    final l = lib;
    if (l == null)
      return {
        'success': false,
        'message': loadError ?? 'native library missing'
      };
    final f = l.lookupFunction<_StrBufFn, _DartStrBufFn>(fn);
    final a = arg.toNativeUtf8();
    final buf = calloc<ffi.Uint8>(8192);
    try {
      final ret = f(a.cast(), buf, 8192);
      final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
      if (text.trim().isEmpty) return {'success': false, 'code': ret};
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    } finally {
      calloc.free(a);
      calloc.free(buf);
    }
  }

  static Map<String, dynamic> scanCleanup() =>
      _callBuf('scan_cleanup') ?? <String, dynamic>{};

  static Map<String, dynamic> executeCleanup(List<String> paths,
      {bool dryRun = true}) {
    final l = lib;
    if (l == null)
      return {
        'success': false,
        'message': loadError ?? 'native library missing'
      };
    final f = l.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, ffi.Size),
        int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>,
            int)>('execute_cleanup');
    final cstr = jsonEncode({'paths': paths, 'dry_run': dryRun}).toNativeUtf8();
    final buf = calloc<ffi.Uint8>(8192);
    try {
      final ret = f(cstr.cast(), buf, 8192);
      final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
      if (text.trim().isEmpty) return {'success': false, 'code': ret};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      calloc.free(cstr);
      calloc.free(buf);
    }
  }

  /// 清理范围扫描：quick / full / custom
  static Map<String, dynamic> cleanupScanMode(String mode, String path) {
    final l = lib;
    if (l == null)
      return {
        'success': false,
        'message': loadError ?? 'native library missing'
      };
    final f = l.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Uint8>, ffi.Size),
        int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Uint8>, int)>('cleanup_scan_mode');
    final a = mode.toNativeUtf8();
    final b = path.toNativeUtf8();
    final buf = calloc<ffi.Uint8>(16384);
    try {
      final ret = f(a.cast(), b.cast(), buf, 16384);
      final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
      if (text.trim().isEmpty) return {'success': false, 'code': ret};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      calloc.free(a);
      calloc.free(b);
      calloc.free(buf);
    }
  }

  /// 清理扫描实时进度
  static Map<String, dynamic> cleanupProgress() =>
      _callBuf('cleanup_progress', cap: 4096) ?? <String, dynamic>{};

  static Map<String, dynamic> scanFile(String engine, String target) {
    final l = lib;
    if (l == null)
      return {
        'success': false,
        'message': loadError ?? 'native library missing'
      };
    final f = l.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Uint8>, ffi.Size),
        int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Uint8>, int)>('scan_file');
    final e = engine.toNativeUtf8();
    final t = target.toNativeUtf8();
    final buf = calloc<ffi.Uint8>(16384);
    try {
      final ret = f(e.cast(), t.cast(), buf, 16384);
      final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
      if (text.trim().isEmpty) return {'success': false, 'code': ret};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      calloc.free(e);
      calloc.free(t);
      calloc.free(buf);
    }
  }

  /// 火绒 hrscan：把目标路径直接交给火绒扫（非阻塞，火绒是 GUI 进程）
  static Map<String, dynamic> scanHuorong(String target) {
    final l = lib;
    if (l == null)
      return {
        'success': false,
        'message': loadError ?? 'native library missing'
      };
    final f = l.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, ffi.Size),
        int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>,
            int)>('scan_huorong');
    final t = target.toNativeUtf8();
    final buf = calloc<ffi.Uint8>(16384);
    try {
      final ret = f(t.cast(), buf, 16384);
      final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
      if (text.trim().isEmpty) return {'success': false, 'code': ret};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      calloc.free(t);
      calloc.free(buf);
    }
  }

  /// PYAS 扫描（带日志回传）
  static Map<String, dynamic> scanPyas(String target) {
    final l = lib;
    if (l == null)
      return {
        'success': false,
        'message': loadError ?? 'native library missing'
      };
    final f = l.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, ffi.Size),
        int Function(
            ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, int)>('scan_pyas');
    final t = target.toNativeUtf8();
    final buf = calloc<ffi.Uint8>(16384);
    try {
      final ret = f(t.cast(), buf, 16384);
      final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
      if (text.trim().isEmpty) return {'success': false, 'code': ret};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      calloc.free(t);
      calloc.free(buf);
    }
  }

  static Map<String, dynamic> launch(String name) {
    final l = lib;
    if (l == null)
      return {
        'success': false,
        'message': loadError ?? 'native library missing'
      };
    final f = l.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, ffi.Size),
        int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>,
            int)>('launch_external');
    final n = name.toNativeUtf8();
    final buf = calloc<ffi.Uint8>(4096);
    try {
      final ret = f(n.cast(), buf, 4096);
      final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
      if (text.trim().isEmpty) return {'success': false, 'code': ret};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      calloc.free(n);
      calloc.free(buf);
    }
  }
}

enum ThemeOption { light, dark, system, smart }

/// 本地设置（首启引导、主题、语言）
class AppSettings {
  static const _kTheme = 'theme_option';
  static const _kFirst = 'first_run_done';
  static const _kLang = 'lang';

  static Future<ThemeOption> theme() async {
    final sp = await SharedPreferences.getInstance();
    switch (sp.getString(_kTheme)) {
      case 'light':
        return ThemeOption.light;
      case 'dark':
        return ThemeOption.dark;
      case 'smart':
        return ThemeOption.smart;
      default:
        return ThemeOption.system;
    }
  }

  static Future<void> saveTheme(ThemeOption v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kTheme, v.name);
  }

  static Future<bool> firstRun() async {
    final sp = await SharedPreferences.getInstance();
    return !(sp.getBool(_kFirst) ?? false);
  }

  static Future<void> markFirstRunDone() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kFirst, true);
  }

  static Future<String> lang() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kLang) ?? 'zh';
  }

  static Future<void> saveLang(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kLang, v);
  }
}
