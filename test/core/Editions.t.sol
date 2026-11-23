// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC1155Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {
    IERC1155MetadataURI
} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { StreamEditions6529 } from "src/core/StreamEditions6529.sol";
import { EditionsBase } from "src/core/EditionsBase.sol";
import { Edition, Minter, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";
import { HostileModule, MockSale } from "../mocks/core/CoreMocks.sol";
import { EditionsFixture, EditionsReceiver } from "./EditionsFixture.sol";

/// @notice Unit and fuzz tests of 6529 Stream Editions (`src/core/StreamEditions6529.sol` on
///         `EditionsBase`): every function, every revert by selector and every event.
contract EditionsTest is EditionsFixture {
    // ------------------------------------------------------------------ construction

    function test_Constructor_WiresStreamOwnerTermsMintersAndTheLaunchSettings() public {
        address[] memory minters = new address[](1);
        minters[0] = address(sale);
        vm.expectEmit();
        emit IEditions.OwnershipTransferred(address(0), marketOwner);
        vm.expectEmit();
        emit IModuleSlots.ModuleSet(Slots.TERMS, address(0), address(terms));
        vm.expectEmit();
        emit IModules.MinterAdded(address(sale), uint48(block.timestamp));
        StreamEditions6529 e = new StreamEditions6529(
            address(manager), address(stream), marketOwner, address(terms), minters
        );
        assertEq(e.stream(), address(stream));
        assertEq(e.owner(), marketOwner);
        assertEq(e.moduleOf(Slots.TERMS), address(terms));
        assertTrue(e.isMinter(address(sale)));
        assertEq(e.minterOf(address(sale)).activeFrom, block.timestamp);
        assertEq(e.rebindDelay(), 14 days);
        assertEq(e.moduleDelay(), 7 days);
        assertEq(e.name(), "6529 Stream Editions");
        assertEq(e.symbol(), "6529STREAMEDITIONS");
        assertEq(e.contractURI(), "");
        assertEq(e.authority(), address(manager));
    }

    function test_SupportsInterface_TheStandardsAndTheCoreInterfaces() public view {
        assertTrue(editions.supportsInterface(type(IERC165).interfaceId));
        assertTrue(editions.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(editions.supportsInterface(type(IERC1155MetadataURI).interfaceId));
        assertTrue(editions.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(editions.supportsInterface(0x49064906), "ERC-4906");
        assertTrue(editions.supportsInterface(type(IEditions).interfaceId));
        assertTrue(editions.supportsInterface(type(IModules).interfaceId));
        assertTrue(editions.supportsInterface(type(IModuleSlots).interfaceId));
        assertFalse(editions.supportsInterface(type(IERC721).interfaceId));
        assertFalse(editions.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------------ create

    function test_Create_RefusesAZeroReceiverWithANonzeroRate() public {
        uint256 id = _sell(1, collector);
        vm.expectRevert(IEditions.InvalidRoyalty.selector);
        sale.createEdition(address(editions), id, 10, address(0), RATE);
        sale.createEdition(address(editions), id, 10, address(0), 0);
    }

    function test_Create_StoresTheEditionAndLogsIt() public {
        uint256 id = _sell(1, collector);
        vm.expectEmit(address(editions));
        emit IEditions.EditionCreated(id, address(sale), 10, ROYALTY, RATE);
        sale.createEdition(address(editions), id, 10, ROYALTY, RATE);
        Edition memory e = editions.editionOf(id);
        assertEq(e.minter, address(sale));
        assertEq(e.maxSupply, 10);
        assertEq(e.minted, 0);
        assertFalse(e.supplySealed);
        assertEq(e.royaltyReceiver, ROYALTY);
        assertEq(e.royaltyRate, RATE);
    }

    function test_Create_ZeroCapIsNoCapUntilTheSeal() public {
        uint256 id = _sell(1, collector);
        vm.expectEmit(address(editions));
        emit IEditions.EditionCreated(id, address(sale), type(uint40).max, ROYALTY, RATE);
        sale.createEdition(address(editions), id, 0, ROYALTY, RATE);
        assertEq(editions.editionOf(id).maxSupply, type(uint40).max);
    }

    function test_Create_ForAMasterStillInItsSaleContractsCustody() public {
        uint256 id = _mint(1);
        sale.createEdition(address(editions), id, 5, ROYALTY, RATE);
        assertEq(editions.editionOf(id).minter, address(sale));
    }

    function test_Create_RefusesAnyoneButAnActiveMinter() public {
        uint256 id = _sell(1, collector);
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(this)));
        editions.create(id, 10, ROYALTY, RATE);
        // Added but still waiting.
        editions.addMinter(address(other));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(other)));
        other.createEdition(address(editions), id, 10, ROYALTY, RATE);
        // Removed.
        editions.removeMinter(address(sale));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(sale)));
        sale.createEdition(address(editions), id, 10, ROYALTY, RATE);
    }

    function test_Create_RefusesAMissingOrBurnedMaster() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        sale.createEdition(address(editions), 1, 10, ROYALTY, RATE);
        uint256 id = _mint(1);
        sale.burn(address(stream), id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        sale.createEdition(address(editions), id, 10, ROYALTY, RATE);
    }

    function test_Create_OnceOnlyEvenByAnotherMinter() public {
        uint256 id = _edition(1, 10);
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionExists.selector, id));
        sale.createEdition(address(editions), id, 20, ROYALTY, RATE);
        _addActive(address(other));
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionExists.selector, id));
        other.createEdition(address(editions), id, 20, ROYALTY, RATE);
    }

    function testFuzz_Create_RateAtMostTheDenominator(uint24 rate, uint40 cap) public {
        uint256 id = _sell(1, collector);
        if (rate > 100_000) {
            vm.expectRevert(IEditions.InvalidRoyalty.selector);
            sale.createEdition(address(editions), id, cap, ROYALTY, rate);
            return;
        }
        sale.createEdition(address(editions), id, cap, ROYALTY, rate);
        Edition memory e = editions.editionOf(id);
        assertEq(e.royaltyRate, rate);
        assertEq(e.maxSupply, cap == 0 ? type(uint40).max : cap);
    }

    // ------------------------------------------------------------------ mint

    function test_Mint_MintsCountsAndLogsThePrice() public {
        uint256 id = _edition(1, 10);
        vm.expectEmit(address(editions));
        emit IEditions.EditionMinted(id, buyer, 3, 0.1 ether);
        vm.expectEmit(address(editions));
        emit IERC1155.TransferSingle(address(sale), address(0), buyer, id, 3);
        sale.mintEdition(address(editions), buyer, id, 3, 0.1 ether);
        assertEq(editions.balanceOf(buyer, id), 3);
        assertEq(editions.editionOf(id).minted, 3);
    }

    function test_Mint_UpToTheCapExactlyAndNotOneMore() public {
        uint256 id = _edition(1, 4);
        sale.mintEdition(address(editions), buyer, id, 4, 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, id));
        sale.mintEdition(address(editions), buyer, id, 1, 1);
    }

    function test_Mint_OnlyTheEditionsOwnMinter() public {
        uint256 id = _edition(1, 10);
        _addActive(address(other));
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, id, address(other))
        );
        other.mintEdition(address(editions), buyer, id, 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, id, address(this))
        );
        editions.mint(buyer, id, 1, 1);
    }

    function test_Mint_RefusesAnEditionNeverCreated() public {
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, 9, address(sale))
        );
        sale.mintEdition(address(editions), buyer, 9, 1, 1);
    }

    function test_Mint_ARemovedMinterMintsOnlyWhatItSealed() public {
        uint256 id = _edition(1, 10);
        sale.mintEdition(address(editions), buyer, id, 2, 1);
        // Left open at its removal: it mints no more and can no longer seal.
        uint256 snap = vm.snapshotState();
        editions.removeMinter(address(sale));
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, id, address(sale))
        );
        sale.mintEdition(address(editions), buyer, id, 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, id, address(sale))
        );
        sale.seal(address(editions), id, 5);
        vm.revertToState(snap);
        // Sealed before its removal: it still mints up to the seal.
        sale.seal(address(editions), id, 5);
        editions.removeMinter(address(sale));
        sale.mintEdition(address(editions), buyer, id, 3, 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, id));
        sale.mintEdition(address(editions), buyer, id, 1, 1);
        assertEq(editions.balanceOf(buyer, id), 5);
    }

    function test_Mint_ToTheZeroAddressReverts() public {
        uint256 id = _edition(1, 10);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(0))
        );
        sale.mintEdition(address(editions), address(0), id, 1, 1);
    }

    function test_Mint_ARefusingReceiverFailsOnlyItsOwnMint() public {
        uint256 id = _edition(1, 10);
        EditionsReceiver r = new EditionsReceiver();
        r.set(EditionsReceiver.Mode.REFUSE, sale, editions);
        vm.expectRevert("refused");
        sale.mintEdition(address(editions), address(r), id, 1, 1);
        sale.mintEdition(address(editions), buyer, id, 1, 1);
        assertEq(editions.editionOf(id).minted, 1);
    }

    function test_Mint_AReenteringReceiverSeesTheNewCountAndStaysUnderTheCap() public {
        uint256 id = _edition(1, 3);
        EditionsReceiver r = new EditionsReceiver();
        r.set(EditionsReceiver.Mode.REENTER, sale, editions);
        sale.mintEdition(address(editions), address(r), id, 2, 1);
        assertEq(r.seenMinted(), 2, "the count is written before the acceptance call");
        assertTrue(r.reenterSucceeded());
        // The re-entered mint took the third copy; one more is refused.
        assertEq(editions.editionOf(id).minted, 3);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, id));
        sale.mintEdition(address(editions), buyer, id, 1, 1);
    }

    function testFuzz_Mint_NeverPassesTheMaximum(uint40 cap, uint256[4] memory amounts) public {
        cap = uint40(bound(cap, 1, 1000));
        uint256 id = _edition(1, cap);
        uint256 total;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 a = bound(amounts[i], 0, 600);
            if (total + a > cap) {
                vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, id));
                sale.mintEdition(address(editions), buyer, id, a, 1);
            } else {
                sale.mintEdition(address(editions), buyer, id, a, 1);
                total += a;
            }
            assertLe(editions.editionOf(id).minted, cap);
        }
        assertEq(editions.editionOf(id).minted, total);
        assertEq(editions.balanceOf(buyer, id), total);
    }

    // ------------------------------------------------------------------ seal

    function test_Seal_FixesTheSupplyOnceAndLogsIt() public {
        uint256 id = _edition(1, 10);
        sale.mintEdition(address(editions), buyer, id, 3, 1);
        vm.expectEmit(address(editions));
        emit IEditions.EditionSupplySealed(id, 4);
        sale.seal(address(editions), id, 4);
        Edition memory e = editions.editionOf(id);
        assertEq(e.maxSupply, 4);
        assertTrue(e.supplySealed);
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSeal.selector, id));
        sale.seal(address(editions), id, 4);
    }

    function test_Seal_BetweenTheCountMintedAndTheMaximum() public {
        uint256 id = _edition(1, 10);
        sale.mintEdition(address(editions), buyer, id, 3, 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSeal.selector, id));
        sale.seal(address(editions), id, 2);
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSeal.selector, id));
        sale.seal(address(editions), id, 11);
        sale.seal(address(editions), id, 3);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, id));
        sale.mintEdition(address(editions), buyer, id, 1, 1);
    }

    function test_Seal_AtZeroAndAtTheUncappedMaximum() public {
        uint256 a = _edition(1, 0);
        uint256 b = _edition(2, 0);
        sale.seal(address(editions), a, 0);
        assertEq(editions.editionOf(a).maxSupply, 0);
        sale.seal(address(editions), b, type(uint40).max);
        assertEq(editions.editionOf(b).maxSupply, type(uint40).max);
    }

    /// @dev Only the edition's minter seals, and only while it has not been removed: an open
    ///      edition of a removed minter waits for the network's rebind.
    function test_Seal_OnlyTheEditionsMinterWhileNotRemoved() public {
        uint256 id = _edition(1, 10);
        _addActive(address(other));
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, id, address(other))
        );
        other.seal(address(editions), id, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, 99, address(sale))
        );
        sale.seal(address(editions), 99, 1);
        editions.removeMinter(address(sale));
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, id, address(sale))
        );
        sale.seal(address(editions), id, 0);
        assertFalse(editions.editionOf(id).supplySealed);
    }

    function testFuzz_Seal_ASealedMaximumNeverGrows(uint40 cap, uint40 minted, uint40 supply)
        public
    {
        cap = uint40(bound(cap, 1, 500));
        minted = uint40(bound(minted, 0, cap));
        uint256 id = _edition(1, cap);
        sale.mintEdition(address(editions), buyer, id, minted, 1);
        if (supply < minted || supply > cap) {
            vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSeal.selector, id));
            sale.seal(address(editions), id, supply);
            return;
        }
        sale.seal(address(editions), id, supply);
        vm.expectRevert(abi.encodeWithSelector(IEditions.InvalidSeal.selector, id));
        sale.seal(address(editions), id, supply);
        if (supply > minted) sale.mintEdition(address(editions), buyer, id, supply - minted, 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, id));
        sale.mintEdition(address(editions), buyer, id, 1, 1);
        assertEq(editions.editionOf(id).maxSupply, supply);
    }

    // ------------------------------------------------------------------ rebind and its wait

    function test_RebindDelay_FourteenDaysAtLaunchOnlyTheNetworkSetsItZeroAllowed() public {
        assertEq(editions.rebindDelay(), 14 days);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        editions.setRebindDelay(0);
        vm.expectEmit(address(editions));
        emit IEditions.RebindDelaySet(14 days, 3 days);
        editions.setRebindDelay(3 days);
        vm.expectEmit(address(editions));
        emit IEditions.RebindDelaySet(3 days, 0);
        editions.setRebindDelay(0);
        assertEq(editions.rebindDelay(), 0);
    }

    function test_Rebind_MovesAStuckEditionAndLogsIt() public {
        uint256 id = _edition(1, 10);
        _addActive(address(other));
        editions.removeMinter(address(sale));
        skip(editions.rebindDelay());
        vm.expectEmit(address(editions));
        emit IEditions.EditionRebound(id, address(sale), address(other));
        editions.rebind(id, address(other));
        assertEq(editions.editionOf(id).minter, address(other));
        // The new minter sells it; the old one can do nothing more with it.
        other.mintEdition(address(editions), buyer, id, 2, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, id, address(sale))
        );
        sale.seal(address(editions), id, 2);
        other.seal(address(editions), id, 2);
        // Minted and sealed: never rebound again.
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, id));
        editions.rebind(id, address(sale));
    }

    function test_Rebind_OnlyTheNetwork() public {
        uint256 id = _edition(1, 10);
        _addActive(address(other));
        editions.removeMinter(address(sale));
        skip(14 days);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        editions.rebind(id, address(other));
    }

    function test_Rebind_RefusesAnEditionWithASealOrNoneAtAll() public {
        uint256 minted = _edition(1, 10);
        uint256 sealed_ = _edition(2, 10);
        sale.mintEdition(address(editions), buyer, minted, 1, 1);
        sale.seal(address(editions), sealed_, 0);
        _addActive(address(other));
        editions.removeMinter(address(sale));
        skip(14 days);
        // Copies without a seal do not hold an edition back.
        editions.rebind(minted, address(other));
        assertEq(editions.editionOf(minted).minter, address(other));
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, sealed_));
        editions.rebind(sealed_, address(other));
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, 99));
        editions.rebind(99, address(other));
    }

    function test_Rebind_RefusesWhileItsMinterIsNotRemovedOrWasAddedAgain() public {
        uint256 id = _edition(1, 10);
        _addActive(address(other));
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, id));
        editions.rebind(id, address(other));
        editions.removeMinter(address(sale));
        editions.addMinter(address(sale));
        skip(30 days);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, id));
        editions.rebind(id, address(other));
    }

    function test_Rebind_RefusesANewMinterThatIsNotActive() public {
        uint256 id = _edition(1, 10);
        editions.removeMinter(address(sale));
        skip(14 days);
        // Never added.
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, id));
        editions.rebind(id, address(other));
        // Added, still waiting.
        editions.addMinter(address(other));
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, id));
        editions.rebind(id, address(other));
        // Removed.
        skip(7 days);
        editions.removeMinter(address(other));
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, id));
        editions.rebind(id, address(other));
    }

    /// @dev The period in force decides, for every caller: refused before it has elapsed
    ///      since the removal, allowed from then on.
    function testFuzz_Rebind_RefusedBeforeThePeriodInForce(uint48 period, uint256 wait) public {
        period = uint48(bound(period, 1, 3650 days));
        wait = bound(wait, 0, uint256(period) - 1);
        uint256 id = _edition(1, 10);
        _addActive(address(other));
        editions.setRebindDelay(period);
        editions.removeMinter(address(sale));
        skip(wait);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, id));
        editions.rebind(id, address(other));
        skip(uint256(period) - wait);
        editions.rebind(id, address(other));
        assertEq(editions.editionOf(id).minter, address(other));
    }

    function test_Rebind_ZeroPeriodAllowsItAtTheRemoval() public {
        uint256 id = _edition(1, 10);
        _addActive(address(other));
        editions.setRebindDelay(0);
        editions.removeMinter(address(sale));
        editions.rebind(id, address(other));
        assertEq(editions.editionOf(id).minter, address(other));
    }

    /// @dev The wait is read when the rebind is attempted: a change after the removal applies
    ///      to it, longer or shorter.
    function testFuzz_Rebind_AChangeAfterTheRemovalApplies(uint48 before_, uint48 after_) public {
        before_ = uint48(bound(before_, 0, 365 days));
        after_ = uint48(bound(after_, 1, 365 days));
        uint256 id = _edition(1, 10);
        _addActive(address(other));
        editions.setRebindDelay(before_);
        editions.removeMinter(address(sale));
        editions.setRebindDelay(after_);
        skip(after_ - 1);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotRebindable.selector, id));
        editions.rebind(id, address(other));
        skip(1);
        editions.rebind(id, address(other));
    }

    // ------------------------------------------------------------------ burn

    function test_Burn_AHolderBurnsItsOwnCopiesAndTheyStillCount() public {
        uint256 id = _edition(1, 3);
        sale.mintEdition(address(editions), buyer, id, 3, 1);
        vm.expectEmit(address(editions));
        emit IERC1155.TransferSingle(buyer, buyer, address(0), id, 2);
        vm.prank(buyer);
        editions.burn(id, 2);
        assertEq(editions.balanceOf(buyer, id), 1);
        assertEq(editions.editionOf(id).minted, 3);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, id));
        sale.mintEdition(address(editions), buyer, id, 1, 1);
    }

    function test_Burn_NeverMoreThanTheCallersOwn() public {
        uint256 id = _edition(1, 3);
        sale.mintEdition(address(editions), buyer, id, 1, 1);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, stranger, 0, 1, id
            )
        );
        editions.burn(id, 1);
        assertEq(editions.balanceOf(buyer, id), 1);
    }

    // ------------------------------------------------------------------ royalties

    function test_SetRoyalty_OnlyTheTermsModule() public {
        uint256 id = _edition(1, 10);
        vm.expectEmit(address(editions));
        emit IEditions.RoyaltySet(id, address(0xBEEF), 5000);
        terms.setEditionRoyalty(address(editions), id, address(0xBEEF), 5000);
        (address receiver, uint256 amount) = editions.royaltyInfo(id, 1 ether);
        assertEq(receiver, address(0xBEEF));
        assertEq(amount, 0.05 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.TERMS, address(this))
        );
        editions.setRoyalty(id, address(this), 1);
        // Once removed, nobody sets royalties; the last values stand.
        editions.removeModule(Slots.TERMS);
        vm.expectRevert(
            abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.TERMS, address(terms))
        );
        terms.setEditionRoyalty(address(editions), id, address(1), 1);
        (receiver,) = editions.royaltyInfo(id, 1 ether);
        assertEq(receiver, address(0xBEEF));
    }

    function test_SetRoyalty_RefusesAnUnknownEditionOrARateOverTheDenominator() public {
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 5));
        terms.setEditionRoyalty(address(editions), 5, ROYALTY, 1);
        uint256 id = _edition(1, 10);
        vm.expectRevert(IEditions.InvalidRoyalty.selector);
        terms.setEditionRoyalty(address(editions), id, ROYALTY, 100_001);
        vm.expectRevert(IEditions.InvalidRoyalty.selector);
        terms.setEditionRoyalty(address(editions), id, address(0), 1);
        terms.setEditionRoyalty(address(editions), id, ROYALTY, 100_000);
        (, uint256 amount) = editions.royaltyInfo(id, 7 ether);
        assertEq(amount, 7 ether);
    }

    function testFuzz_RoyaltyInfo_ExactForAnyPrice(uint256 price, uint24 rate) public {
        rate = uint24(bound(rate, 0, 100_000));
        uint256 id = _sell(1, collector);
        sale.createEdition(address(editions), id, 1, ROYALTY, rate);
        (address receiver, uint256 amount) = editions.royaltyInfo(id, price);
        assertEq(receiver, ROYALTY);
        assertEq(amount, Math.mulDiv(price, rate, 100_000));
        assertLe(amount, price);
    }

    function test_RoyaltyInfo_UnknownEditionAnswersNothing() public view {
        (address receiver, uint256 amount) = editions.royaltyInfo(42, 1 ether);
        assertEq(receiver, address(0));
        assertEq(amount, 0);
    }

    // ------------------------------------------------------------------ metadata

    function test_EmitMetadataUpdate_TermsAndTheMastersRecordsModuleOnly() public {
        vm.expectEmit(address(editions));
        emit IEditions.MetadataUpdate(3);
        vm.prank(address(terms));
        editions.emitMetadataUpdate(3, 3);
        vm.expectEmit(address(editions));
        emit IEditions.BatchMetadataUpdate(1, 9);
        vm.prank(address(records));
        editions.emitMetadataUpdate(1, 9);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotMetadataSource.selector, stranger));
        editions.emitMetadataUpdate(1, 1);
    }

    function test_Uri_TheMastersRendererDrawsIt() public {
        uint256 id = _edition(1, 10);
        assertEq(editions.uri(id), "data:,mock");
        vm.expectRevert(abi.encodeWithSelector(IEditions.UnknownEdition.selector, 77));
        editions.uri(77);
    }

    function test_Uri_AFailingRendererRevertsAndNeverFallsBack() public {
        uint256 id = _edition(1, 10);
        HostileModule hostile = new HostileModule();
        stream.proposeModule(Slots.RENDERER, address(hostile));
        skip(stream.moduleDelay());
        stream.activateModule(Slots.RENDERER);
        hostile.setMode(HostileModule.Mode.REVERT);
        vm.expectRevert("hostile");
        editions.uri(id);
    }

    // ------------------------------------------------------------------ admin

    function test_SetOwner_TheAdminOnly() public {
        vm.expectEmit(address(editions));
        emit IEditions.OwnershipTransferred(marketOwner, stranger);
        editions.setOwner(stranger);
        assertEq(editions.owner(), stranger);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        editions.setOwner(stranger);
    }

    function test_SetContractURI_TheAdminOnlyAndLogsTheValue() public {
        vm.expectEmit(address(editions));
        emit IEditions.ContractURISet("ipfs://contract");
        vm.expectEmit(address(editions));
        emit IEditions.ContractURIUpdated();
        editions.setContractURI("ipfs://contract");
        assertEq(editions.contractURI(), "ipfs://contract");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        editions.setContractURI("x");
    }

    // ------------------------------------------------------------------ transfers

    function test_Transfers_WorkWithEveryModuleAndMinterGone() public {
        uint256 id = _edition(1, 10);
        sale.mintEdition(address(editions), buyer, id, 4, 1);
        editions.removeModule(Slots.TERMS);
        editions.removeMinter(address(sale));
        stream.removeModule(Slots.RENDERER);
        stream.removeModule(Slots.RECORDS);
        vm.prank(buyer);
        editions.safeTransferFrom(buyer, stranger, id, 1, "");
        vm.prank(buyer);
        editions.setApprovalForAll(collector, true);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        (ids[0], amounts[0]) = (id, 2);
        vm.prank(collector);
        editions.safeBatchTransferFrom(buyer, collector, ids, amounts, "");
        assertEq(editions.balanceOf(buyer, id), 1);
        assertEq(editions.balanceOf(stranger, id), 1);
        assertEq(editions.balanceOf(collector, id), 2);
    }

    // ------------------------------------------------------------------ the module wait

    function test_ModuleDelay_OnlyTheNetworkAndLogsOldAndNew() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        editions.setModuleDelay(0);
        vm.expectEmit(address(editions));
        emit IModuleSlots.ModuleDelaySet(7 days, 2 days);
        editions.setModuleDelay(2 days);
        editions.setModuleDelay(0);
        assertEq(editions.moduleDelay(), 0);
    }

    function testFuzz_ModuleDelay_ATermsModuleIsRefusedBeforeThePeriodInForce(
        uint48 period,
        uint256 wait
    ) public {
        period = uint48(bound(period, 1, 3650 days));
        wait = bound(wait, 0, uint256(period) - 1);
        editions.setModuleDelay(period);
        HostileModule next = new HostileModule();
        editions.proposeModule(Slots.TERMS, address(next));
        skip(wait);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.TERMS));
        editions.activateModule(Slots.TERMS);
        skip(uint256(period) - wait);
        vm.prank(stranger);
        editions.activateModule(Slots.TERMS);
        assertEq(editions.moduleOf(Slots.TERMS), address(next));
    }

    function testFuzz_ModuleDelay_AMinterIsRefusedBeforeThePeriodInForce(
        uint48 period,
        uint256 wait
    ) public {
        period = uint48(bound(period, 1, 3650 days));
        wait = bound(wait, 0, uint256(period) - 1);
        uint256 id = _sell(1, collector);
        editions.setModuleDelay(period);
        editions.addMinter(address(other));
        skip(wait);
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(other)));
        other.createEdition(address(editions), id, 1, ROYALTY, RATE);
        skip(uint256(period) - wait);
        other.createEdition(address(editions), id, 1, ROYALTY, RATE);
    }

    function test_ModuleDelay_ZeroIsAtOnceAndAPendingAdditionKeepsItsTime() public {
        editions.addMinter(address(other));
        Minter memory m = editions.minterOf(address(other));
        assertEq(m.activeFrom, block.timestamp + 7 days);
        HostileModule next = new HostileModule();
        editions.proposeModule(Slots.TERMS, address(next));
        editions.setModuleDelay(0);
        // The pending ones keep the time they were given.
        assertFalse(editions.isMinter(address(other)));
        vm.expectRevert(abi.encodeWithSelector(IModuleSlots.ModuleNotReady.selector, Slots.TERMS));
        editions.activateModule(Slots.TERMS);
        // A new addition under the zero wait is active at once.
        MockSale third = new MockSale();
        editions.addMinter(address(third));
        assertTrue(editions.isMinter(address(third)));
    }
}
