// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ContentStore } from "src/content/ContentStore.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { License, PackageItem, Party, SaleTerms } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryOutcome, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { MockRenderer, MockSaleAdapter } from "../mocks/stream/StreamMocks.sol";
import { SymHelpers, SymSink } from "./LedgerSymbolic.t.sol";

/// @dev The artist registry as a federated template reads it: one artist with one wallet, the
///      listing the federation registry writes, the network's recorded share for the token, and
///      every consent accepted.
contract SymFedAccounts is IArtistPayoutResolver {
    uint256 public immutable artistId;
    address public immutable wallet;
    address public federationRegistry;
    uint32 public recordedShare = type(uint32).max;
    mapping(address token => uint256) internal _listed;

    constructor(uint256 artistId_, address wallet_) {
        (artistId, wallet) = (artistId_, wallet_);
    }

    function setFederationRegistry(address registry) external {
        federationRegistry = registry;
    }

    function setRecordedShare(uint32 share) external {
        recordedShare = share;
    }

    function list(address token) external {
        _listed[token] = 1;
    }

    function isWallet(uint256 accountId, address account) external view returns (bool) {
        return accountId == artistId && account == wallet;
    }

    function federatedListing(address token)
        external
        view
        returns (uint256, IArtistRegistry.FederationStatus)
    {
        if (_listed[token] == 0) return (0, IArtistRegistry.FederationStatus.NONE);
        return (artistId, IArtistRegistry.FederationStatus.ACTIVE);
    }

    function federatedFeeShare(address) external view returns (uint32) {
        return recordedShare;
    }

    function payoutAddress(uint256 id) external view returns (address) {
        return id == artistId ? wallet : address(0);
    }

    function requireConsent(uint256, bytes32, bytes calldata) external view returns (address) {
        return wallet;
    }
}

/// @dev The federation registry as a template reads it: `register` lists the caller, and an
///      adapter may mint once the test admits it.
contract SymFederation {
    SymFedAccounts internal immutable _accounts;
    mapping(address adapter => bool) public admitted;

    constructor(SymFedAccounts accounts) {
        _accounts = accounts;
    }

    function admit(address adapter) external {
        admitted[adapter] = true;
    }

    function register(IFederationRegistry.Join calldata) external {
        _accounts.list(msg.sender);
    }

    function canMint(address, address adapter) external view returns (bool) {
        return admitted[adapter];
    }
}

