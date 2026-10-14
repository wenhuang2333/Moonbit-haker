# GitHub 仓库管理

## 仓库信息
- **仓库地址**：`git@github.com:wenhuang2333/Moonbit-haker.git`（SSH 协议）
- **网页地址**：https://github.com/wenhuang2333/Moonbit-haker
- **GitHub 用户名**：`wenhuang2333`
- **默认分支**：`main`
- **认证方式**：SSH 密钥（本机 `~/.ssh/id_ed25519`，指纹 `SHA256:w3CxzIIVBCTm3rcyvSFcwePPGgh7JjJONWwrDQAD3Ro`，与 GitHub 账户绑定）

## 上传要求（每次推送前必须遵守）
1. **先测试后上传**：完成编码后必须先运行/构建测试，无错误才允许 commit & push。
2. **临时脚本不入库**：一次性脚本只放 `test/`；若属临时性质，推送前确认是否需要排除。
3. **目录约定**：代码进 `code/`，静态资源进 `static/`，文档进 `marks/`（本文件按用户要求放根目录）。
4. **提交信息**：英文祈使句，简短明确，如 `Add moonbit http example`。

## 上传步骤
```bash
# 1. 查看改动
git status

# 2. 暂存（确认没有敏感文件混入）
git add <文件或目录>

# 3. 提交
git commit -m "简要描述改动"

# 4. 推送
git push origin main
```

## 敏感信息红线（严禁上传）
以下内容**绝对不能** commit 或 push，即使 `.gitignore` 已拦截也要人工确认：
- SSH 私钥：`id_ed25519`、`id_rsa` 等任何私钥文件（本机位于 `~/.ssh/`，正常不会进入仓库）
- API Key / Token / 密码（包括环境变量文件 `.env`）
- 含密钥的配置文件、日志、截图

> 说明：密钥**指纹**（`SHA256:...`）是公开信息，可以出现在文档里；**私钥本体**绝不入库。
> 若不慎推送了敏感信息：立即吊销/更换该密钥或 Token，而不是仅删除文件（历史记录仍可追溯）。

## 常用管理命令
```bash
git remote -v                     # 查看远程仓库
git pull origin main              # 拉取最新代码
git log --oneline -10             # 查看最近提交
gh repo view --web                # 浏览器打开仓库（需 gh 已登录）
```
