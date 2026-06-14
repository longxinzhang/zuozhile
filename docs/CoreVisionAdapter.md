# Core Vision 接入说明

默认设置使用真实相机检测；设置页关闭“真实相机检测”后，会回退到 `MockPostureSource`
用于无相机环境验证 UI、评分和提醒流程。真实检测使用
`services/CoreVisionPostureSource.ets` + `services/CoreVisionPostureDetector.ets`
完成 `CameraKit -> JPEG -> PixelMap -> Core Vision -> PostureSample` 链路。

已确认的本机 SDK API：

- 骨骼检测：`skeletonDetection.SkeletonDetector.create().process(visionBase.Request)`
- 人脸检测：`faceDetector.init()` + `faceDetector.detect({ pixelMap })`
- 视觉请求：`visionBase.Request.inputData = { pixelMap }`
- 相机入口：`@kit.CameraKit` 的 `camera.getCameraManager(context)`
- 相机预检：`CameraProbeService` 已接入守护启动路径，能查询前置摄像头与输出能力。
- 拍照抽帧：`PhotoOutput.capture()` + `photoAvailable` 回调。
- JPEG 解码：`image.createImageSource(component.byteBuffer)` 后使用
  `ImageSource.getImageInfoSync()` 读取源图真实尺寸，再按最长边 720 以内解码。

## 当前真机链路

1. `Index.ets`
   - 默认创建透明 `XComponent` 作为预览 surface，设置页关闭“真实相机检测”后不创建。
   - 开始守护时申请 `ohos.permission.CAMERA`。
   - 通过 `CameraProbeService` 预检摄像头和输出能力。
   - 用 `CoreVisionPostureSource(context, surfaceId)` 替换模拟采样源。

2. `CoreVisionPostureSource.ets`
   - 选择前置摄像头，创建 `CameraInput`、`PreviewOutput`、`PhotoOutput` 和 `PhotoSession`。
   - 每次 `sample()` 调用 `PhotoOutput.capture()`，等待 `photoAvailable`。
   - 读取 `photo.main` 的 JPEG component，创建 `ImageSource`。
   - 不使用 `photo.main.size` 推导 JPEG 尺寸；该字段在压缩图上可能表现为
     `25165824x1` 这类元数据。实际解码尺寸来自 `ImageSource.getImageInfoSync()`。
   - `PhotoOutput.capture()` 直接失败时会清理 pending 回调状态并抛出阶段错误；等待
     `photoAvailable` 超时仍走 6 秒超时保护；错误回调如果附带 `Photo` 也会释放。
   - 解码后释放 `PixelMap`、`Photo`、`ImageSource`、`main`，不落盘。

3. `CoreVisionPostureDetector.ets`
   - 调用骨骼点检测，产出 `SkeletonFrame`。
   - 调用人脸检测，产出 `FaceFrame`。
   - 多人或多骨架入镜时，不再直接取第一个结果；骨架按整体 score、鼻/肩/髋关键点质量和框面积选择，脸按置信度、面积和关键点数量选择。
   - `FaceFrame` 现在包含 `rect`、pitch/yaw/roll、置信度和嘴部粗估比例。
   - `SkeletonFrame` 现在包含鼻、双耳、双肩、双髋，供正面摄像头代理指标使用。
   - 骨架检测异常时降级为空骨架，人脸检测失败时抛出错误并中止本次采样。
   - 释放检测器时骨架和人脸检测器逐项容错；其中一项释放失败不会阻断另一项释放。

4. 保持现有输出契约：

```typescript
export interface PostureSample {
  timestamp: number;
  skeleton: SkeletonFrame;
  face: FaceFrame;
}
```

5. 不要把 PixelMap、关键点原始坐标或图片落盘。

## 算法实现

实现参考 `/Users/zhanglongxin/Downloads/坐姿守护App_算法设计与开发参考文档.md`：

- `PostureCalibration.ets`：`记录基线` 采集 10 帧；至少 5 帧识别人脸、5 帧识别双肩、3 帧同时识别鼻点与双肩后，才分别对 pitch、roll、yaw、人脸中心/高度/面积、肩中点/肩宽、鼻肩比和嘴部比例取中位数；样本不足时返回失败提示并保留旧基线。
- `PostureEvaluator.ets`：
  - D1 低头/颈前屈：拆成 ITEM_03「抬头」和 ITEM_05「下巴收」；第 3 项反复触发后由提醒引擎升级为 ITEM_10「屏幕抬高」。
  - D3 含胸/驼背：肩宽压缩且脸面积未明显膨胀时触发 ITEM_01「挺起来」；脸面积明显膨胀或下滑辅助信号触发 ITEM_07「靠回椅背」。
  - D4 肩部歪斜：肩倾斜 + face roll 同时异常触发 ITEM_02「坐正」；只有头部 roll 异常且肩膀相对水平时触发 ITEM_06「头别歪」。
  - D5 嘴巴张合：当前用 Face Detector 关键点粗估 mouthOpenRatio，输出 ITEM_11「嘴巴轻合」，后续可替换为 FaceAR blendshape。
