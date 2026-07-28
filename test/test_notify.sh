LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"

( setup_mocks
  make_mock curl 'exit 0'
  source "$LIBDIR/log.sh"; source "$LIBDIR/notify.sh"
  SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T/B/X"
  slack_success "beyond10th" "https://github.com/a/b/pull/5" "3 meta fixes"
  assert_contains "$(mock_stdin curl)" "hooks.slack.com" "webhook URL passed via stdin config"
  assert_not_contains "$(mock_calls curl)" "hooks.slack.com" "webhook URL NOT in argv (ps-safe)"
  assert_contains "$(mock_calls curl)" "pull/5" "PR url present in message payload"
)

# empty webhook -> no curl, returns 0
( setup_mocks
  make_mock curl 'exit 0'
  source "$LIBDIR/log.sh"; source "$LIBDIR/notify.sh"
  SLACK_WEBHOOK_URL=""
  if slack_send "hi"; then pass "empty webhook is non-fatal"; else fail "empty webhook should return 0"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
  assert_eq "$(mock_calls curl)" "" "no curl call when webhook empty"
)

# failure message includes reason + logfile
( setup_mocks
  make_mock curl 'exit 0'
  source "$LIBDIR/log.sh"; source "$LIBDIR/notify.sh"
  SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T/B/X"
  slack_failure "demo" "/tmp/demo.log" "build failed"
  calls="$(mock_calls curl)"
  assert_contains "$calls" "build failed" "failure reason present"
)

# Slack HTTP errors must propagate to the caller.
( setup_mocks
  make_mock curl 'exit 22'
  source "$LIBDIR/log.sh"; source "$LIBDIR/notify.sh"
  SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T/B/X"
  TESTS_RUN=$((TESTS_RUN + 1))
  if slack_send "hi" >/dev/null 2>&1; then fail "Slack HTTP failure was accepted"; else pass "Slack HTTP failure propagates"; fi
  assert_contains "$(mock_calls curl)" "--fail-with-body" "Slack curl enables HTTP failure handling"
)
