# identity

The slim artist registry (`artistId`, authority address, profile document hash,
6529 profile ID) through which artist payouts resolve, and the consolidation
adapter that reads the 6529 delegation contract's registration and expiry
dates directly. Identity and payout changes wait 7 days, cancellers are
captured at staging, and contested changes, estates and lost keys use the
180-day public override. Signatures are checked with the shared verifier in
`libraries/`. Governed by
[ADR 0001](../../docs/adr/0055-v1-network-curated-stream-rescope.md) §11,
including its "Hardening" decisions.
