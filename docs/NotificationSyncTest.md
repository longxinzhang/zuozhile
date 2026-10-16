# 无需 Wear Engine 审批的手环通知同步测试

0.2.10起，本文独立测试入口迁至「设置 → 开发者工具 → 手机通知同步测试」；正式普通通知提醒直接位于「设置 → 腕上提醒」。最新使用版见 [NotificationRelease0210.md](NotificationRelease0210.md)。下文0.2.9操作与结果保留为历史。

2026-10-16 后续：用户已明确选择新增正式普通通知自动提醒，操作见 [NotificationReminder.md](NotificationReminder.md)。正式A/B与「设置 → 腕上提醒」同区域单条测试当前共享10秒持久化冷却；本文独立测试ID `29001` 仍为60秒冷却，“10秒后发送”是发送延迟。本文仍仅记录历史独立手动测试；下文“正式仅Wear Engine”等描述为该测试开发时的范围，不代表最新正式路线范围。

最新用户对新版B同区域单条测试确认手环“显示并振动”（改10秒前安装版），手机额外反馈“未留意”；该证据与本文独立测试分开记录，不外推屏幕状态、正式严重低分自动守护闭环或10秒实机节流通过，未执行UI验证。本次10秒调整的三份快速检查、腕上90组、集成17组/10,080次评分一致、独立通知26组、lint及完整构建结果已记录于正式路线文档，其余旧六项本轮未重跑；10秒版覆盖安装成功，但自动启动因锁屏失败（`Error10106102`），尚无本次启动成功或10秒实机节流结论。

日期：2026-10-16（开发会话日期；设备日志日期为10月15日）。适用版本：坐直了 0.2.9。本文件说明新增的独立手动测试功能，不是 Wear Engine 接通或正式守护验收报告。

**本次结果：用户亲自执行坐直了“10秒后发送”测试，明确确认手环“显示并振动”。** 这是普通通知同步的实际验证，不是 Wear Engine 审批通过，也不证明正式低分提醒链路已经验收。

## 1. 为什么没有 Client ID 也可以测试手环提醒

本方案没有绕过 Wear Engine 审批，也没有直接控制手环马达，而是使用另一条已经获得用户授权的通知链路：

```text
用户手动点击坐直了的普通通知测试
    ↓
Notification Kit 在手机发布坐直了自己的普通通知
    ↓
华为运动健康按用户已开启的消息通知设置同步
    ↓
手环收到同步通知，按自身设置显示、振动
```

QQ 消息让手环振动，先验证了这类手机通知同步链路可用。随后用户通过坐直了的新入口发送测试，并单独确认手环显示和振动，完成当前环境下本应用普通通知同步的验证；不将QQ结果冒充为本应用证据。

准确说法是：**不需要 Wear Engine 的服务审批和 Client ID，但需要手机通知授权、运动健康通知同步设置以及正常的手机/手环连接。** 手机普通通知使用公开的 Notification Kit，不冒用 QQ 的身份或消息，也不调用未获准的 Wear Engine 接口。

## 2. 与原腕上提醒通道的区别

| 项目 | Wear Engine 模板通知 | 本次普通通知同步测试 |
| --- | --- | --- |
| 应用调用的接口 | Wear Engine `NotifyClient.notify` | Notification Kit `notificationManager.publish` |
| Wear Engine 审批与 Client ID | 需要 | 不使用该服务，不需要 |
| 手机通知权限 | 不能代替 Wear Engine 审批 | 需要应用被允许发送普通通知 |
| 运动健康消息通知中勾选坐直了 | 不是模板直发的替代准入条件 | 本次同步测试的前提之一 |
| 目标设备 | 应用查询能力并明确选择单台 | 由运动健康现有同步配置决定，应用不能在此接口中指定某个手环 |
| 振动 | 跟随目标设备设置，不能保证 | 跟随目标设备及同步策略，不能保证 |
| 本版入口 | 设置 → 腕上提醒 | 设置 → 手机通知同步测试 |
| 是否接入正式低分事件 | 原实现保留，待审批和验收 | 没有；只允许用户手动发测试 |

Wear Engine 尚待审批时，上方腕上提醒区域仍会显示“待配置”。下面的普通通知测试不依赖上方开关，也不会把它改成“就绪”。两条通道不会自动切换，不会失败后双发或补发。

## 3. 当前设备与已知证据

| 项目 | 当前记录 |
| --- | --- |
| 手机 | HUAWEI Mate 70 Air，指定无线调试地址 `192.168.31.22:41813`，API 26 |
| 手环 | 用户提供华为 Band 11，型号 `CDY-B19` |
| 手环系统 | 用户提供 `6.0.0.130` |
| 配对 | 用户已在手机华为运动健康中配对 |
| 消息通知 | 用户已开启，支持应用全部，包括坐直了 |
| 已验证的同步 | 用户确认 QQ 收到消息时，手环会振动 |
| Wear Engine | 用户已提交申请，等待审批，尚未配置有效 `client_id` |
| 坐直了的真实通知 | 用户执行“10秒后发送”后先回复“通过”，进一步明确确认“显示并振动”；证据为用户实测反馈 |

