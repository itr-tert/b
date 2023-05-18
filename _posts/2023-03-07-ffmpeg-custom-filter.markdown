---
layout: post
title:  "ffmpeg: 任意の画像加工コマンドで動画を加工する"
date: 2023-03-07
toc: true
---

----

- タイトル: あるいは: `ffmpeg`で大量の中間 png files を作らずに`imagemagick`などのコマンドによる静止画単位での加工をする方法。
- `ffmpeg`で`fifo`を入力や出力に使う場合に注意しなければならないこと。

このページで説明することは
- `ffmpeg`で無限に入力して、無限に出力する映像を`imagemagick`などで加工する
- `ffmpeg`に任意のフレーム補間コマンドを噛ませる

などに応用できるかも知れません。

このページで説明する方法ではUnix互換環境を想定している。
`WSL`(Windows Subsystem for Linux)や`git bash`では、しばしば`fifo`が期待通りの動きをしなかったという噂あり。
`Windows`での動作確認はしていない。

## はじめに

`ffmpeg`には実行時に custom video filter を追加する方法はありません(ffmpeg ver 5.1.1時点)。
> コードを書いて、自分でビルドする必要あり。
> [https://github.com/FFmpeg/FFmpeg/blob/master/doc/writing_filters.txt](https://github.com/FFmpeg/FFmpeg/blob/master/doc/writing_filters.txt)

`imagemagick`などのコマンドを使って動画の全フレームを加工したい場合は

- 全フレームを`png`に書き出す
- `png`を加工する
- `ffmpeg`で再び動画に戻す

大量の一時`png`が作られることになる。
なんとなくそれがいやだから回避する。

出来る人にとっては簡単な問題なせいか、2023-03-07時点では随時変換の実装例がない。

## 概要

以下3つを並列実行する。
- step 1:
  - `ffmpeg`で`input.mp4`を`rawvideo`として`fifoA`へ書き込み
- step 2:
  - `fifoA`を読み込みとして`open`
  - ループ
    - `ffmpeg`で`fifoA`から1フレーム分だけ読み取って`png`へ
	- もし`png`が`0`サイズなら`ループ終了`
    - `png`を加工する
    - `ffmpeg`で`png`を`rawvideo`として`fifoB`へ書き込み
  - `fifoA`を`close`
- step 3:
  - `ffmpeg`で`fifoB`を`output.mp4`へ

## 実装例

実装例を示すためのコードであるため実際に使うなら改変が必要。

{% highlight bash linenos %}
#!/usr/bin/env bash

#
# bash -version: GNU bash, version 5.2.2(1)-release (x86_64-pc-linux-gnu)
#
# ffmpeg version 5.1.1-1ubuntu1 Copyright (c) 2000-2022 the FFmpeg developers
#
# convert -version: Version: ImageMagick 6.9.11-60 Q16 x86_64 2021-01-25 https://imagemagick.org
#
# mkfifo (GNU coreutils) 8.32
# mktemp (GNU coreutils) 8.32
#

function main() {
    ## force_clean

    filter_each_frames 'input.mp4'  'output.mp4'
}


function filter_image() {
    local dest="$(mktemp --suffix=.ffmpeg.png)"
    # convert command of imagemagick
    convert "$1" -liquid-rescale '200x150!'  "${dest}" &&
        mv "${dest}" "$1"
}


function force_clean() {
    ps xa | grep -e ' ffmpeg.*-nostdin\| cat.*ffmpeg' | sed -e '/ grep /d'

    kill -9 $(ps xa |
                  grep -e ' ffmpeg.*-nostdin\| cat.*ffmpeg' |
                  sed -e '/ grep /d' |
                  cut -d ' ' -f 1)

    rm -rf /tmp/tmp.*.ffmpeg*
}


function get_video_whrp() {
    # whrp: Width, Height, (frame)Rate, Pixel-format
    
    ((local != 0)) && echo "local ${prefix}width ${prefix}height ${prefix}r_frame_rate ${prefix}pix_fmt ${prefix}nb_read_frames ${prefix}exit_code"

    if [[ $1 == *.png || $1 == *.jpg  ]]; then
        {
            ffprobe -select_streams v:0  -v error  -show_entries stream=width,height,pix_fmt \
                    -of default=noprint_wrappers=1  -i "$1"
            local exit_code=$?
            echo exit_code=${exit_code}
        } | sed -e s/^/"${prefix}"/
    else
        {
            ffprobe -select_streams v:0  -v error  -count_frames \
                    -show_entries stream=width,height,r_frame_rate,pix_fmt,nb_read_frames \
                    -of default=noprint_wrappers=1 -i "$1"
            local exit_code=$?
            echo exit_code=${exit_code}
        } | sed -e s/^/"${prefix}"/
    fi
}


function make_temp_fifo() {
    local temp="$(mktemp --dry-run --suffix=.ffmpeg)"
    mkfifo -m 600  "${temp}"  &&  echo "${temp}"
}


function filter_each_frames() {

    local input="$1"
    local output="$2"
    local log_isolation=0  # switch. 0 or 1

    source <(local=1 prefix='' get_video_whrp "${input}")

    echo "nb_read_frames[${nb_read_frames}] ${width}x${height}"
    ((exit_code==0)) || return 1

    local fifo_s1_to_s2="$(make_temp_fifo)"
    local fifo_s2_to_s3="$(make_temp_fifo)"
    local dest_whrp="$(make_temp_fifo)"
    local png="$(mktemp --suffix=.ffmpeg.png)"

    # see bash(1)/REDIRECTION/Moving File Descriptors
    exec 101>& 1  # FD[101]: Bypass to stdout for logging

    function log_redirect() {
        if ((log_isolation==1)); then
            local d="$(dirname "$1")"
            test '.' '!=' "${d}" && {
                mkdir -p "${d}"
                mkfifo "$1"
            } &> /dev/null

            cat  &> "$1" ;

            echo end "$1" 1>& 101

            rm "$1"
        else
            cat
        fi
    }

    function step1() {
        # AV_LOG_FORCE_COLOR=1
        ffmpeg  -i "${input}"  -f rawvideo  -pix_fmt rgba  "${fifo_s1_to_s2}"  -y  -nostdin

        echo step1 done 1>& 101
    }

    function step2() {

        # see bash(1)/REDIRECTION/Redirecting Input
        # see open(2)/NOTES/FIFOs: ...blocks until the other end is also opened...
        # Open fifo_s1_to_s2 in read mode and handle as FD 101
        exec 110< "${fifo_s1_to_s2}"

        local count=0
        local first=1

        # while ((count < nb_read_frames)); do
        while true; do
            ((++count))

            echo -n > "${png}"
            # 0<&110 : Redirect ffmpeg standard input to 110(fifo_s1_to_s2).
            ffmpeg  -nostdin  \
                    -f rawvideo  -pix_fmt rgba  -video_size "${width}x${height}"  -i pipe:-  \
                    -frames:v 1  "${png}" -y  0<& 110 || {
                break
            }
            # ffmpeg does not error even if rawvideo input is 0 size.
            test -s "${png}" || break

            filter_image "${png}"

            ((first != 0)) && {
                first=0
                local=1 prefix='dest_' get_video_whrp "${png}"  | tee >(cat  1>&101) > "${dest_whrp}"
                # see bash(1)/REDIRECTION/Redirecting Output
                # Open fifo_s3_to_s3 in write mode and handle as FD 121
                exec 121> "${fifo_s2_to_s3}"
            }

            # output to 121(fifo_s2_to_s3)
            ffmpeg -nostdin  \
                   -i "${png}" -frames:v 1  \
                   -pix_fmt rgba  -f rawvideo  >(cat  1>& 121) -y || {
                break
            }
        done

        # see bash(1)/REDIRECTION/Duplicating File Descriptors: 
        #       ...If word evaluates to -, file descriptor n is closed.
        # '<& -', '>& -' mean the same thing
        exec 110<& -  # close fifo_s1_to_s2
        exec 121>& -  # close fifo_s2_to_s3

        echo step2 done 1>& 101
    }

    function step3() {
        source <(cat "${dest_whrp}")

        ffmpeg -nostdin \
               -f rawvideo  -pix_fmt rgba  -video_size "${dest_width}x${dest_height}" \
               -framerate "${r_frame_rate}"  -i pipe:- \
               -pix_fmt "${pix_fmt}"  "${output}"  -y  0< "${fifo_s2_to_s3}"

        echo step3 done 1>& 101
    }

    set -m  # enable job contorl

    step1  2>&1 | log_redirect fifo/fs1 &
    step2  2>&1 | log_redirect fifo/fs2 &
    step3  2>&1 | log_redirect fifo/fs3 &

    wait

    rm -f "${fifo_s1_to_s2}"  "${fifo_s2_to_s3}"  "${dest_whrp}"  "${png}"
}


main "$@"

{% endhighlight %}

### Notes
`force_clean`は強制終了によって残ったゴミの掃除。
不本意なモノが消えたり停止したりするかも知れない。

`log_isolation`変数が`0`の場合は、全ての進捗ログが標準出力と標準エラー出力に混ざって表示される(ごちゃ混ぜに表示される)。
`1`の場合には step1,step2,step3 のログをそれぞれ`fifo/fs1`,`fifo/fs2`,`fifo/fs3`に流し込む。
別の terminal で `cat fifo/fs1`, `cat fifo/fs2`, `cat fifo/fs3`とすることでログの区別が容易になる。

## 解説

上記コードは`bash`で動く`shell script`というもの。
`shell script`が何であるかはここでは説明しない。



### ffmpeg -f rawvideo
rawvideoフォーマットはヘッダーやメタデータを持たない形式。
`1 frame`のサイズは`width * height * pixel_bytes`固定。
`-pix_fmt`と`-pixel_format`は同義。
`-r`と`-framerate`は同義。
`ffmpeg`の入力ファイル前ならば入力ファイルの形式を指定している事になる。
入力ファイルの後ならば出力ファイルの形式を指定している事になる(これらの使用はrawvideoに限った話ではない)。
`-f rawvideo  -pix_fmt rgba  -video_size "400x300"  -framerate 30`
`rawvideo`形式による書き込みには`seek`を必要としない。

### `ffmpeg`で`fifo`に出力する
特に注意することはない。

`fifo`の取り扱いについては別ページへ:
- [FIFO Special File](2023-05-19-fifo.html)
- [bashのFD(file descriptor)操作について](2023-03-13-bash-fd.html#exec-redi-fifo)

> 余談: 一部のフォーマットは書き込み時に`seek`を必要とするため`fifo`への出力に失敗する。

### `ffmpeg`で`fifo`や標準入力から入力する
`fifo`ファイルを指定しての入力はしばしば上手くいかない。
入力ファイルが`fifo`であるということを示す`fifo:`のようなプロトコル指定子も存在しない。
したがって、(`ffmpeg`にストリームがパイプ的性質であることを伝えるために)標準入力を利用する必要がある。

今回のように`fifo`経由で流れてくる複数フレームのrawvideoを1フレームずつ処理する場合、`ffmpeg`との間に`cat`や`tee`や`dd`など他のコマンドを挟んではいけない。
バッファリングにより読み込み過ぎが発生した状態で`ffmpeg`が終了することにより、読み込み過ぎたまま`ffmpeg`に渡らなかった分のデータが消える。

- 下記2つは動作が異なる。前者では読み込み過ぎは発生しない。
- `ffmpeg -nostdin -i pipe:0 -frames:v 1 dest.mp4 < fifo.rawvideo`
- `cat fifo.rawvideo | ffmpeg -nostdin -i pipe:0 -frames:v 1 dest.mp4`

`-nostdin`: インタラクティブコマンドを無効にするオプション。指定しなくてもいいかも？