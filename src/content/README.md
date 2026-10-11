# content

Work and content records (title, description, artists, media list with sha256,
size, MIME type and append-only locators, license), the content store of
SSTORE2 chunks of up to 24,575 bytes with range reads, the shared dependency
registry, and the renderer that builds a small `tokenURI` with the preferred
locator, inline media only once a work is on-chain complete, and a bounded read
large enough for the inline threshold. Governed by
[ADR 0001](../../docs/adr/0055-v1-network-curated-stream-rescope.md) §8 (works,
content, storage, preferred location, on-chain upgrade, `tokenURI` size) and
§10 (finalize pins the renderer; delivery routing stays operable).
