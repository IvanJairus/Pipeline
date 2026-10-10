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
  scripts/
    build-maven.sh             jar path: build, version stamp, artifact handoff
    run-scan.sh                security stage: image + filesystem scanning
    setup-vault-jwt.sh         short-lived JWT against Vault, per pipeline
jenkins/
  GatewaySIT.groovy            the same stage contract on the legacy engine
  templates/deployment.yaml    rendered manifest for the container platform
shared-library/
  src/com/reference/release/   the standard as plain, testable Groovy classes
  vars/                        five pipeline steps that call those classes
  test/run.groovy              19 assertions, no test framework
  README.md                    why the rules live in src/ and not in the steps
```

## Running the checks locally

```bash
groovy -cp shared-library/src shared-library/test/run.groovy
groovyc -cp shared-library/src -d /tmp/out \
  $(find shared-library/src shared-library/vars -name '*.groovy')
```

Both run in CI against a checksum-pinned Groovy 5.0.3, along with `bash -n`,
shellcheck, YAML parsing, gitleaks and the internal-identifier gate.

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
