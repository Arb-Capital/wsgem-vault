# Security

## Reporting a vulnerability

Report privately through GitHub's private vulnerability reporting for this repository:
<https://github.com/Arb-Capital/wsgem-vault/security/advisories/new>

Do not open a public issue or discuss an unpatched finding elsewhere. Include the affected
function, the conditions required, and a reproduction; a Foundry test against the local
stack in `test/` is ideal.

## Scope

In scope: `src/` and `script/`.

Out of scope: the wsgem and gem contracts the vault wraps (wstGBP, tGBP, and their oracle,
gate, compliance, and proxy administration), the test-only `lib/maseer-one` dependency, and
findings already recorded in `audits/`.

## Response

The vault is immutable and has no owner: there is no pause, upgrade, or admin path. A fix in
`src/` ships as a new deployment, recorded in the README's instance table. No bounty
programme is offered at this time.
