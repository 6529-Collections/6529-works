// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Roles } from "src/governance/Roles.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IMintPolicy } from "src/interfaces/IMintPolicy.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkPowers, WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionTerms,
    License,
    PackageItem,
    Party,
    SaleTerms
} from "src/interfaces/types/PackageTypes.sol";
import { PrimaryOutcome, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { Stream } from "src/stream/Stream.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { MockEconomics, MockRenderer, MockSaleAdapter } from "../mocks/stream/StreamMocks.sol";
import { SymHelpers, SymResolver, SymSink } from "./LedgerSymbolic.t.sol";

/// @dev The artist registry as Stream and its records satellite read it: one artist, whose one
///      wallet acts for it, and every consent signature accepted (the signature scheme is not
///      what these proofs are about; who may call is).
contract SymArtists is IERC165 {
    uint256 public immutable artistId;
    address public immutable wallet;

    constructor(uint256 artistId_, address wallet_) {
        (artistId, wallet) = (artistId_, wallet_);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IArtistRegistry).interfaceId;
    }

    function isWallet(uint256 accountId, address account) external view returns (bool) {
        return accountId == artistId && account == wallet;
    }

    function requireSigned(uint256, bytes32, bytes calldata) external view returns (address) {
        return wallet;
    }

    function authorityOf(uint256 id) external view returns (address) {
        return id == artistId ? wallet : address(0);
    }

    function activeAuthorityOf(uint256 id) external view returns (address) {
        return id == artistId ? wallet : address(0);
    }
}

/// @dev A mint policy that admits any item and answers with its record: the item hash the
///      records satellite checks, the artist, no fee.
contract SymPolicy is IERC165 {
    address public immutable artistRegistry;
    uint256 internal immutable _artist;
    address internal immutable _seller;

    constructor(address artists, uint256 artist, address seller) {
        (artistRegistry, _artist, _seller) = (artists, artist, seller);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IMintPolicy).interfaceId;
    }

    function authorize(IMintPolicy.MintContext calldata, bytes calldata request)
        external
        view
        returns (IMintPolicy.MintRecord memory r)
    {
        PackageItem memory item = abi.decode(request, (PackageItem));
        r.itemHash = WorksHashing.itemHash(item);
        r.artistId = _artist;
        r.collectionId = item.collectionId;
        r.kind = item.kind;
        r.seedPolicy = item.seedPolicy;
        r.royaltyRate = 5_000;
        r.contentHash = item.contentHash;
        r.mediaHash = item.mediaHash;
        r.recordFileId = item.recordFileId;
        r.saleKind = item.sale.saleKind;
        r.seller = _seller;
        r.creator = address(uint160(_artist));
    }

    function preview(IMintPolicy.MintContext calldata, bytes calldata)
        external
        pure
        returns (PrimaryTerms memory terms)
    {
        return terms;
    }
}

