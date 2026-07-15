#!/usr/bin/env bash
# run_github.sh â€” Run the AuraLaunch bot for EXACTLY ONE cycle, then exit.
#
# `node index.js run` runs daily+faucet+stake+tasks for every wallet and then
# AUTO-LOOPS every 8h (setInterval) â€” it never exits on its own. On CI that
# would hang the job forever, so this wrapper:
#   1. writes account.txt from $ACCOUNTS (or uses $PRIVATE_KEY fallback),
#   2. launches `node index.js run` in the background,
#   3. waits for the first cycle to finish â€” detected via the
#      "Bot auto-loop every" log line printed right BEFORE the loop starts,
#   4. kills the bot (so CI doesn't hang) and prints the full log.
#
# Env (all optional â€” also read from GitHub secrets via the workflow):
#   ACCOUNTS        private keys, one per line (used to build account.txt)
#   PRIVATE_KEY     single key fallback if ACCOUNTS is empty
#   RPC_URL         custom RPC (default is fine)
#   DRY_RUN         true|false (simulate, no tx)
#   STAKE_AURA      AURA stake amount or "50%"  (else config.json default)
#   STAKE_REV       REV stake amount
#   STAKE_TIMES     how many times to stake per cycle
#   WALLET_CONCURRENCY  parallel wallets (default 1)
#   HARD_TIMEOUT    seconds before giving up waiting for the marker (default 9000 = 2.5h)
set -uo pipefail

LOG_FILE="bot_run.log"
HARD_TIMEOUT="${HARD_TIMEOUT:-9000}"

# â”€â”€ Build account.txt from secrets/env (never committed) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
if [ -n "${ACCOUNTS:-}" ]; then
  printf '%s\n' "$ACCOUNTS" > account.txt
  echo "[ci] Wrote account.txt from ACCOUNTS ($(printf '%s\n' "$ACCOUNTS" | grep -c .) key(s))."
elif [ -n "${PRIVATE_KEY:-}" ]; then
  printf '%s\n' "$PRIVATE_KEY" > account.txt
  echo "[ci] Wrote account.txt from PRIVATE_KEY (single wallet)."
elif [ -s account.txt ]; then
  echo "[ci] Using existing account.txt."
else
  echo "::error::No accounts. Set the ACCOUNTS secret (multi-wallet) or PRIVATE_KEY (single)."
  exit 1
fi

# â”€â”€ Launch the bot in the background â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
node index.js run > "${LOG_FILE}" 2>&1 &
BOT_PID=$!
echo "[ci] Bot started (pid ${BOT_PID}). Waiting for the first cycle to finish..."

# â”€â”€ Wait for the cycle to complete or the process to die â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
ELAPSED=0
while kill -0 "${BOT_PID}" 2>/dev/null; do
  if grep -q "Bot auto-loop every" "${LOG_FILE}" 2>/dev/null; then
    echo "[ci] First cycle finished (auto-loop marker seen). Stopping bot."
    break
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  if [ "${ELAPSED}" -ge "${HARD_TIMEOUT}" ]; then
    echo "[ci] Hard timeout reached (${HARD_TIMEOUT}s). Stopping bot."
    break
  fi
done

# â”€â”€ Stop the bot (it would otherwise loop forever) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
kill "${BOT_PID}" 2>/dev/null || true
sleep 2
kill -9 "${BOT_PID}" 2>/dev/null || true
wait "${BOT_PID}" 2>/dev/null || true

# â”€â”€ Surface the log for the Actions UI â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo "======================= BOT LOG ======================="
cat "${LOG_FILE}"
echo "======================================================="

# Fail the job on an explicit error/fatal.
if grep -qiE "ERROR:|FATAL|Unhandled|process.exit\(1\)" "${LOG_FILE}" 2>/dev/null; then
  echo "[ci] Error markers detected in log â€” exiting non-zero."
  exit 1
fi

exit 0
