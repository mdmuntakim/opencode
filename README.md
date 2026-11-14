# opencode

Personal opencode agent. Ask it anything through GitHub Issues.

The agent decides what to answer, investigate or build, and GitHub Actions runs it.

Every answer, investigation and build is triggered from an issue on this repository.

## What is in here

| Path | Description |
| --- | --- |
| `.github/workflows/opencode.yml` | Answers questions asked in issue / PR comments. |
| `.github/workflows/opencode-triage.yml` | Automatically answers newly opened issues. |
| `.github/workflows/release.yml` | Builds something and publishes it as a release. |
| `.github/workflows/protect-source.yml` | Fails pull requests that delete source files. |
| `.github/workflows/scripts-test.yml` | Lints the shell tooling and tests the agent runner. |
| `.github/scripts/publish-release.sh` | Builds an artefact and publishes it as a release asset. |
| `.github/scripts/gh-account.sh` | The account level operations (profile, tokens, repositories). |
| `.github/scripts/run-opencode-fallback.sh` | Runs the agent with model fallback and a test gate. |
| `prompts/triage.md` | The instruction used for automatic issue triage. |
| `AGENTS.md` | Context the agent loads for this repository. |

There is **no binary in the source tree**. Every build ends in a GitHub
Release and the binary is an asset of that release.

A *project* that an issue asks for (an app, a module, a daemon) gets its own
repository under `mdmuntakim/`; this repository is only the control plane. Project
releases are published in the project repository and always include the source
archive (`--source-archive`) next to the build and its checksums.

## How to use it

### Where does the answer appear?

**As a comment on the issue, right below your question.**

When you ask, the agent immediately adds a `👀` reaction to your comment and
posts a short `[Working...]` placeholder comment that links to the run. When
the agent finishes it **edits that same comment** into the final answer, so the
issue ends up with exactly one comment from the agent and no leftover
placeholder. The run log stays available under the
`[github run]` link at the bottom of the answer.

If the agent decides the issue needs a code change, it opens a pull request and
replies with a `Created PR #<n>` comment instead of a prose answer.

### Memory and reply style

Every agent job gets an explicit 8 GiB heap budget
(`NODE_OPTIONS=--max-old-space-size=8192`); the hosted runner itself has
16 GiB. Answers are posted as ordinary chat-style Markdown comments, not as
raw JSON or tool-call transcripts.

### Ask a question

Open an issue (or comment on an existing one) and write:

```
/oc what does the release of this repository contain?
```

or

```
/opencode explain how the triage workflow works
```

The agent reads the whole thread, then replies with its answer. If the answer
requires code changes it opens a pull request instead.

### Post-run validation

`run-opencode-fallback.sh` runs `npm test` after a model finishes, but only
when the repository actually has a `test` script in `package.json`. This
control repository has no application code, so its `package.json` maps
`npm test` to the shell regression suite that covers the agent runner; that
gives the gate something real to execute instead of failing with
`ENOENT: no such file or directory, open .../package.json`. A repository
without a manifest (or without a `test` script) is not a failed run: the gate
is skipped and `npm` is never started. The gate reads `GITHUB_WORKSPACE` (the
checkout root) so it does not matter which directory the workflow invokes the
script from, and it is skipped when `npm` is not installed. A failing test
suite is fed back to the model (the last 200 log lines) for up to
`OPENCODE_TEST_RETRIES` attempts.

A stall or a timeout aborts the agent process itself and moves to the next
model. The wrapper no longer streams through `tee`, because `$!` pointed at
`tee` and the timeout left the real agent running in the background.

The runner and its tests also run in CI on every pull request:

```bash
npm test        # the same shell suite, through the package manifest
npm run lint    # shellcheck on the runner and its tests
npm run check   # both
```

### Automatic answers

Every newly opened issue is answered automatically by the triage workflow.
Only the `opened` event is a trigger - if `edited` were included, GitHub would
emit a second event right after creation and every new issue would be
answered twice.

### Manual run

Go to **Actions → opencode-triage → Run workflow** and type your own prompt.

## Releases

Build output is never committed to the source tree. It is always published as
a release asset, and the release URL is what the agent reports back.

The SHA-256 of every published asset is written into the notes of the release,
so a download can be verified against the release it came from.

The releases of this repository:

- https://github.com/mdmuntakim/opencode/releases

Ask for a build and the agent publishes it:

```
/oc build the final ld binary from mdmuntakim/ld and publish it as a release
```

The same can be done from the Actions tab: **Actions → release → Run
workflow**. The build always runs in a scratch copy of the source, so the
checkout is never modified.

### Downloading the .deb

