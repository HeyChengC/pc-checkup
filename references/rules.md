# 分类规则：每一类是什么、清了会怎样

报告里的 `category` 对应下面的条目。对用户说的时候用"对用户怎么说"那一列的说法，不要念类别代号。

## 绿色：清了会自己重建

| category | 是什么 | 在哪 | 清了会怎样 | 对用户怎么说 |
|---|---|---|---|---|
| `temp` | 上次开机之前留下的临时文件 | `%TEMP%` | 没影响。本次开机后产生的不算在内（`extra.recentBytes`），可能有程序在用，重启后再体检才清得掉 | 临时文件 |
| `crash` | 程序崩溃时留下的转储和错误报告 | `%LOCALAPPDATA%\CrashDumps` 等 | 没影响 | 崩溃记录 |
| `browser-cache` | 浏览器缓存的网页图片、脚本 | Chrome / Edge / Brave / Firefox 各配置下的 Cache 类文件夹 | 网页第一次打开慢一点。登录状态、历史、收藏、密码都不在这里，不受影响。浏览器开着时有一部分清不掉 | 浏览器缓存 |
| `app-cache`（绿色） | 桌面软件的网页缓存（Cursor、抖音、网盘等用浏览器内核做的软件） | `%APPDATA%\<软件>\Cache`、`Code Cache`、`GPUCache` 等 | 软件第一次打开慢一点，设置和数据不变 | 某某软件的缓存 |
| `dev-cache` | pip / npm / yarn / uv 下载过的安装包缓存；conda 的包缓存 | `%LOCALAPPDATA%\pip\Cache`、`npm-cache`、`uv\cache` 等 | 已经装好的环境不受影响，下次安装同一个包要重新下载。对应的工具正在运行时脚本会跳过。conda 这一条的大小是下限，实际能清的更多 | 装依赖时留下的下载缓存 |

## 黄色（basic）：清单内，要用户点头

| category | 是什么 | 判断依据 | 清了会怎样 | 对用户怎么说 |
|---|---|---|---|---|
| `recycle-bin` | 回收站 | 所有盘上当前用户的回收站 | **不能恢复**。这是唯一不进隔离区的黄色项 | 回收站里有多少个文件、多大，清空后找不回来 |
| `installer` | 下载文件夹里的旧安装包 | 下载文件夹及其下一层，扩展名是 exe/msi/msix/appx/iso，下载超过 30 天 | 软件装好之后不需要安装包；要重装得重新下载。压缩包、文档、视频不会被列进来 | 旧安装包，列出文件名 |
| `residue` | 疑似卸载残留 | `AppData` 下的文件夹，名字对不上任何已安装的软件、服务、开机启动项，半年内没有文件变动，且不像游戏存档 | **这是按名字猜的**。便携版软件没有安装记录，也会被猜成残留 | "这几个文件夹看起来是已卸载软件留下的，你认一下名字，还在用的告诉我" |
| `app-cache`（黄色） | 剪映 / CapCut 的缓存 | `User Data\Cache` | 特效、素材要重新下载。草稿不在这里，不受影响 | 剪映缓存（草稿不动） |

## 黄色（creator）：大件专项（AI 模型、开发依赖、渲染帧），点名才清

