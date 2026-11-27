# Handing the network over

A checklist for moving the network address of a deployment to a new address (today a 6529 Safe;
later the TDH bridge's executor). The rules are in the
[governance specification](../spec/governance.md#handing-the-network-over) (GV-4); who may call
what is in the [role matrix](../audit/roles.md).

> Pre-audit, Sepolia only. The contracts do not enforce this checklist; it is the network's
> procedure.

## What a handover moves, and what it does not

| | At `acceptNetwork` | Afterwards |
| --- | --- | --- |
| The network address and the five network roles (`ADMIN`, `NETWORK`, `PARAMETER_SETTER`, `FUNDS_SETTER`, `SUCCESSOR_SETTER`) | Move to the new address. The former address holds none of them | The former network's scheduled operations can no longer run |
| Operational roles (`PAUSER`, `CURATION_SIGNER`, `STORAGE_OPERATOR`, `PLATFORM`, `CURATOR`), whoever holds them, the former network's own address included | Unchanged | Each holder acts until the new network revokes it (`revokeRole`, at once) |
| The brake, if one is set | Unchanged | It can delay one scheduled operation of the new network once, by 7 days, its own removal included, until the new network replaces or removes it (`setBrake`, 7 days) |
| Module slots, minters, the four settings, vault destinations, fee terms | Unchanged | The new network's to change, each at its class |

The manager keeps no list of a role's members, so the handover cannot revoke them and nobody can
read them from the contract. They are read from its logs.

## Before the handover is proposed

1. **List what is held.** With the deployment record and an endpoint that serves logs from the
   deployment on:

   ```bash
   DEPLOYMENT=deployments/<chain>/core-<timestamp>.json \
     forge script script/VerifyCore.s.sol --sig "holders()" --rpc-url <rpc>
   ```

   It prints the network, a pending network, the brake, every account that holds each role
   (from every `RoleGranted` and `RoleRevoked` the manager logged since its deployment, each
   with what the manager answers for it now) and the scheduled operations still open. It sends
   nothing and needs no key. `--fork-block-number <block>` gives the list as of a block.
   The list is as complete as the endpoint's logs: use an endpoint you trust, or two.
2. **Compare with the configuration.** Run the full [read-back](../../script/README.md#4-after-the-broadcast)
   with the genesis file. It fails, naming the account, when a role has a holder the file does
   not name. `ALLOW_GOVERNANCE_CHANGES=1` prints every such difference and goes on, for an
   instance whose network changed holders on purpose.
3. **Decide each holder with the incoming network**: keep it, or revoke it. A grant the outgoing
   network made to its own address (for example `PLATFORM`, see LIM-GV-29 in the
   [known limitations](../audit/known-limitations.md#trust-and-governance)) is on this list like
   any other.
4. **Decide the brake**: keep the address, replace it, or remove it.
5. **Let scheduled operations run or cancel them.** After acceptance the outgoing network's
   scheduled operations cannot run and the new network must schedule them again.

## The handover

1. The outgoing network schedules `transferNetwork(next)` on the manager and executes it after
   7 days. It may revoke the holders that are not to stay, and remove a brake (7 days), before
   or during this wait: it is still the network until the new address accepts.
2. `next` calls `acceptNetwork()` itself. Nothing changes before this call; it shows that
   `next` can make a call on that day (LIM-GV-26).

## After acceptance, by the new network

1. **List the holders again** (step 1 above) at the block after acceptance. The outgoing network
   could grant roles until that block.
2. **Revoke every holder that was not agreed**, the outgoing network's own address included:
   `revokeRole(role, account)`, at once. A curation signer is also stopped by the verifier's
   `disableSigner`.
3. **Replace or remove the brake** if it was not agreed: schedule `setBrake(next)` (7 days). The
   existing brake may delay that operation once, by 7 more days.
4. **List once more** and keep the output with the handover's record. The holders and the brake
   should now be exactly the agreed ones.
5. **Record the new configuration epoch**: a governance manifest naming the new network and the
   holders in force, appended to the statement log
   ([governance specification](../spec/governance.md#configuration-epochs-and-governance-manifests)).

## If the outgoing key is not trusted

When a handover replaces a network key that may be in other hands, treat every operational
holder and the brake as untrusted until reviewed: that key could grant roles and schedule a
brake during the 7-day wait. Do steps 1 to 4 of "After acceptance" at once. Pausers can pause;
two curation signers together can approve a package; `PLATFORM` can record dispute outcomes,
create collections and add locators; a brake adds 7 days, once, to each delayed operation.
