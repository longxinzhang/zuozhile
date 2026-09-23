# 0.2.3 嘴部检测预览

更新：2026-09-23。版本 0.2.3 / versionCode 1000004，沿用包名、签名身份和 Preferences。
本次只授权新增嘴部识别及相应评分、校准、显示，不调整坐姿和抬头阈值。

## 实现

原来的 Core Vision `Face.points` 只有双眼、鼻尖和嘴角五点，不能推导上下唇间隙。
0.2.2 已移除错误的伪嘴部数值；本版新增真实输入，不恢复五点估算。

- ArkTS 检查 `SystemCapability.AREngine.Core` 和 FACE 跟踪支持，再创建 `ARPostureSource`。
- 原生 C++ 创建前置 FACE 会话，在离屏 EGL 环境中更新。相机图像必须启用 preview 模式才能获取，界面不展示摄像头画面。
- 图像经带步长校验的 YUV420 转 RGBA、最大边 720、按相机传感器方向旋转后交给原 Core Vision 检测器。该真机为 720 x 540、旋转 270 度。
- 从 SDK 定义的 `JAW_OPEN` 读取下颌强度；从 `UPPER_LIP`、`LOWER_LIP` 语义三角网格取嘴唇中部最近距离，除以嘴宽。排除上下唇共享顶点，避免嘴角接触使间隙恒为零；不猜测私有关键点编号。
- 同一次 AR 更新的图像与嘴部数据用于一个样本；多脸、低置信度、头部角度过大时嘴部不计分。图像时间戳去重，错误时释放图像、网格和会话资源。
- 首帧前失败可释放 AR 并退回原 JPEG 抽帧源；已成功采样后不静默切换相机通路，以免基线失配。支持的是 arm64-v8a 真机包，不包含模拟器架构。

