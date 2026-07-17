#!/usr/bin/env bash
# Behavior tests for deterministic crew-dispatch profile selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-dispatch-select-tests)
mkdir -p "$TMP_ROOT"

write_quota() {
  local file=$1 claude_status=$2 claude_five=$3 claude_week=$4 codex_status=$5 codex_five=$6 codex_week=$7
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<JSON
{
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "$claude_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $claude_five },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": $claude_week },
        { "id": "model:fable", "kind": "model", "percentRemaining": 100 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "$codex_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $codex_five },
        { "id": "weekly", "kind": "weekly", "percentRemaining": $codex_week },
        { "id": "model:codex_bengalfox:5h", "kind": "model", "percentRemaining": 100 }
      ]
    }
  ]
}
JSON
}

profiles='[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'

test_higher_min_vendor_wins() {
  local quota out
  quota="$TMP_ROOT/higher.json"
  write_quota "$quota" fresh 80 30 fresh 70 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "higher-min vendor should win, got: $out"
  pass "quota-balanced picks the candidate with the higher general-window minimum"
}

test_exact_tie_uses_first_profile() {
  local quota out
  quota="$TMP_ROOT/tie.json"
  write_quota "$quota" fresh 90 50 fresh 60 50
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "exact tie should pick first profile, got: $out"
  pass "quota-balanced exact tie uses the first ordered profile"
}

test_quota_missing_falls_back_to_first() {
  local fakebin out err status
  fakebin=$(fm_fakebin "$TMP_ROOT/missing")
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" 2>"$TMP_ROOT/missing.err")
  status=$?
  err=$(cat "$TMP_ROOT/missing.err")
  expect_code 0 "$status" "missing quota-axi should not fail dispatch"
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "missing quota-axi should fall back to first, got: $out"
  assert_contains "$err" "quota-axi missing" "missing quota-axi fallback should be logged"
  pass "quota-axi missing falls back to the first profile and logs"
}

test_quota_error_falls_back_to_first() {
  local fakebin out err status
  fakebin=$(fm_fakebin "$TMP_ROOT/error")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" 2>"$TMP_ROOT/error.err")
  status=$?
  err=$(cat "$TMP_ROOT/error.err")
  expect_code 0 "$status" "quota-axi error should not fail dispatch"
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "quota-axi error should fall back to first, got: $out"
  assert_contains "$err" "quota-axi exited 42" "quota-axi error fallback should be logged"
  pass "quota-axi non-zero exit falls back to the first profile and logs"
}

