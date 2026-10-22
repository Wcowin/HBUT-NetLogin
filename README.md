# HBUT-NetLogin

湖北工业大学（HBUT）校园网自动登录脚本 · Windows PowerShell

开机自动登录 `iHBUT` 无线网络，掉线自动重连，配置一次即可长期使用。

## 功能

- **开机自动登录**：登录 Windows 后自动完成校园网认证
- **掉线自动恢复**：每 5 分钟巡检一次，睡眠唤醒、WiFi 断连、被踢下线都能自动重新登录
- **自动连接 WiFi**：当前没连 `iHBUT` 时自动切回（若已保存该 WiFi）
- **不打扰**：正在用手机热点等其它可用网络时，脚本直接退出，不会强行切换
- **不重复登录**：已在线时只发一个请求就结束（约 1 秒）
- **双保险取参**：优先从门户 302 跳转中解析真实 `queryString`；解析不到时用本机 IP/MAC 现场构造
- **日志自动轮转**：超过 200KB 只保留最近 300 行

## 环境要求

- Windows 10 / 11
- PowerShell 5.1 或更高（系统自带）
- 已连接过一次 `iHBUT` 并保存了该 WiFi 配置
- 首次安装需要管理员权限（会弹 UAC）

## 快速开始

```powershell
# 1. 获取代码
git clone https://github.com/Wcowin/HBUT-NetLogin.git
cd HBUT-NetLogin

# 2. 配置账号密码
Copy-Item config.example.ps1 config.ps1
notepad config.ps1        # 填入学号和密码

# 3. 安装自启（会弹 UAC，点"是"）
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

# 4. 立即测试一次
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -RunNow
```

日志文件 `login.log` 出现 `login OK` 或 `already online` 即表示成功：

```powershell
Get-Content .\login.log -Tail 10
```

## 配置项

`config.ps1`（已被 `.gitignore` 排除，不会上传）：

| 变量 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `$Account` | 是 | - | 学号 |
| `$Password` | 是 | - | 校园网密码 |
| `$Service` | 否 | `LT` | 运营商：`LT` 联通 / `YD` 移动 / `DX` 电信 / `default` 校园网 |
| `$WlanSsid` | 否 | `iHBUT` | 校园 WiFi 名称 |
| `$WlanAcName` | 否 | `logic` | 认证设备名，一般不用改 |
| `$NasIp` | 否 | `10.253.0.17` | NAS 地址，一般不用改 |

其余运行参数通过命令行传入，例如：

```powershell
.\login.ps1 -Force        # 强制重新登录（忽略在线状态）
.\login.ps1 -Poll         # 巡检模式：等待时间更短，用于定时任务
.\login.ps1 -NoWifi       # 只用有线，不自动切换 WiFi
```

## 手动操作

```powershell
# 立即重新登录一次
powershell -NoProfile -ExecutionPolicy Bypass -File .\login.ps1 -Force

# 手动触发一次巡检任务（模拟定时任务）
schtasks /run /tn "CampusNetAutoLoginPoll"

# 查看任务状态
Get-ScheduledTask -TaskName 'CampusNetAutoLogin*' | Select-Object TaskName, State
```

桌面还会生成 `CampusNetLogin.lnk`，双击即可立即登录。

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

会删除两个计划任务和启动文件夹中的启动项（桌面快捷方式可自行删除）。

## 工作原理

1. 探测门户 `http://172.16.54.18/eportal/` 是否可达，不可达则先尝试连回 `iHBUT`
2. 访问一个 HTTP 站点（如 `http://www.msftconnecttest.com/redirect`），未认证时会被强制门户拦截并 302 跳转到
   `http://172.16.54.18/eportal/index.jsp?wlanuserip=...&wlanacname=...&nasip=...&wlanparameter=<MAC>&...`
3. 从跳转地址里取出 `queryString`（拿不到则用本机 IP + 网卡 MAC + AC 参数自行拼接）
4. 请求认证接口：
   ```
   GET /eportal/InterFace.do?method=login
       &userId=<学号>&password=<密码>&service=<运营商>
       &queryString=<上一步的字符串>&passwordEncrypt=false
   ```
5. 调用 `method=getOnlineUserInfo` 复核是否真的在线，失败按间隔重试

> 该门户的登录接口本身要求 `passwordEncrypt=false` 明文提交密码，脚本未做额外加密，密码仅在校园网内网传输。请勿在公共网络中使用。

## 计划任务

| 任务名 | 触发条件 | 作用 |
|---|---|---|
| `CampusNetAutoLogin` | Windows 登录后 20 秒 | 完整登录流程，可等待网络就绪（最长 180 秒） |
| `CampusNetAutoLoginPoll` | 每 5 分钟 | 短巡检，掉线后自动重连 |

设置项：使用电池也运行、失败自动重启 3 次（间隔 1 分钟）、同一时间只跑一个实例。

巡检频率想改成 10 分钟，修改 `install.ps1` 中 `-RepetitionInterval (New-TimeSpan -Minutes 5)` 后重新运行安装即可。

## 常见问题

**Q: 提示 `WEB认证设备未注册`？**
认证网关参数与预期不一致。用浏览器打开任意 HTTP 网站，复制跳转后地址栏中 `eportal/index.jsp?` 后面的内容，检查 `wlanacname` 和 `nasip` 的值，然后修改 `config.ps1` 中对应的 `$WlanAcName` / `$NasIp`。

**Q: 提示 `用户名或密码错误`？**
检查 `config.ps1` 中的学号和密码；默认初始密码通常是身份证后 8 位，可在[校园网自助服务平台](https://172.16.54.17:8443/selfservice/)修改。

**Q: 没有管理员权限？**
`install.ps1` 会自动回退到「启动」文件夹方式（无需管理员），只是少了"每 5 分钟巡检"的能力。

**Q: 换了密码怎么办？**
修改 `config.ps1` 中的 `$Password`，无需重新安装。

**Q: 只用有线，不想自动切 WiFi？**
运行 `.\login.ps1 -NoWifi`，或修改计划任务参数加上 `-NoWifi`。

**Q: 校园网限速/多设备限制？**
脚本只登录当前这一台设备，不会影响你账号下其它已登录设备。

## 隐私说明

- `config.ps1`（账号密码）与 `*.log` 均已写入 `.gitignore`，**不会被提交**
- 提交前可用以下命令自查是否误带个人信息：

```powershell
git status --porcelain
Select-String -Path *.ps1,*.md -Pattern '10\.\d+\.\d+\.\d+','([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}'
```

## 免责声明

本项目仅用于个人设备免去每次手动登录的重复操作，不包含任何绕过认证、破解或共享账号的功能。使用前请遵守湖北工业大学校园网管理规定，因使用不当造成的一切后果由使用者自行承担。

## License

[MIT](LICENSE)
