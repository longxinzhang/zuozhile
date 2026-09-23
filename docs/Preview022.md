# 0.2.2 开发预览与验证边界

更新：2026-09-23。版本 0.2.2 / versionCode 1000003。原包名、签名身份与本地存储保持不变。

## 本次交付

1. 视觉：原生 `Tabs` / `BottomTabBarStyle` 接管底部导航；启用 API 26 沉浸材质元数据。
   页面改为中性浅灰背景、低强度投影；设置中的声音、振动改为扁平分组行。
   开发选项仍默认折叠。保留四个主页面及原有操作，不增加相机画面。
2. 图标：使用用户提供的 `assets/logo.png`。`scripts/build-icons.py` 去除外围深色底、裁切主体，
   生成 AppScope 与 entry 的分层图标、启动图标和首页标识。原图保留。
3. 校准：开始守护固定先执行 3 秒准备倒计时，再采集 5 帧；手动校准为 10 帧。
   取消原来的每帧 500ms 附加等待，进度只在采样完成后推进。实际耗时仍受相机和检测器影响，未作真机秒数承诺。
   质量检查仍要求至少 5 帧有效人脸、5 帧有效双肩、3 帧有效鼻肩关系。
   失败不开始守护，也不覆盖旧基线；用户可取消，离开应用会取消。
4. 浮窗：设置中开启。显示分数、检测状态、上次采样时间、返回/关闭操作，不显示摄像画面。
   已接入 API 26 的 `floatView` 系统闪控窗与原生权限请求，以 STARTED 回调确认开启。
   但当前包不声明该权限，默认走应用内子窗口预览；离开应用关闭预览，明确标注并非跨应用浮窗。
   分数超过 15 秒无新采样、未开始、未识别、检测错误、进入后台时不展示为实时有效分数。
5. 嘴部能力更正：见下一节。此项不是“已经恢复张嘴检测”。

## 嘴部问题

SDK `@hms.ai.face.faceDetector.d.ts` 的 `Face.points` 只有左右眼、鼻尖、左右嘴角五个点，没有上下唇点。
旧实现把下半脸点位的纵向差当作张嘴比例，并在数据不足时回退 `0.16`。该值不能区分闭嘴、张嘴，
也会受侧倾影响，因此原来的“嘴部放松”及固定数值不可靠。综合分数下降不证明嘴部检测工作正常。

本版真实源显式设置 `mouthAvailable: false`，嘴部显示“未启用 / 当前不计分”，不发出张嘴提醒、
不更新嘴部校准值。综合评分暂由坐姿 0.4 与抬头 0.45 归一化计算；两项的单项分数、判定规则和阈值不变。
旧记录不重算，新旧综合分数的统计口径有差异，不能当作完全同口径比较。
模拟数据仍可用于验证原嘴部规则，但不是实际识别能力。

SDK 的 AREngine 提供面部网格和表情能力，但其相机会话与当前抽帧输入方式不同，不能把它直接当作
现有 PixelMap 检测器的替换。本版未强行切换采集链路。真实张嘴检测仍需独立验证模型与相机共用方案、
设备支持、长时功耗，再做闭嘴/张嘴/说话/偏头样本验收。

## 生命周期

- 应用进入后台结束当前守护并生成报告，停止发起新采样；不承诺后台相机持续检测。
- 校准中离开应用不写基线；退出与取消共用清理路径，避免并发释放检测器。
- 常亮与低亮度针对主窗口，而非可能已成为“最后窗口”的浮窗。
- 结束时恢复原亮度，包括代表系统默认亮度的 `-1`。

## 自动验证

```bash
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/verify-core.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/verify-window.cjs
./scripts/verify-app.sh
git diff --check
```

- 参考 `fac06c8`：4 个核心文件、7 个页面核心方法原文一致；坐姿/抬头等评估函数及校准质量检查原文一致。
- 20,160 次有嘴部数据的姿态判断、2,520 次提醒决策、校准和日统计结果与参考版一致。
- 420 组嘴部不可用样本验证：不生成嘴部提醒，不更改单项坐姿/抬头结果，评分按明确的新口径计算。
- 真实页面方法逻辑测试：5 帧启动、每次重启重校准、手动 10 帧、取消、无人入镜、相机错误、离开应用、
  页面销毁均有覆盖；不合格路径保存次数为零。
