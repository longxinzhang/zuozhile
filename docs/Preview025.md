# 0.2.5 HarmonyOS 7 界面预览

更新：2026-09-23。版本 0.2.5 / versionCode 1000006。
本轮按用户要求暂停浮窗，优先改善主应用界面，不调整检测算法。

## 变更范围

- 原生 Navigation 负责固定标题，当前页面标题随 Tabs 切换；首页设置按钮直接跳转设置页。
- API 26 标题与悬浮底栏使用系统沉浸材质，按钮保留系统触控效果；创建和调用均按 API 可用性隔离，旧系统不构造 API 26 材质。
- 首页评分区 150vp 起、三项指标等高 140vp，数值和状态层级统一。保留开始/结束、校准进度、建议和本机隐私摘要。
- 统计页使用概览指标和分隔区域；指南移除图片外的重复框，保留全部 12 组原始对比图；设置按校准、识别、隐私提醒、开发工具和本机数据分区。
- 短页面填满 TabContent，从标题下方开始布局，不再垂直居中。API 26 页面底部预留 96vp 滚动空间。
- 浮窗入口从首页和设置移除，旧窗口服务代码保留，不申请新权限、不修改签名。先前 0.2.4 的窗口实现和实验记录属于历史，不表示当前界面开放浮窗。
- “今日重点”仅缩短展示文案，不再对所有问题一律给出调整桌椅的建议；统计排序、数量和计算不变。

本轮没有修改人脸/骨架/嘴部采样、评分阈值、质量门控、校准流程、提醒规则、数据存储或后台相机策略。
未复制设计图中的装饰性光球；普通内容采用轻量表面，系统沉浸材质只用于平台支持的区域。

## 自动检查

以下命令通过：

```bash
node scripts/verify-core.cjs
node scripts/verify-mouth-source.cjs
node scripts/verify-window.cjs
node scripts/verify-harmony-ui.cjs
./scripts/verify-app.sh
node scripts/verify-harmony-ui-device.cjs
node scripts/verify-calibration-cancel.cjs
node scripts/verify-calibration-cancel.cjs --manual
```

- 20,160 组评估、2,520 次提醒决策、嘴唇间隙回放、基线稳定性、无效输入和实际页面方法回归通过。
- UI 检查对比 `e0806ab`，保护 22 个算法/原生/采样源文件和 15 个主要业务方法；额外逐个比对非 Builder 方法，除了明确保留的浮窗状态处理和今日重点展示文案外不允许变化。
- API 26/旧 API 两个模拟分支检查通过；验证原生标题、页面填满容器、浮窗入口隐藏、未声明受限权限及系统图标资源有效。
- 旧窗口逻辑仍运行原模拟 SDK 回归，防止保留代码倒退；不是本轮继续开展浮窗功能或跨应用验收。
- 签名构建成功。两条已知警告来自保留的窗口服务：FLOAT_VIEW 权限及子窗口背景接口手机适配。本轮无浮窗入口，未通过声明权限绕过安装限制。

## 真机结果

设备 `5ZGYD25A19000137`，API 26，系统 `OpenHarmony-7.0.0.105`。

- 覆盖安装返回 `install bundle successfully`，启动返回 `start ability successfully`。
- 已检查守护、统计、指南、设置四个页面及设置末尾，图像资源正常，原生标题和底栏正常切换。
- 首页开始按钮和姿态建议在底栏上方同屏完整显示；设置快捷按钮可用。长页面可滚动，清空数据按钮能完整移至底栏上方，未执行清空操作。
- 设置中浮窗入口不可见，开发者工具保持折叠。
- 快速校准在点击后约 1,377ms 取消，手动校准约 1,337ms 取消；都在准备倒计时内结束，未进入守护，没有覆盖基线。
- 取消后仍显示“已记录个人基线 · 09/23 11:55”。设置保持灵敏档、2 秒，提示音与振动开启；原有统计显示 167 次采样、88 均分、4 分端正时长。

真机自动脚本只做页面导航、滚动和截图，不启动守护，不修改设置或数据。校准取消由独立脚本验证。

## 产物与边界

- 安装包：`entry/build/default/outputs/default/entry-default-signed.hap`。
- 本地截图：`artifacts/preview-2026-09-23/025-home.jpeg`、`025-stats.jpeg`、`025-guide.jpeg`、`025-settings.jpeg`、`025-settings-bottom.jpeg`。
- 同目录 JSON 留存页面布局；`quick-countdown.json`、`quick-cancelled.json`、`manual-countdown.json`、`manual-cancelled.json` 记录校准取消。
- 截图与签名材料不提交 Git。构建包为开发签名，仅适用于签名授权的设备。
- 本轮验证的是当前手机、当前字体下的主页面和校准取消。未重新做真人识别准确率、功耗、长时间守护、大字体、其他屏幕尺寸或旧系统真机验收，也不宣称通过鸿蒙设计认证。

平台依据：[华为启用沉浸光感说明](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-immersive-light-sense-enable)，以及本机 API 26 的 Navigation、Tabs、ImmersiveMaterial 声明。
