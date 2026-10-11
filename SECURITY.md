# Security policy

6529 Works is pre-audit and not production-ready. Do not use these contracts to
custody value.

## Reporting a vulnerability

Please do not open public issues for exploitable vulnerabilities.

1. Use GitHub private vulnerability reporting:
   <https://github.com/6529-Collections/6529-works/security/advisories/new>
2. If that is unavailable, contact a maintainer privately and keep exploit
   details out of public channels.

Include:
- the affected contract or script path;
- the impact and preconditions;
- a minimal proof of concept where safe;
- the commit tested.

Never include private keys or secrets.

## Scope

In scope:
- Solidity under `src/`;
- deployment scripts under `script/`;
- CI workflows.

The RC1 reference implementation is kept in the private 6529Stream repository.
Report anything that affects it through this repository's private vulnerability
reporting as well.
