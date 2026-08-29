# `serverlab` — the driver

Everything in this repository that is worth repeating is a bash script: the
package build, the ISO build, the autoinstall drive, the VM, the collectors and
the acceptance lists. Those scripts follow the conventions of upstream Omarchy,
they are readable on their own, and they are meant to stay runnable by hand.

What they were missing is the layer above: the order they go in, the environment
each one needs, the `LAB_OUT` that keeps one machine's disk and ssh key from
another's, and the report written from what they produced. That layer was a
paragraph in a README and a shell history. `serverlab` is that layer as a
program — a single static Go binary, no daemon, no state outside the repository.

```bash
make serverlab          # builds bin/serverlab (gitignored)
./bin/serverlab doctor  # what this host is missing
```

## What it wraps

`serverlab` runs no build logic of its own. Every subcommand shells out to the
script that already does the work, with the right arguments and environment,
streams its output line by line behind a `[label]` prefix, times it, stops at
the first failure, and appends to a run log.

| Command | What it runs |
|---|---|
| `serverlab pkgs build [PKG…]` | `pkgs/build.sh` — the server packages, signed, into `pkgs/repo/`, built against the **working tree** of `profile/server/` |
| `serverlab pkgs test` | `pkgs/test.sh` — installs them in a clean `archlinux` container |
| `serverlab pkgs verify [--build]` | in `omarchy-server-pkgs`: `scripts/publish.sh --local` then `scripts/verify.sh` — the published repository over HTTP, including the hostile-mirror cases |
| `serverlab pkgs publish --yes` | in `omarchy-server-pkgs`: `scripts/publish.sh` — uploads the assets. Refuses to run without `--yes` |
| `serverlab iso build [--profile P] [--fresh] [--debug]` | `iso/build.sh` |
| `serverlab lab up NAME [flags]` | `pocs/lab/mkcidata.sh` → `vm.sh create` → `vm.sh start` → `vm.sh wait-ssh` |
| `serverlab lab test NAME [--suite S]` | `collect.sh` → `surface.sh` → `acceptance*.sh` → `reboot-check.sh`, then publishes the evidence into `pocs/server-install/reference/<name>/` unless `--no-publish` |
| `serverlab lab down\|status\|ssh\|screenshot NAME` | the matching `vm.sh` command |
| `serverlab report NAME` | no script: writes `reports/YYYY-MM-DD-<name>.md` from the evidence files |
| `serverlab all` | all of the above, in order, with a summary table |

Every run writes `pocs/lab/runs/<timestamp>-<command>.log` (gitignored) and
prints its path at the end, so a failure that scrolled past is still readable
and a CI job has exactly one file to upload.

## One command, from a checkout to a report

```bash
serverlab all --profile server --name srv
```

That is: build and sign the packages, install them in a container to prove they
are installable, build the ISO with the profile's offline mirror, generate the
autoinstall drive, create and boot a VM, wait for the install to answer over
ssh, collect the artifacts, measure the attack surface, run the acceptance list
the machine was installed for, reboot it and check it came back, then write the
report and add its row to `reports/README.md`. It ends with a timing table and
exits non-zero if any step failed.

`--dry-run` prints the plan and touches nothing, which is how a two-hour run is
reviewed before it starts:

```bash
$ serverlab all --dry-run --name srv --iso iso/release/omarchy-2026.08.29-x86_64-server-local.iso
plan for `serverlab all` in /…/omarchy-server:

  1. pkgs build     pkgs/build.sh — build and sign the server packages into pkgs/repo/
  2. pkgs test      pkgs/test.sh — install them in a clean archlinux container
  3. lab up         mkcidata + vm create + start + wait-ssh for `srv` (profile server), 4 vCPU, 8 GiB, 40 GiB disk, from omarchy-2026.08.29-x86_64-server-local.iso
  4. lab test       collect + surface + acceptance + reboot-check, into the lab's evidence directory
  5. report         reports/2026-08-29-srv.md, and the index row
```

`--iso PATH` reuses an image instead of spending an hour building one;
`--skip-pkgs`, `--skip-iso` and `--skip-report` drop stages.

## A lab remembers what it is

`lab up` writes `lab.json` into the lab's own `LAB_OUT`
(`pocs/lab/out-<name>/`, gitignored) with the profile, the addons, the MAC
marker, the Secure Boot flag, the VM shape and the ISO it was installed from.

That is what makes `lab test` a one-word command: a machine installed with
`--mac selinux` gets `acceptance.sh` **and** `acceptance-selinux.sh` from
`--suite all`, and asking for a suite the machine was not installed for is
refused rather than run against a kernel with no SELinux in it.

```bash
serverlab lab up srvsel --profile server --mac selinux --hostname omarchy-selinux
serverlab lab test srvsel --suite all --enforce   # permissive pass, then ENFORCE=1
serverlab report srvsel
```

Evidence goes to `pocs/lab/out-<name>/evidence/`, one directory per machine, so
two labs never overwrite each other's record.

## Evidence that a reader can open

`pocs/lab/out-<name>/` is gitignored, which makes it the wrong place for a
report to point at: the report is committed, the file it cites is not, and a
link in `reports/` resolves to nothing in a fresh clone. So `lab test`
**publishes** by default — it copies every file it produced (the `acceptance*.txt`
of each suite, `surface.txt`, `reboot-check.txt` and everything `collect.sh`
gathered) into `pocs/server-install/reference/<name>/`, which is committed.
That directory is the record; the lab's own directory is the working copy.