| category | 是什么 | 判断依据 | 清了会怎样 | 对用户怎么说 |
|---|---|---|---|---|
| `model-cache` | AI 模型缓存：HuggingFace（按模型分条）、PyTorch、Whisper、ModelScope、抠图模型、OCR 模型、Ollama、LM Studio | 各工具的默认缓存目录 | 下次用到会重新下载，大模型要等很久、费流量。还在用的别清 | 模型名、大小、最后使用日期。建议只清很久没用的 |
| `duplicate` | 同一个模型文件存了两份 | 大于 200 MB、大小相同、首尾各 1 MB 内容相同。`extra.sameAs` 是保留的那一份 | 读这一份的那个程序下次要重新下载。两个程序各用各的目录时，清掉一份并不能让它们共用 | "这个模型在两个地方各有一份"，说明各在哪个工具的目录里 |
| `browser-runtime` | Playwright 旧版本的浏览器、Puppeteer 的浏览器 | Playwright 同一种浏览器有多个版本时，列出不是最新的那些 | 旧项目再跑时会提示重新安装（`npx playwright install`） | 自动化用的浏览器，旧版本 |
| `other-cache` | `~/.cache` 里认不出主人的大文件夹 | 大于 200 MB，不属于上面任何一类 | 按惯例是缓存，但不知道是哪个工具的，可能要重新下载 | 说出文件夹名，请用户判断 |
| `node-modules` | 旧项目的 node_modules | 项目根目录的文件超过 90 天没改动，大于 100 MB | `npm install` 可以装回来，要联网、花几分钟。近期动过的项目不列，只在 `notTouched.activeProjects` 里计数 | 哪个项目、多大、最后改动日期 |
| `venv` | 旧的 Python 虚拟环境 | 文件夹里有 `pyvenv.cfg`，超过 90 天没装过东西，大于 100 MB | 要按项目的依赖清单重建。带 GPU 版 PyTorch 的环境重建很慢 | 同上 |
| `frames` | 渲染出来的帧序列 | 一个文件夹里 100 张以上、同一前缀、编号连续的图片，大于 100 MB。相机和手机的命名（IMG_、DSC 等）不算 | 成片已经导出就没用了；还没导出、还要改的别清，否则要重新渲染。`extra.stale` 为真表示超过 90 天没动 | 哪个项目的帧、多少张、多大、最后渲染日期。先问这条片子交付了没有 |

## 报告里只说明、不清理的部分（`notTouched`）

| 字段 | 内容 | 对用户怎么说 |
|---|---|---|
| `system` | Windows 临时目录、更新下载缓存、旧版 Windows、休眠文件、页面文件、Windows Installer | 前三项请用户到"设置 > 系统 > 存储 > 临时文件"里自己勾选清理。Installer 和页面文件不能动 |
| `personalApps` | 微信、QQ、飞书、钉钉的数据，剪映草稿 | 属于个人资料，不动。占地大时建议用软件自带的存储管理，或者把文件存储位置改到别的盘 |
| `protectedFolders` | 按原因汇总的受保护文件夹：`games` 游戏、`chat` 聊天、`personal` 个人文件夹、`installed-app` 已安装的软件、`ai-tools` AI 工具数据、`version-control` 代码仓库、`credentials` 密钥、`user-protected` 用户指定 | 各占多少，一句话说明没动 |
| `activeProjects` | 近期还在用的项目的 node_modules 和虚拟环境 | 还在用，没列进清单 |
| `tempInUseBytes` | 本次开机后产生的临时文件 | 重启电脑后再体检可以多清这么多 |
| `identicalFilesInfoOnly`（顶层字段） | 内容相同的大文件（视频、压缩包等） | 只提醒有重复，不建议清哪一份，其中往往有一份是原始素材 |

`droppedByGuard` 是扫描时被保护规则拦下、没进清单的路径，用来排查，不用念给用户。

## 清理结果里的状态

| status | 意思 |
|---|---|
| `done` | 全部完成 |
| `partial` | 清了一部分，`keptInUse` 是因为被占用留下的文件数 |
| `skipped` | 没动。原因在下面一行：`protected:*` 被保护规则拦下；`changed-since-the-scan` 体检之后又有新文件写入，说明有人在用；`tool-is-running-now` 对应的工具正在运行；`could-not-move` 文件夹被占用或在另一个盘上 |
| `failed` | 出错，附错误信息 |

## 脚本用不了时的只读位置表

只用来查大小、列清单，不要据此自己写删除命令。

- 临时文件：`%TEMP%`
- 浏览器缓存：`%LOCALAPPDATA%\Google\Chrome\User Data\<配置>\Cache`、`Code Cache`；Edge 在 `%LOCALAPPDATA%\Microsoft\Edge\User Data` 下同样的位置
- 下载缓存：`%LOCALAPPDATA%\pip\Cache`、`%LOCALAPPDATA%\npm-cache`、`%LOCALAPPDATA%\uv\cache`
- 模型：`%USERPROFILE%\.cache\huggingface\hub`、`.cache\torch`、`.cache\whisper`、`.u2net`、`.ollama\models`
- 无头浏览器：`%LOCALAPPDATA%\ms-playwright`、`%USERPROFILE%\.cache\puppeteer`
- 旧安装包：下载文件夹里的 exe / msi / iso
- 回收站：各盘的 `$Recycle.Bin`
