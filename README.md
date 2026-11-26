# Qwitter for HarmonyOS

Qwitter（趣推，原名 Qyx）是使用 ArkTS、ArkUI、ArkWeb 和鸿蒙关系型数据库 RDB 实现的 X 客户端。

本仓库包含 **0.4.102** 源码。已发布的安装包与更新记录见 [GitHub Releases](https://github.com/llnode/hmos-qwitter/releases)。源码版本与最新 Release 安装包版本可能不同。

## 实现方式

```text
X 官方网页（ArkWeb 登录、读取与提交）
                  ↓
        ArkTS 数据层 / 本地接口
                  ↕
            鸿蒙 RDB 本地缓存
                  ↓
          ArkUI 原生页面与组件
```

- ArkWeb 负责 X 登录及网页会话，网页适配器提取可见数据，并代原生界面提交发帖、回复、互动和设置修改。
- ArkTS 负责数据校验、任务调度、预取、缓存和页面状态；ArkUI 渲染时间线、详情、个人资料、搜索、通知、聊天及设置。
- 首次访问尚无缓存的页面，需要等待 X 网页加载；已有缓存时先显示本地内容，再按页面逻辑同步更新。图片、视频还取决于 X 提供的地址和媒体网络请求。
- 账号相关缓存保存在设备的应用沙箱和 RDB 中；Cookie 与站点存储由 ArkWeb 管理。仓库不包含用户会话、账号数据或签名材料。
- 核心读取和提交依赖 X 网页适配，不需要配置 X 开发者 API Key，也没有配套的用户数据服务器。

## 主要功能

- 独立的推荐 / 关注时间线、分页、浏览位置恢复、新帖提示及手动刷新。
- 原生帖子详情、引用帖、评论与原位展开的楼中楼；发帖、回复与互动操作。
- 个人资料、书签、喜欢和本地浏览记录；原生通知、聊天列表与会话界面。
- 搜索支持热度、最新、用户、视频、图片五个分类，各分类独立缓存；用户结果可打开个人资料。
- 多图浏览、缩放与保存；原生视频播放、画质与倍速，以及支持的 HLS 点播下载和音视频封装。
- 外观、主题色、底栏、应用图标、语言和默认媒体清晰度设置。

X 会因账号、语言、地区及页面实验提供不同内容；网页结构变化也可能使适配失效。功能说明不代表所有账号和设备均已完成验收。`2in1` 已加入设备声明，MateBook 尚未完成完整真机验收。

## 工程目录

| 路径 | 内容 |
| --- | --- |
| `entry/src/main/ets/pages/Index.ets` | 页面入口与任务协调 |
| `entry/src/main/ets/components/` | ArkUI 原生组件 |
| `entry/src/main/ets/data/` | RDB 缓存、媒体预取及偏好设置 |
| `entry/src/main/ets/web/` | 网页桥、本地数据模型、媒体加载与提交逻辑 |
| `entry/src/main/resources/rawfile/` | X 网页适配脚本及语言资源 |
| `entry/src/main/cpp/` | 原生音视频封装模块 |
| `tests/` | 网页适配器、搜索路由与 HLS 解析回归测试 |
| `design/launcher-icons/` | 应用图标 SVG 资源 |

## 构建

需要配置 HarmonyOS API 26 SDK、DevEco 命令行工具及原生 CMake 编译环境。工程使用本地 NAPI 模块 `libqwitter_media.so`。

```sh
ohpm install --all
hvigorw --no-daemon --mode module -p product=default -p module=entry@default assembleHap
```

未签名包输出：

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
```

原应用包名为 `com.cex.qwitter`。安装真机前须使用与包名、证书及目标设备匹配的调试签名；仓库不提供证书或私钥。请在自己的本地环境配置签名，不要提交签名材料。

## 测试

网页适配器测试使用本地合成 HTML，不需要登录 X；TypeScript 仅用于在 Node.js 中测试纯逻辑模块。

```sh
npm ci
npm test
```

自动化测试不能代替真机验收。登录、发帖、回复、通知、私信、媒体播放及相册保存仍需在目标设备检查；发送测试内容会实际提交到 X。
