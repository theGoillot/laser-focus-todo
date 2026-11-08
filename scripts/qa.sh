#!/bin/sh
# QA channel for debug builds (see mac/App/DebugHooks.swift). Usage: ./scripts/qa.sh <command> [args]
cmd="$*"
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('laser-focus.debug', \$('$cmd'), \$(), true)" >/dev/null
sleep 0.4
