# 坐直了

HarmonyOS NEXT / ArkTS 姿态守护应用 MVP。

## 当前实现

- 守护页：开始/结束守护、周期抽帧状态、三项指标、识别姿势图与建议、基线校准、单次抽样、前台轻提醒/强提醒。
- 统计页：今日均分、端正时长、提醒次数、今日问题分布、最近时段分布、最近记录。
- 指南页：展示 `assets/posture` 的 12 组错误/正确姿势对比图。
- 设置页：标准/灵敏两档灵敏度、抽帧间隔、真实/模拟检测切换、本机隐私模式、提示音、振动、本地数据确认清空。
- 规则层：按《坐姿守护 App 算法设计与开发参考文档》和《坐姿守护 App Codex 开发规格书》实现 D1-D5 代理指标，并对外拆成 9 项提醒：
  挺起来、坐正、抬头、下巴收、头别歪、靠回椅背、屏幕抬高、嘴巴轻合、呼吸一下。
- 提醒层：按 item 级提醒维护去抖、优先级和冷却；强提醒弹窗展示错误姿势到正确姿势的对比图。
- 标准档对 D3 含胸/肩前扣更保守，普通电脑操作时的轻微前倾优先显示为“身体靠前”，避免过早判定“肩膀前扣”。
- 校准：`记录基线` 会采集 10 帧，按字段取中位数，保存 pitch/roll/yaw、人脸框、肩宽、鼻肩比和嘴部比例。
- 检测层：已提供 `PostureSource` 抽象、`MockPostureSource`、`CoreVisionPostureSource`、`CoreVisionPostureDetector`。
- 相机层：已提供 `CameraProbeService`，开始守护时会查询摄像头、前置摄像头和预览/拍照能力；真实检测使用隐藏 `XComponent` 预览 surface + `PhotoOutput.capture()` 抽帧。
- 相机准备：开始守护、记录基线和单次抽样共用同一套权限申请、预览 surface 检查和相机预检流程。
- 守护模式：开始守护时设置窗口常亮并压低窗口亮度，结束守护时恢复。
- 权限：开始守护前会动态申请 `ohos.permission.CAMERA`。
- 存储：Preferences 本机保存设置和会话记录。

默认设置使用真实相机检测；设置页仍可关闭为模拟采样，便于无相机环境验证 UI/规则。
真实链路已在真机上验证：前置相机 JPEG 抽帧、`ImageSource` 读取源图尺寸、解码为 `PixelMap`，
再交给 Core Vision 骨架与人脸检测，结果写入守护页和统计页。实现细节见
[docs/CoreVisionAdapter.md](docs/CoreVisionAdapter.md)。

## 构建

```bash
./scripts/build-hap.sh --stacktrace
```

## 真机开发闭环

```bash
./scripts/start-phone-keepawake.sh
./scripts/install-run.sh
./scripts/keepawake-status.sh
```

- `start-phone-keepawake.sh` 会安装并加载 macOS LaunchAgent，每 480 秒用 `hdc uinput` 点击一次手机。
- `install-run.sh` 会构建、安装 signed HAP，并启动 `com.longxin.zuozhile/EntryAbility`。
- `keepawake-status.sh` 用于确认保活任务退出码和最近点击日志。

如果 DevEco Studio 重新生成签名，请确认 `build-profile.json5` 的 `products.default.signingConfig` 仍指向 `default`。

## 目录

```text
entry/src/main/ets/
  components/  状态块等可复用 UI 组件
  models/      姿态类型、评分、统计、校准和分项提醒决策
  services/    真实/模拟采样、窗口守护、本地 Preferences 存储
  theme/       颜色 token 与状态颜色映射
  pages/       ArkUI 主页面
assets/posture/
  12 组姿势对比源图，文件名已去掉抠图工具追加的 _cut 后缀
entry/src/main/resources/rawfile/assets/posture/
  App 内实际加载的姿势对比图资源
```
