launch.env is sourced by restore_script.sh, so every value must be shell-quoted.
Write it with printf %q, for example:
  printf 'GAME_DIR=%q\nGAME_CMD=%q\nGAME_PORT=%q\nGAME_PROTO=%q\n' "$dir" "$cmd" "$port" "$proto" > launch.env
Found in T6: an unquoted GAME_CMD made restore fail with "-u: command not found".
