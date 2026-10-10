# Shared library: the standard as executable code

Five pipeline steps and the rules behind them. Split deliberately: the decisions
live in `src/` as plain Groovy classes with no Jenkins types, and `vars/` holds
the thin layer that talks to a controller. That split is what makes the standard
testable: a rule you cannot run is a rule you cannot trust.

## Layout

```
src/com/reference/release/
  ReleaseRules.groovy      branch, tag, manifest and approval-chain rules
  DeploymentPlan.groovy    manifest -> ordered waves, with skip decisions
  GateResult.groovy        deploy + quality + scan -> one fail-closed verdict
vars/
  validateTicket.groovy    refuses a release the standard does not describe
  mergeApprove.groovy      five layers, and segregation of duties at merge time
  deployPlan.groovy        triggers waves, stops on the first failing wave
  qualityGate.groovy       the composite gate, with the reason written first
  vaultCredentials.groovy  leased credentials, revoked in the scope that opened them
test/run.groovy            19 assertions, no test framework
```

## Run it

```bash
groovy -cp src test/run.groovy          # 19 passed, 0 failed
groovyc -cp src -d out $(find src vars -name '*.groovy')
```

CI does both, against a checksum-pinned Groovy 5.0.3, so "it compiles" is a build
result and not a claim.

## The three rules worth reading

**Missing evidence fails.** `GateResult` treats an absent scan report, an absent
quality status and an unmeasured coverage number as failures. The naive version
(`if (findings && findings.critical > 0)`) passes all three, and the release
that slips through is the one where the scanner timed out.

**One identity cannot sign the whole chain.** `approvalChainProblems` counts the
signers, not the signatures. Five approvals from one account is a formality, and
this is the place it stops being one. (It also caught a real Groovy trap while
being written: `List.unique()` mutates its receiver, so the original comparison
compared a de-duplicated list against itself and could never fail. `toUnique()`
is the non-mutating one.)

**A skipped run is announced.** `deployPlan` prints and comments every service it
skips because the same tag already succeeded there. A board that quietly drops a
service is a board people stop trusting within a week.

## What is deliberately absent

`commentOnTicket`, `mergeRequest`, `triggerServicePipeline`, `timestamped` and
`vaultJwtForCurrentJob` are the integration seam: in production they are the
tracker's REST API, the forge's merge endpoint and the runner's own identity.
Here they are names without bodies, because the endpoints, project ids and
tokens behind them belong to an employer's network. Everything that decides
*whether* a release may proceed is real code, in `src/`, and is tested.
