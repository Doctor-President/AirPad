#!/bin/zsh
# 1.1 store — the two CC0 photos seed_entry.py puts in the synthetic entry (Wikimedia Commons), resized to 2400 px.
set -eu
A=${0:A:h}/assets; mkdir -p $A; cd $A
curl -sL -o pourover.jpg "https://upload.wikimedia.org/wikipedia/commons/d/df/Manual_drip_%28pour-over%29_coffee.jpg"   # CC0
curl -sL -o drip.jpg "https://upload.wikimedia.org/wikipedia/commons/1/11/Drip_brewing_%28Unsplash%29.jpg"                  # CC0
magick pourover.jpg -resize 2400x2400 -quality 88 pourover-2400.jpg; magick drip.jpg -resize 2400x2400 -quality 88 drip-2400.jpg