- `ReminderEngine.ets`：
  - 每个 ITEM 类型独立维护 `firstTriggeredAt`、连续触发帧数和上次提醒时间。
  - 按 ITEM_02 > ITEM_01 > ITEM_07 > ITEM_03 > ITEM_05 > ITEM_10 > ITEM_06 > ITEM_11 > ITEM_12 选择提醒。
  - 普通姿态项提醒后 120s 冷却；ITEM_10 冷却 300s；ITEM_12 为 20 分钟久坐计时器。
- `Index.ets`：轻提醒显示为守护页内紧凑横幅，强提醒显示为带姿势对比图的前台遮罩，可点“知道了”关闭，8 秒后也会自动收起。
- `Index.ets`：灵敏度只保留“标准/灵敏”两档，切换时会重置分项提醒状态，避免旧档位累计的连续触发影响新档位。
- `Index.ets`：首页三项指标使用两帧显示稳定策略；异常状态需要连续出现两帧才替换当前显示，恢复正常立即更新，用于减少单帧误识别导致的文案跳动。
- `Index.ets`：新增 `指南` tab，加载 `rawfile/assets/posture` 的 12 组错误/正确姿势对比图。
- 首页仍保持三块反馈：`坐姿` 聚合 ITEM_01/02/06/07，`抬头` 对应 ITEM_03/05/10，`嘴巴` 对应 ITEM_11。

## 2026-06-14 真机验证

- signed HAP 安装并启动成功，包名 `com.longxin.zuozhile`。
- 守护页开启真实相机检测后，UI 显示“结束守护”，采样周期为 2 秒。
- `hilog -P 51873 -T ZuozhileCamera` 确认持续完成：
  - `创建 ImageSource · source=480x480 target=480x480`
  - `创建 PixelMap · actual=480x480 format=3 stride=1920`
  - `Core Vision 已完成一次本机检测 · 骨架与人脸检测完成`
- 统计页出现 14:27 附近连续真实采样记录，说明结果已写入本地记录。
- 15:00 版本验证：
  - `ZuozhileGuard` 日志显示 `守护窗口常亮 · 低亮度`，停止后显示 `守护窗口已恢复`。
  - UI 显示真实相机检测、守护窗口低亮、`开始/结束守护` 正常切换。
  - `hilog -P 7707 -T ZuozhileCamera` 连续显示 480x480 PixelMap 和 `骨架与人脸检测完成`。
- 15:14 版本验证：
  - 分项提醒类型已写入 `PostureResult.primaryAlert` 与 `SessionRecord.alertType`。
  - 真机守护启动、真实相机采样、窗口低亮和统计页最近记录渲染正常。
  - 当没有持续异常时 UI 保持 `无提醒`，符合分项去抖策略。
- 15:30 版本验证：
  - `./scripts/verify-app.sh` 通过，signed HAP 安装启动成功，设备进程 pid `22772`。
  - 首页三项卡片保持紧凑横排，`开始守护` 坐标为 `[58,1392][1262,1561]`，首屏完整可见。
  - 守护启动后 UI 显示 `ON`、`前台守护中`、`结束守护`，真实相机持续输出 480x480 PixelMap 并完成 Core Vision 检测。
  - 停止后 UI 显示 `OFF`、`开始守护`、`守护窗口已恢复`、`真实相机已释放`。
- 20:32 版本验证：
  - `CoreVisionPostureDetector` 改为按质量选择主骨架和主脸，避免多人入镜时误取第一个检测结果。
  - `./scripts/verify-app.sh` 通过，signed HAP 安装启动成功，设备进程 pid `40958`。
  - 真机点击 `抽样一次` 后页面显示 `上次采样 20:32:30 · 2 秒 抽帧`。
  - `hilog -T ZuozhileCamera` 显示前置相机、JPEG 解码、PixelMap 和 Core Vision 检测链路完成；本次画面无脸/骨架时也正常返回空结果，没有采样失败。
- 20:38 版本验证：
  - 校准采样新增质量门槛，识别到的人脸、双肩和头肩关键点数量不足时不保存新基线。
  - `./scripts/verify-app.sh` 通过，signed HAP 安装启动成功，设备进程 pid `50583`。
  - 真机点击 `记录基线` 后完成 10 次真实抽帧；当前画面 `骨架 0 · 人脸 0`，页面显示 `校准失败` 和 `人脸识别不足，请正对屏幕并保持脸在画面内`。

后续真机阶段继续观察：

- 上半身场景中鼻、肩、髋关键点命中率。
- pitch 与真实低头动作的方向和量级。
- 嘴巴张合比的稳定性；当前 face detector 未提供语义化唇部点，代码中只保留粗估逻辑。
- 每 2 秒、3 秒、5 秒抽帧时的温度和耗电。
