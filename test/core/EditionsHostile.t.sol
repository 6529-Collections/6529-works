// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { Edition, MintFacts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";
import { HostileModule } from "../mocks/core/CoreMocks.sol";
import { EditionsFixture } from "./EditionsFixture.sol";

/// @notice Hostile modules and minters against 6529 Stream Editions: a module that lies,
///         reverts, burns all its gas or re-enters, in each seam position it can hold (TERMS,
///         the master's RENDERER and RECORDS, a minter active, pending or removed, an ERC-1155
///         receiver). Pass condition: no copy moves, no edition's facts change, nothing outside
///         its own seam succeeds, and transfers keep working.
contract EditionsHostileTest is EditionsFixture {
    HostileModule internal hostile;
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        hostile = new HostileModule();
        id = _edition(1, 10);
        sale.mintEdition(address(editions), buyer, id, 4, 1);
        vm.prank(buyer);
        editions.setApprovalForAll(collector, true);
    }

    /// @dev Every call a module or another minter must not succeed at against the edition the
    ///      fixture's sale contract sells and the buyer's copies.
    function _forbidden() internal view returns (bytes[] memory calls) {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        (ids[0], amounts[0]) = (id, 1);
        calls = new bytes[](12);
        calls[0] = abi.encodeCall(IERC1155.safeTransferFrom, (buyer, address(hostile), id, 1, ""));
        calls[1] = abi.encodeCall(
            IERC1155.safeBatchTransferFrom, (buyer, address(hostile), ids, amounts, "")
        );
        calls[2] = abi.encodeCall(IEditions.burn, (id, 1));
        calls[3] = abi.encodeCall(IEditions.mint, (address(hostile), id, 1, 0));
        calls[4] = abi.encodeCall(IEditions.seal, (id, 10));
        calls[5] = abi.encodeCall(IEditions.create, (id, 100, address(hostile), 100_000));
        calls[6] = abi.encodeCall(IEditions.rebind, (id, address(hostile)));
        calls[7] = abi.encodeCall(IEditions.setRebindDelay, (0));
        calls[8] = abi.encodeCall(IEditions.setOwner, (address(hostile)));
        calls[9] = abi.encodeCall(IEditions.setContractURI, ("hostile"));
        calls[10] = abi.encodeCall(IModules.addMinter, (address(hostile)));
        calls[11] = abi.encodeCall(IModuleSlots.proposeModule, (Slots.TERMS, address(hostile)));
    }

    function _snapshot() internal view returns (bytes32) {
        Edition memory e = editions.editionOf(id);
        return keccak256(
            abi.encode(
                e,
                editions.balanceOf(buyer, id),
                editions.balanceOf(address(hostile), id),
                editions.owner(),
                editions.contractURI(),
                editions.rebindDelay(),
                editions.moduleOf(Slots.TERMS),
                editions.isMinter(address(hostile))
            )
        );
    }

    /// @dev Runs every forbidden call through `hostile` and requires each to fail with the
    ///      state unchanged.
    function _attackAll() internal {
        bytes32 before = _snapshot();
        bytes[] memory calls = _forbidden();
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = hostile.exec(address(editions), calls[i]);
            assertFalse(ok, string.concat("forbidden call succeeded: ", vm.toString(i)));
        }
        assertEq(_snapshot(), before, "state changed");
        _transfersStillWork();
    }

    function _transfersStillWork() internal {
        uint256 held = editions.balanceOf(buyer, id);
        vm.prank(buyer);
        editions.safeTransferFrom(buyer, stranger, id, 1, "");
        vm.prank(collector);
        editions.safeTransferFrom(buyer, collector, id, 1, "");
        assertEq(editions.balanceOf(buyer, id), held - 2);
    }

    function _install(bytes32 slot) internal {
        editions.proposeModule(slot, address(hostile));
        skip(editions.moduleDelay());
        editions.activateModule(slot);
    }

    function test_HostileTerms_ReachesOnlyRoyaltiesAndMetadata() public {
        _install(Slots.TERMS);
        _attackAll();
        // What its seam allows: royalties and ERC-4906, nothing else.
        (bool ok,) = hostile.exec(
            address(editions), abi.encodeCall(IEditions.setRoyalty, (id, address(hostile), 100_000))
        );
        assertTrue(ok);
        (ok,) =
            hostile.exec(address(editions), abi.encodeCall(IEditions.emitMetadataUpdate, (1, 2)));
        assertTrue(ok);
        assertEq(editions.balanceOf(buyer, id), 2, "only the two test transfers moved copies");
        assertEq(editions.editionOf(id).minted, 4);
        assertEq(editions.editionOf(id).maxSupply, 10);
    }

    function test_HostileMinter_Active_CannotTouchAnotherMintersEdition() public {
        _addActive(address(hostile));
        _attackAll();
        // It can sell its own editions only.
        uint256 own = _sell(2, collector);
        (bool ok,) = hostile.exec(
            address(editions), abi.encodeCall(IEditions.create, (own, 2, address(hostile), 0))
        );
        assertTrue(ok);
        (ok,) = hostile.exec(
            address(editions), abi.encodeCall(IEditions.mint, (stranger, own, 3, 0))
        );
        assertFalse(ok, "never past its own cap");
        (ok,) = hostile.exec(
            address(editions), abi.encodeCall(IEditions.mint, (stranger, own, 2, 0))
        );
        assertTrue(ok);
        assertEq(editions.editionOf(id).minter, address(sale));
    }

    function test_HostileMinter_PendingOrRemoved_CreatesNothing() public {
        editions.addMinter(address(hostile));
        uint256 own = _sell(2, collector);
        bytes memory create = abi.encodeCall(IEditions.create, (own, 2, address(hostile), 0));
        (bool ok,) = hostile.exec(address(editions), create);
        assertFalse(ok, "pending");
        _attackAll();
        skip(editions.moduleDelay());
        editions.removeMinter(address(hostile));
        (ok,) = hostile.exec(address(editions), create);
        assertFalse(ok, "removed");
        _attackAll();
    }

    function test_HostileRenderer_LiesRevertsOrBurnsGasAndCopiesStillMove() public {
        stream.proposeModule(Slots.RENDERER, address(hostile));
        skip(stream.moduleDelay());
        stream.activateModule(Slots.RENDERER);
        assertEq(editions.uri(id), "data:,a lie");
        hostile.setMode(HostileModule.Mode.REVERT);
        vm.expectRevert("hostile");
        editions.uri(id);
        hostile.setMode(HostileModule.Mode.BURN_GAS);
        (bool ok,) =
            address(editions).staticcall{ gas: 2_000_000 }(abi.encodeCall(editions.uri, (id)));
        assertFalse(ok, "out of gas reverts; no default answer");
        _attackAll();
    }

    function test_HostileMasterRecords_EmitsMetadataOnly() public {
        stream.proposeModule(Slots.RECORDS, address(hostile));
        skip(stream.moduleDelay());
        stream.activateModule(Slots.RECORDS);
        (bool ok,) =
            hostile.exec(address(editions), abi.encodeCall(IEditions.emitMetadataUpdate, (id, id)));
        assertTrue(ok);
        _attackAll();
    }

    /// @dev A minter re-entering from the ERC-1155 receiver of its own mint gets no more than
    ///      the cap, and a receiver re-entering into another edition's mint is refused.
    function test_HostileReceiver_ReenteringAMintStaysWithinTheSeam() public {
        _addActive(address(hostile));
        uint256 own = _sell(2, collector);
        hostile.exec(address(editions), abi.encodeCall(IEditions.create, (own, 1, address(0), 0)));
        // `hostile` has no ERC-1155 receiver hook: minting to it reverts, so its only copy
        // cannot be taken twice. Minting its one copy to a plain account works.
        (bool ok,) = hostile.exec(
            address(editions), abi.encodeCall(IEditions.mint, (address(hostile), own, 1, 0))
        );
        assertFalse(ok);
        (ok,) =
            hostile.exec(address(editions), abi.encodeCall(IEditions.mint, (stranger, own, 1, 0)));
        assertTrue(ok);
        (ok,) =
            hostile.exec(address(editions), abi.encodeCall(IEditions.mint, (stranger, own, 1, 0)));
        assertFalse(ok);
        _attackAll();
    }

    /// @dev The facts the master's own token states are untouched by anything an edition
    ///      minter does: minting into Stream needs a Stream minter.
    function test_HostileEditionsMinter_IsNotAStreamMinter() public {
        _addActive(address(hostile));
        MintFacts memory f = _facts(9);
        (bool ok,) = hostile.exec(
            address(stream),
            abi.encodeWithSignature(
                "mint(address,(bytes32,bytes32,uint256,uint256,uint8,uint8,bytes32,address,uint24,bytes32,bytes32,bytes32,address))",
                address(hostile),
                f
            )
        );
        assertFalse(ok);
    }
}
