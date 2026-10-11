# governance

The OpenZeppelin 5 `AccessManager` configuration that governs Stream, 6529
Editions and every satellite: role holders (admin Safe, guardian Safe,
curation signer, storage operator, keepers), the delay classes (immediate,
48 hours, 14 days, 30 days), and the hardening rules: meta-governance never
faster than the slowest class, guardian cancellation of the manager's own admin
operations, one selector per delay class, compare-and-set on sensitive setters,
non-payable governed functions and a manifest hash per configuration epoch. No
bespoke executor, policy or registry contracts. Governed by
[ADR 0001](../../docs/adr/0055-v1-network-curated-stream-rescope.md) §13.
