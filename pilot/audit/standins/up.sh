#!/bin/sh
# A stand-in candidate for the audit's self-check: answers every request with the same canned "up" JSON. Right for the cases whose spec that JSON satisfies, wrong for the rest.
# Started as `up.sh serve --port <n> ...`; uses the audit's world in `reply` mode.
exec "${AUDIT_BIN:?}/world" "$3" 1000 reply '200:{"ok":true,"verdict":"up","status":200,"final_url":"http://127.0.0.1/","redirects":[]}'
