// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Directory } from "src/core/Directory.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { FederatedDeployer } from "src/federated/FederatedDeployer.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { Core, MintFacts, MintTerms } from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH, ProductEconomics } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionTerms,
    License,
    PackageItem,
    Party,
    SaleTerms
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import { MockSale } from "../mocks/core/CoreMocks.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";

/// @notice A contract with code that accepts ETH: the split ledger's network and fee sink.
contract FedSink {
    receive() external payable { }
}

/// @notice The economics resolver as the federation module reads it: the split ledger and the
///         federated product's fee recipient and share.
contract FedEconomics {
    address public splitFactory;
    address public feeRecipient;
    uint32 public feeShare;

    constructor(address splitFactory_, address feeRecipient_, uint32 feeShare_) {
        (splitFactory, feeRecipient, feeShare) = (splitFactory_, feeRecipient_, feeShare_);
    }

    function setFeeShare(uint32 share) external {
        feeShare = share;
    }

    function economics(bytes32) external view returns (ProductEconomics memory) {
        return ProductEconomics(feeRecipient, feeShare, 0);
    }
}

/// @notice A federated sale contract: asks the federation module, then mints into its custody.
contract FedSale is MockSale {
    function start(address policy, address token, bytes calldata request)
        external
        returns (uint256 tokenId, MintFacts memory f, MintTerms memory t)
    {
        (f, t) = IMintPolicy(policy).authorize(token, request);
        tokenId = IStream(token).mint(address(this), f);
    }
}

