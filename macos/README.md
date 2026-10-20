# Sist for macOS

参照 [sist2](../README.md) 的框架思路重新实现的 macOS 原生本地文件全文搜索应用：SwiftUI 界面，PDFKit / Vision / AVFoundation / QuickLook 等系统框架做解析，SQLite FTS5（GRDB）做索引，`sist-worker` 子进程隔离解析器崩溃，FSEvents 自动增量更新，中文子串可直接搜索。

设计说明见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 环境要求

- macOS 14 Sonoma 或更新
- Xcode 16 或更新（Swift 6 工具链）

## 运行

```bash
cd macos
swift run SistApp          # 直接运行界面（找不到 sist-worker 时退回进程内解析）
```

或者用 Xcode 打开 `macos/Package.swift`，选择 `SistApp` scheme 运行。调试界面时建议先 `swift build --product sist-worker`，这样扫描会走子进程。

打包成可分发的 `.app`：

```bash
scripts/make-app.sh                                   # 本机 ad-hoc 签名，产物在 build/Sist.app
SIGN_IDENTITY="Developer ID Application: 姓名 (TEAMID)" \
BUNDLE_ID=com.yourname.sist NOTARY_PROFILE=notary \
scripts/make-app.sh                                   # Developer ID 签名 + 公证
```

## 命令行

`sist` 与 App 共用同一个索引库（`~/Library/Application Support/Sist/catalog.sqlite`）：

```bash
swift build -c release           # 构建 sist 和 sist-worker
.build/release/sist scan ~/Documents --ocr --ocr-languages zh-Hans,en-US
.build/release/sist search 季度报告 --kind document --sort modifiedNewest
.build/release/sist search 'name:合同 -草稿' --json
.build/release/sist sources
.build/release/sist stats --source 1
```

再次执行 `scan` 即增量更新：只解析新增和变化的文件，删除已不存在的文件。

## 测试

```bash
swift test
```

核心引擎不依赖 Apple 专有框架，也能在 Linux 上编译测试（需要 `libsqlite3-dev`、`libarchive-dev`）。macOS 上 libarchive 是系统自带的，不需要安装任何东西。

测试用的压缩包和 xls/ppt 样例在 `Tests/SistExtractorsTests/Fixtures`，由其中的 `generate.py` 生成（需要 rar、bsdtar、LibreOffice）。

## 目录结构

```
macos/
├── Package.swift
├── Sources/
│   ├── SistCore/         模型、MIME、中文单字索引、查询解析、高亮、遍历、忽略规则、worker 协议
│   ├── SistStore/        catalog 数据库：结构、增量写入、搜索、统计
│   ├── SistExtractors/   各格式解析器；Apple/ 下为仅 macOS 的 PDFKit、ImageIO、Vision、AVFoundation…
│   ├── SistScan/         扫描调度、进程内/子进程解析池
│   ├── sist-worker/      解析子进程
│   └── sist/             命令行工具
├── App/
│   ├── Sources/          SwiftUI 应用
│   └── Info.plist        打包用（用途说明等）
├── Tests/
├── scripts/make-app.sh   构建、签名、公证
└── docs/ARCHITECTURE.md  架构设计
```
