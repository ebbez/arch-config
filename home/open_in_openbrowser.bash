#!/bin/bash

if [[ $(pgrep -x "brave") ]] && ! [[ $(pgrep -x "librewolf") ]]; then
	brave $1
else
	librewolf $1
fi
