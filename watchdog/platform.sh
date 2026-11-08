#!/bin/bash
# Platform calls for the watchdog. Linux uses ss/pgrep; Windows (Cygwin) uses netstat/ps.
# Every function prints its result on stdout and returns 0 on success.
if [[ "$(uname -s)" == CYGWIN* || "$(uname -s)" == MINGW* ]]; then GSE_PLATFORM=windows; else GSE_PLATFORM=linux; fi

# port_listening <tcp|udp> <port>  -> exit 0 if something is listening on that port
port_listening() {
  local proto="$1" port="$2"
  if [ "$GSE_PLATFORM" = "linux" ]; then
    if [ "$proto" = "udp" ]; then ss -lun 2>/dev/null | awk -v p=":$port" '$4 ~ p"$"' | grep -q .
    else ss -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p"$"' | grep -q .; fi
  else
    if [ "$proto" = "udp" ]; then netstat -an -p UDP 2>/dev/null | awk -v p=":$port" '$2 ~ p"$"' | grep -q .
    else netstat -an -p TCP 2>/dev/null | awk -v p=":$port" '$2 ~ p"$" && $4 ~ /LISTEN/' | grep -q .; fi
  fi
}

# port_owner_pid <tcp|udp> <port>  -> prints the pid owning the listening port
port_owner_pid() {
  local proto="$1" port="$2"
  if [ "$GSE_PLATFORM" = "linux" ]; then
    if [ "$proto" = "udp" ]; then ss -lunp 2>/dev/null | grep ":$port " | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1
    else ss -ltnp 2>/dev/null | grep ":$port " | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1; fi
  else
    if [ "$proto" = "udp" ]; then netstat -ano -p UDP 2>/dev/null | awk -v p=":$port" '$2 ~ p"$" {print $NF}' | head -1
    else netstat -ano -p TCP 2>/dev/null | awk -v p=":$port" '$2 ~ p"$" && $4 ~ /LISTENING/ {print $NF}' | head -1; fi
  fi
}

# child_pids <pid>  -> prints direct children of pid
child_pids() {
  local p="$1"
  if [ "$GSE_PLATFORM" = "linux" ]; then pgrep -P "$p" 2>/dev/null
  else ps -ef 2>/dev/null | awk -v p="$p" '$3 == p {print $2}'; fi
}
