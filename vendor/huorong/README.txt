火绒引擎组件（用户自行提供，仅本地整合）

必需文件（缺一不可，否则 HipsDaemon 起不来）：
  HipsMain.exe      主界面
  HipsDaemon.exe    扫描守护进程
  usysdiag.dll      反病毒核心引擎

HipsDaemon.exe 还依赖下面这些（当前未提供）：
  behavior.dll  HipsDB.dll  hrcomm.dll  jansson.dll
  驱动：hrelam.sys  hrdevmon.sys  hrfwdrv.sys  hrwfpdrv.sys
  以及病毒库 vir.db / 规则包

没有驱动和病毒库时，引擎加载会失败——这是火绒本身的架构决定的，
不是本程序的调用问题。