/// @notice The permanent core of `CoreFixture` plus a second, real directory for the federation:
///         the real `Accounts` (with the consolidation adapter over the delegation mock), the
///         real `FederationRegistry`, the split ledger paying through that directory, the two
///         template deployers, a federated sale contract, and one artist (root `artist`,
///         consolidated with `wallet`) whose `FederatedStream` and `FederatedEditions` are listed.
abstract contract FederationFixture is CoreFixture {
    uint256 internal constant FAR = type(uint64).max;
    address internal constant ALL = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;
    uint32 internal constant SHARE = 10_000;
    uint24 internal constant RATE = 5_000;
    bytes32 internal constant PROFILE = keccak256("profile");
    bytes32 internal constant PROFILE_DOC = keccak256("profile document");

    Directory internal fedDirectory;
    SplitLedger internal ledger;
    FedEconomics internal econ;
    Accounts internal accountsModule;
    FederationRegistry internal registry;
    FederatedDeployer internal streamDeployer;
    FederatedDeployer internal editionsDeployer;
    DelegationManagementMock internal delegation;
    ConsolidationAdapter internal adapter;
    FedSale internal fedSale;
    FedSink internal sink;
    FederatedStream internal fStream;
    FederatedEditions internal fEditions;

    address internal feeVault = makeAddr("feeVault");
    address internal stranger = makeAddr("stranger");
    address internal packageRegistry = makeAddr("packageRegistry");

    uint256 internal artistKey = 0xA1;
    uint256 internal walletKey = 0xB2;
    uint256 internal collabKey = 0xC3;
    uint256 internal otherKey = 0xD4;
    address internal artist;
    address internal wallet;
    address internal collab;
    address internal other;
    uint256 internal fArtistId;
    bytes32 internal licenseText;

    function setUp() public virtual override {
        super.setUp();
        artist = vm.addr(artistKey);
        wallet = vm.addr(walletKey);
        collab = vm.addr(collabKey);
        other = vm.addr(otherKey);
        fArtistId = uint256(uint160(artist));

        delegation = new DelegationManagementMock();
        adapter = new ConsolidationAdapter(IDelegationManagement(address(delegation)));
        sink = new FedSink();
        uint64 n = vm.getNonce(address(this));
        address predictedAccounts = vm.computeCreateAddress(address(this), n + 3);
        address predictedRegistry = vm.computeCreateAddress(address(this), n + 4);
        fedDirectory = new Directory(
            address(manager), predictedAccounts, predictedRegistry, address(terms), address(records)
        );
        ledger = new SplitLedger(IArtistPayoutResolver(address(fedDirectory)), address(sink));
        econ = new FedEconomics(address(ledger), feeVault, SHARE);
        accountsModule = new Accounts(
            address(manager),
            adapter,
            address(adapter).codehash,
            Accounts.Wiring(
                address(fedDirectory),
                address(stream),
                address(editions),
                address(ledger),
                address(0),
                packageRegistry
            )
        );
        registry = new FederationRegistry(
            address(manager),
            address(fedDirectory),
            address(facts),
            address(econ),
            address(store),
            address(0)
        );
        assertEq(address(accountsModule), predictedAccounts, "predicted accounts");
        assertEq(address(registry), predictedRegistry, "predicted registry");

        streamDeployer = new FederatedDeployer(type(FederatedStream).creationCode);
        editionsDeployer = new FederatedDeployer(type(FederatedEditions).creationCode);
        fedSale = new FedSale();
        registry.approveTemplate(address(streamDeployer), 1, IFederationRegistry.Form.ERC721);
        registry.approveTemplate(address(editionsDeployer), 1, IFederationRegistry.Form.ERC1155);
        registry.setAdapter(address(fedSale), IFederationRegistry.Form.ERC721, true);

        _consolidate(artist, wallet);
        licenseText = _file("license text of the work", "text/plain");
        fStream = _deployStream(fArtistId, bytes32(0));
        _join(address(fStream), artistKey, artistKey, address(streamDeployer));
        fEditions = _deployEditions(address(fStream), fArtistId, bytes32(0));
        _join(address(fEditions), walletKey, artistKey, address(editionsDeployer));
    }

    // ------------------------------------------------------------------ deployment helpers

    function _deployStream(uint256 id, bytes32 salt) internal returns (FederatedStream) {
        bytes memory config = abi.encode(
            "Artist Works",
            "ART",
            address(facts),
            address(fedDirectory),
            id,
            marketOwner,
            address(renderer)
        );
        return FederatedStream(streamDeployer.deploy(salt, config));
    }

    function _deployEditions(address master, uint256 id, bytes32 salt)
        internal
        returns (FederatedEditions)
    {
        bytes memory config = abi.encode(
            "Artist Editions", "ARTED", master, address(fedDirectory), id, marketOwner
        );
        return FederatedEditions(editionsDeployer.deploy(salt, config));
    }

    /// @dev The `Join` for `token`: consent by `signerKey` (a wallet of the account), and a
    ///      registration signature by `rootKey` when the account has no identity yet.
    function _joinData(address token, uint256 signerKey, uint256 rootKey, address deployer)
        internal
        view
        returns (IFederationRegistry.Join memory j)
    {
        uint64 deadline = uint64(block.timestamp + 1 days);
        address root = vm.addr(rootKey);
        IFederationRegistry.Form form = registry.templateOf(deployer).form;
        address partner = form == IFederationRegistry.Form.ERC1155
            ? FederatedEditions(token).stream()
            : address(0);
        bytes memory registration;
        if (accountsModule.artistIdOf(root) == 0) {
            registration = _sign(
                rootKey, accountsModule.registrationDigest(root, PROFILE, PROFILE_DOC, deadline)
            );
        }
        bytes32 subject = registry.listingSubject(token, form, partner, econ.feeShare(), deadline);
        bytes memory consent =
            _proof(signerKey, accountsModule.consentDigest(address(registry), subject));
        j = IFederationRegistry.Join(
            deployer, PROFILE, PROFILE_DOC, deadline, registration, consent
        );
    }

    function _join(address token, uint256 signerKey, uint256 rootKey, address deployer) internal {
        registry.register(token, _joinData(token, signerKey, rootKey, deployer));
    }

    // ------------------------------------------------------------------ identity helpers

    function _consolidate(address a, address b) internal {
        vm.prank(a);
        delegation.registerDelegationAddress(ALL, b, FAR, CONSOLIDATION, true, 0);
        vm.prank(b);
        delegation.registerDelegationAddress(ALL, a, FAR, CONSOLIDATION, true, 0);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _proof(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        return abi.encodePacked(vm.addr(key), _sign(key, digest));
    }

    // ------------------------------------------------------------------ content helpers

    /// @dev Registers one complete single-chunk SHA-256 file.
    function _file(bytes memory data, string memory mime) internal returns (bytes32 fileId) {
        (bytes32 h,) = store.writeChunk(data);
        bytes32[] memory chunks = new bytes32[](1);
        chunks[0] = h;
        fileId = store.registerManifest(chunks, data.length, 0, mime, sha256(data));
    }

    /// @dev An original item number `n` of the fixture's artist, with no collaborator: one media
    ///      file, the license text, the artist paid through the artist-resolved payee.
    function _item(uint256 n) internal returns (PackageItem memory item, MediaFile[] memory media) {
        return _itemOf(n, 0, new address[](0));
    }

    function _itemOf(uint256 n, uint8 kind, address[] memory collaborators)
        internal
        returns (PackageItem memory item, MediaFile[] memory media)
    {
        bytes memory data = abi.encodePacked("federated work ", n);
        bytes32 fileId = _file(data, "image/png");
        media = new MediaFile[](1);
        media[0] = MediaFile(fileId, sha256(data), 0);
        item.kind = kind;
        item.collectionId = 1;
        item.contentHash = sha256(data);
        item.mediaHash = WorksHashing.mediaHash(media);
        item.recordFileId = _file(abi.encodePacked("record ", n), "application/json");
        item.parties = new Party[](1 + collaborators.length);
        item.parties[0] = Party(artist, 0);
        for (uint256 i; i < collaborators.length; ++i) {
            item.parties[i + 1] = Party(collaborators[i], 1);
        }
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(fArtistId, address(0), 100_000);
        item.license = License("CC-BY-4.0", licenseText);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        item.edition = EditionTerms(0, CURRENCY_ETH, bytes32(0), "");
    }

    function _request(PackageItem memory item, MediaFile[] memory media, bytes[] memory consents)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(IFederatedStream.FederatedMint(item, media, consents));
    }

    /// @dev A collaborator's consent to `item` at `rate` for `token`.
    function _consent(uint256 key, address token, PackageItem memory item, uint24 rate)
        internal
        view
        returns (bytes memory)
    {
        bytes32 what = Core.federatedConsent(WorksHashing.itemHash(item), rate);
        return _proof(key, accountsModule.consentDigest(token, what));
    }

    function _approve(address token, PackageItem memory item, uint24 rate) internal {
        vm.prank(artist);
        registry.approveItem(token, WorksHashing.itemHash(item), rate);
    }

    /// @dev Approves and starts item `n` in the federated stream; the token sits in the sale.
    function _fedMint(uint256 n) internal returns (uint256 tokenId) {
        (PackageItem memory item, MediaFile[] memory media) = _item(n);
        _approve(address(fStream), item, RATE);
        (tokenId,,) = fedSale.start(
            address(registry), address(fStream), _request(item, media, new bytes[](0))
        );
    }

    /// @dev Mints item `n`, records it sold and delivers it to `to`.
    function _fedSell(uint256 n, address to) internal returns (uint256 tokenId) {
        tokenId = _fedMint(n);
        fedSale.record(address(fStream), tokenId, true, to, 1 ether);
        fedSale.send(address(fStream), tokenId, to);
    }
}
