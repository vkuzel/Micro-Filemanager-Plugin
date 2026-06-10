#!/bin/bash

src="$(pwd)"
dst="$HOME/.config/micro/plug/file-manager2"

if [[ ! -d "$src" ]]; then
	echo "File manager plugin not found, run the install script from repository root!"
	exit 1
fi

if [[ ! -e "$dst" ]]; then
	ln -s "$src" "$dst"
else
	echo "Already installed!"
fi
