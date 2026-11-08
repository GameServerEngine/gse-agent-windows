#!/usr/bin/env bash
set -u

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <port[/tcp|/udp|/any]> [more ports...]"
  echo "Example: $0 2302/udp 2303/udp 27015/tcp"
  exit 64
fi

declare -A expected_tcp=()
declare -A expected_udp=()
declare -A listening_tcp=()
declare -A listening_udp=()

add_expected() {
  local value="$1"
  local port="${value%%/*}"
  local proto="any"
  if [[ "$value" == */* ]]; then
    proto="${value##*/}"
  fi
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "Invalid port: $value"
    exit 65
  fi
  case "$proto" in
    tcp) expected_tcp["$port"]=1 ;;
    udp) expected_udp["$port"]=1 ;;
    any) expected_tcp["$port"]=1; expected_udp["$port"]=1 ;;
    *) echo "Invalid protocol: $value"; exit 65 ;;
  esac
}

for item in "$@"; do
  add_expected "$item"
done

collect_with_powershell() {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "\$p=[System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties();\$p.GetActiveTcpListeners()|ForEach-Object{'TCP '+\$_.Port};\$p.GetActiveUdpListeners()|ForEach-Object{'UDP '+\$_.Port}" 2>/dev/null
}

collect_with_netstat() {
  local line proto token port
  netstat -an 2>/dev/null | while IFS= read -r line; do
    set -- $line
    proto="${1:-}"
    case "$proto" in
      TCP|tcp)
        case "$line" in
          *LISTEN*|*Listen*|*listen*)
            shift
            for token in "$@"; do
              case "$token" in
                *:*|*.*)
                  port="${token##*:}"
                  port="${port##*.}"
                  echo "TCP $port"
                  break
                  ;;
              esac
            done
            ;;
        esac
        ;;
      UDP|udp)
        shift
        for token in "$@"; do
          case "$token" in
            *:*|*.*)
              port="${token##*:}"
              port="${port##*.}"
              echo "UDP $port"
              break
              ;;
          esac
        done
        ;;
    esac
  done
}

while read -r proto port; do
  [ -n "${proto:-}" ] || continue
  case "$proto" in
    TCP) listening_tcp["$port"]=1 ;;
    UDP) listening_udp["$port"]=1 ;;
  esac
done < <(collect_with_powershell || collect_with_netstat)

missing=0
found=0

echo "Expected ports:"
for port in "${!expected_tcp[@]}"; do
  if [ "${listening_tcp[$port]+x}" ]; then
    echo "  TCP $port listening"
    found=$((found + 1))
  else
    echo "  TCP $port missing"
    missing=$((missing + 1))
  fi
done
for port in "${!expected_udp[@]}"; do
  if [ "${listening_udp[$port]+x}" ]; then
    echo "  UDP $port listening"
    found=$((found + 1))
  else
    echo "  UDP $port missing"
    missing=$((missing + 1))
  fi
done

if [ "$missing" -eq 0 ]; then
  echo "Result: Running"
  exit 0
fi
if [ "$found" -gt 0 ]; then
  echo "Result: Warning"
  exit 2
fi
echo "Result: Failed"
exit 3