没有读取用户的健康数据、佩戴状态、勿扰状态、设备序列号或账号。运动健康版本与当前完整系统设置未由工具检查。

## 4. 代码实现

### 文件职责

| 文件 | 职责 |
| --- | --- |
| `entry/src/main/ets/models/NotificationSyncTest.ets` | 测试专用通知 ID、10 秒延迟、5 秒有效窗口、独立 60 秒冷却与 UI 状态 |
| `entry/src/main/ets/services/NotificationSyncTestService.ets` | 通知权限检查、单次发布、短时后台任务、超时/取消、清除测试通知 |
| `entry/src/main/ets/components/NotificationSyncTestPanel.ets` | 设置页独立测试入口与结果提示 |
| `entry/src/main/ets/pages/Index.ets` | 仅在设置页面接入面板，守护/校准/采样等忙碌状态禁止开始测试 |
| `scripts/verify-notification-sync-test.cjs` | 用受控时钟与 SDK 桩验证，不向真实设备发通知 |

### 通知授权与发布流程

1. 只在用户主动点击后检查 `notificationManager.isNotificationEnabled()`。
2. 尚未允许时，用当前 UIAbility 上下文调用 `requestEnableNotification(context)`，由用户决定是否授权。返回后重新查询真实状态，不能把 Promise 成功当作已经允许通知。
3. 使用 `notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION)` 创建或使用服务提醒渠道。不会删除重建渠道来覆盖用户设置。
4. 构造有明确类型的 `NotificationBasicContent`、`NotificationContent` 和 `NotificationRequest`，发布一条普通文本通知。正文只包含测试说明，不带实时分数、相机数据、基线或个人记录。
5. 调用 `notificationManager.publish(request)`。成功提示仅表示手机发布请求成功，不自动标记手环收到或振动。

核心字段如下，实际实现以服务源码为准：

```ets
const request: notificationManager.NotificationRequest = {
  id: NOTIFICATION_SYNC_TEST_ID,
  label: 'zuozhile-notification-sync-test',
  notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
  content
};
await notificationManager.publish(request);
```

没有设置分布式通知预留字段、优先通知特权、自定义强制铃声或任意蓝牙控制命令。手环同步和振动由运动健康及穿戴设备执行，而不是应用获得了手环控制权限。

### 立即发送与锁屏后发送

- **立即发送**：权限确认后发布一条手机通知，便于先确认通知中心能收到。
- **10 秒后发送**：在用户明确点击后申请 `backgroundTaskManager.requestSuspendDelay` 短时任务，保留短暂后台执行窗口，方便用户锁屏后观察。它不是长时后台守护，不启动相机，也不使用音频或长期保活。
- 短时任务不支持、申请失败或额度不足时，停止此次延迟测试并提示使用立即发送；不会静默切换或临时扩大权限。
- 使用单调时间限制有效窗口。进程被挂起、权限查询过慢或回前台时已经超过有效窗口，则丢弃，不把过期测试补发。
- 结束、取消或页面销毁时释放定时器与短时任务。锁屏/退后台本身不取消已明确选择的 10 秒测试；切离设置、进入守护/校准或销毁面板会取消未提交的测试。
- 用户强行停止应用、系统终止进程、后台额度或省电策略都可能让测试无法发出；不承诺系统一定在精确第 10 秒送达。

### 防重复和数据隔离

- 同一时间只处理一个测试/清除操作，双击不发两条。
- 使用独立于 Wear Engine 和手机短振动的进程内 60 秒冷却；页面切换、清除通知不重置。它是手动测试防连点机制，不替代正式腕上通道的持久化冷却。
- SDK 发布或清除超时后，结果记为未知；原 Promise 未完成前不启动新的发布，避免不可取消的系统请求重叠。不自动重试，迟到结果不触发补发。
- 固定专用 ID `29001` 与标签，只更新或清除自己的测试通知，不调用 `cancelAll`，不删除其他通知。
- 测试不写入设置、坐姿采样、提醒次数、会话报告或 Wear Engine 诊断，不消耗正式腕上冷却，不启动相机、不修改校准或分数。
- 已交系统的通知不能保证撤回手环副本；“清除手机测试通知”只负责手机端对应通知，手环副本按设备界面手动处理。

## 5. 手工测试步骤

1. 在手机系统「设置 → 通知和状态栏 → 坐直了」确认允许通知，并检查服务提醒渠道未被关闭。运动健康中的勾选不能替代这个系统开关。
2. 在「华为运动健康 → 设备 → Band 11 → 消息通知/通知管理」确认坐直了开启且设备在线。用户本次已完成消息通知设置。
3. 保持未开始守护，打开「坐直了 → 设置 → 手机通知同步测试」，点“立即发送一条普通通知”；如有系统通知授权框，按意愿授权。
4. 下拉手机通知中心，确认出现“坐直了 · 手环同步测试”。记录“手机有 / 没有”，不要仅凭页面成功文案判断。
5. 若手机通知出现但手环未提醒，等待独立冷却结束，点“10秒后发送，请随后锁屏”，看到安排提示后锁屏，戴好手环并等待约 10 秒。
6. 分别记录：手机通知是否出现、手环是否显示、是否感觉到振动。结果可为“收到并振动”“只收到通知”“没收到”，不能由程序自动代填。
7. 需要时点“清除手机测试通知”；手环上的测试副本自行清除。无需开启上方 Wear Engine 腕上提醒开关，无需填写任何占位 Client ID。

