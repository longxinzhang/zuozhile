# 0.2.6 光感与深色模式修正

日期：2026-09-23。版本 0.2.6 / versionCode 1000007。

## 本次修改

1. 移除首页抬头“待识别”的蓝色覆盖，UNKNOWN 状态统一为中性灰。
2. 全局颜色迁移到 base/dark 资源，保留状态色语义。页面、标题、底栏 maskColor、系统状态栏和手势区域跟随系统切换，修正深色底部白边。按钮填充色与状态文字色分离，避免深色浅绿底配白字。
3. 设置新增外观滑块 1–5 档，默认 3。原生材质由 ULTRA_THICK 到 ULTRA_THIN；阴影、交互及光效分档启用。这是应用内外观预设，不是系统硬件 MaterialLevel。
4. 内容区校准、恢复默认、清空数据、灵敏度和间隔选中按钮使用 ContentLightSurface：随档位变化的高光、细边和阴影。普通内容按钮不依赖只在特定原生区域生效的 systemMaterial；原生标题和底栏继续使用系统材质。
5. 独立 Preferences 文件 zuozhile_appearance 保存 immersive_level。连续调整串行写入，过期回调不覆盖最新结果；读取/保存失败明确提示并支持重试。清空守护数据保留外观偏好，确认文案已说明。

API 26 材质调用有版本隔离；不支持沉浸材质的设备禁用光感滑块并保留普通表面。本轮没有新增权限、修改签名或开启浮窗。

## 自动回归

通过命令：

```bash
node scripts/verify-core.cjs
node scripts/verify-mouth-source.cjs
node scripts/verify-window.cjs
node scripts/verify-harmony-ui.cjs
node scripts/verify-appearance.cjs
./scripts/verify-app.sh
UI_SNAPSHOT_PREFIX=026-dark node scripts/verify-harmony-ui-device.cjs --levels
UI_SNAPSHOT_PREFIX=026-light node scripts/verify-harmony-ui-device.cjs --levels --settings
node scripts/verify-calibration-cancel.cjs
node scripts/verify-calibration-cancel.cjs --manual
```

- 22 个算法/原生/采样源文件和 15 个主要业务方法与 e0806ab 一致；157 个非 Builder 方法只允许明确列出的颜色类型/展示资源变化及已有例外。
- 20,160 组评估、2,520 次提醒决策、嘴唇间隙回放、生命周期、校准取消及实际页面评分更新回归通过。
- 新增五档、双主题、API 26/旧 API 模拟分支检查；设置按钮取消选中时清除高光、细边和阴影。
- 外观测试覆盖非法值归一化、独立保存、连续写入顺序、put/flush 失败重试、旧异步结果隔离、忙碌锁定、系统栏运行时主题更新。
- 签名构建成功，仅保留窗口服务原有两条警告；模拟窗口测试不代表本轮开展浮窗真机验收。

## 真机结果

设备 5ZGYD25A19000137，API 26 / OpenHarmony-7.0.0.105，1320×2760。

- 覆盖安装、启动成功。深浅色四页、设置快捷入口、首屏守护按钮和建议、设置末尾可滚动至底栏上方均通过。
- 系统“全天开启”深色模式确认开启后截图；两个主题都逐档测试 1–5，进程重启保留第 5 档，测试后恢复第 3 档。
- 深色首页、设置、设置末尾、统计、指南和 1/3/5 档共 8 张截图检查：底部 75 像素区域没有 RGB 三通道均大于 160 的亮像素；未见白色横条。按钮背景采样验证第 1、5 档高光确有像素变化。
- 标准/灵敏及 2/3/5 秒逐项点击均能切换，随后恢复灵敏、2 秒。未清空任何用户数据。
- 快速校准在点击后约 1,442ms 取消，手动校准约 1,363ms 取消，均未进入守护。个人基线仍为 09/23 11:55，原统计仍为 167 次采样、均分 88、端正 4 分。
- 测试结束恢复手机原来的浅色模式，未改变定时深色设置。提示音、振动和识别源未修改。

## 产物与边界

- 安装包：entry/build/default/outputs/default/entry-default-signed.hap。
- 本地截图和布局：artifacts/preview-2026-09-23/026-light-*.jpeg/json、026-dark-*.jpeg/json。
- 校准取消布局：同目录 quick-countdown.json、quick-cancelled.json、manual-countdown.json、manual-cancelled.json。
- 不提交签名材料、用户现有 build-profile.json5 改动或截图。包仅适用于签名授权的测试设备。
- 没有重新开展真人识别准确率、功耗、大字体、其他尺寸及旧系统真机测试。检测、评分、校准帧数、提醒规则、相机数据处理与统计计算不变。

平台参考：[系统材质属性](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/ts-universal-attributes-image-effect)；具体 API 与兼容分支以本机 SDK26 的 uiMaterial、Tabs、Navigation 声明及真机结果为准。
