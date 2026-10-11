# editions

The single shared 6529 Editions ERC-1155. Every edition is anchored by a Stream
work of kind `EDITION_MASTER`; the edition token records `(stream, workId,
contentHash)`, renders the master's `ContentStore` bytes, carries the master's
license, and is created only from the approved package. Edition sales use the
shared fixed-price (allowlist phases with the recipient-bound leaf fix, ERC-20
permits) and Dutch adapters from `sales/`. Governed by
[ADR 0001 §6](../../docs/adr/0001-v1-scope.md#6-6529-editions), with
the exclusivity rule in §3 and the license rule in §8.
