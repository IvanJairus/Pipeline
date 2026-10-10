# Pipeline gateway, reference

A sanitised reference implementation of the delivery gateway described on
[my portfolio](https://portofolio-six-delta-18.vercel.app). It is **not** the
production repository and it is **not** a copy of one: hostnames, IP addresses,
project paths and service names were replaced by a deterministic script, and the
raw files are excluded by `.gitignore`.

## The design in one paragraph

Source repositories do not carry CI configuration at all. Delivery lives in a
separate project group: one gateway, one service map per domain, and per-stage
scripts. A release board resolves *what* is being released, the gateway resolves
*how*, and the developer's repository stays clean: no `.gitlab-ci.yml` to copy,
drift, or forget to update. Where a repository is GitLab-native and wants its own
pipeline, it attaches with a short `include` instead.

That separation is the whole point. Patching a scanner version, a gate rule or a
Vault path happens in one place and reaches every service the next time it runs.

## Layout

```
ci-library/
  gateway.yml                  routing: which service map, which stage set
  includes/gitlab-ci.yml       what a GitLab-native repo includes
  templates/                   one stage set per artifact family, all DAG-shaped
    backend.yml                jar: build, test, four scans, gate, deploy, promote
    web.yml                    bundle + image, a11y job, web never precedes its API
    platform.yml               config/discovery/edge: auto-rollback, because these
                               are the services other services find things with
    library.yml                built and published, never deployed: promotion is
                               refused by the rules, not by a missing button
    mobile.yml                 signed bundle, internal track only
  scripts/
    lib/log.sh                 one log line, four implementations agree on it
    build-maven.sh             jar path: build, version stamp, artifact handoff
    run-scan.sh                security stage: image + filesystem scanning
    setup-vault-jwt.sh         short-lived JWT against Vault, per pipeline
    publish-artifact.sh        image digest, maven deploy, apk sign, track upload
    deploy.sh                  render, apply, wait for rollout, promote, roll back
    ticket-sync.sh             which ticket this run belongs to, then post the verdict
    observability-push.sh      metrics and one audit line, never an invented number
    run-gate.groovy            the GitLab side of the same three Groovy classes
  tools/
    release_stamp.py           version, build-info.json, SBOM and config checks
    ticket_sync.py             idempotent, retried, credential-blind ticket writes
  examples/
    release.json               a manifest the rules accept, with synthetic ids
    trivy-report.json          the passing scan
    trivy-refused.json         the same scan with one critical in it
    sonar-gate.json            quality-gate response, coverage and duplication
    replay.sh                  runs the chain and writes transcript.txt
    transcript.txt             real output of the above, one uniform log shape
jenkins/
  GatewaySIT.groovy            the same stage contract on the legacy engine
  templates/deployment.yaml    rendered manifest for the container platform
shared-library/
  src/com/reference/release/   the standard as plain, testable Groovy classes
  vars/                        five pipeline steps that call those classes
  test/run.groovy              19 assertions, no test framework
  README.md                    why the rules live in src/ and not in the steps
```

## The log line

Everything that writes to a console in this repository writes the same shape:

```
2026-10-10T23:41:02.118+07:00 INFO deploy:sit applying revision=1421 tier=1
```

RFC3339 with an offset, a level, the job, the message, then `key=value` pairs.
GitLab produces that shape with `gitlab-runner --timestamps`; Jenkins produces
the same clock through the Timestamper plugin. Four implementations agree on it
(`lib/log.sh`, `run-gate.groovy`, `release_stamp.py`, `ticket_sync.py`), and each
one tests its own rendering in `--selftest`, because a format nobody checks is a
format that drifts.

## Running the checks locally

```bash
groovy -cp shared-library/src shared-library/test/run.groovy
groovy -cp shared-library/src ci-library/scripts/run-gate.groovy --selftest
for s in publish-artifact deploy ticket-sync observability-push; do
  bash "ci-library/scripts/$s.sh" --selftest
done
python3 ci-library/tools/release_stamp.py --selftest
python3 ci-library/tools/ticket_sync.py --selftest
bash ci-library/examples/replay.sh          # writes the transcript, then checks it
bash scripts/check-sanitised.sh --selftest  # a gate that cannot fail is not a gate
bash scripts/check-sanitised.sh
node rules/run-fixture.mjs                  # 31 golden cases, JS against Groovy
```

The selftests need no network and no runner: `ticket_sync.py` starts a real HTTP
server on loopback and points itself at it, and everything else runs with
`DRY_RUN=1`. CI runs the same commands against a checksum-pinned Groovy 5.0.3,
along with `bash -n`, shellcheck, YAML parsing, an `include:` target check,
gitleaks and the internal-identifier gate.

Two bugs found this way rather than by reading: `tierOf()` is not idempotent, so
mapping a plan through it a second time turned every service into a gateway tier;
and `null as Double` is `0.0` in Groovy, which would have reported an unmeasured
coverage as "0.0%, below floor" instead of "not measured".

## How a service is delivered

1. A card moves on the board; the board opens a branch and a merge request.
2. A human merges. Nothing else triggers a deploy.
3. The gateway reads the service map, picks the stage set for that artifact type,
   and runs build → scan → composite gate → deploy.
4. The gate fails closed: an unevaluable scan is a failure, not a warning.
5. Promotion between environments is tag-and-merge, and the result is written
   back to the ticket and to an append-only ledger.

## What was measured, and where the numbers come from

Taken from the private GitLab API on 2026-10-08. Readers cannot reproduce them;
I can walk through them.

| Figure | Meaning | Sample |
|---|---|---|
| 53 | distinct services declared across the service maps | union of 6 map files, deduplicated by name |
| 99 | repositories in the platform source group | all, 43 active within 30 days |
| 46 | of those, with at least one pipeline run | API `X-Total` per project |
| 10 | projects in the pipeline group | the delivery side of the separation |
| 7 550 | pipelines across those 10 projects | summed `X-Total` |
| 93 s | median deploy job to an app-server VM | n=13 successful jobs, p90 162 s, range 19–199 s |
| 80 s | median SonarQube scan job | n=30 successful jobs, p90 140 s |
| 0 | `.gitlab-ci.yml` files in the 99 source repositories | that is the design, not an oversight |

## What is deliberately absent

Secrets and their locations, real hostnames and addresses, internal project
paths, service and application names, cluster namespaces, resource limits,
retention windows, and anything an auditor would want from the real system
rather than from a reference.

## Licence

MIT: the code shape is free to use. The prose describing my employment context
is under the same terms as the rest of my published work.
