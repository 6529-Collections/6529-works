// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { EditionSalesHandler } from "./EditionSalesHandler.sol";

/// @notice Stateful invariants of 6529 Editions and its two sale adapters on the real stack
///         (`DeployV1` with the committed genesis): fixed price with allowlist phases, and
///         Dutch.
///
///         The handler (`EditionSalesHandler`, inherited) creates editions from settled masters,
///         opens fixed-price and Dutch sales as the artist or PLATFORM (with or without the
///         artist's signed consent), buys through allowlist and public phases in ETH and an
///         ERC-20 (directly, by EIP-2612 permit or by a relayed Permit2 intent), pauses and
///         unpauses the adapters, deprecates and re-admits currencies, changes increment
///         floors, Editions' fee terms and default license by governed, revisioned actions
///         (sometimes with a stale revision), closes sales, re-rates masters, claims credits,
///         and makes fee recipients refuse ETH so payouts take the real revenue escrow. After
///         every call:
///
///         1. Supply: an edition never mints past its size, and every copy is held by a buyer;
///            the edition and its master stay linked both ways.
///         2. Caps: every wallet stays within its cap in every capped phase (allowlist leaf
///            caps and the public wallet cap), across every sale of the edition.
///         3. Funds: each adapter's ETH and ERC-20 balances cover what it owes (exactly: the
///            fixed-price adapter keeps nothing, the Dutch adapter only its ETH credits);
///            everything paid reached the seller, the network (or the escrow for a refusing
///            recipient) or a credit; the revenue escrow holds exactly what it owes.
///         4. Price: every purchase paid the schedule price, fixed (the package price, or the
///            leaf price of an approved phase) or the Dutch curve, both moved by the schedule
///            delay, which equals an independent model of the adapter's pauses and the
///            currency's deprecations since the sale opened (MARKET-1).
///         5. Halts: no purchase succeeds while the adapter is paused or the currency
///            deprecated, and no sale opens then.
///         6. Royalties follow the master: an edition's royalty is its master's current rate,
///            paid to the receiver locked when the edition was created.
///         7. Locked terms never change: a sale's terms as it opened (seller, fee recipient and
///            share, currency, price) and an edition's economics as it was created, whatever the
///            resolver's fee terms become.
///         8. Configuration moves only by governed, revisioned changes: each currency's status
///            clock (status, last change, closed deprecation time), increment floor and
///            revision, and Editions' fee terms, default license and revision counters, equal
///            the model; a stale revision is refused; a re-admission lands at least 14 days
///            after its deprecation.
///         Every action also predicts its outcome; any disagreement fails the campaign.
contract EditionSalesInvariantTest is EditionSalesHandler {
    uint256 internal constant ACTIONS = 17;
    /// @dev Replayed sequences in `test_EveryActionRuns`.
    uint256 internal constant RUNS = 32;

    function setUp() public override {
        super.setUp();
        targetContract(address(this));
        targetSelector(FuzzSelector(address(this), _selectors()));
    }

    function _selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](ACTIONS);
        s[0] = this.createEdition.selector;
        s[1] = this.openFixedSale.selector;
        s[2] = this.openDutchSale.selector;
        s[3] = this.purchaseFixed.selector;
        s[4] = this.purchaseDutch.selector;
        s[5] = this.pauseAdapter.selector;
        s[6] = this.unpauseAdapter.selector;
        s[7] = this.deprecateCurrency.selector;
        s[8] = this.readmitCurrency.selector;
        s[9] = this.closeSale.selector;
        s[10] = this.rerate.selector;
        s[11] = this.claim.selector;
        s[12] = this.setIncrementFloor.selector;
        s[13] = this.setFeeTerms.selector;
        s[14] = this.setDefaultLicense.selector;
        s[15] = this.toggleRefusal.selector;
        s[16] = this.warp.selector;
    }

    /// @notice Every invariant above (1 to 8). In CI the state is asserted every fourth call
    ///         and after the last call of each run (every action still checks its own outcome
    ///         at once); the `deep` profile asserts it after every call.
    /// forge-config: default.invariant.check_interval = 4
    /// forge-config: deep.invariant.check_interval = 1
    function invariant_editionSales() public view {
        _assertEditionSales();
    }

    /// @notice The campaign is not vacuous: sequences of the campaign's shape (uniform random
    ///         actions, depth 128) replayed from fixed seeds reach every action and the paths
    ///         the invariants are about, with every invariant holding along the way.
    function test_EveryActionRuns() public {
        string[29] memory paths = [
            "createEdition",
            "openByArtist",
            "openByPlatform",
            "openRefused",
            "buyAllowlist",
            "buyPublic",
            "buyDutch",
            "direct",
            "permit",
            "permit2",
            "purchaseRefused",
            "haltedRefused",
            "pause",
            "unpause",
            "deprecate",
            "readmit",
            "closeSale",
            "closeRefused",
            "rerate",
            "claim",
            "warp",
            "editionExists",
            "setFloor",
            "setFeeTerms",
            "setLicense",
            "staleRefused",
            "refuse",
            "flush",
            "escrowed"
        ];
        uint256[29] memory totals;
        for (uint256 run; run < RUNS; ++run) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 depth; depth < 128; ++depth) {
                // Nothing a step allocates is used after it: reuse the memory, so the replay's
                // cost stays linear in its length.
                uint256 free;
                assembly ("memory-safe") {
                    free := mload(0x40)
                }
                _step(uint256(keccak256(abi.encode("editions", run, depth))));
                if (depth % 16 == 15) _assertEditionSales();
                assembly ("memory-safe") {
                    mstore(0x40, free)
                }
            }
            for (uint256 i; i < paths.length; ++i) {
                totals[i] += hits[bytes32(bytes(paths[i]))];
            }
            vm.revertToStateAndDelete(snapshot);
        }
        for (uint256 i; i < paths.length; ++i) {
            console2.log(paths[i], totals[i]);
        }
        for (uint256 i; i < paths.length; ++i) {
            assertGt(totals[i], 0, paths[i]);
        }
    }

    /// @dev One handler call chosen and parameterised from `seed`, as the fuzzer would.
    function _step(uint256 seed) internal {
        uint256 which = seed % ACTIONS;
        (uint256 a, uint256 b, uint256 c) = (
            uint256(keccak256(abi.encode(seed, 1))),
            uint256(keccak256(abi.encode(seed, 2))),
            seed >> 32
        );
        if (which == 0) this.createEdition(a);
        else if (which == 1) this.openFixedSale(a, b);
        else if (which == 2) this.openDutchSale(a, b);
        else if (which == 3) this.purchaseFixed(a, b, c);
        else if (which == 4) this.purchaseDutch(a, b, c);
        else if (which == 5) this.pauseAdapter(a);
        else if (which == 6) this.unpauseAdapter(a);
        else if (which == 7) this.deprecateCurrency(a);
        else if (which == 8) this.readmitCurrency(a);
        else if (which == 9) this.closeSale(a, b);
        else if (which == 10) this.rerate(a, b);
        else if (which == 11) this.claim(a);
        else if (which == 12) this.setIncrementFloor(a);
        else if (which == 13) this.setFeeTerms(a);
        else if (which == 14) this.setDefaultLicense(a);
        else if (which == 15) this.toggleRefusal(a);
        else this.warp(a);
    }
}
