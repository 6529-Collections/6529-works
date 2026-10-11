# stream

The single shared 6529 Stream ERC-721 that holds every curated 1/1: one
chronological, never-reused token-ID sequence assigned when an auction starts,
collections as in-contract groupings (collection ID plus per-collection serial),
royalty terms locked at mint and read directly by `royaltyInfo`, the bilateral
link to an edition master's 6529 Editions token, and burn-with-gap after an
upheld dispute. The optional VRF reveal module sits beside Core, never in its
mint path. Governed by [ADR 0001 §4](../../docs/adr/0001-v1-scope.md#4-stream-token-model)
(token model), §5 (permissionless start), §7 (royalties), §9 (seeded works),
§10 (permanence) and §12 (disputes), with the "Core" row of the §17 reuse plan.
