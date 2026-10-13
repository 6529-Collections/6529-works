// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { StateGrowth } from "../helpers/StateGrowth.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @dev Storage that `_coolAll` does not cool.
contract UncooledStore {
    uint256 public value;

    function set(uint256 next) external {
        value = next;
    }
}

/// @notice The gas harness of the integration report checked against the truth (ADR 0004).
/// @dev `setUp` is a transaction of its own, so at the start of a test every account and slot is
///      cold, as in a real transaction. A steady-state `start` measured there is the true Prague
///      gas. After the test warms every account the call reaches, `_measureGrowth` must still
///      report exactly that figure: the warmth probe finds the warm accounts, and the
///      cold-account surcharge adds back what Foundry priced warm.
contract GasHarnessTest is IntegrationBase {
    address internal artist;
    address internal starter = makeAddr("harnessStarter");
    bytes internal startData;

    function setUp() public override {
        super.setUp();
        artist = _actor("harnessArtist");
        Work[] memory works = new Work[](4);
        for (uint256 i; i < works.length; ++i) {
            works[i] = _work(artist, collectionId);
        }
        bytes32 root = _publish(works);
        (uint256 first,) = _start(root, works, 0);
        _start(root, works, 1);
        _ethBid(first, makeAddr("harnessBidder"), 1 ether);
        // Built here: building it reads the registries, which would warm them in the test.
        startData = abi.encodeCall(auction.start, (address(stream), _mintData(root, works, 2)));
    }

    /// @dev The contracts, the fee recipient and the artist, whose signature check reaches it.
    function _probeSet() internal override returns (address[] memory accounts) {
        address[] memory base = super._probeSet();
        accounts = new address[](base.length + 1);
        for (uint256 i; i < base.length; ++i) {
            accounts[i] = base[i];
        }
        accounts[base.length] = artist;
    }

    function test_TheColdAccountCorrectionIsExact() public {
        uint256 cold = vm.snapshotState();
        (uint256 truth,) = _measure(starter, address(auction), startData, 0);

        // Back to the cold state, then touch every account the call may reach.
        vm.revertToState(cold);
        address[] memory reach = _probeSet();
        uint256 sizes;
        for (uint256 i; i < reach.length; ++i) {
            sizes += reach[i].code.length;
        }
        assertGt(sizes, 0);
        uint256 warmed = vm.snapshotState();
        (uint256 warmRaw,) = _measure(starter, address(auction), startData, 0);
        vm.revertToState(warmed);

        (uint256 corrected,, StateGrowth.Growth memory growth) =
            _measureGrowth(starter, address(auction), startData, 0);
        assertGt(truth, warmRaw, "warm accounts read low");
        assertEq(
            truth - warmRaw,
            COLD_ACCOUNT_SURCHARGE * growth.coldAccounts.length,
            "each reached account costs 2,500 more cold"
        );
        assertEq(corrected, truth, "the corrected figure is the true Prague gas");
    }

    /// @dev Without the warm-up, nothing the call reaches is warm, and nothing is added.
    function test_NothingIsAddedForAccountsAlreadyCold() public {
        uint256 cold = vm.snapshotState();
        (uint256 truth,) = _measure(starter, address(auction), startData, 0);
        vm.revertToState(cold);
        (uint256 corrected,,) = _measureGrowth(starter, address(auction), startData, 0);
        assertEq(corrected, truth);
    }

    function test_RequireCooledRefusesStorageItDoesNotCool() public {
        UncooledStore uncooled = new UncooledStore();
        vm.startStateDiffRecording();
        uncooled.set(1);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        vm.expectRevert(
            bytes(
                string.concat(
                    "measured storage that _coolAll does not cool: ", vm.toString(address(uncooled))
                )
            )
        );
        this.requireCooled(accesses);
    }

    function requireCooled(Vm.AccountAccess[] calldata accesses) external view {
        _requireCooled(accesses);
    }
}
