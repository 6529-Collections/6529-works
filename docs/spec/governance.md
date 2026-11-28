# Governance

One OpenZeppelin 5.7.0 `AccessManager`, subclassed as `StreamAccessManager`, governs every
6529 Stream contract.

- **One authority, the network.** A single address holds every network power. Today that is one
  6529 Safe; later it is the executor of TDH governance, bridged from 6529chain. The network can
  hand over to a new address in two steps.
- **Delay classes.** Each network power is in a class: at once, 24 hours, 3 days or 7 days. The
  classes are the network's too: one 7-day action can remap a function to another class or
  change a class, so a class's delay holds until such a remap changes it. No delay is a
  guarantee.
- **Settings of the permanent contracts.** The waits inside the permanent contracts are not role
  delays. They are stored settings with launch values, which the network changes at once
  (below).
- **One optional brake.** A second address that can make one scheduled network action wait 7
  more days, once. There may be no brake at all.
- **Operational keys.** Pauser, curation signers, storage operator, platform and curator keys
  are ordinary roles that the network grants and revokes at once.

`GovernanceConfigurator` installs the genesis configuration in one transaction. The
selector-by-selector view is the generated [role and permission matrix](../audit/roles.md).

> Pre-audit. See the [project status](../../README.md#status).

## Settings of the permanent contracts

There are no fixed waiting periods in the permanent contracts
([ADR 0010](../adr/0010-plain-permanent-core.md)). Each wait is a stored value with a launch
value. The network changes it at once through the `NETWORK` role (no floor, no delay on the
change, zero allowed), and the contract emits the old and the new value.

| Setting | Contract | Launch value | Rule for what is already running |
| --- | --- | --- | --- |
| `moduleDelay` | `Stream6529`, `StreamEditions6529`, `StreamDirectory6529`, each Independent Stream token | 7 days | An announced module or added minter keeps the time it was given |
| `rescueDelay` | `Stream6529`, each Independent Stream token | 14 days | Read when a rescue is attempted |
| `rebindDelay` | `StreamEditions6529`, each Independent Stream Editions token | 14 days | Read when a rebind is attempted |
| `unclaimedPeriod` | `StreamDirectory6529` (read by `SplitLedger` and `RevenueEscrow`) | 180 days | Read when a forfeit or expiry is attempted |

Adding a module or a minter waits `moduleDelay`; removing one is immediate. Anyone may install
an announced module once its time has come.

## Roles

| Role | ID | Held by | Delay at genesis | Used for |
| --- | --- | --- | --- | --- |
| `ADMIN` | 0 | The network | 7 days | The manager's own administration (remaps, closing targets, `updateAuthority`, `transferNetwork`, `setBrake`) and every unmapped selector |
| `NETWORK` | 1 | The network | none | Powers used at once, including every module, minter and setting function of the permanent contracts |
| `PAUSER` | 2 | Operational keys | none | `pause` selectors |
| (unused) | 3 | | | |
| `CURATION_SIGNER` | 4 | Operational keys | none | Nothing mapped: the curation verifier reads membership |
| `STORAGE_OPERATOR` | 5 | Operational key | none | Preferred-location setters |
| `MINTER`, `KEEPER` | 6, 7 | Nobody | none | Unused: minting is each token's minter list; upkeep is permissionless |
| `PLATFORM` | 8 | Operational key | none | Collections, locators, platform statements |
| `PARAMETER_SETTER` | 9 | The network | 24 hours | The 24-hour class |
| `FUNDS_SETTER` | 10 | The network | 3 days | Money and recipients |
| `SUCCESSOR_SETTER` | 11 | The network | 7 days | Long changes on managed modules |
| `CURATOR` | 12 | Operational key | none | Curator statements |

`PUBLIC` is never mapped. Which selector is in which class: the
[role matrix](../audit/roles.md), generated from
[`config/genesis.core.example.json`](../../config/genesis.core.example.json).

### Roles that targets read directly

Some modules read a role by hand: `StatementLog.appendSigned` accepts a `CURATOR` or `PLATFORM`
signer only when the role answers with no delay; the curation verifier accepts a signer only
with `CURATION_SIGNER` and no delay, and not disabled; locators added by someone other than the
work's artist need `PLATFORM` with no delay. A revoked key fails all of them in the same block.

### Configuration epochs and governance manifests

Each epoch (roles, holders, delays and mappings in force) has a JSON manifest. Genesis emits its
hash in `GovernanceConfigured`, beside the hash of the installed configuration and the hash of
the wiring calls, and records it in the statement log; a later epoch's hash is recorded (7 days)
before its operations take effect. The deployment read-back (`script/VerifyCore.s.sol`)
recomputes the three hashes from the genesis file and compares them with the log.

## A scheduled network action

A delayed call is scheduled, waits its class delay, then runs by `execute` or a direct call. The
brake may mark it once to run no earlier than 7 days after its ready time; cancelling and
scheduling it again keeps the mark. An operation not run within 14 days of its ready time
expires.

## Cancellation rules

The account that scheduled an operation can cancel it, and so can the network. The brake,
pausers and outsiders cannot.

## Suspension of operational keys

The network revokes an operational key at once (`NETWORK` administers every operational role); a
key may renounce its own role. A curation signer is also stopped at once by the verifier's
`disableSigner`.

## Genesis configure

The deployer deploys the configurator (which deploys the manager), deploys every target with the
manager as authority, then calls `configure(cfg, manifestHash, wiring)` once: it runs the
allow-listed wiring calls, maps every selector, grants the operational keys, sets the brake if
named, proposes the network and renounces. The network then calls `acceptNetwork`, and
`verify(cfg)` reads everything back by `eth_call`, reverting on the first difference. Any
reverting wiring call aborts the whole configuration.

In the plain core, the permanent contracts take their genesis modules and minters as constructor
arguments, so wiring no longer binds them; it only sets the modules' own genesis values.

## Handing the network over

The network schedules `transferNetwork(next)` (7 days); `next` takes over only by calling
`acceptNetwork`. That call moves the network address and, with it, the five network roles: from
that block the former network holds none of them and its scheduled operations cannot run.

It moves nothing else. Operational roles (`PAUSER`, `CURATION_SIGNER`, `STORAGE_OPERATOR`,
`PLATFORM`, `CURATOR`) are ordinary grants: every holder, the former network's own address
included if it granted itself one, keeps its role until the new network revokes it, which takes
one call with no delay. A brake stays the brake until the new network replaces or removes it
(`setBrake`, 7 days). The manager keeps no list of a role's members; they are read from its
`RoleGranted` and `RoleRevoked` logs (`script/VerifyCore.s.sol --sig "holders()"`). The
procedure is [Handing the network over](../operations/network-handover.md).

## Rules and invariants

Rule IDs use the prefix `GV`.

| ID | Rule | Enforced in | Tested by |
| --- | --- | --- | --- |
| GV-1 | Only `network()` holds the network roles; nobody can be granted one; the installer holds them only until it renounces. | `StreamAccessManager.hasRole`, `_grantRole` | `test_NobodyCanBeGrantedANetworkRole`, `testFuzz_OnlyTheNetworkHoldsTheNetworkRoles`, `test_NoNetworkBeforeAcceptance`, `test_ConfiguratorDeploysAndOwnsAStreamAccessManager` |
| GV-2 | The network acts through each class at the class's configured delay (genesis: none, 24 hours, 3 days, 7 days); nothing runs before the delay in force. The classes are the network's to remap with one 7-day action. | `Roles.executionDelay`, OpenZeppelin `schedule` | `test_EachClassRunsAtItsDelayAndNotBefore`, `test_ManagerAdministrationIsTheSevenDayClass`, `test_TheNetworkActsAtOnceThroughTheNetworkRole`, `test_UnmappedSelectorFallsBackToTheSevenDayClass` |
| GV-3 | Operational keys act with no delay; the network grants and revokes them at once; a key may renounce its role. | `GovernanceConfig.install` | `test_OperationalKeysAreGrantedAndRevokedAtOnce`, `test_EveryRoleIsLabelledAndOperationalKeysAnswerToTheNetworkAtOnce` |
| GV-4 | `transferNetwork(next)` only proposes; `next` takes over by `acceptNetwork`; afterwards the former network holds none of the network roles. Operational roles, whoever holds them, and the brake are unchanged by the handover and last until the new network revokes or replaces them. | `StreamAccessManager.transferNetwork`, `acceptNetwork` | `test_TransferNetworkTakesEffectOnlyOnAccept`, `test_TransferCanBeWithdrawnOrReplaced`, `test_OnlyTheNetworkCanStartATransfer`, `test_Handover_AnOperationalRoleOfTheFormerNetworkLastsUntilTheNewNetworkRevokesIt`, `test_Handover_KeysTheFormerNetworkGrantedToOthersStayUntilRevoked`, `test_Handover_TheBrakeStaysUntilTheNewNetworkReplacesIt`, `test_Handover_TheLogsNameEveryKeyTheNewNetworkMustReview` |
| GV-5 | `setBrake` is the network at the 7-day class; zero means no brake. | `StreamAccessManager.setBrake` | `test_OnlyTheBrakeCanBrake`, `test_TheBrakeCanDelayItsOwnRemovalOnce`, `test_NoBrakeIsAllowed` |
| GV-6 | Only the brake brakes, once per scheduled operation until it runs; the operation then cannot run before its ready time plus 7 days. | `StreamAccessManager.brakeOnce` | `test_TheBrakeDelaysAnOperationOnce`, `test_TheBrakeAlsoHoldsADirectDelayedCall`, `test_CancelAndRescheduleDoesNotEscapeTheBrake`, `test_AnActionWithNoDelayCannotBeBraked` |
| GV-7 | A scheduled operation expires 14 days after its ready time. | `StreamAccessManager.expiration` | `test_ABrakedOperationDoesNotExpireBeforeItCanRun` |
| GV-8 | Only the scheduler or the network can cancel an operation. | OpenZeppelin `_canCancel` | `test_CancellationIsTheSchedulerOrTheNetwork` |
| GV-9 | The manager's own selectors cannot be remapped and the manager cannot be closed. | `StreamAccessManager._setTargetFunctionRole`, `_setTargetClosed` | `test_TheManagerCannotBeRemappedOrClosed` |
| GV-10 | A configuration names a network; grants are of operational roles only, never repeated; targets have code and this manager; selectors appear once and never map to `ADMIN`, `CURATION_SIGNER` or `PUBLIC`. | `GovernanceConfig.validate` | `test_RejectsAMissingNetwork`, `test_RejectsGrantsOfNetworkRoles`, `test_RejectsInvalidGrants`, `test_RejectsInvalidTargets`, `test_RejectsOneSelectorInTwoClasses` |
| GV-11 | Only `deployer` configures, once; the configurator ends with no role. | `GovernanceConfigurator.configure` | `test_OnlyDeployerCanConfigure`, `test_ConfigureIsOneShot` |
| GV-12 | Genesis wiring has at most 64 allow-listed calls on configured targets, runs before mapping, and any revert aborts the configuration. | `GovernanceConfig.validateWiring` | `test_RejectsMoreThanTheWiringBound`, `testFuzz_OnlyGenesisSelectorsPassValidation`, `test_RejectsWiringOnAnUnconfiguredTarget`, `test_WiringRunsBeforeSelectorsAreMapped`, `test_RevertingWiringCallAbortsTheWholeConfiguration` |
| GV-13 | Readback reverts on any difference from the configuration. | `GovernanceConfigurator.verify` | `test_ConfigureInstallsTheWholeEpochInOneTransaction`, `test_ReadbackDetectsRemappedSelector`, `test_ReadbackDetectsMissingHolder` |
| GV-14 | Whatever random actors do, exactly one address holds the network roles, and it is `network()`. | All of the above | `invariant_ExactlyOneAddressHoldsTheNetworkRoles` |
| GV-15 | Every `restricted` function is mapped to exactly one role, or listed as genesis-only or deferred. | `tools/check_genesis.py` | `test_RoleMap_EveryRestrictedFunctionIsMapped`, `test_RoleMap_AnUnmappedRestrictedFunctionFailsTheCheck`, `test_RoleMap_NothingIsMappedThatDoesNotExist`, `test_GenesisOnlySelectorsAreNotMapped` |
| GV-16 | Governed functions are non-payable. | Each target | `test_GovernedFunctionsRejectValueThroughExecute`, `test_EveryGovernedSelectorIsNonPayable` |
| GV-17 | Module setters for funds, recipients, verifiers and sale parameters are compare-and-set. | Each setter | `test_StaleCompareAndSetOperationReverts` |
| GV-18 | Every governed setter emits an event with the old and the new value, or the key and its new state. | Each setter's event | Per module: `test_SetDelay_OnlyTheNetworkAtOnceWithOldAndNew`, `testFuzz_SetRescueDelay_OnlyTheNetworkEventCarriesOldAndNew`, `test_RebindDelay_FourteenDaysAtLaunchOnlyTheNetworkSetsItZeroAllowed`, `testFuzz_SetUnclaimedPeriod_OnlyTheNetworkEventCarriesOldAndNew`, `test_Propose_AnnouncesAndDoesNotInstall`, `test_RemoveModule_AtOnceAndCancelsAnAnnouncement`, `test_CancelModule_KeepsTheLiveModule`, `test_AddMinter_ActiveAfterSevenDays`, `test_RemoveMinter_AtOnceKeepsItsRecord`, `test_SetOwner_EventAndValue`, `test_SetContractURI_EventAndValue`, `test_SetConfig_WithinBoundsAndCompareAndSet`, `test_SetStreamPolicy_CompareAndSetAndChecked`, `test_Unpause_TheNetworkUnpausesAtOnce`, `test_SetConfig_CompareAndSetAndLocksPerSale`, `test_SetLimits_CompareAndSetBoundsAndEvent`, `test_SetTarget_OnlyEditions`, `test_SetFeeTermsIsCompareAndSet`, `test_SetRoyaltyRateIsCompareAndSetOnItsOwnRevision`, `test_SetDefaultLicenseIsCompareAndSetAndValidated`, `test_SetMuseum_IsCompareAndSet`, `test_IncrementFloorIsCompareAndSet`, `test_OpeningBid_LivesInTheStatusWord`, `test_SetDestinationIsCompareAndSet`, `test_SetArtistResolver_SwapsAndEmits`, `test_setVerifier`, `test_setEntropyModule`, `test_disableSigner_immediateAndOneWay`, `test_enableSigner_restores`, `test_SetConsolidationSource_SwapsTheSourceWithItsPin`, `test_SetPackageRegistry_SwapsTheOnlyRegisterCaller`, `test_SetConfig_UpdatesAndEmits`, `test_SetCoordinator_SwapsAndEmits`, `test_SetWrapper_IsGovernedCompareAndSetAndPinned`, `test_LowerCallbackGasLimit_EmitsTheOldAndTheNewConfiguration`, `test_SetDelivery_TheNetworkSwapsToASuccessorThatNamesThisModule`, `test_Stores_TheNetworkAddsAndRetires`, `test_FileStore_TheArtistChoosesAStoreThatServesEveryChunk`, `test_SetRoyaltyRate_EmitsRoyaltySetOnTheTokenAndBumpsTheVersion`, `test_Setters_TheStorageOperatorOnlyAndTheyRefresh`, `test_Setters_RefreshTheTokenAndItsEditions`, `test_LowerFeeShare_DeploysTheNewVaultFirstAndKeepsTheRate`, `test_SetEditions_TheNetworkPairsAMatchingEditionsContract`, `test_ApproveTemplate_RecordsAndLogs`, `test_Templates_EveryTransitionEmitsTemplateSetWithTheNewStatus`, `test_SetAdapter_AddRemoveReAdd`, `test_SetStatus_DelistsAndRelistsWithEvents`, `test_SetAccountDelisted_DelistsEveryContractOfTheAccount`, `test_LowerFeeShare_LowersAndLogs`, `test_SetEntropyModule_SetsAndLogs`, `test_Register_ResolvesWithManifestFlags`, `test_Deprecate_IsAFlagOnly`, `test_Replacement_LogsAndAppliesTheWholeIdentity` |
| GV-19 | Raise-only parameters use `BoundedParameter`: each raise at most doubles and never passes the ceiling. | `BoundedParameter` | `test_RaiseRejectsMoreThanDouble`, `test_RaiseRejectsAboveCeiling`, `testFuzz_RaiseMatchesSpecification` |
| GV-20 | A contract installed by a governed setter is checked for code where it is set (most through `Dependency`, which also refuses an EIP-7702 delegated account and, where the setter names an interface, requires it through ERC-165), and pinned to a code hash where the module says so. `IndependentStreamRegistry.setEntropyModule` refuses an address without code too (zero, for no module, is accepted); it is not compare-and-set. | `Dependency`, each setter | Per module: `test_Propose_RefusesAnAddressWithoutCode`, `test_AddMinter_OnlyTheNetworkWithCodeAndNotTwice`, `test_ProposeModule_OnlyTheRendererSlotAndOnlyCode`, `test_setVerifier_rejectsBadVerifier`, `test_setEntropyModule`, `test_SetCoordinator_RejectsStaleAndCodelessValues`, `test_SetCoordinator_PinsTheCodeHash`, `test_SetWrapper_RefusesAnAccountWithoutCode`, `test_SetWrapper_RefusesADelegatedAccount`, `test_SetWrapper_IsGovernedCompareAndSetAndPinned`, `test_SetConsolidationSource_SwapsTheSourceWithItsPin`, `test_SetPackageRegistry_SwapsTheOnlyRegisterCaller`, `test_SetArtistResolver_RejectsUnsuitableResolvers`, `test_SetDelivery_TheNetworkSwapsToASuccessorThatNamesThisModule`, `test_Stores_TheNetworkAddsAndRetires`, `test_SetStreamPolicy_CompareAndSetAndChecked`, `test_SetAdapter_Refusals`, `test_CheckUnchanged_RefusesCodeOnEitherSideOfThePin`, `test_SetEntropyModule_RefusesAnAddressWithoutCode`, `test_SetEntropyModule_SetsAndLogs` |
| GV-21 | Reversing a tightening takes no wait of its own: `unpause` and the dispute `resume` and `cancel` are the network's at once. | `EnglishAuction.unpause`, `UniformEditionAuction.unpause` | `test_Unpause_TheNetworkUnpausesAtOnce`, `test_Resume_TheNetworkResumesAtOnce`, `test_Cancel_TheNetworkCancelsAtOnce`, `test_GenesisConfig_EachPauserStopsTheSalesAtOnceAndOnlyTheNetworkResumes` |
| GV-22 | Retired: the one-shot bind steps are gone; the permanent contracts take their genesis modules and minters as constructor arguments. | | |
| GV-23 | An added module or minter is usable only once the `moduleDelay` in force when it was announced has passed; a later change of the setting leaves it alone; zero installs at once; removal is immediate. | `ModuleSlots`, `Modules` | `testFuzz_AModuleWaitsTheModuleDelayInForce`, `testFuzz_AChangedModuleDelayLeavesAPendingAnnouncementAlone`, `test_AZeroModuleDelayInstallsAtOnce`, `testFuzz_AMinterWaitsAndIsRemovedAtOnce`, `test_AModuleIsRemovedAtOnce` |
| GV-24 | A rescue or a rebind is refused until the setting in force when it is attempted has passed since the minter's removal; zero allows it at once; only the network changes the settings, with old and new in the event. | `StreamBase.rescue`, `EditionsBase.rebind`, the setters | `testFuzz_ARescueWaitsTheRescueDelayInForce`, `test_AZeroRescueDelayRescuesAtOnce`, `testFuzz_ARebindWaitsTheRebindDelayInForce`, `testFuzz_TheUnclaimedPeriodIsTheNetworksSetting` |
| GV-25 | Every module, minter and setting function of the permanent contracts maps to `NETWORK`; nobody else can call them. | `config/genesis.core.example.json` | `test_TheModuleMinterAndSettingFunctionsAreTheNetworksAtOnce`, `test_NobodyButTheNetworkCallsTheGovernedFunctions` |

## Events

The manager adds `NetworkTransferStarted`, `NetworkTransferred`, `BrakeSet` and
`OperationBraked` to OpenZeppelin's events; the settings emit `ModuleDelaySet`,
`RescueDelaySet`, `RebindDelaySet` and `UnclaimedPeriodSet`. Full list:
[events and indexing](../integrators/events-and-indexing.md).

## Failure modes and recovery

| Failure | Recovery |
| --- | --- |
| The network's key is compromised | Its holders replace the address with `transferNetwork`; the brake, if any, can add 7 days once per scheduled action. The new network then reviews every operational holder and the brake, which the handover leaves in place ([checklist](../operations/network-handover.md#if-the-outgoing-key-is-not-trusted)) |
| The network address is lost | None on chain; today the network is a Safe whose signers can rotate |
| The brake is compromised | The network replaces or removes it with `setBrake` |
| An operational key is compromised | The network revokes it at once |
| An operation expires or is stale | Schedule it again with the current value |

## References

Code: [`StreamAccessManager.sol`](../../src/governance/StreamAccessManager.sol),
[`GovernanceConfigurator.sol`](../../src/governance/GovernanceConfigurator.sol),
[`GovernanceConfig.sol`](../../src/governance/GovernanceConfig.sol),
[`Roles.sol`](../../src/governance/Roles.sol), [`Modules.sol`](../../src/core/Modules.sol).
Tests: [`test/governance/`](../../test/governance/), [`test/deploy/`](../../test/deploy/).
Related: [role matrix](../audit/roles.md), [trust assumptions](../audit/trust-assumptions.md).
