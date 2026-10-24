# Verify an existing fix

Adapted from pstack's Benny automation (MIT, Lauren Tan).

The existing artifact owns the fix. Verify it; do not edit it, author a competing patch, or open another PR.

## Qualify the artifact

One concrete artifact: an open PR with code that addresses the symptom, a merged PR, or a merged commit with matching code and intent. A comment, branch name or cause hypothesis is not one. Several candidates: the one linked from the issue, else the closest match to the affected code, with why.

## Measure

In a loop worktree, with the same install and environment for both sides:

1. **Baseline**: the PR's base, or for a merged fix the commit before it. Write the issue's acceptance criteria as a failing test or command and run it twice. Red twice, or there is no baseline.
2. **Patched**: the PR head or the fix commit. The same test or command, twice.

## Outcomes

- **Confirmed**: red on baseline, green on patched. Comment on the issue with both runs and the artifact link. No PR. When the test is not in the artifact, offer it on the artifact's PR in a comment.
- **Insufficient**: red on both. Comment that the artifact does not resolve it, with the run. No competing PR.
- **Inconclusive**: the baseline never went red, or a side could not run. Say which half could not be measured; claim nothing.

Unassign the issue in every outcome but a merged confirmation, and remove the worktree.
