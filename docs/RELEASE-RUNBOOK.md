# 发布执行清单（Release Runbook）—— 司南

> 来源：v0.3.00 首次发布过程踩过的每一个坑（2026-11-17 ~ 11-19）。
> **每次发布从上往下执行；每条后面括号里是当初踩坑的记录。**
> 上游自己的发布核对表在 [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md)，与本清单互补。

## 0. 环境检查

- [ ] `git push fork` 直连试一次；失败立刻换 `git -c http.proxy=http://127.0.0.1:7890 push fork …`。两次失败别硬试，切换代理开/关换线路（11-19：直连与代理交替故障）
- [ ] 大文件下载（CEF/模型）用**8 段并行 Range**：`redirect_url` 拿签名链接 → 8 条 `curl -r` 并发 → `cat` 拼接 → `tar -tjf` 校验。单连接只有 ~50KB/s（142MB 要 47 分钟），并行约 1 分钟（11-17 实测：单连最差 3KB/s）
- [ ] 中途重启过机器的话 `/tmp` 会被清空——临时脚本用完即移入仓库，或按 OBS-5 的记录重建

## 1. 构建前

- [ ] **版本号三处一致**：`CRA_VERSION`、RELEASE-NOTES 文件名与正文、git tag
- [ ] **`CRA_RELEASE=1` 必须带上**——不带会删掉 SUFeedURL，用户拿到的包完全没有自动更新（v0.3.00 差点中招，11-19 发现）
- [ ] 跨架构构建带齐环境变量：`CRA_ARCH=arm64 CRA_LLAMA_BUILD=$PWD/vendor/llama.cpp/build-arm64 CRA_WHISPER_BUILD=$PWD/vendor/whisper.cpp/build-arm64`（arm64 静态库需先交叉编译：`-DCMAKE_OSX_ARCHITECTURES=arm64 -DGGML_NATIVE=OFF`）
- [ ] 构建后核对 Info.plist 三样：版本号、SUFeedURL（指向 `jerry699/sinan-browser`）、CFBundleDisplayName=司南浏览器
- [ ] `grep -r 'VictorKildahl.*appcast' scripts/` 应无结果（曾把 Intel 更新源指到上游 appcast——用户会升级成上游 Cra，11-19 抓出的大雷）

## 2. 图标与品牌资源

- [ ] 新图标放进 **`resources/AppIcon.icns`**（build.sh 实际拷贝的路径；放 resources/app-icons/ 子目录不生效——0.2.02 踩坑，靠安装包与源文件的 sha256 对比抓出）
- [ ] AppIconManager 的用户选择（UserDefaults `appIcon`）会在每次启动覆盖 bundle 图标——验证新图标前 `defaults delete dk.kildahl.cra appIcon`
- [ ] 图标缓存三层全清：`rm -rf /private/var/folders/*/…/C/com.apple.iconservices` + `killall Dock Finder` + `lsregister -f` + `touch` 应用包
- [ ] **Spotlight 元数据跟随 bundle 文件名**——plist 改名不够，应用文件必须叫 司南.app（Launchpad/Dock 名称顽固时 force-with-lease 推 main 重建索引）

## 3. 打包与资产

- [ ] **发布资产一律 ASCII 文件名**（`Sinan-Intel.zip` 等）。gh CLI 会把中文文件名损坏成 `default.zip`，全站 404（v0.3.00 首传踩坑，删除重传）
- [ ] 主页/README 的下载链接与发布资产名**逐字一致**——改名后同步改 gh-pages 的 index.html（11-19 踩坑，主页链接 404）
- [ ] `scripts/package.sh` 产物名已对齐（司南→Sinan）；跨架构两轮打包后 **SHA256SUMS.txt 必须重算**
- [ ] 清掉 dist/ 里历史命名残留（Cra*.zip 等旧文件会混进校验和）
- [ ] 安装到 /Applications 用 `ditto` 不用 `cp -R`——进程未退净时 cp 批量 "Operation not permitted"（11-18 踩坑）；先 `pkill -9` 并确认 `pgrep` 清零
- [ ] dist/ 里 appcast 的 `sparkle:version` 必须大于已发布版本（CFBundleVersion 时间戳天然递增，但要核对）

## 4. 签名与更新源

- [ ] **签名账户是 `cra-fork`**（不是默认 cra）：`SPARKLE_ACCOUNT=cra-fork scripts/appcast.sh …`。参数缺失会静默写出旧 appcast——生成后 grep 核对内容版本号（11-19 踩坑）
- [ ] appcast.sh 的 URL 默认已指向 sinan-browser；**任何 CRA_UPDATE_URL 覆盖都不得指向上游**（v0.3.00 前把 Intel SUFeedURL 指到上游 appcast——用户会升级成上游 Cra）
- [ ] 双架构 appcast 分开生成：Intel 走 `appcast-intel.xml`（build.sh 给 x86_64 设置的通道），ARM 走 `appcast.xml`
- [ ] 发布资产 8 件套：两 zip、两 dmg、两 appcast、SHA256SUMS.txt、RELEASE-NOTES

## 5. 发布与发布后

- [ ] `gh release create` 后 `gh release view` 核对资产名与大小
- [ ] 发布后 30 分钟验证 `releases/latest/download/<资产名>` 302→200（11-19：主页链接 404 教训）
- [ ] 旧用户从 Cra.app 原地升级：文件名保持 Cra.app 属正常——发布说明保留「手动重装换名」提示
- [ ] 数据目录迁移（Cra→司南）失败时回退旧目录并记日志——发布后第一天关注 cra.log 的 `migrated` 行
- [ ] 大版本发布后 48 小时盯 Issues 和模型下载失败反馈（新手第一坎：设置 ▸ Max 下载）

## 6. 本机调试注意

- [ ] 覆盖安装：`pkill -9` 清零进程后用 `ditto`
- [ ] Launchpad 名称顽固：`defaults write com.apple.dock ResetLaunchPadFolders -bool true; killall Dock`
- [ ] 非 release 构建没有 SUFeedURL 键属正常（dev 不自动更新）
- [ ] `log show` 谓词查询在本机经常返回 0 行——诊断走 CDP 抓包（`--remote-debugging-port=9222`）或 cra.log；CDP 事件名是 `requestWillBeSentExtraInfo`（参数 `requestId`，不是 associatedRequestId）
- [ ] `NSLog` 写 stderr + 统一日志，**不写 cra.log**；stderr 要重定向到文件才有据可查

## 7. 面向国内用户的已知边界（写进发布说明）

- [ ] 阿里系站点不要叠加 uBlock 等第三方拦截器（规则会拦支付风控脚本，毒化设备档案 → 拒单）；内置拦截器已做支付豁免
- [ ] huggingface 直连不可达属正常（自动降级 ModelScope/镜像）
- [ ] GitHub Releases 在国内时通时不通——Gitee 镜像上线后加进下载渠道