test_bad_quota_json_falls_back_to_first() {
  local quota out err
  quota="$TMP_ROOT/bad.json"
  printf '%s\n' 'not-json' > "$quota"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/bad.err")
  err=$(cat "$TMP_ROOT/bad.err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "bad quota JSON should fall back to first, got: $out"
  assert_contains "$err" "unparseable JSON" "bad quota JSON fallback should be logged"
  pass "unparseable quota JSON falls back to the first profile and logs"
}

test_stale_with_cache_needs_clear_margin_to_beat_fresh() {
  local quota out
  quota="$TMP_ROOT/stale-margin.json"
  write_quota "$quota" stale 85 70 fresh 65 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "fresh vendor should win when stale lead is below margin, got: $out"

  write_quota "$quota" stale 90 85 fresh 65 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "stale vendor should win when lead clears margin, got: $out"
  pass "stale cached quota is usable only when it clears the documented margin over fresh"
}

test_vendor_absent_or_unusable_falls_back_conservatively() {
  local quota out err
  quota="$TMP_ROOT/absent.json"
  cat > "$quota" <<'JSON'
{
  "providers": [
    {
      "provider": "codex",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 40 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": 50 }
      ]
    }
  ]
}
JSON
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "available candidate should win over absent vendor, got: $out"

  cat > "$quota" <<'JSON'
{ "providers": [] }
JSON
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/none.err")
  err=$(cat "$TMP_ROOT/none.err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "no usable vendors should fall back to first, got: $out"
  assert_contains "$err" "no usable quota windows" "no usable vendor fallback should be logged"
  pass "absent or unusable vendors resolve to an available candidate or the first fallback"
}

test_backward_compatible_first_selection() {
  local fakebin marker out single array_rule
  fakebin=$(fm_fakebin "$TMP_ROOT/no-call")
  marker="$TMP_ROOT/quota-called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf called > '$marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"

  single='{"harness":"grok","model":"grok-4","effort":"high"}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$single")
  [ "$out" = '{"harness":"grok","model":"grok-4","effort":"high"}' ] \
    || fail "single-object use should resolve to itself, got: $out"

  array_rule='{"when":"big work","use":[{"harness":"claude","effort":"high"},{"harness":"codex","effort":"high"}]}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$array_rule")
  [ "$out" = '{"harness":"claude","effort":"high"}' ] \
    || fail "array without select should resolve to first, got: $out"
  [ ! -e "$marker" ] || fail "quota-axi should not be called without quota-balanced select"
  pass "single-object use and no-select arrays preserve first-profile selection"
}

test_ultracode_boolean_is_preserved() {
  local out
  out=$("$ROOT/bin/fm-dispatch-select.sh" '{"harness":"claude","model":"opus","effort":"xhigh","ultracode":true,"ultracode_role":"independent-review"}')
  [ "$out" = '{"harness":"claude","model":"opus","effort":"xhigh","ultracode":true,"ultracode_role":"independent-review"}' ] \
    || fail "boolean ultracode true and its role should be preserved, got: $out"
  pass "ultracode boolean true and ultracode_role pass through unchanged"
}

test_ultracode_non_boolean_string_fails_loud() {
  local out err status
  out=$("$ROOT/bin/fm-dispatch-select.sh" '{"harness":"claude","ultracode":"true"}' 2>"$TMP_ROOT/ultracode-string.err")
  status=$?
  err=$(cat "$TMP_ROOT/ultracode-string.err")
  expect_code 2 "$status" "a hand-edited string ultracode should fail loud, not resolve"
  [ -z "$out" ] || fail "a non-boolean ultracode must never resolve to a profile, got: $out"
  assert_contains "$err" "ultracode must be a boolean" "a non-boolean ultracode should be reported"
  pass "a JSON string ultracode value fails loud instead of being silently dropped"
}

test_ultracode_non_boolean_number_fails_loud() {
  local out err status
  out=$("$ROOT/bin/fm-dispatch-select.sh" '{"harness":"claude","ultracode":1}' 2>"$TMP_ROOT/ultracode-number.err")
  status=$?
  err=$(cat "$TMP_ROOT/ultracode-number.err")
  expect_code 2 "$status" "a numeric ultracode should fail loud, not resolve"
  [ -z "$out" ] || fail "a non-boolean ultracode must never resolve to a profile, got: $out"
  assert_contains "$err" "ultracode must be a boolean" "a numeric ultracode should be reported"
  pass "a numeric ultracode value fails loud instead of being silently coerced away"
}

test_ultracode_rejected_inside_quota_balanced_array() {
  local out err status array_rule
  array_rule='{"when":"big feature","use":[{"harness":"claude","ultracode":"true"},{"harness":"codex"}],"select":"quota-balanced"}'
  out=$("$ROOT/bin/fm-dispatch-select.sh" "$array_rule" 2>"$TMP_ROOT/ultracode-array.err")
  status=$?
  err=$(cat "$TMP_ROOT/ultracode-array.err")
  expect_code 2 "$status" "a non-boolean ultracode anywhere in a quota-balanced array should fail loud"
  [ -z "$out" ] || fail "a non-boolean ultracode must never resolve to a profile, got: $out"
  assert_contains "$err" "ultracode must be a boolean" "a non-boolean ultracode inside an array should be reported"
  pass "a non-boolean ultracode inside a quota-balanced profile array fails loud before any selection runs"
}

test_ultracode_role_non_string_fails_loud() {
  local out err status
  out=$("$ROOT/bin/fm-dispatch-select.sh" '{"harness":"claude","ultracode":true,"ultracode_role":42}' 2>"$TMP_ROOT/ultracode-role.err")
  status=$?
  err=$(cat "$TMP_ROOT/ultracode-role.err")
  expect_code 2 "$status" "a non-string ultracode_role should fail loud, not resolve"
  [ -z "$out" ] || fail "a non-string ultracode_role must never resolve to a profile, got: $out"
  assert_contains "$err" "ultracode_role must be a non-empty string" "a non-string ultracode_role should be reported"
  pass "a non-string ultracode_role value fails loud instead of being silently dropped"
}

test_higher_min_vendor_wins
test_exact_tie_uses_first_profile
test_quota_missing_falls_back_to_first
test_quota_error_falls_back_to_first
test_bad_quota_json_falls_back_to_first
test_stale_with_cache_needs_clear_margin_to_beat_fresh
test_vendor_absent_or_unusable_falls_back_conservatively
test_backward_compatible_first_selection
test_ultracode_boolean_is_preserved
test_ultracode_non_boolean_string_fails_loud
test_ultracode_non_boolean_number_fails_loud
test_ultracode_rejected_inside_quota_balanced_array
test_ultracode_role_non_string_fails_loud

echo "# all fm-dispatch-select tests passed"
