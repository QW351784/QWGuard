import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

typedef _IntFn = ffi.Int32 Function();
typedef _BufFn = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _StrBufFn = ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _DartIntFn = int Function();
typedef _DartBufFn = int Function(ffi.Pointer<ffi.Uint8>, int);
typedef _DartStrBufFn = int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, int);

/// Rust 底层桥
class Native {
  static ffi.DynamicLibrary? _lib;
  static String? loadError;

  static ffi.DynamicLibrary? get lib {
    if (_lib != null) return _lib;
    try {
      if (Platform.isWindows) {
        _lib = ffi.DynamicLibrary.open('toolkit_native.dll');
      } else if (Platform.isLinux) {
        _lib = ffi.DynamicLibrary.open('libtoolkit_native.so');
      } else if (Platform.isMacOS) {
        _lib = ffi.DynamicLibrary.open('libtoolkit_native.dylib');
      }
    } catch (e) {
      loadError = e.toString();
    }
    return _lib;
  }

  static Map<String, dynamic>? _callBuf(String fn, {int cap = 16384}) {
    final l = lib;
    if (l == null) return {'success': false, 'message': loadError ?? 'native library missing'};
    final f = l.lookupFunction<_BufFn, _DartBufFn>(fn);
    final buf = ffi.calloc<ffi.Uint8>(cap);
    try {
      final ret = f(buf, cap);
      final raw = ffi.cast<ffi.Pointer<ffi.Char>, buf>;
      if (ret < 0 && ret != -1) {
        final text = raw.cast<ffi.Utf8>().toDartString();
        if (text.trim().isNotEmpty) return jsonDecode(text) as Map<String, dynamic>;
      }
      final text = raw.cast<ffi.Utf8>().toDartString();
      if (text.trim().isEmpty) {
        return {'success': false, 'code': ret, 'message': 'empty response'};
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    } finally {
      ffi.calloc.free(buf);
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

  static Map<String, dynamic> hardware() => _callBuf('get_hardware_info');

  static Map<String, dynamic> scanCleanup() => _callBuf('scan_cleanup');

  static Map<String, dynamic> executeCleanup(List<String> paths, {bool dryRun = true}) {
    final l = lib;
    if (l == null) return {'success': false, 'message': loadError ?? 'native library missing'};
    final f = l.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, ffi.Size), int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, int)>('execute_cleanup');
    final cstr = jsonEncode({'paths': paths, 'dry_run': dryRun}).toNativeUtf8();
    final buf = ffi.calloc<ffi.Uint8>(8192);
    try {
      final ret = f(cstr.cast(), buf, 8192);
      final text = ffi.cast<ffi.Pointer<ffi.Char>, buf>().cast<ffi.Utf8>().toDartString();
      if (text.trim().isEmpty) return {'success': false, 'code': ret};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      ffi.calloc.free(cstr);
      ffi.calloc.free(buf);
    }
  }

  static Map<String, dynamic> scanFile(String engine, String target) {
    final l = lib;
    if (l == null) return {'success': false, 'message': loadError ?? 'native library missing'};
    final f = l.lookupFunction<_StrBufFn, _DartStrBufFn>('scan_file');
    final e = engine.toNativeUtf8();
    final t = target.toNativeUtf8();
    final buf = ffi.calloc<ffi.Uint8>(16384);
    try {
      final ret = f(e.cast(), t.cast(), buf, 16384);
      final text = ffi.cast<ffi.Pointer<ffi.Char>, buf>().cast<ffi.Utf8>().toDartString();
      if (text.trim().isEmpty) return {'success': false, 'code': ret};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      ffi.calloc.free(e);
      ffi.calloc.free(t);
      ffi.calloc.free(buf);
    }
  }

  static Map<String, dynamic> launch(String name) {
    final l = lib;
    if (l == null) return {'success': false, 'message': loadError ?? 'native library missing'};
    final f = l.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, ffi.Size), int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, int)>('launch_external');
    final n = name.toNativeUtf8();
    final buf = ffi.calloc<ffi.Uint8>(4096);
    try {
      final ret = f(n.cast(), buf, 4096);
      final text = ffi.cast<ffi.Pointer<ffi.Char>, buf>().cast<ffi.Utf8>().toDartString();
      if (text.trim().isEmpty) return {'success': false, 'code': ret};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      ffi.calloc.free(n);
      ffi.calloc.free(buf);
    }
  }
}

enum ThemeOption { light, dark, system }

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
