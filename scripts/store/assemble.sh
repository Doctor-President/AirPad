#!/bin/zsh
# 1.1 store — gather the raw stills and clips into <dest> (design-refs/1.1-store): stills/<device>/<shot>-…-<appearance>.png,
# clips/, then the manifest and the contact sheets. Usage: assemble.sh <dest>
set -u
D=$1; HERE=${0:A:h}; O=$HERE/out
mkdir -p $D/stills $D/clips
for dev in pro:6.3in-iphone17pro promax:6.9in-iphone17promax; do src=${dev%%:*}; dst=$D/stills/${dev#*:}; mkdir -p $dst
  for f in $O/$src/map/*.png(N); do [[ $f == *-start.png ]] && continue; cp $f $dst/; done
  for ap in light dark; do
    for f in $O/$src/$ap/*.png(N); do b=${f:t:r}
      # the streaming frames: every third one is plenty to choose from
      if [[ $b =~ '^02-librarian-t([0-9][0-9])$' ]]; then (( 10#${match[1]} % 3 == 0 )) || continue; fi
      cp $f $dst/$b-$ap.png
    done
  done
done
cp $O/pro/clips/*.mov $D/clips/ 2>/dev/null
python3 $HERE/fps.py $D/clips >/dev/null; cp $D/clips/fps.md $D/fps.md; cp $HERE/README-delivery.md $D/README.md
python3 $HERE/manifest.py $D
python3 $HERE/contact.py $D
print -l 'stills/' 'clips/' > $D/.gitignore   # raw media stay on this Mac (≈1.5 GB): T composes from here
du -sh $D/stills $D/clips