/// @notice Halmos proofs of a federated template's rules on the real `FederatedStream`, with the
///         real `SplitLedger` and `ContentStore` and stand-ins for the artist and federation
///         registries (docs/testing/README.md, "Symbolic").
/// @dev The template is deployed directly, as its deployer would, with a 10% share fixed at
///      deployment. Proofs that need a token join and mint one through `adapter`.
contract FederatedSymbolicTest is SymHelpers {
    uint256 internal constant ARTIST_ID = 0xA471;
    address internal constant ARTIST = address(0xA471);
    address internal constant FEE = address(0xFEE5);
    address internal constant NETWORK = address(0x6529);
    uint32 internal constant SHARE = 10_000;
    uint32 internal constant RATE = 7_500;

    SymFedAccounts internal accounts;
    SymFederation internal federation;
    ContentStore internal store;
    MockRenderer internal renderer;
    FederatedStream internal fed;
    MockSaleAdapter internal adapter;
    MockSaleAdapter internal other;
    bytes internal mintData;
    bytes32 internal itemHash;

    function setUp() public {
        accounts = new SymFedAccounts(ARTIST_ID, ARTIST);
        federation = new SymFederation(accounts);
        accounts.setFederationRegistry(address(federation));
        store = new ContentStore();
        renderer = new MockRenderer("default");
        SplitLedger ledger = new SplitLedger(accounts, address(new SymSink()));
        bytes32 cc0Text = _file("CC0 1.0 Universal", "text/plain");
        fed = new FederatedStream(
            IFederatedStream.Config({
                name: "Artist",
                symbol: "ART",
                artistRegistry: address(accounts),
                splitLedger: address(ledger),
                contentStore: address(store),
                artistId: ARTIST_ID,
                feeShare: SHARE,
                feeRecipient: FEE,
                renderer: address(renderer),
                rendererCodeHash: address(renderer).codehash,
                owner: ARTIST
            })
        );
        adapter = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        other = new MockSaleAdapter(SaleKind.ENGLISH_AUCTION);
        federation.admit(address(adapter));
        federation.admit(address(other));

        MediaFile[] memory media = new MediaFile[](1);
        media[0] = MediaFile(_file("the media", "image/png"), keccak256("the media"), 0);
        PackageItem memory item;
        item.contentHash = keccak256("the media");
        item.mediaHash = WorksHashing.mediaHash(media);
        item.recordFileId = _file('{"name":"work"}', "application/json");
        item.parties = new Party[](1);
        item.parties[0] = Party(ARTIST, 0);
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(ARTIST_ID, address(0), 100_000);
        item.license = License("CC0-1.0", cc0Text);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        itemHash = WorksHashing.itemHash(item);
        mintData = abi.encode(IFederatedStream.FederatedMint(item, media, new bytes[](0)));
    }

    // ---------------------------------------------------------------------------------------
    // FED-4, FED-5
    // ---------------------------------------------------------------------------------------

    /// @notice FED-4: a template has no restricted function: no `authority()`, and every write
    ///         that is not a sale adapter's refuses any caller that is not a wallet of the
    ///         artist's account, the network included; `setAdmittedMinter` refuses everyone.
    /// @dev Bounds: any caller but the artist's wallet; the template's eleven artist writes and
    ///      `setAdmittedMinter`, with any word as their argument.
    function check_noRestrictedFunction_onATemplate(address caller, uint8 action, bytes32 word)
        public
    {
        vm.assume(caller != ARTIST);
        _joinAndMint();
        (bool hasAuthority,) = address(fed).staticcall(abi.encodeWithSignature("authority()"));
        assert(!hasAuthority);
        bytes memory data;
        if (action == 0) {
            data = abi.encodeCall(fed.approveItem, (word, 1));
        } else if (action == 1) {
            data = abi.encodeCall(fed.revokeItem, (word));
        } else if (action == 2) {
            data = abi.encodeCall(fed.setRecord, (1, word));
        } else if (action == 3) {
            data = abi.encodeCall(fed.finalize, (1));
        } else if (action == 4) {
            data = abi.encodeCall(fed.setRoyaltyRate, (1, 0));
        } else if (action == 5) {
            data = abi.encodeCall(fed.setLocator, (1, 0, 1, "ar://x"));
        } else if (action == 6) {
            data = abi.encodeCall(
                fed.setDefaultRenderer, (address(renderer), address(renderer), word)
            );
        } else if (action == 7) {
            data = abi.encodeCall(fed.linkEditions, (address(renderer)));
        } else if (action == 8) {
            data = abi.encodeCall(fed.setContractURI, ("x"));
        } else if (action == 9) {
            data = abi.encodeCall(fed.setOwner, (address(uint160(uint256(word)))));
        } else if (action == 10) {
            data = abi.encodeCall(fed.joinFederation, (_noJoin()));
        } else {
            data = abi.encodeCall(fed.setAdmittedMinter, (address(uint160(uint256(word))), true));
        }
        (bool ok, bytes4 err) = _call(caller, address(fed), data);
        assert(!ok);
        if (action < 11) assert(err == IFederatedToken.NotArtist.selector);
        else assert(err == IFederatedToken.FederationStateInvalid.selector);
    }

    /// @notice FED-5: before the template joins, no address is an admitted minter and every
    ///         mint reverts, even an approved item by an adapter the federation registry admits;
    ///         `setAdmittedMinter` always reverts, for the artist too.
    /// @dev Bounds: any caller and probe address; the approved item.
    function check_beforeJoining_nothingMints(address caller, address probe, bool asArtist) public {
        vm.prank(ARTIST);
        fed.approveItem(itemHash, RATE);
        assert(!fed.isAdmittedMinter(probe));
        (bool ok, bytes4 err) = _call(
            caller,
            address(fed),
            abi.encodeCall(fed.mint, (caller, uint256(0), uint256(1), mintData))
        );
        assert(!ok && err == IMintTarget.NotAdmittedMinter.selector);
        (ok,) = address(adapter)
            .call(abi.encodeCall(adapter.start, (IMintTarget(address(fed)), mintData)));
        assert(!ok);
        (ok, err) = _call(
            asArtist ? ARTIST : caller,
            address(fed),
            abi.encodeCall(fed.setAdmittedMinter, (probe, true))
        );
        assert(!ok && err == IFederatedToken.FederationStateInvalid.selector);
        assert(!fed.federationState());
    }

    // ---------------------------------------------------------------------------------------
    // FED-16, FED-24, FED-73
    // ---------------------------------------------------------------------------------------

    /// @notice FED-16: only the adapter that minted a token settles it, once; SOLD needs a
    ///         buyer; any other caller, an admitted adapter included, is refused.
    /// @dev Bounds: any caller, outcome byte, buyer and price.
    function check_settle_onlyTheMintingAdapterOnce(
        address caller,
        uint8 outcome,
        address buyer,
        uint256 price
    ) public {
        uint256 tokenId = _joinAndMint();
        bytes memory data = abi.encodeWithSelector(
            fed.settlePrimary.selector, tokenId, uint256(outcome), buyer, address(0), price
        );
        (bool ok, bytes4 err) = _call(caller, address(fed), data);
        assert(fed.primarySaleSettled(tokenId) == ok);
        if (caller != address(adapter)) {
            assert(!ok);
            if (outcome <= uint8(PrimaryOutcome.RESCUED)) {
                assert(err == IFederatedStream.NotMintingAdapter.selector);
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
            (bool again, bytes4 err2) = _call(caller, address(fed), data);
            assert(!again && err2 == IFederatedStream.SaleAlreadySettled.selector);
        }
    }

    /// @notice FED-24: a work's royalty rate only falls: the artist's change succeeds exactly
    ///         when the new rate is below the current one, twice in a row.
    /// @dev Bounds: any two rates.
    function check_royaltyRate_onlyFalls(uint32 first, uint32 second) public {
        uint256 tokenId = _joinAndMint();
        vm.prank(ARTIST);
        (bool ok1,) = address(fed).call(abi.encodeCall(fed.setRoyaltyRate, (tokenId, first)));
        assert(ok1 == (first < RATE));
        uint32 current = ok1 ? first : RATE;
        assert(_rate(tokenId) == current);
        vm.prank(ARTIST);
        (bool ok2,) = address(fed).call(abi.encodeCall(fed.setRoyaltyRate, (tokenId, second)));
        assert(ok2 == (second < current));
        assert(_rate(tokenId) == (ok2 ? second : current));
        assert(_rate(tokenId) <= RATE);
    }

    /// @notice FED-73: the share in force is the smaller of the share fixed at deployment and the
    ///         share the artist registry records for the token: a mint and `primaryTerms` both
    ///         report it, so no recorded share can raise it, and a lower one is used.
    /// @dev Bounds: any recorded share, before the mint and changed again after it.
    function check_feeShareInForce_isTheMinimum(uint32 atMint, uint32 later) public {
        accounts.setRecordedShare(atMint);
        vm.prank(ARTIST);
        fed.joinFederation(_noJoin());
        vm.prank(ARTIST);
        fed.approveItem(itemHash, RATE);
        (uint256 tokenId, PrimaryTerms memory terms) =
            adapter.start(IMintTarget(address(fed)), mintData);
        assert(terms.feeShare == (atMint < SHARE ? atMint : SHARE));
        assert(terms.feeShare <= SHARE && terms.feeRecipient == FEE);
        accounts.setRecordedShare(later);
        PrimaryTerms memory now_ = fed.primaryTerms(tokenId, "");
        assert(now_.feeShare == (later < SHARE ? later : SHARE));
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    function _file(bytes memory text, string memory mime) internal returns (bytes32 fileId) {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(text);
        fileId = store.registerManifest(
            hashes, text.length, uint8(IContentStore.Encoding.Identity), mime, keccak256(text)
        );
        store.writeChunk(text);
    }

    function _noJoin() internal pure returns (IFederationRegistry.Join memory j) { }

    /// @dev Joins, approves the item and mints it through `adapter`; returns the token.
    function _joinAndMint() internal returns (uint256 tokenId) {
        vm.startPrank(ARTIST);
        fed.joinFederation(_noJoin());
        fed.approveItem(itemHash, RATE);
        vm.stopPrank();
        (tokenId,) = adapter.start(IMintTarget(address(fed)), mintData);
    }

    function _rate(uint256 tokenId) internal view returns (uint32 rate) {
        (,,,,, rate) = fed.coreOf(tokenId);
    }
}
