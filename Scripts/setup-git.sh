#!/bin/zsh
# 克隆后跑一次：启用仓库内 git 钩子（提交信息校验）与提交信息模板。
set -euo pipefail

repo_root=${0:a:h:h}
cd "$repo_root"

git config core.hooksPath .githooks
git config commit.template .gitmessage

print "已启用 .githooks（commit-msg 校验）与 .gitmessage 模板。"