/// @notice Halmos proofs of 6529 Stream's token rules and its records satellite's record and
///         power rules, on the real `Stream`, `WorkRecords` and `ContentStore` behind a real
///         OpenZeppelin `AccessManager`, with lean stand-ins for the policy, artist registry,
///         economics and renderer (docs/testing/README.md, "Symbolic").
/// @dev One work, minted by `adapter` in setUp (its record opened unless a proof says not), and
///      a second admitted adapter of the same kind.
contract StreamSymbolicTest is SymHelpers {
    uint256 internal constant ARTIST_ID = 0xA471;
    address internal constant ARTIST = address(0xA471);
    address internal constant SELLER = address(0x5E11);
    address internal constant GOV = address(0x6060);
    address internal constant OWNER = address(0x0123);

    AccessManager internal manager;
    SymArtists internal artists;
    ContentStore internal store;
    Stream internal stream;
    WorkRecords internal records;
    MockRenderer internal renderer;
    MockSaleAdapter internal adapter;
    MockSaleAdapter internal other;
    bytes32 internal cc0Text;
    PackageItem internal item;
    MediaFile[] internal media;
    uint256 internal tokenId;

    function setUp() public {
        manager = new AccessManager(address(this));
        artists = new SymArtists(ARTIST_ID, ARTIST);
        SplitLedger ledger = new SplitLedger(new SymResolver(), address(new SymSink()));
        MockEconomics econ =
            new MockEconomics(WorkTerms(SELLER, address(0), 0, SELLER, 5_000), address(ledger));
        renderer = new MockRenderer("default");
        stream = new Stream(
            address(manager),
            address(new SymPolicy(address(artists), ARTIST_ID, SELLER)),
            address(artists),
            address(econ),
            address(0),
            address(renderer),
            address(renderer).codehash,
            OWNER
        );
        store = new ContentStore();
        cc0Text = _file("CC0 1.0 Universal", "text/plain");
        records = new WorkRecords(
            address(manager), address(stream), address(store), License("CC0-1.0", cc0Text)
        );
        stream.bindWorkRecords(address(records));
        _roles();
        adapter = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        other = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        vm.startPrank(GOV);
        stream.setAdmittedMinter(address(adapter), true);
        stream.setAdmittedMinter(address(other), true);
        stream.createCollection("Genesis", keccak256("genesis"));
        vm.stopPrank();

        bytes32 mediaFile = _file("the media", "image/png");
        media.push(MediaFile(mediaFile, keccak256("the media"), 0));
        item.kind = 0;
        item.collectionId = 1;
        item.contentHash = keccak256("the media");
        item.mediaHash = keccak256(abi.encode(WorksHashing.MEDIA_DOMAIN, media));
        item.recordFileId = _file('{"name":"work"}', "application/json");
        item.parties.push(Party(ARTIST, 0));
        item.payees.push(ISplitWallet.Payee(ARTIST_ID, address(0), 100_000));
        item.license = License("CC0-1.0", cc0Text);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, address(0), "");
        (tokenId,) = adapter.start(IMintTarget(address(stream)), abi.encode(item));
    }

    // ---------------------------------------------------------------------------------------
    // The token: INV-STR-6, INV-STR-7, INV-STR-11, DSP-20, INV-STR-14
    // ---------------------------------------------------------------------------------------

    /// @notice INV-STR-6, INV-STR-11: only the adapter that minted a token settles it, once,
    ///         even after its removal; any other caller, an admitted adapter of the same kind
    ///         included, is refused, and a refused call leaves the token unsettled.
    /// @dev Bounds: any caller, outcome byte, buyer and price; the minting adapter removed or
    ///      not.
    function check_settlePrimary_onlyTheMintingAdapterOnce(
        address caller,
        uint8 outcome,
        address buyer,
        uint256 price,
        bool removed
    ) public {
        if (removed) {
            vm.prank(GOV);
            stream.setAdmittedMinter(address(adapter), false);
        }
        bytes memory data = abi.encodeWithSelector(
            stream.settlePrimary.selector, tokenId, uint256(outcome), buyer, address(0), price
        );
        (bool ok, bytes4 err) = _call(caller, address(stream), data);
        assert(stream.primarySaleSettled(tokenId) == ok);
        if (caller != address(adapter)) {
            assert(!ok);
            if (outcome <= uint8(PrimaryOutcome.RESCUED)) {
                assert(err == IStream.NotMintingAdapter.selector);
            }
            return;
        }
        bool sold = _and(outcome == uint8(PrimaryOutcome.SOLD), buyer != address(0));
        bool unsold = _and(
            _or(
                outcome == uint8(PrimaryOutcome.UNBID), outcome == uint8(PrimaryOutcome.FROZEN_OUT)
            ),
            _and(buyer == address(0), price == 0)
        );
        assert(ok == _or(sold, unsold));
        if (ok) {
            (bool again, bytes4 err2) = _call(caller, address(stream), data);
            assert(!again && err2 == IStream.SaleAlreadySettled.selector);
        }
    }

    /// @notice INV-STR-7, DSP-20: only the adapter that minted a token burns it, while it holds
    ///         it and before its primary sale settled, even after its removal.
    /// @dev Bounds: any caller; settled (SOLD, kept in the adapter's custody) or not; the
    ///      minting adapter removed or not.
    function check_burn_onlyTheMintingAdapterBeforeSettlement(
        address caller,
        bool settledFirst,
        bool removed
    ) public {
        if (settledFirst) adapter.settle(IStream(address(stream)), tokenId);
        if (removed) {
            vm.prank(GOV);
            stream.setAdmittedMinter(address(adapter), false);
        }
        uint256 minted = stream.totalMinted();
        (bool ok,) =
            _call(caller, address(stream), abi.encodeCall(stream.burn, (tokenId, uint256(1))));
        assert(ok == _and(caller == address(adapter), !settledFirst));
        assert(stream.totalMinted() == minted);
        if (ok) {
            (bool alive,) = address(stream).call(abi.encodeCall(stream.ownerOf, (tokenId)));
            assert(!alive);
        }
    }

    /// @notice INV-STR-14: a royalty rate is set only through the records satellite, never above
    ///         100,000, and the core then holds exactly the rate set; no other caller sets one.
    /// @dev Bounds: any rate; any direct caller of the core.
    function check_royaltyRate_atMost100000(uint32 rate, address caller) public {
        records.openRecord(tokenId, item, media);
        (bool ok,) = _call(GOV, address(records), _setRate(rate));
        (,,,,, uint32 stored) = stream.coreOf(tokenId);
        assert(ok == (rate <= 100_000));
        assert(stored == (ok ? rate : 5_000));
        assert(stored <= 100_000);
        vm.assume(caller != address(records));
        (bool direct, bytes4 err) =
            _call(caller, address(stream), abi.encodeCall(stream.setRoyaltyRate, (tokenId, rate)));
        assert(!direct && err == IStream.UnboundCaller.selector);
    }

    /// @notice Every restricted write of Stream and of its records satellite reverts with
    ///         `AccessManagedUnauthorized` for any caller without the role mapped to it.
    /// @dev Bounds: any caller but the role holder and the manager's admin; every restricted
    ///      selector of `Stream` (11) and `WorkRecords` (6).
    function check_everyRestrictedStreamWrite_needsItsRole(address caller, uint8 action) public {
        vm.assume(caller != GOV && caller != address(this) && caller != address(manager));
        (address target, bytes memory data) = _restricted(action);
        (bool ok, bytes4 err) = _call(caller, target, data);
        assert(!ok && err == IAccessManaged.AccessManagedUnauthorized.selector);
    }

    // ---------------------------------------------------------------------------------------
    // Records and powers: INV-STR-8, INV-STR-12, INV-STR-13, WS-1, WS-12, WS-37, WS-38
    // ---------------------------------------------------------------------------------------

    /// @notice INV-STR-12, WS-37: a work's renounced mask only gains bits: each accepted
    ///         renunciation ORs its bits in, unknown bits are refused, and no call clears one.
    /// @dev Bounds: any two 16-bit masks; the work finalized first or not (RENDERER_REPIN needs
    ///      it).
    function check_renounce_onlyGainsBits(uint16 first, uint16 second, bool finalizeFirst) public {
        records.openRecord(tokenId, item, media);
        if (finalizeFirst) _finalize();
        uint16 mask = _renounce(first, 0);
        uint16 mask2 = _renounce(second, mask);
        assert(mask2 & mask == mask);
        assert(mask2 & ~WorkPowers.ALL == 0);
    }

    /// @notice INV-STR-13, WS-38: once a power is renounced, its function reverts with
    ///         `PowerRenounced` for that work whatever the arguments, a no-op included.
    /// @dev Bounds: each of the three powers; any rate (the current one included); the license
    ///      the work has or another; any renderer address.
    function check_renouncedPower_alwaysReverts(
        uint8 which,
        uint32 rate,
        bool sameLicense,
        address next
    ) public {
        vm.assume(which < 3);
        records.openRecord(tokenId, item, media);
        _finalize();
        uint16 power = uint16(1) << which;
        assert(_renounce(power, 0) == power);
        bytes memory data;
        if (power == WorkPowers.ROYALTY_RATE) {
            data = _setRate(rate);
        } else if (power == WorkPowers.RELICENSE) {
            License memory l = sameLicense ? item.license : License("MIT", cc0Text);
            data = abi.encodeCall(
                records.relicense, (tokenId, l, item, _state(), type(uint64).max, _sigs())
            );
        } else {
            data = abi.encodeCall(records.repinRenderer, (tokenId, next, next.codehash, _state()));
        }
        (bool ok, bytes4 err) = _call(GOV, address(records), data);
        assert(!ok && err == IWorkPowers.PowerRenounced.selector);
    }

    /// @notice WS-12: CC0 is irrevocable: from the CC0 default, a relicense to any identifier
    ///         whose lowercase is not `cc0-1.0` reverts with `LicenseIrrevocable`, whatever its
    ///         case, and the work's license key stays CC0.
    /// @dev Bounds: every 3-byte identifier, and every 7-byte identifier ending in `-1.0`
    ///      (so `CC0-1.0` in each of its eight cases and every other 3-byte stem), any text file
    ///      ID. Each byte of the identifier is a three-way branch in the lowercasing loop, so a
    ///      fully symbolic 7-byte identifier (2,187 paths) is left to the unit tests.
    function check_cc0_isIrrevocable(bytes3 stem, bool short, bytes32 textFileId) public {
        records.openRecord(tokenId, item, media);
        bytes memory id = short ? abi.encodePacked(stem) : abi.encodePacked(stem, "-1.0");
        License memory next = License(string(id), textFileId);
        bytes32 key = WorksHashing.licenseKey(next.spdxId);
        (bool ok, bytes4 err) = _call(
            GOV,
            address(records),
            abi.encodeCall(
                records.relicense, (tokenId, next, item, _state(), type(uint64).max, _sigs())
            )
        );
        if (key != WorksHashing.CC0_LICENSE_KEY) {
            assert(!ok && err == IWorkRecords.LicenseIrrevocable.selector);
        }
        assert(
            WorksHashing.licenseKey(records.licenseOf(tokenId).spdxId)
                == WorksHashing.CC0_LICENSE_KEY
        );
    }

    /// @notice INV-STR-8: a finalized work refuses `setRecord` and `finalize` from anyone,
    ///         whatever the arguments, and keeps its record file and renderer pin.
    /// @dev Bounds: any caller, record file ID and expected state hash.
    function check_finalizedRecord_refusesSetRecordAndFinalize(
        address caller,
        bytes32 recordFileId,
        bytes32 expected,
        bool viaFinalize
    ) public {
        records.openRecord(tokenId, item, media);
        _finalize();
        IWorkRecords.RecordInfo memory before = records.record(tokenId);
        bytes memory data = viaFinalize
            ? abi.encodeCall(records.finalize, (tokenId, expected))
            : abi.encodeCall(records.setRecord, (tokenId, recordFileId, expected));
        (bool ok, bytes4 err) = _call(caller, address(records), data);
        assert(!ok && err == IWorkRecords.WorkIsFinalized.selector);
        IWorkRecords.RecordInfo memory afterwards = records.record(tokenId);
        assert(afterwards.recordFileId == before.recordFileId);
        assert(afterwards.renderer == before.renderer && afterwards.renderer == address(renderer));
        assert(stream.rendererOf(tokenId) == address(renderer));
    }

    /// @notice WS-1: until `openRecord`, every per-token view and mutator of `WorkRecords`
    ///         except `isOpen` reverts with `RecordNotOpen`, whoever calls.
    /// @dev Bounds: any caller (the delivery contract for `refreshMetadata`, which checks its
    ///      caller first); any file ID, index and state; 18 functions. `finalizeNoticeAt` is
    ///      not among them: it returns zero for a work never opened (see the lane report).
    function check_perTokenCalls_revertUntilOpen(
        address caller,
        uint8 action,
        bytes32 word,
        uint32 rate
    ) public {
        bytes memory data;
        if (action == 0) {
            data = abi.encodeCall(records.record, (tokenId));
        } else if (action == 1) {
            data = abi.encodeCall(records.mediaOf, (tokenId));
        } else if (action == 2) {
            data = abi.encodeCall(records.mediaIndex, (tokenId, word));
        } else if (action == 3) {
            data = abi.encodeCall(records.mediaStore, (tokenId, uint256(word)));
        } else if (action == 4) {
            data = abi.encodeCall(records.licenseOf, (tokenId));
        } else if (action == 5) {
            data = abi.encodeCall(records.workStateHash, (tokenId));
        } else if (action == 6) {
            data = abi.encodeCall(records.pinnedRenderer, (tokenId));
        } else if (action == 7) {
            data = abi.encodeCall(records.seedOf, (tokenId));
        } else if (action == 8) {
            data = abi.encodeCall(records.renouncedPowers, (tokenId));
        } else if (action == 9) {
            data = abi.encodeCall(records.preferredLocator, (tokenId, word));
        } else if (action == 10) {
            data = abi.encodeCall(records.setRecord, (tokenId, word, word));
        } else if (action == 11) {
            data = abi.encodeCall(records.finalize, (tokenId, word));
        } else if (action == 12) {
            data = abi.encodeCall(records.syncOnChain, (tokenId, 0, 1));
        } else if (action == 13) {
            data = _setRate(rate);
        } else if (action == 14) {
            data = abi.encodeCall(
                records.relicense, (tokenId, item.license, item, word, type(uint64).max, _sigs())
            );
        } else if (action == 15) {
            data = abi.encodeCall(records.repinRenderer, (tokenId, address(renderer), word, word));
        } else if (action == 16) {
            data =
                abi.encodeCall(records.renounce, (tokenId, uint16(1), word, type(uint64).max, ""));
        } else {
            caller = records.delivery();
            data = abi.encodeCall(records.refreshMetadata, (tokenId));
        }
        // The governed functions are called by their role holder, so the role check passes.
        if (action >= 13 && action <= 15) caller = GOV;
        (bool ok, bytes4 err) = _call(caller, address(records), data);
        assert(!ok && err == IWorkRecords.RecordNotOpen.selector);
        assert(!records.isOpen(tokenId));
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    /// @dev Registers and stores a one-chunk Identity file holding `text`, declaring
    ///      `keccak256(text)` as its SHA-256 (the store does not recompute it).
    function _file(bytes memory text, string memory mime) internal returns (bytes32 fileId) {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(text);
        fileId = store.registerManifest(
            hashes, text.length, uint8(IContentStore.Encoding.Identity), mime, keccak256(text)
        );
        store.writeChunk(text);
    }

    function _roles() internal {
        _map(address(stream), stream.setAdmittedMinter.selector, Roles.SUCCESSOR_SETTER);
        _map(address(stream), stream.createCollection.selector, Roles.PLATFORM);
        _map(address(stream), stream.setContractURI.selector, Roles.PARAMETER_SETTER);
        _map(address(stream), stream.setOwner.selector, Roles.FUNDS_SETTER);
        _map(address(stream), stream.setDefaultRenderer.selector, Roles.SUCCESSOR_SETTER);
        _map(address(stream), stream.releaseContent.selector, Roles.PARAMETER_SETTER);
        _map(address(stream), stream.setDependency.selector, Roles.SUCCESSOR_SETTER);
        _map(address(stream), stream.rescueToMuseum.selector, Roles.PARAMETER_SETTER);
        _map(address(stream), stream.lowerFeeShare.selector, Roles.PARAMETER_SETTER);
        _map(address(records), records.relicense.selector, Roles.PARAMETER_SETTER);
        _map(address(records), records.setRoyaltyRate.selector, Roles.FUNDS_SETTER);
        _map(address(records), records.repinRenderer.selector, Roles.SUCCESSOR_SETTER);
        _map(address(records), records.setDelivery.selector, Roles.SUCCESSOR_SETTER);
        _map(address(records), records.addStore.selector, Roles.SUCCESSOR_SETTER);
        _map(address(records), records.renounce.selector, Roles.PARAMETER_SETTER);
        _map(address(records), records.retireStore.selector, Roles.PARAMETER_SETTER);
        manager.grantRole(Roles.PLATFORM, GOV, 0);
        manager.grantRole(Roles.PARAMETER_SETTER, GOV, 0);
        manager.grantRole(Roles.FUNDS_SETTER, GOV, 0);
        manager.grantRole(Roles.SUCCESSOR_SETTER, GOV, 0);
    }

    function _map(address target, bytes4 selector, uint64 role) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }

    /// @dev The restricted call `action` selects (17 of them), with arguments that would pass
    ///      every other check where that is cheap.
    function _restricted(uint8 action) internal view returns (address, bytes memory) {
        address s = address(stream);
        address r = address(records);
        if (action == 0) {
            return
                (s, abi.encodeCall(stream.releaseContent, (tokenId, item.contentHash, ARTIST_ID)));
        }
        if (action == 1) {
            return (s, abi.encodeCall(stream.setAdmittedMinter, (address(adapter), false)));
        }
        if (action == 2) return (s, abi.encodeCall(stream.rescueToMuseum, (tokenId)));
        if (action == 3) return (s, abi.encodeCall(stream.createCollection, ("Two", bytes32(0))));
        if (action == 4) {
            return (
                s,
                abi.encodeCall(
                    stream.setDefaultRenderer, (address(renderer), address(renderer), bytes32(0))
                )
            );
        }
        if (action == 5) {
            return (s, abi.encodeCall(stream.setDependency, (bytes32(0), address(0), address(0))));
        }
        if (action == 6) return (s, abi.encodeCall(stream.bindWorkRecords, (r)));
        if (action == 7) return (s, abi.encodeCall(stream.bindEditions, (r)));
        if (action == 8) return (s, abi.encodeCall(stream.lowerFeeShare, (tokenId, 0)));
        if (action == 9) return (s, abi.encodeCall(stream.setContractURI, ("x")));
        if (action == 10) return (s, abi.encodeCall(stream.setOwner, (OWNER, address(1))));
        if (action == 11) {
            return
                (r, abi.encodeCall(records.relicense, (tokenId, item.license, item, 0, 0, _sigs())));
        }
        if (action == 12) return (r, _setRate(1));
        if (action == 13) {
            return (r, abi.encodeCall(records.repinRenderer, (tokenId, address(renderer), 0, 0)));
        }
        if (action == 14) {
            return (r, abi.encodeCall(records.setDelivery, (address(0), address(0))));
        }
        if (action == 15) {
            return (r, abi.encodeCall(records.addStore, (address(store), bytes32(0))));
        }
        return (r, abi.encodeCall(records.retireStore, (uint256(1))));
    }

    function _setRate(uint32 rate) internal view returns (bytes memory) {
        return abi.encodeCall(
            records.setRoyaltyRate, (tokenId, rate, item, _stateOrZero(), type(uint64).max, _sigs())
        );
    }

    /// @dev The current state hash, or zero before the record opens (the call reverts first).
    function _stateOrZero() internal view returns (bytes32) {
        return records.isOpen(tokenId) ? records.workStateHash(tokenId) : bytes32(0);
    }

    function _state() internal view returns (bytes32) {
        return records.workStateHash(tokenId);
    }

    /// @dev One consent per party (the work has one); the stand-in registry accepts it.
    function _sigs() internal pure returns (bytes[] memory s) {
        s = new bytes[](1);
    }

    function _finalize() internal {
        bytes32 state = _state();
        vm.prank(ARTIST);
        records.finalize(tokenId, state);
    }

    /// @dev Renounces `powers` as the network's role holder with the artist's (accepted)
    ///      signature and returns the mask afterwards; `previous` is the mask before.
    function _renounce(uint16 powers, uint16 previous) internal returns (uint16 mask) {
        bytes32 state = _state();
        (bool ok, bytes4 err) = _call(
            GOV,
            address(records),
            abi.encodeCall(records.renounce, (tokenId, powers, state, type(uint64).max, ""))
        );
        mask = records.renouncedPowers(tokenId);
        if (powers & ~WorkPowers.ALL != 0) {
            assert(!ok && err == IWorkPowers.UnknownPower.selector && mask == previous);
        } else if (ok) {
            assert(mask == previous | powers);
        } else {
            assert(mask == previous);
        }
    }
}
