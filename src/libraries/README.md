# libraries

Shared internal libraries that every v1 contract compiles in: signature
verification (low-s ECDSA, ERC-2098, EIP-7702 delegated accounts and gas-capped
ERC-1271), EIP-7702 delegation detection, JSON and inline-script escaping with
RFC 3629 UTF-8 validation, content-addressed SSTORE2 storage and bounded
`staticcall`. Every function is `internal`, so nothing here is a linked library
and nothing counts against the five-linked-library budget. Governed by
[ADR 0001 §11](../../docs/adr/0001-v1-scope.md#11-artist-identity-and-recovery)
("Hardening": one shared signature library), §8 (content storage and the
renderer's bounded read) and the §17 reuse plan ("Signatures and identity",
"Core" gas-reserve check, "Metadata, content, entropy" keep list), within the
engineering budgets under "Intended behavior".
