#!/usr/bin/env bash

rbenv local 2.7.6

# pygmentize -S default -f html -a .highlight

bundle exec jekyll build --verbose
