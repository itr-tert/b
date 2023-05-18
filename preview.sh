#!/usr/bin/env bash

rbenv local 2.7.6

# pygmentize -S default -f html -a .highlight

N="itr-tert/note/preview" 

tmux has-session -t "$N" ||
    tmux new-session -d -s "$N" "bundle exec jekyll serve --incremental --verbose $@"

echo tmux ls
tmux ls

echo
echo tmux a -t "$N"
