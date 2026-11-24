# Nightly maintenance log

State carried from one autonomous run to the next. Each entry records what was
inspected, the single change that was made, how it was verified, and what is
still open, so the next run does not repeat the same investigation.

## 2026-10-28

**Area:** `.github/scripts/run-opencode-fallback.sh` (the runner both agent
workflows use).

**Finding:** every successful agent run in this repository ended as a failure.
After the model finished, the wrapper ran `npm test --if-present`; this control
repository has no `package.json`, and npm exits 254 in that case. The wrapper
interpreted that as "the agent broke the tests", re-ran the agent up to three
times with a bogus failure message, then returned 1 and failed the job. The
fallback chain was never reached because the log did not contain a provider
limit error.

Three smaller defects were found in the same path:

- `PROMPT` (the `workflow_dispatch` input and the value exported by
  `opencode-triage.yml`) was read by the workflow but never used by the script.
- Prompts were built with `"\n"` inside double quotes, so the agent received
  the two characters `\` and `n` instead of paragraph breaks.
- A stall or timeout killed `tee`, not the agent, and returned status 143
  instead of 124, so the next model was not tried and the agent kept running.

**Change:** gate post-run validation on a real `test` script in
`package.json`, use `PROMPT` first and build the prompt with `$'\n'`, run the
agent with its output redirected to the log and stream it with `tail -f`, kill
the actual process (TERM then KILL) and return 124 on stall/timeout. A failing
suite is fed back with the last 200 log lines. Added a stubbed-binary test
suite and a `scripts-test` workflow.

**Verification:** `shellcheck -x` is clean; the 19 assertions in
`.github/scripts/tests/run-opencode-fallback.test.sh` pass, including the
no-`package.json` success case, the failing-suite retry case and the stall
watchdog.

**Open, not changed this run:**

- The "Create or Update Pull Request Automatically" step in
  `opencode-triage.yml` runs against the checked out default branch and does
  not push the agent's branch. It is effectively dead today and its title uses
  an empty issue number on `workflow_dispatch`. It should be replaced by an
  explicit branch/push/PR step or removed by the owner.
- `publish-release.sh --help` prints only a slice of the header and the header
  contains a stray `#       --source-archive` line. Cosmetic.

### Second run, 2026-10-28

**Reported symptom:** the nightly run failed again with
`npm error path .../package.json` / `ENOENT`, and the retry prompt
("CRITICAL FIX REQUIRED") was passed back to the agent.

**Root cause:** the fix above exists only on the `test` branch. The
`opencode-triage` workflow checks out
`ref: ${{ github.event.repository.default_branch }}`, which is `main`, and
`main` still contains the old runner that calls `npm test` unconditionally.
Every issue-triggered run therefore executes the unfixed script from `main`;
the guard on `test` is never reached. This is a deployment gap, not a new
regression in the script.

**Change (on `test`):** resolve the manifest from `GITHUB_WORKSPACE` (the
checkout root, falling back to the current directory) and run `npm` from that
directory, so the guard and the invocation cannot disagree when a workflow
step starts in a subdirectory. Skip the gate when `npm` itself is missing.
Added two regression cases: a manifest without a `test` script must never
start `npm`, and a run from a subdirectory must validate the workspace root.
The suite is now 26 assertions.

**Verification:** `shellcheck -x` is clean; all 26 assertions pass.

**Open, needs the owner:** PR #93 (`test` → `main`) carries the runner fix and
must be merged before issue-triggered runs stop using the old script. Until it
is merged, no change on `test` can affect the workflow, because the workflow
always checks out the default branch. An alternative is to change the
checkout `ref` in `opencode-triage.yml` to the branch the agent uses.

### Third run, 2026-10-28

