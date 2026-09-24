#!/bin/sh
#
# Exercises the half of the bridge a Windows machine cannot reach: the unix
# socket discovery branch in claude/server.lua, which globs
# $XDG_RUNTIME_DIR/nvim*/... and /tmp/nvim*/... The plenary suites all run on
# Windows, so that branch had never executed under test -- and was broken when
# this was first written, still looking for the pre-0.10 socket layout.
#
# The instance is started with no --listen on purpose. An explicit address would
# not land in the directory layout the glob looks for, so discovery would be
# tested against a path only this script had arranged. Letting Neovim choose is
# what makes the result mean anything.
#
# Replies are parsed with jq rather than grep. An action's payload is a JSON
# string nested inside the MCP envelope, so its quotes arrive escaped and a
# naive grep for '"address"' silently matches nothing.

set -e

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -n "$XDG_RUNTIME_DIR" ] && mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
echo "-- XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-(unset)}"

nvim --headless -u /test/init.lua >/dev/null 2>&1 &
sleep 2

# One MCP session per check: the bridge reads stdin to EOF, so a fresh
# invocation per request is simpler than holding the stream open.
mcp() {
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    "$1" | nvim -u NONE -l /src/claude/server.lua 2>/dev/null
}

# The action payload, unwrapped from the MCP envelope.
payload() {
  jq -rs --argjson id "$2" '.[] | select(.id == $id) | .result.content[0].text' <<EOF
$1
EOF
}

call() {
  printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"drive","arguments":{"action":"%s","args":%s}}}' "$1" "$2" "$3"
}

echo "-- instances (unix discovery):"
found=$(payload "$(mcp "$(call 2 instances '{}')")" 2)
count=$(printf '%s' "$found" | jq 'length')
[ "$count" -ge 1 ] || fail "discovery found no instance"

# The bridge and this script both run Neovim too, and those have no nvim-mcp, so
# only entries that answered `identify` carry an `info` block.
address=$(printf '%s' "$found" | jq -r '[.[] | select(.info)][0].address // empty')
[ -n "$address" ] || fail "discovered $count socket(s) but none answered identify"
echo "   found: $address"

case "$address" in
  /*) ;;
  *) fail "address is not a unix path: $address" ;;
esac

echo "-- wait_for, server attached (expect no timed_out):"
body=$(payload "$(mcp "$(call 3 faketest "{\"instance\":\"$address\",\"wait_for\":\"roslyn\",\"timeout\":30}")")" 3)
[ "$(printf '%s' "$body" | jq -r '.timed_out // "absent"')" = "absent" ] ||
  fail "waited for an attached server and still timed out"
echo "   returned without timing out"

echo "-- wait_for, server absent (expect timed_out):"
start=$(date +%s)
body=$(payload "$(mcp "$(call 4 faketest "{\"instance\":\"$address\",\"wait_for\":\"ghost\",\"timeout\":2}")")" 4)
elapsed=$(($(date +%s) - start))
[ "$(printf '%s' "$body" | jq -r '.timed_out // false')" = "true" ] ||
  fail "absent server did not report timed_out"
[ "$(printf '%s' "$body" | jq -r '.waited_for // empty')" = "ghost" ] ||
  fail "timed-out reply does not say what it waited for"
[ "$elapsed" -le 8 ] || fail "timeout of 2s took ${elapsed}s"
echo "   timed out as expected after ${elapsed}s"

echo "-- show and close a real file:"
payload "$(mcp "$(call 5 show "{\"instance\":\"$address\",\"path\":\"/etc/os-release\",\"line\":2}")")" 5 |
  jq -e '.focus_kept != null' >/dev/null || fail "show did not report focus_kept"
payload "$(mcp "$(call 6 close "{\"instance\":\"$address\",\"path\":\"/etc/os-release\"}")")" 6 |
  jq -e '.' >/dev/null || fail "close returned nothing"
echo "   ok"

echo "PASS"
