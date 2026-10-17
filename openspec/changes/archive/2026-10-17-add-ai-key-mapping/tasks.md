## 实施与验证

- [x] 新增 `keyinject.c`：CGEvent/SendInput 注入、CGEventTap/GetAsyncKeyState 捕获与权限预检。
- [x] 注入修饰键补聚合 flags 并归零来源进程，绕过输入法对合成事件的过滤。
- [x] MicSession 新增 triggerID 边沿计数，常开模式开放 AI 键边沿。
- [x] 新增 KeyNames 键码名称表与跨平台单元测试。
- [x] Settings.aiKeyMap 向后兼容解码，configure 重绑声卡保留映射。
- [x] keymap 子命令：交互捕获、none 清除、test 试注入。
- [x] run 集成注入与五路粘键保护（松开、打字停麦、会话重建、退出、预检失败）。
- [x] 登录启动脚本转发 keymap，README 与帮助文本更新。
- [x] macOS 实机验收：捕获 fn、注入唤起微信输入法语音浮层、按 AI 键端到端确认。
- [x] Windows 分支代码就绪，待 Windows 实机构建验证。
