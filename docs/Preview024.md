# 0.2.4 浮窗与 HarmonyOS 7 界面预览

更新：2026-09-23。版本 0.2.4 / versionCode 1000005，沿用包名与签名身份。
本次范围为窗口交互和 UI，不修改 0.2.3 的检测算法、校准时序、提醒规则或统计口径。

## 界面

- API 26 使用 `Tabs.barFloatingStyle` 和系统沉浸材质；按钮开启原生材质触控光效。普通内容区域不滥用有使用范围限制的系统材质。
- 旧系统隔离 API 26 调用，保留普通底栏、按钮和表面。
- 首页评分改为紧凑环形进度，三项指标等高，保留开始/结束守护和姿态建议；右上角增加浮窗图标入口。
- 统计和设置使用分隔线组织内容，减少嵌套卡片。浮窗设置前置，开发功能保持默认折叠。
- 悬浮底栏下方内容预留 96vp 滚动空间；旧系统为 24vp。字号不随屏宽放大。

## 浮窗

窗口内容包含总分、检测状态、最近采样时间、坐姿/抬头/嘴巴状态和返回入口。
仅在前台守护中、有不超过 15 秒且非未来的有效样本、分数为有限的 0 至 100 数值时展示实时评分和分项状态。
模拟数据继续明确标记；未开启、过期和退后台时不把旧值作为实时结果。

### 当前可安装包

使用应用内子窗口，标题明确标注“应用内”，可拖动、关闭和返回。
标题拖动区域与关闭按钮分开；退出应用时关闭子窗口并停止相机检测。
此模式不是跨应用悬浮球，也不能后台监测坐姿。

### API 26 系统闪控窗

代码支持设备能力检测、用户权限申请、系统窗口尺寸约束、标题栏避让及恢复主窗口。
启动以 `STARTED` 回调为确认依据，不以异步调用返回成功代替显示成功。
处理了启动中取消、退后台取消、重复操作、侧边栏/隐藏状态、错误回调及 10 秒超时。
关闭失败保留窗口状态并允许重试，不假报关闭成功。

当前仍受签名权限阻塞：

```text
ohos.permission.FLOAT_VIEW
availableLevel: system_basic
provisionEnable: true
install failed, code 9568289
install failed due to grant request permissions failed
```

该权限需要签名 Profile 获准，不能只在 manifest 中添加声明。
本轮曾构建带声明的验证包，手机拒绝安装；随后移除新增声明，恢复可安装的应用内窗口版本。
未修改用户签名文件、伪造权限或使用强制授权命令。
后续取得授权 Profile 后，再添加权限声明、覆盖安装并验收授权拒绝/允许、拖动、侧边收纳、恢复及关闭。
即使系统窗口可以跨应用显示，当前业务仍会在退后台时停止相机，不能据此宣称后台实时守护。

## 本轮验证

设备 `5ZGYD25A19000137` 已升级到 API 26，系统返回 `OpenHarmony-7.0.0.105`。
历史 0.2.3 报告中的 API 24 是升级前记录，不代表当前系统。

已通过：

```bash
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/verify-core.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/verify-mouth-source.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/verify-window.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node scripts/verify-harmony-ui.cjs
./scripts/verify-app.sh
```

- 20,160 组评估、2,520 次提醒决策及原有嘴部、校准和生命周期回归通过。
- 22 个算法/原生/采样源文件和 15 个核心页面方法与 `e0806ab` 一致。
- 窗口模拟 SDK 测试覆盖权限、尺寸、避让、取消、错误、超时、关闭失败和返回，不代表跨应用真机通过。
- API 26 UI 分支、旧系统隔离、底部内容预留和过期浮窗读数检查通过。
- signed HAP 构建成功，最终 0.2.4 覆盖安装返回 `install bundle successfully`。
- 用户解锁后启动返回 `start ability successfully`；首页、统计、指南、设置四页已检查。首页开始按钮和姿态建议同屏，绿色按钮文字清晰；设置滚到底后末尾操作完整显示在底栏上方。
- 首页和设置入口均可打开应用内浮窗。标题拖动后布局坐标实际改变；返回按钮关闭浮窗并保留主页面，关闭按钮可单独点击。按 Home 退后台再返回时浮窗已关闭，开关同步为未开启。
- 全程保持未开启守护，没有重新校准或改写个人基线；设置仍为灵敏档、2 秒采样，提示音和振动开启。

