#!/bin/bash

# 设置错误时退出
set -e

# 进入博客目录
cd /Users/yin/my-blog

# 构建 Hugo 站点
echo "正在构建 Hugo 站点..."
hugo --minify

# 复制所有构建文件到根目录
echo "正在复制文件到根目录..."
cp -r public/* .

# 添加所有更改
echo "正在添加文件到 Git..."
git add .

# 提交更改
echo "正在提交更改..."
git commit -m "Update site $(date '+%Y-%m-%d %H:%M:%S')"

# 推送到 master 分支
echo "正在推送到 GitHub..."
git push origin master

echo "Hugo 博客已成功部署！"
echo "请访问：https://yin123-ybh.github.io/"