The **`<name>`** matters. The flat files at the top of `reference/` predate this
and are cited by the hand-written reports — the `packages-all.txt` there is the
*desktop* reference install, not a server one — so a run that published on top
of them would rewrite the evidence behind a report nobody touched. One
subdirectory per lab means publishing grows the record instead of overwriting
it, and two labs never collide.

```bash
serverlab lab test srv --suite base                # publishes, and the report links resolve
serverlab lab test scratch --suite base --no-publish   # a throwaway run, kept out of the record
```

`--no-publish` (also on `serverlab all`) is for a run that should not become the
record: a debugging pass, a machine deliberately broken to see what fails, a
second lab whose evidence would sit on top of the first one's.

`serverlab report` follows the same rule per file rather than per run: a link
points at `../pocs/server-install/reference/<name>/<file>` when the published copy is
**byte for byte** the file the report was written from, and at the lab's private
path when it is not. A `--no-publish` run therefore keeps its private links, and
so does a file another lab has since overwritten — a stale link is never
presented as the record.

## How the report is generated

`serverlab report NAME` reads the lab's evidence directory and writes a report
with the same structure as the hand-written ones. Each section comes from a
file:

| Section | Source |
|---|---|
| Title / Date / Subject / Result | `lab.json` plus the `=== N passed, M failed ===` trailer of every acceptance file |
| Scope | `lab.json` — profile, addons, MAC, Secure Boot, unattended updates |
| Environment | `lab.json` for the VM shape and the firmware; the ISO file for its name, size and `sha256` (read from the `.sha256` beside it, computed when absent); the reconstructed `mkcidata.sh` command line; the timestamp in the acceptance header |
| Method | the `serverlab` commands that reproduce the run, and the scripts they call underneath |
| Results — one table per suite | `acceptance*.txt`, parsed into `#`, item, verdict and one evidence line per check |
| Results — attack surface | `surface.txt` (packages, size, units, listeners, setuid, root services) |
| Results — reboot survival | `reboot-check.txt` |
| Evidence | links to every file above, relative to `reports/` |
| Limitations | a placeholder |

The evidence column quotes the **last** line of a check's output that is not a
pacman warning — the line the script's own pattern was matched against. It is a
heuristic, and where it picks a less telling line than a human would, the linked
evidence file is the authority.

The last section is deliberately not written. What a report is worth is the
prose a generator cannot produce: why a number moved, which bug the run found,
what the environment does not cover. `## Limitations` therefore arrives as three
`TODO` lines to be replaced by hand, and the section says the tables were
generated. A report nobody edited is visible as such.

The index row in `reports/README.md` is inserted directly under the table
header, which is where "newest first" puts it.

## Configuration

`serverlab.toml` at the repository root holds the paths to the sibling
checkouts, the default profile and the VM sizing. Every value in it is also the
built-in default, so the tool works in this checkout with no configuration at
all; the file exists for a machine where something lives elsewhere.

An environment variable overrides the file, and the two names the bash scripts
already read are honoured, so an exported shell keeps working:

| Setting | Env |
|---|---|
| `paths.pkgs_repo` | `SERVERLAB_PKGS_DIR`, `OMARCHY_PKGS_DIR` |
| `paths.tui_tools` | `SERVERLAB_TUI_TOOLS_DIR`, `TUI_TOOLS_DIR` |
| `defaults.profile` | `SERVERLAB_PROFILE` |
| `vm.disk_gb` / `data_disk_gb` / `memory_mb` / `cpus` | `SERVERLAB_DISK_GB`, `SERVERLAB_DATA_DISK_GB`, `SERVERLAB_MEM_MB`, `SERVERLAB_CPUS` |
| the repository root itself | `SERVERLAB_ROOT` |
| the config file | `SERVERLAB_CONFIG` |

## How a runner would call it

There is no remote runner yet, and nothing here needs one: `serverlab` is a
binary that takes arguments and exits non-zero when something failed. A
self-hosted runner with docker, qemu and KVM runs the same three lines a person
does.

```yaml
# .github/workflows/lab.yml, on a self-hosted runner
- run: make serverlab
- run: ./bin/serverlab doctor
- run: ./bin/serverlab all --profile server --name ci
- if: always()
  uses: actions/upload-artifact@v4
  with:
    name: lab-run
    path: |
      pocs/lab/runs/
      pocs/lab/out-ci/evidence/
      reports/
```

Three properties make that work, and they are the reason the tool is shaped this
way: **the exit status is the verdict** (any failed step fails the run);
**everything a run produced is under two directories** (the run log and the
lab's evidence); and **nothing depends on the operator's shell** — the paths, the
profile and the VM shape come from `serverlab.toml` or its environment
overrides, never from an ambient `LAB_OUT`.

What a runner still needs from a human: the lab signing key (`pkgs/keys/`,
generated on first run and never committed), `gh auth` for
`serverlab pkgs publish`, and the decision to publish at all.

## Testing the driver

```bash
make test    # gofmt, go vet, go test
```

The tests cover the three pieces with no VM in them: the acceptance parser
(including a multi-line command, an interrupted run with no trailer, and the
pacman warnings that must not become evidence), the report generator against a
golden file built from a real `acceptance.txt`, and the configuration loader
with its file-then-environment precedence. `go test ./... -update` rewrites the
golden file when the report format changes on purpose.