- 浮窗 SDK mock 测试：拒绝授权、开启失败、等待 STARTED、重复开启、提前关闭、旧系统子窗口、
  未声明权限、背景色能力不可用、回到后台、主窗口亮度恢复。该测试不等于 API 26 真机闪控窗验证。
- 安装脚本检查 hdc 输出中的实际成功标记，不再将“退出码为零但安装/启动报错”当作成功。

## 真机状态与未完成项

- DevEco 26.0.0.821 / SDK 26.0.0.105；target API 26，最低兼容 API 23。
- API 24 手机可被 hdc 访问，0.2.2 开发签名包覆盖安装成功，未卸载或清空数据。
- 后续安装带 `FLOAT_VIEW` 声明的包被设备以 `9568289 / grant request permissions failed` 拒绝。
  SDK 权限定义显示其为 `system_basic`、`provisionEnable: true`，不仅需要弹框授权，还受签名权限范围限制。
  当前可安装配置已移除该声明，代码检查包内是否声明权限，再决定能否进入原生闪控窗分支。
  未使用 hdc 强制授权、修改权限等级或修改用户签名来绕过限制。
- 首次启动返回 `10106102`，设备锁屏；用户继续后设备已可启动，完成下列 UI 检查。
  未绕过锁屏、未关闭安全设置、未使用模拟器。
- 包信息确认 `versionName=0.2.2`、`versionCode=1000003`；四个主页面的原生底栏切换与内容显示正常。
  1320 x 2760 真机上首页守护按钮与建议首屏可见，嘴部显示未启用，桌面图标已更新。
- 应用内浮窗实际创建成功；显示正确的未守护状态，没有伪造分数。标题栏拖动后坐标改变，
  关闭后开关回到未开启，再次打开正常；Home 回到桌面后不遗留浮窗。
- 自动 UI 操作分别在 1378ms / 1340ms 内取消启动校准 / 手动校准，倒计时和 0% 可见，
  取消后未开启守护，个人基线时间仍为 09/22 23:53。未完成无人监督的基线写入。
- 本机截图与布局证据：`artifacts/preview-2026-09-23/`，包含 home、stats、guide、settings、float、launcher，
  以及 quick/manual 的倒计时和取消结果 JSON。该目录不提交到 Git。
- 真实 5 帧校准完整耗时、真人健康基线质量和浮窗实时评分同步仍需真人测试；当前只验证了取消路径和静态窗口交互。
- API 26 原生材质与跨应用闪控窗，需要 HarmonyOS 7 真机验证；闪控窗还需确认平台权限准入与签名范围。
- 嘴部真实识别未实现；本版完成的是错误能力声明和错误计分的修正。

校准取消真机回归（先打开 App，当前不在守护中）：

```bash
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/verify-calibration-cancel.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/verify-calibration-cancel.cjs --manual
```

浮窗“返回坐直了”按钮的唤回行为和 API 26 自带关闭栏仍待补测。本轮测试结束不保持相机采样。

安装包：`entry/build/default/outputs/default/entry-default-signed.hap`。
开发签名仅适用于签名授权设备。截图、用户签名密码与运行日志不随源码提交。

系统闪控窗授权与测试条件满足后，在 `module.requestPermissions` 中添加以下声明，再正常签名构建。
不要直接把含受限权限、尚未获准的包分发给用户。

```json
{
  "name": "ohos.permission.FLOAT_VIEW",
  "reason": "$string:float_reason",
  "usedScene": { "abilities": ["EntryAbility"], "when": "inuse" }
}
```

## 官方依据

- [沉浸光感启用条件与组件范围](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-immersive-light-sense-enable)
- [系统闪控窗与权限、回调、系统版本](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/float-view-guide)
- 本机 SDK 类型声明：`@hms.ai.face.faceDetector.d.ts`、`@hms.core.ar.arengine.d.ts`、
  `@ohos.window.floatView.d.ts`、`@ohos.window.d.ts`。
