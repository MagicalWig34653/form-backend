#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Card 85E16E07 (blocker criterion): a client that disconnects while its request waits in the body-budget queue (FORM_BODY_BUDGET_MB=64, one stalled
# 20 MiB upload holds 60 MiB) must not be processed afterwards: no submission row, no mail for it (observed > 20 s after the budget is free);
# the retry with the same idempotency key yields exactly one submission and one mail. Same environment as e2e-mail-resilience.sh (own ports/containers).
# Exit 0 ok, 1 failed, 2 environment problem.
cd "$(dirname "$0")" || exit 1
MR_SPEC=real-body-budget-wait.spec.ts MR_BODY_BUDGET_MB=64 \
MR_OK_MSG="a client abort in the body-budget queue leaves no submission/mail behind; the retry yields exactly one" \
exec ./e2e-mail-resilience.sh
