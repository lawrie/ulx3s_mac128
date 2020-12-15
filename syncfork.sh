#!/bin/sh

git remote add upstream https://github.com/lawrie/ulx3s_mac128.git
git fetch upstream
git checkout main
git merge upstream/main

# to change alredy pushed commits to github
# git log
# git rebase -i <commit hex number here>
# git push origin +master