接口依据为本机 API 26 SDK 的 `ar_engine_core.h`、`@hms.core.ar.*` 与 Core Vision 类型声明。
ArkTS 的相机图像获取接口有版本限制，本版使用原生 C 接口，已在 API 24 真机跑通；API 23 其他机型未验证。
平台介绍：[Huawei AR Engine](https://developer.huawei.com/consumer/en/hms/huawei-arengine)、
[Core Vision Kit](https://developer.huawei.com/consumer/cn/sdk/core-vision-kit?ha_source=hms1)。

## 评分与校准

每次开始时用户应自然闭嘴。原有 3 秒准备 + 5 帧校准不变，手动校准仍为 10 帧。
至少 3 帧可靠嘴部样本，下颌强度小于本档阈值、唇间隙极差不超过 0.025，才取中位数作为 `neutralLipGapRatio`。
不合格则清除嘴部基线并提示重新闭嘴校准，不能把旧基线带入新相机位置。身体校准质量规则不变。

令 `s = max(灵敏度, 0.6)`：

```text
pressure = max(jawOpen / (0.025 / s), max(0, lipGap - baseline) / (0.015 / s))
pressure < 1: 正常，100 分
1 <= pressure < 3: 轻微张口
pressure >= 3: 请轻合嘴唇
张口分数 = max(20, 100 - round(pressure * 15))
```

这是保留噪声容差的严格分唇规则，不是零阈值检测。无法保证每一次肉眼可见的极小缝隙都能被模型分辨。
嘴部可靠且有基线时按原权重 15% 计入总分；不可用时坐姿和抬头按原 40:45 比例归一化。
嘴部卡片与总分同次刷新，不再等待原来的两帧显示去抖；因此可能更易受单帧噪声影响。
仍按设置的 2/3/5 秒采样，短于采样周期的动作可能漏掉。
ITEM_11 原有 15 秒轻提醒、30 秒强提醒及 120 秒冷却不变，并非一分唇就振动。

## 真实测试证据

2026-09-23，API 24、DevEco Studio 26.0.0、API 26 SDK。

1. 首轮仅使用 JAW_OPEN：用户完成闭嘴 6 秒、轻微分唇 6 秒、闭嘴 6 秒，数值仍为 0。
   该方案未通过轻微分唇验收，因此增加语义唇网格，而不是继续降低下颌阈值。
2. 加入唇网格后，11:50:22 的校准有效唇距为 0.0081、0.0056、0.0040、0.0037，中位数约 0.0048。
3. 11:50:39 至 49 连续得到 0.0587、0.0519、0.0620、0.0625、0.0555、0.0542；
   11:50:51 至 55 回到 0.0053、0.0057、0.0058。这些帧的下颌强度都是 0，嘴部质量检查通过。
4. 以日志四舍五入值、灵敏档 1.2 和基线 0.0048 回放实际评分函数，得到张口单项
   35、43、31、31、39、41，回落后为 100、100、100。该结果是代码回放，不是逐帧 UI 录像证据。
5. 已看到当次结束报告包含嘴部问题。用户回复“OK”仅视作同意配合测试，不能当作“全程扣分与恢复均已人工确认”。

上述是单用户、单设备的开发验证。动作时间未严格标注，不报告召回率、误报率或“6+6+6 全部通过”。
后续需要闭嘴、分唇、说话、微笑、打哈欠、距离、光照及角度变化的标注测试集。

## 自动验证

```bash
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/verify-core.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/verify-mouth-source.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/verify-window.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/audit-algorithm.cjs
xcrun clang++ -std=c++17 -O1 -Wall -Wextra scripts/verify-yuv.cpp -o /tmp/zuozhile-verify-yuv-plain
/tmp/zuozhile-verify-yuv-plain
xcrun clang++ -std=c++17 -O1 -Wall -Wextra scripts/verify-lip-gap.cpp -o /tmp/zuozhile-verify-lip-gap
/tmp/zuozhile-verify-lip-gap
./scripts/verify-app.sh
```

- 原有规则：20,160 组评估、2,520 次提醒决策、旧校准和统计对比 `fac06c8`。
- 新增：缺失嘴部、非法数值、嘴唇基线稳定性、下颌/唇距分支、数值回放及页面同帧更新。
- 原生输入：语义唇距、共享边界排除逻辑、缩放/平移、异常网格；YUV 平面步长、交错、奇数尺寸与颜色转换。
- 源适配：同帧调用次序、方向、单脸/置信度/角度门槛、首帧降级、成功后不切换、资源释放。
- 原有生命周期与浮窗模拟契约测试继续执行。宿主机 C++ 普通测试通过，不宣称已通过 sanitizer。

以上自动验证于 2026-09-23 全部完成。`audit-algorithm.cjs` 的通过含义仍是成功复现已知问题。
最终 signed HAP 构建成功，覆盖安装返回 `install bundle successfully`，启动返回 `start ability successfully`。
真机包信息确认 0.2.3 / 1000004、target 26、compatible 23；首页初始为未开启且无旧实时分数。
快速/手动校准取消分别在点击后约 1345/1364 毫秒完成，页面显示原基线未更改，均未启动守护。
设置页仍保留 09/23 11:55 的个人基线与灵敏度设置，新增闭嘴提示正常显示。

构建保留原有 FLOAT_VIEW 权限/设备适配警告及原生工具链 unused argument 警告；本次未宣称修复系统浮窗权限。
产物：`entry/build/default/outputs/default/entry-default-signed.hap`。
SHA-256：`2d39d15bbe3b2e681484ddb50b3955ed666379076b8fc7d1e0c416c7770c2c33`。
校准取消布局和设置页截图位于本地 `artifacts/preview-2026-09-23/`，不随源码提交。

## 隐私与边界

没有新增网络传输、相片或视频文件。原生图像与人脸网格只在内存处理，Preferences 新增个人唇距基线数值。
开发日志包含张口强度、唇距、人数、采样时间等标量，不记录图像；导出日志仍应征得测试者同意。

AR 引擎会维持相机与原生人脸跟踪，业务 2 秒抽样不代表相机每 2 秒才工作一次。
耗电、温升、长期运行和跨机型效果未完成测试。退出/退后台仍停止检测并释放会话。
身体规则虽未变化，但相机裁剪、分辨率和颜色通路变了，需继续对比坐姿误报。
校准无法证实用户确实闭嘴，仍依赖正确执行校准；微笑、斜脸等可能影响唇距，不能替代临床测量。

应用只描述嘴唇状态，不能依据张嘴确认口呼吸。嘴唇应自然轻合，不咬紧，不在鼻塞或呼吸不适时强迫闭嘴。
口呼吸需综合检查的边界可参考[临床研究](https://pmc.ncbi.nlm.nih.gov/articles/PMC6293616/)。