The package is published as a release asset, byte-for-byte as it was built,
so the blob on GitHub has the exact same SHA-1 as the file on the device:

```bash
gh release download v2.0.22 --repo mdmuntakim/opencode \
  --pattern 'opencode_2.0.22_aarch64.deb'
```

Verify it after downloading:

```bash
sha256sum opencode_2.0.22_aarch64.deb
# 629b6819e40418b96a8dedfc15f8b6cac8f5e4b54682d9f4194c59b68aa95829
```

## Reach of the agent

The agent authenticates with a token that has access to **every repository of
the `mdmuntakim` account**, so it can read and modify any of them, not just this
one. You can ask it to work on another repository:

```
/oc fix the failing build in mdmuntakim/su and open a PR there
```

It can also work on the account itself - the profile, the repositories, the
releases and the tokens. `.github/scripts/gh-account.sh` is the interface:

| Command | What it does |
| --- | --- |
| `whoami`, `scopes` | the login, the id and the scopes of the token in use |
| `profile`, `profile bio="..." company="..."` | shows and changes the profile |
| `username` | shows the login and explains how to rename the account |
| `emails`, `ssh-keys` | the e-mail addresses and the SSH keys of the account |
| `pat --name NAME [--repo OWNER/NAME]` | creates a new personal access token |
| `repo-create NAME [--public\|--private]` | creates a repository |

Two limits are worth knowing:

- **The login of the account cannot be changed with an API.** GitHub only
  allows it in the browser, `username` prints the exact steps.
- **Creating a token needs the `OPENCODE_ADMIN_TOKEN` secret**, a fine grained
  token with `Administration: write`. A classic token cannot create other
  tokens. Without that secret the `pat` command stops with a clear message
  and everything else still works.

## Setup details

- **Model** – the runner uses free models only, in this fallback chain:
  `opencode/glm-5.3-flash-free opencode/deepseek-v4.1-flash-free
  opencode/flint-40b-free opencode/beam-free
  opencode/mimo-v2.6-flash-free`.  The first entry is used for the session and
  the rest back it up when a model stalls, times out or hits a free tier limit,
  so the job keeps running on free capacity as long as one entry holds. No
  provider API key is required. To use a keyed model, add an `OPENCODE_API_KEY`
  secret and set the repository variable `OPENCODE_MODELS` to a chain that
  lists the keyed models first, for example
  `opencode-go/glm-5.3-flash opencode-go/kimi-k2.7-code`. Free models are rotated
  by the provider, so if a run fails with `Model not found` or
  `Free usage limit reached`, pick a working model and update the
  `OPENCODE_MODELS` variable. Google/Gemini is not used, even when a
  `GOOGLE_API_KEY` or `GEMINI_API_KEY` secret exists.
- **Permissions** – a headless runner has nobody to approve a prompt.
  `external_directory` and `doom_loop` default to `"ask"`, so the agent used
  to wait forever and the job was cancelled at GitHub's 6 hour limit. The
  repository therefore has an `opencode.json` with `"permission": "allow"`,
  and both workflows export `{"*":"allow"}` in `OPENCODE_PERMISSION` so every
  permission is granted automatically, also when the agent works in a scratch
  directory. The agent jobs also have `timeout-minutes: 350` as a backstop, and
  a single model attempt may run for 45 minutes (the watchdog only gives up
  after 15 minutes without any output, because a long compile is silent but
  still working).
- **Resuming a failed run** – the agent works in `/tmp/opencode` and
  `/tmp/scratchpad`. After every run, successful or not, those trees are
  archived and uploaded as the `agent-checkpoint-<issue>` artifact (kept for 14
  days). The next run for the same issue downloads the newest checkpoint and
  unpacks it before the agent starts, so a model limit or a timeout continues
  from the saved state instead of starting over. A failed run also leaves a
  comment on the issue saying so.
- **Auth** – the workflows read the token from the `OPENCODE_GITHUB_TOKEN`
  secret (an optional `PAT_TOKEN` secret wins) and may use the optional
  `OPENCODE_ADMIN_TOKEN` secret. No GitHub App has to be installed.
- **Agent install** – opencode is installed directly from the official installer
  (`curl -fsSL https://opencode.ai/v2/install | bash -s -- --version 2.0.22`)
  instead of the `anomalyco/opencode` action, which used to fail on its version
  lookup step. The version is pinned on purpose.

## Fixing `Free usage limit reached`

When every model in the fallback chain stops with `Error: Free usage limit
reached` the GitHub Actions runner, the workflow and this repository are fine —
the limit is enforced on the OpenCode account server side. There is **no
permanent unlimited mode without either a subscription or a key**; the options,
in order of cost:

