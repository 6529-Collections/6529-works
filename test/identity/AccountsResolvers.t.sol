// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Directory } from "src/core/Directory.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { MintFacts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { SplitFactoryWalletsMock } from "../mocks/identity/IdentityWorksMocks.sol";

/// @notice A federation module answering `entry` as the test sets it.
contract EntryStub {
    mapping(address token => IFederationRegistry.Entry) internal _entries;

    function set(address token, uint256 artistId, IFederationRegistry.Status status) external {
        _entries[token].artistId = artistId;
        _entries[token].status = status;
    }

    function entry(address token) external view returns (IFederationRegistry.Entry memory) {
        return _entries[token];
    }
}

/// @notice A token that answers `workOf` with whatever bytes the test sets.
contract RawWorkToken {
    bytes internal _answer;
    address public stream;

    function setAnswer(bytes calldata answer) external {
        _answer = answer;
    }

    function setStream(address stream_) external {
        stream = stream_;
    }

    function workOf(uint256) external view returns (bytes memory) {
        bytes memory a = _answer;
        assembly ("memory-safe") {
            return(add(a, 0x20), mload(a))
        }
    }
}

/// @notice The accounts module against the real permanent core: `isArtist` for 6529 Stream
///         works and editions (any token answering `workOf`, any edition through its master),
///         `federatedListing` forwarding the federation module, `registerFederated` taking its
///         caller from the directory, and `payoutAddress` through the real `Directory`.
contract AccountsResolversTest is CoreFixture {
    Accounts internal acc;
    Directory internal dir;
    EntryStub internal federation;
    DelegationManagementMock internal delegation;
    ConsolidationAdapter internal adapter;
    address internal packageRegistry = makeAddr("packageRegistry");
    uint256 internal artistKey = 0xA1;
    uint256 internal walletKey = 0xB2;
    address internal artist;
    address internal wallet;
    address internal outsider = makeAddr("outsider");
    uint256 internal artistId;

    function setUp() public override {
        super.setUp();
        artist = vm.addr(artistKey);
        wallet = vm.addr(walletKey);
        delegation = new DelegationManagementMock();
        adapter = new ConsolidationAdapter(IDelegationManagement(address(delegation)));
        federation = new EntryStub();
        SplitFactoryWalletsMock factory = new SplitFactoryWalletsMock();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        dir = new Directory(
            address(manager), predicted, address(federation), address(terms), address(records)
        );
        acc = new Accounts(
            address(manager),
            adapter,
            address(adapter).codehash,
            Accounts.Wiring(
                address(dir),
                address(stream),
                address(editions),
                address(factory),
                address(0),
                packageRegistry
            )
        );
        assertEq(address(acc), predicted);
        _consolidate(artist, wallet);
        vm.prank(packageRegistry);
        artistId = acc.register(artist, bytes32(0), bytes32(0));
    }

    // ------------------------------------------------------------------ isArtist

    function test_IsArtist_AStreamWorkAnswersForEveryWalletOfTheLead() public {
        uint256 id = _mintFor(1, artistId);
        assertTrue(acc.isArtist(address(stream), id, artist));
        assertTrue(acc.isArtist(address(stream), id, wallet), "a consolidated wallet");
        assertFalse(acc.isArtist(address(stream), id, outsider));
        assertFalse(acc.isArtist(address(stream), id, address(0)));
        assertFalse(acc.isArtist(address(stream), id + 1, artist), "an unminted ID");
        assertFalse(acc.isArtist(address(0), id, artist), "no token");
    }

    function test_IsArtist_AnEditionAnswersThroughItsMaster() public {
        uint256 id = _mintFor(1, artistId);
        sale.createEdition(address(editions), id, 10, address(0xFEE), 1000);
        assertTrue(acc.isArtist(address(editions), id, wallet));
        assertFalse(acc.isArtist(address(editions), id, outsider));
        uint256 other = _mintFor(2, uint160(outsider));
        assertFalse(acc.isArtist(address(editions), other, artist), "another artist's master");
        assertTrue(acc.isArtist(address(editions), other, outsider));
    }

    function test_IsArtist_AFrozenAccountIsNo() public {
        uint256 id = _mintFor(1, artistId);
        acc.freeze(artistId);
        assertFalse(acc.isArtist(address(stream), id, artist));
        assertFalse(acc.isArtist(address(stream), id, wallet));
    }

    /// @dev A burned work keeps its facts, so its artist still speaks about it.
    function test_IsArtist_ABurnedWorkStillAnswers() public {
        uint256 id = _mintFor(1, artistId);
        sale.burn(address(stream), id);
        assertTrue(acc.isArtist(address(stream), id, artist));
    }

    /// @dev Anything that is not a token answering a whole `Work` is "no": an account without
    ///      code, a contract without the function, short or malformed answers, an artist ID
    ///      over 160 bits, and an editions-like contract naming itself or nothing.
    function test_IsArtist_AnythingElseIsNo() public {
        assertFalse(acc.isArtist(outsider, 1, artist), "an account without code");
        assertFalse(acc.isArtist(address(manager), 1, artist), "no workOf");
        RawWorkToken raw = new RawWorkToken();
        raw.setAnswer(abi.encode(bytes32(0), artistId));
        assertFalse(acc.isArtist(address(raw), 1, artist), "a short answer");
        raw.setAnswer(_work(artistId, 12));
        assertFalse(acc.isArtist(address(raw), 1, artist), "a long answer");
        raw.setAnswer(_work(uint256(1) << 160 | artistId, 11));
        assertFalse(acc.isArtist(address(raw), 1, artist), "an ID over 160 bits");
        raw.setAnswer(_work(artistId, 11));
        assertTrue(acc.isArtist(address(raw), 1, artist), "a whole answer of any token counts");
        raw.setAnswer("");
        raw.setStream(address(raw));
        assertFalse(acc.isArtist(address(raw), 1, artist), "an edition naming itself");
        raw.setStream(address(0));
        assertFalse(acc.isArtist(address(raw), 1, artist), "an edition naming nothing");
        raw.setStream(address(stream));
        uint256 id = _mintFor(1, artistId);
        assertTrue(acc.isArtist(address(raw), id, artist), "an edition naming a master");
    }

    // ------------------------------------------------------------------ federation forwards

    function test_FederationRegistry_IsTheDirectorysFederationModule() public {
        assertEq(acc.federationRegistry(), address(federation));
        dir.removeModule(Slots.FEDERATION);
        assertEq(acc.federationRegistry(), address(0), "an empty slot answers nothing");
    }

    function test_RegisterFederated_OnlyTheDirectorysFederationModule() public {
        uint256 key = 0xF1;
        address account = vm.addr(key);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig =
            _sign(key, acc.registrationDigest(account, bytes32(0), bytes32(0), deadline));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, outsider));
        acc.registerFederated(account, bytes32(0), bytes32(0), deadline, sig);
        vm.prank(packageRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, packageRegistry)
        );
        acc.registerFederated(account, bytes32(0), bytes32(0), deadline, sig);
        vm.prank(address(federation));
        assertEq(
            acc.registerFederated(account, bytes32(0), bytes32(0), deadline, sig), uint160(account)
        );
        assertEq(acc.authorityOf(uint160(account)), account);
    }

    function test_RegisterFederated_RefusedWhileTheSlotIsEmpty() public {
        dir.removeModule(Slots.FEDERATION);
        uint256 key = 0xF1;
        address account = vm.addr(key);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig =
            _sign(key, acc.registrationDigest(account, bytes32(0), bytes32(0), deadline));
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, address(0)));
        acc.registerFederated(account, bytes32(0), bytes32(0), deadline, sig);
        vm.prank(address(federation));
        vm.expectRevert(
            abi.encodeWithSelector(IArtistRegistry.UnboundCaller.selector, address(federation))
        );
        acc.registerFederated(account, bytes32(0), bytes32(0), deadline, sig);
    }

    // ------------------------------------------------------------------ payout through Directory

    function test_PayoutAddress_ThroughTheDirectory() public {
        assertEq(dir.payoutAddress(artistId), artist);
        acc.freeze(artistId);
        assertEq(dir.payoutAddress(artistId), address(0), "held while frozen");
        acc.unfreeze(artistId);
        assertEq(dir.payoutAddress(artistId), artist);
        assertEq(dir.payoutAddress(uint160(outsider)), address(0), "an unknown artist");
        dir.removeModule(Slots.ACCOUNTS);
        vm.expectRevert();
        dir.payoutAddress(artistId);
    }

    // ------------------------------------------------------------------ helpers

    function _mintFor(uint256 n, uint256 lead) internal returns (uint256) {
        MintFacts memory f = _facts(n);
        f.artistId = lead;
        return sale.mint(address(stream), f);
    }

    function _work(uint256 lead, uint256 words) internal pure returns (bytes memory w) {
        w = new bytes(words * 32);
        assembly ("memory-safe") {
            mstore(add(w, 0x40), lead)
        }
    }

    function _consolidate(address a, address b) internal {
        address all = 0x8888888888888888888888888888888888888888;
        vm.prank(a);
        delegation.registerDelegationAddress(all, b, type(uint64).max, 999, true, 0);
        vm.prank(b);
        delegation.registerDelegationAddress(all, a, type(uint64).max, 999, true, 0);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
