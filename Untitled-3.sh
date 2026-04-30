#!/bin/sh
# update_nptv6.sh
# MIT License
# Copyright (c) 2026 Sladernom
# LICENSE: https://github.com/Sladernom/NPTv6-External-Updater/blob/main/LICENSE
#
# DISCLAIMER: This script is provided "as-is", without any warranties.
# Use at your own risk; the author is not responsible for any damages,
# data loss, or issues caused by running this script.
#
#
# This script intends to hook into /var/etc/dhcp6c_wan_script.sh to pull
# PDINFO so the delegated prefix can be written to NPTv6 rules. Currently
# it only checks the first <rule> in the first <npt> within /conf/config.xml
# and, if different from the value of PDINFO, writes PDINFO to all <rule>s in
# first <npt>
##############################################################################

# Lock to prevent race conditions
# Open shared lock file and assign it to file descriptor 9 (this process only)
exec 9>/tmp/npt_update.lock || {
  logger -p daemon.err -t npt-update "Can't open lock file /tmp/npt_update.lock, skipping run"
  exit 0
}
# Attempts to acquire exclusive lock on the file referenced by FD 9
# Lock is per-process; if another process holds it, this fails immediately (-n)
if ! flock -n 9; then
  logger -p daemon.info -t npt-update "Another process holds the lock, another instance likely running"
  exit 0
fi
# Previous critical fail check
if [ -f /conf/npt_update_failed ]; then
  logger -p daemon.crit -t npt-update "Previous critical failure detected, refusing to run"
  exit 1
fi
# Exit if XML parser is present/working
if ! command -v xmlstarlet >/dev/null 2>&1; then
  logger -p daemon.err -t npt-update "xmlstarlet not found! Can't update NPTv6 destinations"
  exit 1
fi

PDINFO="$1"
# Flag I may use in the future to disable some non-critical loggers
# OLOG="1"

if [ -z "$PDINFO" ]; then
  logger -p daemon.err -t npt-update "No PDINFO provided, exiting"
  exit 0
fi

PREFIX=${PDINFO%% *}
# Format validation
if [ -z "$PREFIX" ]; then
  logger -p daemon.err -t npt-update "Failed to parse prefix from PDINFO: $PDINFO"
  exit 0
fi
if ! printf "%s" "$PREFIX" | grep -Eq '^[0-9A-Fa-f:]*:[0-9A-Fa-f:]+/[0-9]{1,3}$'; then
  logger -p daemon.err -t npt-update "Invalid IPv6 prefix format: $PREFIX"
  exit 0
fi
if [ "$(printf "%s" "$PREFIX" | grep -o '::' | wc -l | tr -d ' ')" -gt 1 ]; then
  logger -p daemon.err -t npt-update "Invalid IPv6 prefix (multiple ::): $PREFIX"
  exit 0
fi
PLEN=${PREFIX#*/}
if [ "$PLEN" -gt 128 ]; then
  logger -p daemon.err -t npt-update "Invalid IPv6 prefix length (>128): $PREFIX"
  exit 0
fi



CONFIG_FILE="/conf/config.xml"
BACKUP_FILE="/conf/config.xml.npt.bak.$(date +%s)"

if ! CURRENT=$(xmlstarlet sel -t -v "//npt[1]/rule[1]/destination_net" "$CONFIG_FILE" 2>&1); then
 logger -p daemon.err -t npt-update "Failed to read NPTv6 rule from config.xml: $CURRENT"
 exit 1
fi

if [ -z "$CURRENT" ]; then
  logger -p daemon.info -t npt-update "No existing NPTv6 rule found"
  exit 0
fi

if [ "$CURRENT" = "$PREFIX" ]; then
  logger -p daemon.info -t npt-update "No change needed: $PREFIX already set"
  exit 0
fi

# Prepare tmp file for xmlstarlet to write to, to swap on success, for atomicity
TMP_FILE="/conf/config.xml.npt.tmp.$$"
# 1. Generate Updated config
if xmlstarlet ed -u "//npt[1]/rule/destination_net" -v "$PREFIX" "$CONFIG_FILE" > "$TMP_FILE"; then
  logger -p daemon.info -t npt-update "Generated candidate NPTv6 config"
else
  logger -p daemon.err -t npt-update "Failed to generate condidate NPTv6 config"
  rm -f "$TMP_FILE"
  exit 1
fi
# 2. Check XML well-formedness (As of 4/30/26 OPNsense has no schema to validate against)
if ! xmlstarlet val "$TMP_FILE" >/dev/null 2>&1; then
  logger -p daemon.err -t npt-update "Generated config.xml is invalid XML"
  rm -f "$TMP_FILE"
  exit 1
fi
# 3. Generate backup after XML passes check
if ! cp -p "$CONFIG_FILE" "$BACKUP_FILE"; then
  logger -p daemon.err -t npt-update "Failed to create backup. Exiting"
  rm -f "$TMP_FILE"
  exit 1
fi
# 4. Remove old backups to prevent bloat
find /conf -maxdepth 1 -name 'config.xml.npt.bak.*' -mtime +7 -delete
# 5. Atomic replacement
if ! mv "$TMP_FILE" "$CONFIG_FILE"; then
  logger -p daemon.err -t npt-update "Failed to replace config.xml"
  rm -f "$TMP_FILE"
  exit 1
fi



if configctl filter reload; then
    logger -p daemon.notice -t npt-update "Filter reloaded successfully"
else
    logger -p daemon.err -t npt-update "Reload failed, restoring backup"
    if ! cp -p "$BACKUP_FILE" "$CONFIG_FILE"; then
      touch /conf/npt_update_failed
      logger -p daemon.err -t npt-update "ERROR: NPTv6 updater failed to restore backup!"
      logger -p daemon.crit -t npt-update "CRITICAL: Failed to restore after reload fail! Flag set (/conf/npt_update_failed)"
      logger -p daemon.crit -t npt-update "CRITICAL: Firewall may be in an inconsistent state!"
      echo "CRITICAL: Firewall backup restore failed after NPTv6 update!" > /dev/console
      exit 1
    fi
    if configctl filter reload; then
      logger -p daemon.err -t npt-update "Filter reload succeeded after restoring backup"
    else
      touch /conf/npt_update_failed
      logger -p daemon.err -t npt-update "ERROR: Filter reload failed after restoring backup!"
      logger -p daemon.crit -t npt-update "CRITICAL: Filter reload failed after restore! Flag set (/conf/npt_update_failed)"
      logger -p daemon.crit -t npt-update "CRITICAL: Firewall may be in an inconsistent state!"
      echo "CRITICAL: Firewall reload failed after NPTv6 update!" > /dev/console
      exit 1
    fi
    exit 0
fi