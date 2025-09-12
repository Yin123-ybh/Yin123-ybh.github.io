#!/bin/bash

cd ~/my-blog || exit 1
hugo || exit 1
cd public || exit 1

git add .
git commit -m "Update site $(date '+%Y-%m-%d %H:%M:%S')"
git push -u origin main -f

echo "Hugo 博客已成功部署！"