1. **Wait for the quota to reset.** The free models are rate limited per
   account; once the window passes the same workflow works again with no
   changes. (Current judged status: reset is not reliable.)
2. **Add free provider keys.** Create a free account at one or more of
   [Groq](https://console.groq.com/) (`GROQ_API_KEY`),
   [OpenRouter](https://openrouter.ai/) (`OPENROUTER_API_KEY`),
   [NVIDIA](https://build.nvidia.com) (`NVIDIA_API_KEY`),
   [Mistral](https://console.mistral.ai/) (`MISTRAL_API_KEY`) or
   [Cerebras](https://inference.cerebras.ai/) (`CEREBRAS_API_KEY`), then run
   `gh secret set <NAME> --repo mdmuntakim/opencode` for each. Set the repo
   variable `OPENCODE_MODELS` to a space separated fallback chain that lists
   those providers first, and the runner will use the free opencode models
   only as a last resort. Free tiers still rate limit, so this raises the
   ceiling; it does not remove it.
3. **Subscribe to OpenCode Go** ($10/month) or **Go Plus** — see
   [opencode.ai/v2/docs/console/go](https://opencode.ai/v2/docs/console/go/).
   Copy the key from the OpenCode Console and run
   `gh secret set OPENCODE_API_KEY --repo mdmuntakim/opencode`. Then set the
   `OPENCODE_MODELS` variable to e.g.
   `opencode-go/glm-5.3-flash opencode-go/kimi-k2.7-code opencode-go/deepseek-v4.1-flash`
   (model ids from the Go docs). Paying is the only officially supported way
   to get sustained, reliable capacity.

The fallback wrapper treats quota/auth/stall failures from *any* model as a
signal to switch to the next one (it recognises `FreeUsageLimitError`,
`Free usage limit`, `429`, `RESOURCE_EXHAUSTED`, `billing`, `quota`, `rate
limit`, `subscription`, `not configured`, `not authenticated`, `ProviderError`,
`model not found`, `model unavailable`, `401`/`403`, …), so an exhausted
provider, an unset key or a dead model no longer aborts the whole run before
the remaining models are tried.

### Logging the runner in instead of staying anonymous

GitHub-hosted runners share egress IPs, and anonymous free inference is
already saturated on them — the jobs fail with `Free usage limit reached`
even though the same models answer fine from a normal network connection.

Logging the runner into an OpenCode Console account lifts that anonymous
pool limit (`opencode auth login` → *Console* → *device*), and the token can
be handed to the workflow as a secret:

    opencode auth export > auth.json
    gh secret set OPENCODE_AUTH_JSON --repo mdmuntakim/opencode < auth.json

Both agent workflows import it with `opencode auth import` before the agent
starts, and stay anonymous when the secret is absent. The account still has to
satisfy its own free-tier limits; subscribing to OpenCode Go is the path to
sustained capacity.

## Secrets used

| Secret | Required | Purpose |
| --- | --- | --- |
| `OPENCODE_GITHUB_TOKEN` | yes | Token used for the GitHub API and for git clone/fetch/push. Needs `repo` and `workflow` scopes to reach all repositories. With the `user` scope it can also change the profile, with `admin:public_key` it can manage the SSH keys. |
| `OPENCODE_ADMIN_TOKEN` | no | Fine grained token with `Administration: write`. It is the only way to create further tokens. |
| `OPENCODE_API_KEY` | no | Only needed if you switch away from the free model (e.g. an OpenCode Go key). |
| `OPENCODE_AUTH_JSON` | no | `opencode auth export` of an OpenCode Console login; when present the agent workflows authenticate instead of staying anonymous (fixes `Free usage limit reached` on GitHub-hosted runners). |
| `OPENROUTER_API_KEY`, `GROQ_API_KEY`, `NVIDIA_API_KEY`, `MISTRAL_API_KEY`, `CEREBRAS_API_KEY` | no | Free-tier provider keys; together with the `OPENCODE_MODELS` repo variable they decide what the fallback chain tries. |

### Rotating the token

Create a classic personal access token with the `repo` and `workflow` scopes,
then update the secret:

```bash
gh secret set OPENCODE_GITHUB_TOKEN --repo mdmuntakim/opencode
```

### Adding the administration token

Create a **fine grained** personal access token for the `mdmuntakim` account with
the `Administration: write` permission, then store it:

```bash
gh secret set OPENCODE_ADMIN_TOKEN --repo mdmuntakim/opencode
```

With that secret the agent can create new personal access tokens through
`.github/scripts/gh-account.sh pat`.
