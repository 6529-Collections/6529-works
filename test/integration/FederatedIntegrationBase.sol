// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { FederatedDeployer } from "src/federated/FederatedDeployer.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { Core } from "src/interfaces/core/CoreTypes.sol";
import { PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { Party, PartyRole } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Federated helpers on the real deployed stack: a federated artist's pair deployed
///         through the genesis template deployers, listed through the federation module the
///         directory names, its items approved and started through the English auction.
abstract contract FederatedIntegrationBase is IntegrationBase {
    /// @dev The federated product's launch network share (`EconomicsResolver`).
    uint32 internal constant FED_SHARE = 10_000;
    /// @dev The royalty rate federated items are approved at here.
    uint24 internal constant FED_RATE = 5_000;

    FederatedDeployer internal streamDeployer;
    FederatedDeployer internal editionsDeployer;
    uint256 private _fedSalt;

    function setUp() public virtual override {
        super.setUp();
        streamDeployer = FederatedDeployer(deployment.federatedStreamDeployer);
        editionsDeployer = FederatedDeployer(deployment.federatedEditionsDeployer);
    }

    // ------------------------------------------------------------------ the pair

    /// @dev Deploys and lists `artist`'s FederatedStream and its FederatedEditions. The artist
    ///      (an actor with a key) gets its identity from its own signature at the first listing.
    function _listPair(address artist)
        internal
        returns (FederatedStream fStream, FederatedEditions fEditions)
    {
        fStream = _deployFedStream(artist);
        _register(address(fStream), artist, address(streamDeployer));
        fEditions = _deployFedEditions(address(fStream), artist);
        _register(address(fEditions), artist, address(editionsDeployer));
    }

    function _deployFedStream(address artist) internal returns (FederatedStream) {
        bytes memory config = abi.encode(
            "Federated Works",
            "FED",
            address(facts),
            address(directory),
            uint256(uint160(artist)),
            marketOwner,
            address(renderer)
        );
        return FederatedStream(streamDeployer.deploy(bytes32(++_fedSalt), config));
    }

    function _deployFedEditions(address master, address artist)
        internal
        returns (FederatedEditions)
    {
        bytes memory config = abi.encode(
            "Federated Editions",
            "FEDED",
            master,
            address(directory),
            uint256(uint160(artist)),
            marketOwner
        );
        return FederatedEditions(editionsDeployer.deploy(bytes32(++_fedSalt), config));
    }

    /// @dev The artist's `Join` for `token`, signed by the artist (its listing consent, and its
    ///      registration while it has no identity).
    function _joinOf(address token, address artist, address templateDeployer)
        internal
        view
        returns (IFederationRegistry.Join memory j)
    {
        uint64 deadline = uint64(block.timestamp + 1 days);
        IFederationRegistry.Form form = federation.templateOf(templateDeployer).form;
        address partner = form == IFederationRegistry.Form.ERC1155
            ? FederatedEditions(token).stream()
            : address(0);
        bytes memory registration;
        if (accounts.artistIdOf(artist) == 0) {
            registration = _sign(
                artist,
                accounts.registrationDigest(
                    artist, _profileId(artist), _profileDoc(artist), deadline
                )
            );
        }
        uint32 share = economics.economics(PRODUCT_FEDERATED).feeShare;
        bytes32 subject = federation.listingSubject(token, form, partner, share, deadline);
        bytes memory consent = abi.encodePacked(
            artist, _sign(artist, accounts.consentDigest(address(federation), subject))
        );
        j = IFederationRegistry.Join(
            templateDeployer,
            _profileId(artist),
            _profileDoc(artist),
            deadline,
            registration,
            consent
        );
    }

    function _register(address token, address artist, address templateDeployer) internal {
        federation.register(token, _joinOf(token, artist, templateDeployer));
    }

    // ------------------------------------------------------------------ items

    /// @dev A federated original of `artist` (collection 1), sole payee through its account.
    function _fedWork(address artist) internal returns (Work memory w) {
        w = _work(artist, 1);
    }

    /// @dev Adds `collaborator` as a party, paid `share` of 100,000 at its own address (a fixed
    ///      payee: a collaborator without an identity has no payout address to resolve).
    function _withFedCollaborator(Work memory w, address collaborator, uint32 share)
        internal
        pure
        returns (Work memory)
    {
        Party[] memory parties = new Party[](2);
        parties[0] = w.item.parties[0];
        parties[1] = Party(collaborator, uint8(PartyRole.COLLABORATOR));
        w.item.parties = parties;
        ISplitWallet.Payee[] memory payees = new ISplitWallet.Payee[](2);
        // Canonical order: the fixed payee (artist ID zero) first.
        payees[0] = ISplitWallet.Payee(0, collaborator, share);
        payees[1] =
            ISplitWallet.Payee(uint256(uint160(parties[0].account)), address(0), 100_000 - share);
        w.item.payees = payees;
        return w;
    }

    function _itemHash(Work memory w) internal pure returns (bytes32) {
        return WorksHashing.itemHash(w.item);
    }

    /// @dev `artist` approves `w` for `token` at `rate`.
    function _approveFed(address token, address artist, Work memory w, uint24 rate) internal {
        vm.prank(artist);
        federation.approveItem(token, _itemHash(w), rate);
    }

    /// @dev `party`'s consent to `w` at `rate` for `token` (`Core.federatedConsent`).
    function _fedConsent(address party, address token, Work memory w, uint24 rate)
        internal
        view
        returns (bytes memory)
    {
        bytes32 what = Core.federatedConsent(_itemHash(w), rate);
        return abi.encodePacked(party, _sign(party, accounts.consentDigest(token, what)));
    }

    function _fedRequest(Work memory w, bytes[] memory consents)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(IFederatedStream.FederatedMint(w.item, w.media, consents));
    }

    /// @dev Starts `w` (approved, no collaborator) on `token` through the English auction.
    function _fedStart(address token, Work memory w)
        internal
        returns (uint256 saleId, uint256 tokenId)
    {
        saleId = auction.start(token, _fedRequest(w, new bytes[](0)));
        tokenId = FederatedStream(token).totalMinted();
        assertEq(saleId, auction.saleIdOf(token, tokenId), "sale ID");
    }

    /// @dev Approves and starts a new work of `artist` on `token`.
    function _fedApproveAndStart(address token, address artist)
        internal
        returns (Work memory w, uint256 saleId, uint256 tokenId)
    {
        w = _fedWork(artist);
        _approveFed(token, artist, w, FED_RATE);
        (saleId, tokenId) = _fedStart(token, w);
    }

    function _asArray(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    /// @dev Deploys a module from its build artifact with real constructor arguments, the way
    ///      `DeployCore` builds the genesis modules.
    function _deployArtifact(string memory artifact, bytes memory args)
        internal
        returns (address a)
    {
        bytes memory code = bytes.concat(vm.getCode(artifact), args);
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0) && a.code.length != 0, "module constructor reverted");
    }

    /// @dev A second English auction for 6529 Stream and federated tokens, its genesis
    ///      constructor arguments with `policy` as 6529 Stream's mint policy.
    function _newEnglishAuction(address policy) internal returns (address) {
        return _deployArtifact(
            "EnglishAuction.sol:EnglishAuction",
            bytes.concat(
                abi.encode(
                    address(manager),
                    address(stream),
                    address(directory),
                    address(economics),
                    address(escrow),
                    address(statements),
                    policy
                ),
                params.auctionConfig
            )
        );
    }

    /// @dev A second StreamTerms, the genesis constructor arguments.
    function _newStreamTerms() internal returns (address) {
        return _deployArtifact(
            "StreamTerms.sol:StreamTerms",
            abi.encode(
                address(manager),
                address(ledger),
                address(stream),
                address(editions),
                address(directory)
            )
        );
    }

    /// @dev A second Renderer, the genesis constructor arguments.
    function _newRenderer() internal returns (address) {
        return _deployArtifact(
            "Renderer.sol:Renderer", abi.encode(address(store), address(statements), 262_144)
        );
    }

    /// @dev A network call that reverts with `reason`, at the selector's role delay.
    function _governExpectRevert(address target, bytes memory data, bytes memory reason) internal {
        (bool immediate, uint32 delay) = manager.canCall(network, target, bytes4(data));
        if (!immediate) {
            vm.prank(network);
            manager.schedule(target, data, 0);
            vm.warp(block.timestamp + delay);
        }
        vm.prank(network);
        vm.expectRevert(reason);
        if (immediate) {
            (bool ok,) = target.call(data);
            ok;
        } else {
            manager.execute(target, data);
        }
    }
}
