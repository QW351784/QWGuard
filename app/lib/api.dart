import 'dart:convert';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';

import 'bridge.dart';

/// 扩展能力：显卡 / 设置 / 自启动 / U盘 / 安装目录 / 运行库 / 更新 / 白名单 / 多线程
class Api {
  static Map<String, dynamic> _buf(String fn, {int cap = 16384}) {
    final lib = Native.lib;
    if (lib == null) {
      return {'success': false, 'message': Native.loadError ?? 'native library missing'};
    }
    try {
      final f = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Size), int Function(ffi.Pointer<ffi.Uint8>, int)>(fn);
      final buf = calloc<ffi.Uint8>(cap);
      try {
        final ret = f(buf, cap);
        final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
        if (text.trim().isEmpty) return {'success': false, 'code': ret};
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        calloc.free(buf);
      }
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  static Map<String, dynamic> _str(String fn, List<String> args, {int cap = 16384}) {
    final lib = Native.lib;
    if (lib == null) {
      return {'success': false, 'message': Native.loadError ?? 'native library missing'};
    }
    try {
      final f = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, ffi.Size), int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, int)>(fn);
      final a = args[0].toNativeUtf8();
      final b = args.length > 1 ? args[1].toNativeUtf8() : calloc<ffi.Char>(1);
      final buf = calloc<ffi.Uint8>(cap);
      try {
        final ret = f(a.cast(), b.cast(), buf, cap);
        final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
        if (text.trim().isEmpty) return {'success': false, 'code': ret};
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        calloc.free(a);
        calloc.free(b);
        calloc.free(buf);
      }
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  /// 单字符串参数 + 缓冲区
  static Map<String, dynamic> _one(String fn, String arg, {int cap = 4096}) {
    final lib = Native.lib;
    if (lib == null) return {'success': false};
    try {
      final f = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, ffi.Size), int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, int)>(fn);
      final a = arg.toNativeUtf8();
      final buf = calloc<ffi.Uint8>(cap);
      try {
        final ret = f(a.cast(), buf, cap);
        final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
        if (text.trim().isEmpty) return {'success': false, 'code': ret};
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        calloc.free(a);
        calloc.free(p);
        calloc.free(buf);
      }
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  static Map<String, dynamic> setTopmost(String title) => _one('set_topmost', title);
  static Map<String, dynamic> scanAuto(String target) => _one('scan_auto', target, cap: 16384);
  /// 四种扫描模式：quick / full / usb / custom
  static Map<String, dynamic> scanByMode(String mode, String path) =>
      _str('scan_by_mode', [mode, path], cap: 65536);
  static void scanCancel() => _str('scan_cancel', ['']);
  static Map<String, dynamic> cleanupScanMode(String mode, String path) =>
      Native.cleanupScanMode(mode, path);
  static Map<String, dynamic> cleanupProgress() => Native.cleanupProgress();
  static Map<String, dynamic> applyGpuPreference(String mode) => _one('apply_gpu_preference', mode);
  static Map<String, dynamic> scanHuorong(String target) => _one('scan_huorong', target, cap: 16384);
  static Map<String, dynamic> scanPyas(String target) => _one('scan_pyas', target, cap: 16384);

  // ===== 规则库（病毒库） =====
  static Map<String, dynamic> rulesStatus() => Native.rulesStatus();
  static Map<String, dynamic> rulesImport(String path) => Native.rulesImport(path);

  static Map<String, dynamic> gpu() => _buf('detect_gpu');
  static Map<String, dynamic> gpuPreference() => _buf('get_gpu_preference');

  static Map<String, dynamic> settings() => _buf('get_settings');
  static Map<String, dynamic> setSetting(String key, Object value) =>
      _str('set_setting', [key, value is String ? value : jsonEncode(value)]);

  static Map<String, dynamic> autostartList() => _buf('autostart_list');
  static Map<String, dynamic> autostartSet(String name, String exe, bool on) {
    final lib = Native.lib;
    if (lib == null) return {'success': false};
    try {
      final f = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Size), int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, int, ffi.Pointer<ffi.Uint8>, int)>(
          'autostart_set');
      final n = name.toNativeUtf8();
      final e = exe.toNativeUtf8();
      final buf = calloc<ffi.Uint8>(4096);
      try {
        final ret = f(n.cast(), e.cast(), on ? 1 : 0, buf, 4096);
        final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
        if (text.trim().isEmpty) return {'success': false, 'code': ret};
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        calloc.free(n);
        calloc.free(e);
        calloc.free(buf);
      }
    } catch (err) {
      return {'success': false, 'message': err.toString()};
    }
  }

  static Map<String, dynamic> usb() => _buf('usb_check');
  static Map<String, dynamic> recommendDir() => _buf('recommend_install_dir');
  static Map<String, dynamic> runtime() => _buf('runtime_check');
  static Map<String, dynamic> cpuProfile() => _buf('cpu_profile');
  static Map<String, dynamic> scanDirFast(String dir) => _str('scan_dir_fast', [dir]);
  static Map<String, dynamic> update(String repo, String current) => _str('check_update', [repo, current]);

  static Map<String, dynamic> whitelist() => _buf('whitelist_list');
  static Map<String, dynamic> whitelistAdd(String p) => _str('whitelist_add', [p]);
  static Map<String, dynamic> whitelistRemove(String p) => _str('whitelist_remove', [p]);

  // ============ 隔离库 ============
  static Map<String, dynamic> quarantineList() => _buf('quarantine_list', cap: 65536);

  /// 三字符串参数（路径 / 引擎 / 原因）
  static Map<String, dynamic> _three(String fn, List<String> args, {int cap = 4096}) {
    final lib = Native.lib;
    if (lib == null) {
      return {'success': false, 'message': Native.loadError ?? 'native library missing'};
    }
    try {
      final f = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Uint8>, ffi.Size), int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Uint8>, int)>(fn);
      final a = args[0].toNativeUtf8();
      final b = args[1].toNativeUtf8();
      final c = args[2].toNativeUtf8();
      final buf = calloc<ffi.Uint8>(cap);
      try {
        final ret = f(a.cast(), b.cast(), c.cast(), buf, cap);
        final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
        if (text.trim().isEmpty) return {'success': false, 'code': ret};
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        calloc.free(a);
        calloc.free(b);
        calloc.free(c);
        calloc.free(buf);
      }
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  static Map<String, dynamic> quarantineAdd(String path, String engine, String reason) =>
      _three('quarantine_add', [path, engine, reason]);
  static Map<String, dynamic> quarantineRestore(String id) => _one('quarantine_restore', id);
  static Map<String, dynamic> quarantineDelete(String id) => _one('quarantine_delete', id);
  static Map<String, dynamic> quarantineClear() => _buf('quarantine_clear');

  // ============ 密码 / 安全设置 ============
  static Map<String, dynamic> passwordSet(String pwd) => _one('password_set', pwd);
  static Map<String, dynamic> passwordVerify(String pwd) => _one('password_verify', pwd);
  static Map<String, dynamic> passwordClear() => _buf('password_clear');
  static Map<String, dynamic> passwordState() => _buf('password_state');

  static Map<String, dynamic> securitySettings() => _buf('security_settings');
  static Map<String, dynamic> securitySet(String key, Object v) =>
      _str('security_set', [key, v is String ? v : jsonEncode(v)]);

  // ============ 后台任务 ============
  static Map<String, dynamic> idleState() => _buf('idle_state');
  static Map<String, dynamic> bgStart() => _buf('bg_start');
  static Map<String, dynamic> bgStop() => _buf('bg_stop');
  static Map<String, dynamic> bgStatus() => _buf('bg_status');
  static Map<String, dynamic> bgRunOnce() => _buf('bg_run_once');

  // ============ 运行库补全 ============
  /// 扫 DLL 看缺哪些运行库
  static Map<String, dynamic> runtimeScan() => _buf('runtime_scan', cap: 8192);

  /// 看两个内置修复工具在不在、哈希对不对
  static Map<String, dynamic> runtimeTools() => _buf('runtime_tools', cap: 8192);

  /// 开始修：mode = vc / dx / all
  static Map<String, dynamic> runtimeFix(String mode) => _one('runtime_fix', mode, cap: 4096);

  /// 轮询进度
  static Map<String, dynamic> runtimeStatus() => _buf('runtime_status', cap: 8192);

  // ============ 小工具 ============
  static Map<String, dynamic> shortcutArrow(bool on) => _one('shortcut_arrow', on ? '1' : '0');
  static Map<String, dynamic> fileExtShow(bool show) => _one('file_ext_show', show ? '1' : '0');
  static Map<String, dynamic> shredderRun(List<String> paths, {int passes = 3, bool dryRun = false}) {
    final lib = Native.lib;
    if (lib == null) return {'success': false};
    try {
      final f = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Int32, ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Size), int Function(ffi.Pointer<ffi.Char>, int, int, ffi.Pointer<ffi.Uint8>, int)>(
          'shredder_run');
      final a = jsonEncode(paths).toNativeUtf8();
      final buf = calloc<ffi.Uint8>(8192);
      try {
        final ret = f(a.cast(), passes, dryRun ? 1 : 0, buf, 8192);
        final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
        if (text.trim().isEmpty) return {'success': false, 'code': ret};
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        calloc.free(a);
        calloc.free(buf);
      }
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  static Map<String, dynamic> envCheck() => _buf('env_check');
  static Map<String, dynamic> osVersion() => _buf('os_version');
  static Map<String, dynamic> isInstalled() => _buf('is_installed');

  // ============ 安装 / 卸载 ============
  static Map<String, dynamic> systemTheme() => _buf('system_theme');
  static Map<String, dynamic> installPrecheck(String src) => _one('install_precheck', src);

  static Map<String, dynamic> installRun(String src, String dst,
      {bool desktopIcon = true, bool autostart = false}) {
    final lib = Native.lib;
    if (lib == null) return {'success': false};
    try {
      final f = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Int32, ffi.Int32,
              ffi.Pointer<ffi.Uint8>, ffi.Size), int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, int, int,
              ffi.Pointer<ffi.Uint8>, int)>('install_run');
      final a = src.toNativeUtf8();
      final b = dst.toNativeUtf8();
      final buf = calloc<ffi.Uint8>(8192);
      try {
        final ret = f(a.cast(), b.cast(), desktopIcon ? 1 : 0, autostart ? 1 : 0, buf, 8192);
        final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
        if (text.trim().isEmpty) return {'success': false, 'code': ret};
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        calloc.free(a);
        calloc.free(b);
        calloc.free(buf);
      }
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  static Map<String, dynamic> uninstallRun(String appDir, {bool keepConfig = false, String pwd = ''}) {
    final lib = Native.lib;
    if (lib == null) return {'success': false};
    try {
      final f = lib.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Int32, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, ffi.Size),
          int Function(ffi.Pointer<ffi.Char>, int, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint8>, int)>('uninstall_run');
      final a = appDir.toNativeUtf8();
      final p = pwd.toNativeUtf8();
      final buf = calloc<ffi.Uint8>(8192);
      try {
        final ret = f(a.cast(), keepConfig ? 1 : 0, p.cast(), buf, 8192);
        final text = buf.cast<ffi.Char>().cast<Utf8>().toDartString();
        if (text.trim().isEmpty) return {'success': false, 'code': ret};
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        calloc.free(a);
        calloc.free(buf);
      }
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }
}