### 结果判读

| 现象 | 意义与排查方向 |
| --- | --- |
| 手机通知中心没有测试通知 | 先检查坐直了的系统通知权限、服务提醒渠道及页面错误提示；尚不能判断手环同步有问题 |
| 手机有，手环没有 | 检查运动健康在线连接、坐直了同步开关、仅熄屏提醒策略、手环佩戴/勿扰/睡眠设置；这些设置由用户检查，不由应用强改 |
| 手环显示但不振动 | 同步显示已成立，振动仍受手环设置和设备策略影响；不等于获得马达控制能力 |
| 手环显示且振动 | 仅证明当前环境下这条普通通知成功同步，仍不证明 Wear Engine 能力已批准或正式低分链路已验收 |
| 延迟测试提示额度不足或超时 | 没有自动重试；可等恢复后手动用立即发送，或重新安排一次锁屏测试 |

普通通知同步不保证只发到本次 Band 11，其他已配置同步的穿戴设备也可能收到；不要把测试内容换成敏感数据。

## 6. 检查命令与验证边界

```sh
node scripts/verify-notification-sync-test.cjs
node scripts/verify-wearable-reminder.cjs
node scripts/verify-reminder-integration.cjs d73d591
node scripts/verify-low-score.cjs
node scripts/verify-reminder-feedback.cjs
node scripts/verify-edge-light.cjs
node scripts/verify-appearance.cjs
node scripts/verify-mouth-source.cjs
node scripts/verify-skeleton.cjs
devecocli check lint entry/src/main/ets
devecocli build
devecocli run --skip-build --device 192.168.31.22:41813
```

### 本次实际检查结果

| 项目 | 结果与证据边界 |
| --- | --- |
| 新增普通通知离线回归 | `node scripts/verify-notification-sync-test.cjs`：26组通过；`node --check`语法检查通过，不调用设备 |
| 原有回归 | 八项全部重跑通过，包含腕上35组、低分规则14组、手机反馈20组、10,080次评分对比、光效24组、外观7组及嘴部/骨骼测试 |
| lint | `devecocli check lint entry/src/main/ets`：0错误20项既有警告，新增普通通知文件未增加lint问题 |
| 完整SDK构建 | `devecocli build`：实际执行CompileArkTS、打包与签名成功；保留2条既有浮窗警告 |
| MCP快速检查 | 新模型/面板无诊断，Index仅既有未使用项；新服务收到错位的Error/BusinessError诊断，与完整SDK编译不一致，未将该文件的快速检查记为通过 |
| 安装启动 | 指定Mate 70 Air `192.168.31.22:41813`覆盖安装成功；首次因锁屏启动失败，用户解锁后重新安装并启动成功，未关闭开发者模式 |
| 手环真实结果 | 用户亲自点坐直了“10秒后发送”，并明确确认手环“显示并振动”；不是由API成功、QQ测试或自动化工具推断 |
| 未覆盖 | 立即发送的手环表现、精确10秒硬件送达时间、所有勿扰/省电/固件条件、长期功耗、正式守护闭环与Wear Engine通道均不扩大为已通过 |
| Git | 未暂存、提交或推送；本机签名与原始截图不改写 |

本次没有运行UI自动验证或截图工具，也没有自动点击真实通知发送。测试由用户在真机操作并反馈；Wear Engine审批、能力查询及正式守护验收仍未完成。

## 7. 官方依据

已通过 `devecocli docs search` / `devecocli docs read` 核对以下本地官方文档：

- 普通文本通知发布：`开发指南/Notification_Kit_用户通知服务/发布通知/发布文本类型通知/text-notification`。
- 通知查询、授权、服务提醒渠道、发布及按 ID/标签取消：`API参考/Notification_Kit_用户通知服务/ArkTS_API/ohos_notificationManager_NotificationManager模块_/js-apis-notificationmanager`。
- 通知请求结构：`API参考/Notification_Kit_用户通知服务/ArkTS_API/notification/NotificationRequest/js-apis-inner-notification-notificationrequest`。
- 短时后台任务：`API参考/Background_Tasks_Kit_后台任务开发服务/ArkTS_API/ohos_resourceschedule_backgroundTaskManager_后台任务管理_/js-apis-resourceschedule-backgroundtaskmanager`。
- Wear Engine 仍需审批：`开发指南/硬件/Wear_Engine_Kit_穿戴服务/手机侧应用开发/接入准备/申请接入Wear_Engine服务/wearengine_apply` 与 `wearengine_faq-3`。

这些文档说明 API 与服务前提，不是对 Band 11 所有固件或运动健康同步行为的兼容性承诺。审批通过后，原 Wear Engine 通道仍按 [WearableReminder.md](WearableReminder.md) 核对身份、配置和能力并另行验收。
