#!/bin/zsh
# 1.1 store — contact sheets: one page per shot number (01–08, extras), every still with its file name; clips as their
# middle frame. Usage: contact.sh <root>  → <root>/contact-sheet-<nn>.jpg
set -u
R=$1; T=$(mktemp -d)
for n in 01 02 03 04 05 06 07 08; do
  fs=($(cd $R && ls stills/*/$n-*.png 2>/dev/null | grep -v -- '-t[0-9][0-9]\.png$'))
  # the streaming frames: every 4th
  fs+=($(cd $R && ls stills/*/$n-*-t[0-9][0-9].png 2>/dev/null | awk 'NR%4==1'))
  (( ${#fs} == 0 )) && continue
  (cd $R && magick montage -font Helvetica -pointsize 13 -label '%d/%f' $fs -tile 8x -geometry 240x522+10+26 -background '#F4F2ED' $T/c-$n.jpg)
  magick $T/c-$n.jpg -quality 82 $R/contact-sheet-$n.jpg
done
cs=($(cd $R && ls clips/*.mov 2>/dev/null))
if (( ${#cs} )); then
  for c in $cs; do d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 $R/$c); ffmpeg -v error -y -ss $(python3 -c "print($d/2)") -i $R/$c -frames:v 1 $T/${c:t:r}.png; done
  (cd $T && magick montage -font Helvetica -pointsize 13 -label '%f' clip-*.png -tile 8x -geometry 240x522+10+26 -background '#F4F2ED' c-clips.jpg)
  magick $T/c-clips.jpg -quality 82 $R/contact-sheet-clips.jpg
fi
ls $R/contact-sheet-*.jpg