尚未通过的验收：

- 未取得系统闪控窗签名权限，未完成原生跨应用窗口真机测试。
- 本轮仅检查当前设备、默认字体的未守护界面和应用内浮窗；其他尺寸、大字体和新材质下守护中/校准中画面仍待补充。
- 未进行新的真人姿态识别、功耗或长时间稳定性测试；不将源码规则未变等同于这些项目通过。

产物：`entry/build/default/outputs/default/entry-default-signed.hap`。
本地检查目录：`artifacts/preview-2026-09-23/`。新版截图为 `024-home.jpeg`、`024-float.jpeg`、
`024-stats.jpeg`、`024-guide.jpeg`、`024-settings.jpeg` 和 `024-settings-bottom.jpeg`；
`024-return.json`、`024-float-closed.json`、`024-float-resumed.json` 留存返回、关闭、退后台后的布局。
此前 `ui-home.jpeg` 是锁屏画面，不作为新版首页验收截图。
构建仍提示 `FLOAT_VIEW` 权限缺失及子窗口背景 API 的手机适配警告；后者为可失败的外观设置，不作为窗口打开成功的前提。

## 获取授权 Profile

此处不是重新生成普通签名，而是让签名 Profile 包含获准的受限权限。

1. 登录 AppGallery Connect，从“开发与服务”进入坐直了项目，在“项目设置”找到“ACL权限申请”。选择包名为 `com.longxin.zuozhile` 的对应应用，查找 `ohos.permission.FLOAT_VIEW`。
2. 若该权限提供试用入口，可先申请临时调试权限。华为公布了 5 天 ACL 试用机制，但尚未核实当前帐号中 FLOAT_VIEW 的开放范围和试用资格；以实际后台为准。正式发布不能依赖临时权限。
3. 获准后在“证书、APP ID和Profile”的 Profile 管理中生成/更新调试 Profile，选择正确应用、原调试证书和测试手机，确认包含所需 ACL，再下载 `.p7b`。
4. 在 DevEco Studio 的 `File > Project Structure > Project > Signing Configs` 中配置新的 Profile。优先沿用原 App ID、证书和 `.p12` 密钥；不要为排查权限问题先卸载应用或随意更换签名身份。具体 Profile/证书匹配在安装前校验。
5. 开发侧恢复 manifest 权限声明并重新构建安装。Profile 获准不等于用户已同意，首次启用闪控窗仍需运行时授权。

若后台没有该权限或试用入口，应通过华为开发者工单确认开放资格，不手工篡改 `.p7b`、不强行提升应用等级。
仅更新自动签名而未加入获准 ACL，不能证明此问题已解决。不要在聊天或 Git 中提交私钥、签名密码或含密钥材料的文件。

申请用途建议：

> 用于坐直了姿态提醒应用。用户主动开启后，通过系统闪控窗展示本机计算的坐姿评分、检测状态和返回主界面入口，用户可随时关闭。图像不保存、不上传；当前离开主界面后检测暂停，窗口明确展示非实时状态。申请用于 API 26 真机功能验证。

后台菜单和试用机制依据[华为 AGC 更新说明](https://developer.huawei.com/consumer/cn/monthly/202512?ha_source=202512yk&ha_sourceId=89000503)。
Profile 和 DevEco 配置参见[签名配置说明](https://developer.huawei.com/consumer/cn/doc/HMSCore-Guides/harmonyos-sdk-config-agc-0000001101459188)、
[申请调试 Profile](https://developer.huawei.com/consumer/cn/doc/app/agc-help-add-debugprofile-0000001914423102)。

## 平台依据

- [系统闪控窗](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/float-view-guide)
- [启用沉浸光感](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-immersive-light-sense-enable)
- [沉浸光感通用能力](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-common-capability)

具体接口、权限等级和支持范围同时核对了本机 API 26 SDK 声明。
