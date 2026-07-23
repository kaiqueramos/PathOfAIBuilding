# PathOfAIBuilding security and distribution

## Security model

PathOfAIBuilding does not ship an API key or an AI service. Each user configures an
OpenAI-compatible HTTPS endpoint, model, and personal API key.

The key is used only in the `Authorization: Bearer` header sent to that configured
endpoint. It is never included in the build payload, chat history, PoB share code,
release archive, or debug log.

## Local configuration

Use the `AI Setup` button in PoB's bottom toolbar:

1. Enter an HTTPS endpoint, API key, and model identifier.
2. Click `Test Connection`.
3. Save only after the connection succeeds.

The key field is masked in the UI. PathOfAIBuilding stores the configuration in
`ai_config.json`:

- Portable archive: next to `Path of Building.exe` in the extracted directory.
- Installed Windows build: `%APPDATA%\\Path of Building\\ai_config.json`.
- Wine: the equivalent `Path of Building` directory inside the selected Wine
  prefix.
- Source/development checkout: under `src/`, because PoB runs in Dev Mode.

On systems where the filesystem supports POSIX permissions, the application
attempts to set mode `0600`. The file is plaintext local configuration; this V1
does not use Windows Credential Manager or another OS keychain. Protect the
directory and do not share the file.

The repository ignores `ai_config.json`, `ai_debug.log`, `.ai_key`, `.ai_secrets`,
`ai_keys/`, and user-specific `Settings*.xml` files.

## Network and data disclosure

- Endpoints must use `https://`.
- Requests have a configurable total timeout and a bounded connect timeout.
- The configured provider receives the user's question, bounded conversation
  history, the current build's calculated core state, and any optional context
  required by that question.
- Additional context is requested at most once per question.
- No trade API, telemetry endpoint, analytics service, or hidden proxy is used in
  V1.

Use only a provider you trust with build data. Provider retention and training
policies are outside PathOfAIBuilding's control.

## Action safety

Model output is untrusted input. Before PoB changes the active build, the bridge:

1. Parses a dense JSON action array and rejects malformed or unknown actions.
2. Validates all 18 action schemas and their domain constraints.
3. Runs the whole batch against an isolated cloned build.
4. Recalculates that clone and shows the actual DPS, EHP, max-hit, and passive-point
   diff.
5. Requires the active build fingerprint to still match the preview.
6. Applies only after explicit user confirmation.
7. Stops on an unexpected failure and restores temporary simulation mutations.

This prevents silent partial application and stale previews. It does not make an
LLM's advice correct; the user must still review the proposed changes and PoB
numbers.

## Logging

Normal operation does not log the API key. `AIConfig:GetSanitizedConfig()` exposes
only `[CONFIGURED]` or `[EMPTY]` in place of the key.

`ai_debug.log` is local diagnostic output and is ignored by Git and excluded from
release manifests. Do not attach it to a public issue without reviewing its build
and provider-error content.

## Release controls

`scripts/package_release.py` builds the portable archive from the tracked runtime
and release manifest. It:

- starts from the clean Windows runtime archive;
- validates every manifest-managed source file against its SHA-1;
- rejects local configs, debug logs, settings, build saves, and Git metadata;
- writes a local manifest pinned to the stable `release` branch;
- emits a SHA-256 digest for the completed archive.

The GitHub release workflow publishes both the archive and `SHA256SUMS.txt`.

## Developer checklist

Before publishing a release:

- [x] `ai_config.json` and related secret files are ignored.
- [x] `ai_config.example.json` contains no real key.
- [x] The UI masks the key and validates endpoint, model, and key.
- [x] HTTPS is mandatory.
- [x] HTTP requests have total and connect timeouts.
- [x] Logs never intentionally include the key.
- [x] Model actions are structurally validated and preflighted in isolation.
- [x] The generated archive contains no local config, log, settings, or build save.
- [x] The focused AI tests and full PoB suite pass on the release commit.
- [x] A clean portable archive boots and opens the AI-enabled PoB UI.

## If a key is exposed

1. Revoke it immediately at the provider.
2. Remove the file or secret from the repository and release artifact.
3. Rewrite Git history if the key was committed.
4. Rotate any other credentials stored with it.
5. Publish a corrected release and notify affected users.

References:

- [GitHub secret scanning](https://docs.github.com/en/code-security/secret-scanning)
- [OpenAI API keys](https://platform.openai.com/api-keys)
- [Qwen Cloud](https://dashscope.console.aliyun.com/)
