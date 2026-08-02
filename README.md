# aur-safe-update

`aur-safe-update` is a small Bash wrapper for `paru` or `yay` that checks pending AUR upgrades against [AURWatch](https://aurwatch.org/) before allowing the helper to run a full system update.

It is a defense-in-depth check, not a replacement for reviewing PKGBUILDs and upstream sources. A clean automated scan cannot prove that a package is safe.

## How it works

1. Uses `paru -Qua` or `yay -Qua --aur` to list pending AUR upgrades.
2. Intersects that list with packages reported by `pacman -Qmq`, so only installed foreign packages are checked.
3. Requests the AURWatch verdict for each candidate.
4. Compares the verdict's scan time with the package's current `LastModified` value from the AUR RPC.
5. Applies the policy below, then runs the selected helper as `paru -Syu` or `yay -Syu` with any supplied arguments.

The default policy is fail-closed:

- `clean`: continue.
- `low`: display the findings and continue.
- `medium`: require interactive confirmation.
- `high`: block the update.
- API errors, invalid responses, missing metadata, stale scans, and unknown verdicts: block the update.

All candidate packages are checked before the helper starts. One blocked package prevents the entire update.

## Requirements

- Arch Linux or an Arch-based system with `pacman`
- Bash 4 or newer
- One supported AUR helper: `paru` or `yay` (`paru` is preferred when both exist)
- `curl`
- `jq`
- GNU `date` from `coreutils`

## Installation

Install for the current user:

```bash
install -Dm755 aur-safe-update "$HOME/.local/bin/aur-safe-update"
```

Ensure `$HOME/.local/bin` is on `PATH`, then run:

```bash
aur-safe-update
```

To install system-wide instead:

```bash
sudo install -Dm755 aur-safe-update /usr/local/bin/aur-safe-update
```

To update an existing installation, rerun the same `install` command with the
new script. To uninstall it, remove the installed `aur-safe-update` file.

## Usage

Run a normal system update:

```bash
aur-safe-update
```

Arguments are appended to the helper's final `-Syu` invocation. For example:

```bash
aur-safe-update --needed
```

Arguments are **not** applied to the earlier update-discovery command. Do not
pass package names or options such as `--devel` that can expand the final
transaction: the helper could then install a package or revision that was not
in the checked candidate list. Run without arguments whenever possible, and
limit forwarded options to ones that do not add installation targets.

If there are no pending AUR upgrades, the script skips AURWatch and immediately
delegates to the helper so official repository upgrades still run. This also
means package targets passed as arguments would be installed without an
AURWatch check.

### Fail-open review mode

To turn API, freshness, and unknown-verdict failures into an interactive warning instead of a hard block:

```bash
AURWATCH_FAIL_OPEN=1 aur-safe-update
```

This mode still blocks `high` verdicts. It also refuses to continue when standard input is not a terminal, because confirmation cannot be obtained safely.

`AURWATCH_FAIL_OPEN` accepts only `0` or `1`.

### Custom endpoints

Both endpoints must use HTTPS. They can be overridden for testing or self-hosted compatible services:

```bash
AURWATCH_API=https://example.test/api/v1/check \
AUR_RPC=https://example.test/rpc/v5/info \
aur-safe-update
```

The AURWatch-compatible response must be a JSON object whose `pkg` matches the requested package. The script expects `status`, `last_scanned`, and optional `rules` fields.

The script disables user curl configuration and restricts curl to HTTPS so a
local `.curlrc` cannot weaken these requests.

### Network and privacy

For every pending AUR upgrade, the script sends the package name to AURWatch
and the public AUR RPC. Those services also receive the network metadata
normally associated with an HTTPS request, including the source IP address.
The script does not intentionally send the complete installed-package list or
any credentials.

Proxy environment variables supported by curl can still route these requests
through a configured proxy. User curl configuration files are ignored.

## Exit behavior

- `0`: the selected helper completed successfully.
- `2`: AUR updates or installed foreign packages could not be enumerated.
- `3`: at least one package or required safety check blocked the update.
- `4`: interactive review was unavailable or declined.
- `64`: invalid configuration.
- `127`: a required command or supported AUR helper was not found.

Once the helper starts, its exit status is returned unchanged.

## Security model and limitations

This wrapper is intended to catch known AURWatch findings and prevent an old
scan from being mistaken for a scan of the current recipe. Its decision is
point-in-time and should be treated as an additional review signal, not an
authorization guarantee.

### Outside the wrapper's scope

- AURWatch is an external service, and automated analysis can have false
  negatives. A `clean` verdict does not prove that a package is safe.
- The wrapper checks recipe metadata, not every downloaded source archive,
  generated build output, or upstream release artifact.
- Packages absent from the initial helper update list are not checked.
- Additional package targets or scope-changing options forwarded to the final
  helper command are not checked.
- The wrapper does not protect against a compromised AUR helper, package
  manager, local system, TLS trust store, AUR service, or AURWatch service.

For sensitive packages, inspect the PKGBUILD, `.SRCINFO`, install scripts,
patches, source URLs, checksums, and upstream release signatures before
updating.

## Troubleshooting

- **Exit 2:** the script could not establish the candidate set. Run the helper's
  query command and `pacman -Qmq` directly to identify the failing command.
- **Exit 3:** at least one result blocked the transaction. Review every package
  URL printed above the final error.
- **Exit 4:** a medium or fail-open result required confirmation, but input was
  non-interactive or confirmation was declined. Run from a terminal to review
  interactively; do not pipe an automatic `yes`.
- **API or AUR RPC outage:** the default policy blocks the update. Fail-open
  mode is available for an explicit interactive override, but high verdicts
  remain blocked.
- **Unexpected helper selection:** `paru` is preferred when both supported
  helpers are installed.

## Development checks

Development requires `just` and `shellcheck` in addition to the runtime
requirements above.

The regression suite uses temporary command mocks and never invokes the real
package manager or AUR helper. Run all syntax, ShellCheck, and smoke checks with:

```bash
just verify
```

The checks can also be run separately:

```bash
just lint
just test
```

## License

This project is licensed under the [MIT License](LICENSE).
