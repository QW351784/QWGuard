/// 语言包：简体中文（默认）/ 繁體中文 / English
class I18n {
  static String lang = 'zh';

  static const Map<String, String> _zh = {
    'app': 'QW 电脑安全管家',
    'hw': '硬件检测',
    'clean': '系统清理',
    'scan': '病毒查杀',
    'tools': '工具合集',
    'settings': '设置',
    'welcome': '欢迎使用 QW 电脑安全管家',
    'pickTheme': '请选择界面主题',
    'light': '浅色模式',
    'dark': '深色模式',
    'system': '跟随系统',
    'confirm': '确认并进入',
    'language': '语言',
    'refresh': '刷新',
    'cpu': '处理器',
    'mem': '内存',
    'disk': '磁盘',
    'gpu': '显卡',
    'temp': '温度',
    'load': '负载',
    'scanNow': '开始扫描',
    'preview': '预演（不删除）',
    'doClean': '确认清理',
    'builtin': '内置引擎',
    'external': '外部工具',
    'path': '扫描路径',
    'total': '可清理',
    'empty': '暂无数据',
    'wip': '开发中',
    'glass': '液态玻璃',
    'particles': '粒子特效',
    'blur': '实时模糊',
    'floatingWindow': '悬浮窗监控',
    'autostart': '开机自启动',
    'update': '检查更新',
    'whitelist': '白名单',
    'add': '添加',
    'remove': '移除',
    'runtimeFix': '运行库补全',
    'installRec': '推荐安装位置',
    'usbCheck': 'U 盘安全检测',
    'cpuSchedule': 'CPU 调度',
    'threads': '多线程',
    'recommendedGpu': '推荐显卡',
    'graphicsMode': '显卡模式',
    'auto': '自动',
    'discrete': '独显',
    'integrated': '核显',
    'checkUpdate': '立即检查',
    'noUpdate': '已是最新版本',
    'hasUpdate': '发现新版本',
  };

  static const Map<String, String> _en = {
    'app': 'QW PC Security Suite',
    'hw': 'Hardware',
    'clean': 'Cleanup',
    'scan': 'Antivirus',
    'tools': 'Tools',
    'settings': 'Settings',
    'welcome': 'Welcome to QW PC Security Suite',
    'pickTheme': 'Choose a theme',
    'light': 'Light',
    'dark': 'Dark',
    'system': 'Follow system',
    'confirm': 'Continue',
    'language': 'Language',
    'refresh': 'Refresh',
    'cpu': 'CPU',
    'mem': 'Memory',
    'disk': 'Disk',
    'gpu': 'GPU',
    'temp': 'Temp',
    'load': 'Load',
    'scanNow': 'Scan now',
    'preview': 'Preview (dry run)',
    'doClean': 'Clean selected',
    'builtin': 'Built-in engines',
    'external': 'External tools',
    'path': 'Target path',
    'total': 'Reclaimable',
    'empty': 'Nothing to show',
    'wip': 'Coming soon',
    'glass': 'Liquid glass',
    'particles': 'Particles',
    'blur': 'Live blur',
    'floatingWindow': 'Floating monitor',
    'autostart': 'Run at startup',
    'update': 'Check updates',
    'whitelist': 'Whitelist',
    'add': 'Add',
    'remove': 'Remove',
    'runtimeFix': 'Runtime check',
    'installRec': 'Recommended install path',
    'usbCheck': 'USB safety check',
    'cpuSchedule': 'CPU scheduling',
    'threads': 'Threads',
    'recommendedGpu': 'Recommended GPU',
    'graphicsMode': 'Graphics mode',
    'auto': 'Auto',
    'discrete': 'Discrete',
    'integrated': 'Integrated',
    'checkUpdate': 'Check now',
    'noUpdate': 'Already up to date',
    'hasUpdate': 'New version found',
  };

  /// 常用字简体 → 繁體
  static const Map<String, String> _hantChar = {
    '电': '電', '脑': '腦', '设': '設', '统': '統', '应': '應', '检': '檢', '测': '測',
    '杀': '殺', '语': '語', '浅': '淺', '随': '隨', '确': '確', '认': '認', '进': '進',
    '处': '處', '内': '內', '盘': '盤', '温': '溫', '负': '負', '载': '載', '开': '開',
    '扫': '掃', '预': '預', '删': '刪', '径': '徑', '暂': '暫', '无': '無', '项': '項',
    '发': '發', '欢': '歡', '请': '請', '选': '選', '题': '題', '显': '顯', '驱': '驅',
    '动': '動', '启': '啟', '单': '單', '运': '運', '库': '庫', '补': '補', '残': '殘',
    '悬': '懸', '计': '計', '划': '劃', '调': '調', '线': '線', '级': '級', '独': '獨',
    '优': '優',
  };

  static String _toHant(String s) {
    final buf = StringBuffer();
    for (final ch in s.split('')) {
      buf.write(_hantChar[ch] ?? ch);
    }
    return buf.toString();
  }

  static String t(String key) {
    final zh = _zh[key] ?? key;
    switch (lang) {
      case 'en':
        return _en[key] ?? zh;
      case 'hant':
        return _toHant(zh);
      default:
        return zh;
    }
  }
}
