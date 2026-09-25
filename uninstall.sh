#!/bin/sh

##
# Uninstalls Battery Toolkit and its settings.
#
# Copyright (C) 2022 Marvin Häuser. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause
##

# Remove the Battery Toolkit daemon.
sudo rm /Library/LaunchDaemons/com.delfuria.batterytoolkitd.plist
sudo rm /Library/PrivilegedHelperTools/com.delfuria.batterytoolkitd
sudo launchctl remove com.delfuria.batterytoolkitd

# Remove the Battery Toolkit daemon data.
sudo defaults delete com.delfuria.batterytoolkitd
sudo security authorizationdb remove com.delfuria.batterytoolkitd.manage

# Remove the Battery Toolkit Autostart helper.
launchctl remove com.delfuria.BatteryToolkitAutostart

# Remove the Battery Toolkit app data.
defaults remove com.delfuria.BatteryToolkit
