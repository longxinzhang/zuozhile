# Core Vision 接入说明

默认设置仍保留 `MockPostureSource`，用于无相机环境验证 UI、评分和提醒流程。
设置页开启“真实相机检测”后，当前工程会使用
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
   - 设置页开启“真实相机检测”后创建透明 `XComponent` 作为预览 surface。
   - 开始守护时申请 `ohos.permission.CAMERA`。
   - 通过 `CameraProbeService` 预检摄像头和输出能力。
   - 用 `CoreVisionPostureSource(context, surfaceId)` 替换模拟采样源。

2. `CoreVisionPostureSource.ets`
   - 选择前置摄像头，创建 `CameraInput`、`PreviewOutput`、`PhotoOutput` 和 `PhotoSession`。
   - 每次 `sample()` 调用 `PhotoOutput.capture()`，等待 `photoAvailable`。
   - 读取 `photo.main` 的 JPEG component，创建 `ImageSource`。
   - 不使用 `photo.main.size` 推导 JPEG 尺寸；该字段在压缩图上可能表现为
     `25165824x1` 这类元数据。实际解码尺寸来自 `ImageSource.getImageInfoSync()`。
   - 解码后释放 `PixelMap`、`Photo`、`ImageSource`、`main`，不落盘。

3. `CoreVisionPostureDetector.ets`
   - 调用骨骼点检测，产出 `SkeletonFrame`。
   - 调用人脸检测，产出 `FaceFrame`。
   - `FaceFrame` 现在包含 `rect`、pitch/yaw/roll、置信度和嘴部粗估比例。
   - `SkeletonFrame` 现在包含鼻、双耳、双肩、双髋，供正面摄像头代理指标使用。
   - 骨架检测异常时降级为空骨架，人脸检测失败时抛出错误并中止本次采样。

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

- `PostureCalibration.ets`：`记录基线` 采集 10 帧，分别对 pitch、roll、yaw、人脸中心/高度/面积、肩中点/肩宽、鼻肩比和嘴部比例取中位数。
- `PostureEvaluator.ets`：
  - D1 低头/颈前屈：face pitch 偏移为主，鼻尖到肩中点垂直比为辅助。
  - D2 身体下滑：人脸中心下移 + 肩中点下移共同触发。
  - D3 含胸/驼背：肩宽压缩为主，人脸面积膨胀为辅助；标准档会要求更强的肩宽压缩或配合脸部靠近，轻微前倾显示为“身体靠前”，灵敏档保留更积极的前扣提醒。
  - D4 肩部歪斜：肩部倾斜比偏移 + face roll 偏移。
  - D5 嘴巴张合：当前用 Face Detector 关键点粗估 mouthOpenRatio，后续可替换为 FaceAR blendshape。
- `ReminderEngine.ets`：
  - 每个 D1-D5 类型独立维护 `firstTriggeredAt`、连续触发帧数和上次提醒时间。
  - 持续时间阈值按文档区分：D1/D4 20s、D2 30s、D3 25s、D5 15s。
  - 同一项提醒后 120s 冷却。
  - 多项同时满足时按 D2 > D1 > D3 > D4 > D5 选择最优先提醒。
- `Index.ets`：轻提醒显示为守护页内紧凑横幅，强提醒显示为前台遮罩并可点“知道了”关闭，8 秒后也会自动收起。
- `Index.ets`：灵敏度只保留“标准/灵敏”两档，切换时会重置分项提醒状态，避免旧档位累计的连续触发影响新档位。
- `Index.ets`：首页三项指标使用两帧显示稳定策略；异常状态需要连续出现两帧才替换当前显示，恢复正常立即更新，用于减少单帧误识别导致的文案跳动。
- 首页仍保持三块反馈：`坐姿` 聚合 D2/D3/D4，`抬头` 对应 D1，`嘴巴` 对应 D5。

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

后续真机阶段继续观察：

- 上半身场景中鼻、肩、髋关键点命中率。
- pitch 与真实低头动作的方向和量级。
- 嘴巴张合比的稳定性；当前 face detector 未提供语义化唇部点，代码中只保留粗估逻辑。
- 每 2 秒、3 秒、5 秒抽帧时的温度和耗电。
