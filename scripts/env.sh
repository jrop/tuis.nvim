#!/usr/bin/env bash

export VIMRUNTIME="$(nvim -u NORC --headless +'echo $VIMRUNTIME' +'quitall' 2>&1)"
eval $(luarocks path)