**Reported symptom (issue #92, still open):** every consumer of `npm test` at
the checkout root - the agent's post-run gate in this repository, and any
external harness - failed with

```
npm error path /home/runner/work/opencode/opencode/package.json
npm error enoent Could not read package.json
```

**Root cause:** the previous run fixed the guard inside the runner, but the
repository still had no manifest at all. Any `npm test` invocation that did
not go through the guard (the old runner on `main`, a CI harness, a developer)
hit ENOENT. Fixing the caller and leaving the missing file in place made the
failure dependent on which copy of the script ran.

**Change:**

- added `package.json` at the repository root: `npm test` runs
  `.github/scripts/tests/run-opencode-fallback.test.sh`, `npm run lint` runs
  `shellcheck`, `npm run check` runs both. The manifest is private, has no
  dependencies and adds no install step.
- `scripts-test.yml` now invokes `npm run lint` / `npm test`, so CI validates
  the same entry points the gate uses, and the workflow triggers on
  `package.json` changes.
- the runner test suite gained case 7: it asserts the repository manifest
  exists, parses as JSON and exposes a non-empty `test` script, and that the
  gate accepts it (31 assertions).

**Verification:** `npm test` (31 assertions) and `npm run lint` pass; the
runner still skips the gate for a manifest without a test script and for a
missing manifest.

**Still open:** the `issues` event always loads the workflow from the default
branch, so `main` must receive the runner and manifest through a pull request
(`test` → `main`) before issue-triggered runs use them. Nothing on `test` can
change what an issue-triggered run executes.

## 2026-11-24

**Area:** provider keys (`GROQ_API_KEY`, `OPENROUTER_API_KEY`), the runner and
the agent workflows.

**Reported symptom:** a request to prove the new Groq and OpenRouter keys work
with one small inference per provider.

**Finding:** both repository secrets hold the same value as
`OPENCODE_GITHUB_TOKEN` (a GitHub personal access token, updated
2026-11-24T00:02Z), not a provider key. The providers reject it:
Groq answers `HTTP 401 {"error":{"message":"Invalid API Key",...}}` and
OpenRouter answers `HTTP 401 {"error":{"message":"Missing Authentication
header",...}}`; OpenCode itself prints `Error: Invalid API Key` for
`groq/openai/gpt-oss-120b` and `Error: Missing Authentication header` for an
OpenRouter model. No model inference succeeded. A second gap: the
`OPENCODE_MODELS` variable still lists only the five free `opencode/*` models,
so even a valid key would not be used.

**Change:** added `.github/scripts/check-provider-keys.sh`, which sends one
tiny completion per configured provider and prints the model, the reply and the
seconds, or the exact error. It refuses to send a secret that looks like a
GitHub token to a third party. Both agent workflows run it as a non-blocking
preflight, so a rejected key shows up as a warning instead of being hidden by a
silent fallback. `run-opencode-fallback.sh` now drops keyed models whose key is
missing or malformed (before any provider call) and treats `Invalid API Key` as
a switch-model signal instead of a task failure.

**Verification:** `npm test` (44 runner assertions, 24 provider-key assertions)
and `npm run lint` pass; the real probe against the configured secrets reports
both keys as GitHub tokens and sends nothing.

**Open, needs the owner:** set real keys with
`gh secret set GROQ_API_KEY --repo mdmuntakim/opencode` and the same for
`OPENROUTER_API_KEY`, then add the keyed models to `OPENCODE_MODELS`, e.g.
`groq/openai/gpt-oss-120b` and `openrouter/inclusionai/ling-3.2-flash:free`.
The agent cannot create provider accounts or read the real keys.
## 2026-11-24

**Area:** provider keys (`GROQ_API_KEY`, `OPENROUTER_API_KEY`) and the keyed
part of the fallback chain.

**Reported symptom (issue #58, `/oc` comment):** verify that the new Groq and
OpenRouter keys work with a quick inference test.

**Finding:** neither key works. Both repository secrets hold the same GitHub
personal access token that `OPENCODE_GITHUB_TOKEN` holds (40 characters,
`ghp_` prefix, identical SHA-256), so they are a copy/paste mistake, not
provider keys. Evidence:

- `GROQ_API_KEY` and `OPENROUTER_API_KEY` are byte-identical to `GH_TOKEN`;
- Groq `POST /openai/v1/chat/completions` (model `openai/gpt-oss-120b`):
  HTTP 401 in about 0.05 s, `{"error":{"message":"Invalid API Key",...}}`;
- OpenRouter `POST /api/v1/chat/completions` (model
  `inclusionai/ling-3.2-flash:free`): HTTP 401 in about 0.03 s,
  `{"error":{"message":"Missing Authentication header","code":401}}`;
- through OpenCode itself: `Error: Invalid API Key` (groq) and
  `Error: Missing Authentication header` (openrouter), both in about 2 s.

Two more gaps made this invisible and would have kept the "limit fix" from
working even with valid keys:

- the secrets are exported to the agent process, so OpenCode lists Groq and
  OpenRouter as *configured* (`opencode auth list`) although it cannot use
  them;
- the `OPENCODE_MODELS` repository variable still lists only free
  `opencode/*` models, so no keyed model is in the chain at all.

**Change:**

- new `.github/scripts/check-provider-keys.sh`: one tiny completion per
  configured provider, prints model, reply and seconds, or the exact error;
  a GitHub token in a provider secret is reported and never sent; `--strict`
  exits non-zero on failure;
- both agent workflows run it as a non-blocking preflight, so a rejected key
  is a visible warning instead of a silent fallback;
- `run-opencode-fallback.sh` drops keyed models whose key is missing or is a
  GitHub token (no attempt wasted, no token sent to a third party) and treats
  `Invalid API Key` as a provider failure, so the chain continues;
- tests: 9 new assertions in the runner suite (44 total) and a new 24
  assertion suite for the probe; `npm test` and `shellcheck` pass.

**Still open, needs the owner:** replace both secrets with the real keys
(`gh secret set GROQ_API_KEY` / `OPENROUTER_API_KEY`) and, once the probe
reports OK, extend `OPENCODE_MODELS` with the keyed models. No API can create
a provider key.
