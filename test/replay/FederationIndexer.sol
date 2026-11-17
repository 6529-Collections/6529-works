// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";

/// @notice Rebuilds the artist registry's permanent federation directory (ID-12, ID-13, FED-65)
///         and its accounts' created identities from the registry's own logs: each listed token's
///         artist, status and recorded network share, each account's delisting, the bound and
///         replaced dependencies, and every `ArtistRegistered` identity.
/// @dev Scope: the directory and identity creation only. The identity change events
///      (`ChangeStaged`, `ChangeExecuted`, `ChangeCancelled`, contests, freezes, nonces) are not
///      replayed by this lane; one in the history fails the replay as an unknown event.
contract DirectoryIndexer is ReplayIndexer {
    struct Listing {
        uint256 artistId;
        IArtistRegistry.FederationStatus status;
        uint32 feeShare;
        bytes32 codeHash;
        uint8 form;
        address partner;
    }

    address public authority;
    address public consolidationSource;
    bytes32 public consolidationSourceCodeHash;
    mapping(bytes32 name => address) public bound;
    address[] internal _tokens;
    mapping(address token => Listing) internal _listings;
    uint256[] internal _artistIds;
    mapping(uint256 artistId => ArtistIdentity) internal _identities;
    mapping(uint256 artistId => bool) internal _delisted;

    constructor(address artists_) ReplayIndexer(artists_) { }

    function listing(address token) external view returns (Listing memory) {
        return _listings[token];
    }

    /// @notice The status `federatedListing` reports: an account-wide delisting overrides ACTIVE.
    function effectiveStatus(address token) public view returns (IArtistRegistry.FederationStatus) {
        Listing storage l = _listings[token];
        if (l.status == IArtistRegistry.FederationStatus.ACTIVE && _delisted[l.artistId]) {
            return IArtistRegistry.FederationStatus.DELISTED;
        }
        return l.status;
    }

    function _apply(Vm.Log memory log) internal override {
        bytes32 sig = log.topics[0];
        if (sig == IArtistRegistry.FederatedContractListed.selector) {
            address token = _addr(log.topics[2]);
            Listing storage l = _listings[token];
            assertEq(uint8(l.status), 0, "indexer: listed twice");
            _tokens.push(token);
            l.artistId = uint256(log.topics[1]);
            l.status = IArtistRegistry.FederationStatus.ACTIVE;
            (l.codeHash, l.form, l.partner, l.feeShare,) =
                abi.decode(log.data, (bytes32, uint8, address, uint32, address));
        } else if (sig == IArtistRegistry.FederatedContractStatus.selector) {
            Listing storage l = _listings[_addr(log.topics[1])];
            (IArtistRegistry.FederationStatus previous, IArtistRegistry.FederationStatus status,) = abi.decode(
                log.data,
                (IArtistRegistry.FederationStatus, IArtistRegistry.FederationStatus, bytes32)
            );
            assertEq(uint8(previous), uint8(l.status), "indexer: previous status");
            assertEq(uint256(log.topics[2]), l.artistId, "indexer: status artist");
            l.status = status;
        } else if (sig == IArtistRegistry.FederationDelistedSet.selector) {
            uint256 artistId = uint256(log.topics[1]);
            (bool previous, bool delisted,) = abi.decode(log.data, (bool, bool, bytes32));
            assertEq(previous, _delisted[artistId], "indexer: previous delisting");
            _delisted[artistId] = delisted;
        } else if (sig == IArtistRegistry.FederatedFeeShareLowered.selector) {
            Listing storage l = _listings[_addr(log.topics[1])];
            (uint32 previous, uint32 share) = abi.decode(log.data, (uint32, uint32));
            assertEq(previous, l.feeShare, "indexer: previous share");
            l.feeShare = share;
        } else if (sig == IArtistRegistry.ArtistRegistered.selector) {
            uint256 artistId = uint256(log.topics[1]);
            _artistIds.push(artistId);
            _identities[artistId] = abi.decode(log.data, (ArtistIdentity));
        } else if (sig == IArtistRegistry.Bound.selector) {
            bound[log.topics[1]] = abi.decode(log.data, (address));
        } else if (
            sig == IArtistRegistry.FederationRegistrySet.selector
                || sig == IArtistRegistry.PackageRegistrySet.selector
        ) {
            (address previous, address next) = abi.decode(log.data, (address, address));
            bytes32 name = sig == IArtistRegistry.FederationRegistrySet.selector
                ? bytes32("FEDERATION_REGISTRY")
                : bytes32("PACKAGE_REGISTRY");
            assertEq(previous, bound[name], "indexer: replaced dependency");
            bound[name] = next;
        } else if (sig == IArtistRegistry.ConsolidationSourceSet.selector) {
            (, consolidationSource, consolidationSourceCodeHash) =
                abi.decode(log.data, (address, address, bytes32));
        } else if (sig == IAccessManaged.AuthorityUpdated.selector) {
            authority = abi.decode(log.data, (address));
        } else {
            _unknown(sig);
        }
    }

    function assertMatches() external view override {
        IArtistRegistry a = IArtistRegistry(target);
        assertEq(IAccessManaged(target).authority(), authority, "authority");
        assertEq(a.federationRegistry(), bound["FEDERATION_REGISTRY"], "federationRegistry");
        assertEq(a.packageRegistry(), bound["PACKAGE_REGISTRY"], "packageRegistry");
        assertEq(a.stream(), bound["STREAM"], "stream");
        assertEq(a.splitFactory(), bound["SPLIT_FACTORY"], "splitFactory");
        assertEq(a.statementLog(), bound["STATEMENT_LOG"], "statementLog");
        assertEq(address(a.consolidationSource()), consolidationSource, "consolidationSource");
        assertEq(a.consolidationSourceCodeHash(), consolidationSourceCodeHash, "source code hash");
        for (uint256 i; i < _artistIds.length; ++i) {
            uint256 id = _artistIds[i];
            ArtistIdentity memory model = _identities[id];
            (ArtistIdentity memory live,) = a.artist(id);
            assertEq(keccak256(abi.encode(live)), keccak256(abi.encode(model)), "artist identity");
            assertEq(a.artistIdOf(model.root), id, "artistIdOf");
            assertEq(a.isFederationDelisted(id), _delisted[id], "isFederationDelisted");
        }
        for (uint256 i; i < _tokens.length; ++i) {
            address token = _tokens[i];
            Listing storage l = _listings[token];
            (uint256 artistId, IArtistRegistry.FederationStatus status) = a.federatedListing(token);
            assertEq(artistId, l.artistId, "federatedListing artistId");
            assertEq(uint8(status), uint8(effectiveStatus(token)), "federatedListing status");
            assertEq(a.federatedFeeShare(token), l.feeShare, "federatedFeeShare");
        }
    }
}

/// @notice Rebuilds the federation registry from its own logs (FED-43 to FED-49, FED-64): each
///         template version's deployer, version, form and status, and each admitted adapter.
///         Its derived answers (`entry`, `isActive`, `canMint`) are checked against what the
///         registry's logs and the artist registry's directory logs give together.
contract FederationRegistryIndexer is ReplayIndexer {
    struct Template {
        uint32 version;
        IFederationRegistry.Form form;
        FederationRegistry.TemplateStatus status;
        address deployer;
    }

    DirectoryIndexer public immutable directory;
    address public authority;
    bytes32[] internal _codeHashes;
    mapping(bytes32 codeHash => Template) internal _templates;
    address[] internal _adapters;
    mapping(address adapter => bool) internal _knownAdapter;
    mapping(address adapter => bool) internal _admitted;
    address[] internal _registered;

    constructor(address registry_, DirectoryIndexer directory_) ReplayIndexer(registry_) {
        directory = directory_;
    }

    function _apply(Vm.Log memory log) internal override {
        bytes32 sig = log.topics[0];
        if (sig == FederationRegistry.TemplateSet.selector) {
            Template storage t = _templates[log.topics[1]];
            if (t.deployer == address(0)) _codeHashes.push(log.topics[1]);
            (t.deployer,, t.version, t.form, t.status) = abi.decode(
                log.data,
                (
                    address,
                    bytes32,
                    uint32,
                    IFederationRegistry.Form,
                    FederationRegistry.TemplateStatus
                )
            );
        } else if (sig == FederationRegistry.AdapterSet.selector) {
            address adapter = _addr(log.topics[1]);
            if (!_knownAdapter[adapter]) {
                _knownAdapter[adapter] = true;
                _adapters.push(adapter);
            }
            _admitted[adapter] = abi.decode(log.data, (bool));
        } else if (sig == IFederationRegistry.Registered.selector) {
            address token = _addr(log.topics[1]);
            (bytes32 codeHash, address deployer) = abi.decode(log.data, (bytes32, address));
            DirectoryIndexer.Listing memory l = directory.listing(token);
            // A listing is the token's own when the registry's Registered follows it with the
            // same facts (FED-65).
            assertEq(uint256(log.topics[2]), l.artistId, "indexer: registered artist");
            assertEq(codeHash, l.codeHash, "indexer: registered code hash");
            assertEq(deployer, _templates[codeHash].deployer, "indexer: registered deployer");
            _registered.push(token);
        } else if (sig == IAccessManaged.AuthorityUpdated.selector) {
            authority = abi.decode(log.data, (address));
        } else {
            _unknown(sig);
        }
    }

    function assertMatches() external view override {
        FederationRegistry r = FederationRegistry(target);
        assertEq(r.authority(), authority, "authority");
        for (uint256 i; i < _codeHashes.length; ++i) {
            FederationRegistry.Template memory live = r.templateOf(_codeHashes[i]);
            Template memory t = _templates[_codeHashes[i]];
            assertEq(live.version, t.version, "template version");
            assertEq(uint8(live.form), uint8(t.form), "template form");
            assertEq(uint8(live.status), uint8(t.status), "template status");
            assertEq(live.deployer, t.deployer, "template deployer");
        }
        for (uint256 i; i < _adapters.length; ++i) {
            assertEq(
                r.isAdmittedAdapter(_adapters[i]), _admitted[_adapters[i]], "isAdmittedAdapter"
            );
        }
        for (uint256 i; i < _registered.length; ++i) {
            _checkToken(r, _registered[i]);
        }
    }

    function _checkToken(FederationRegistry r, address token) private view {
        DirectoryIndexer.Listing memory l = directory.listing(token);
        Template memory t = _templates[l.codeHash];
        IArtistRegistry.FederationStatus status = directory.effectiveStatus(token);
        IFederationRegistry.Entry memory e = r.entry(token);
        assertEq(e.artistId, l.artistId, "entry artistId");
        assertEq(uint8(e.form), uint8(t.form), "entry form");
        assertEq(e.partner, l.partner, "entry partner");
        assertEq(e.templateVersion, t.version, "entry version");
        assertEq(e.codeHash, l.codeHash, "entry codeHash");
        // The recorded share only ever falls below the deployed one (R8), so it is the minimum.
        assertEq(e.feeShare, l.feeShare, "entry feeShare");
        assertEq(uint8(e.status), uint8(status), "entry status");
        bool active = status == IArtistRegistry.FederationStatus.ACTIVE;
        bool approved = t.status == FederationRegistry.TemplateStatus.APPROVED;
        assertEq(
            r.isActive(token),
            active && (approved || t.status == FederationRegistry.TemplateStatus.SUSPENDED),
            "isActive"
        );
        for (uint256 i; i < _adapters.length; ++i) {
            bool can = _admitted[_adapters[i]] && approved && active;
            if (can && t.form == IFederationRegistry.Form.ERC1155) {
                DirectoryIndexer.Listing memory p = directory.listing(l.partner);
                can = directory.effectiveStatus(l.partner)
                        == IArtistRegistry.FederationStatus.ACTIVE
                    && _templates[p.codeHash].status == FederationRegistry.TemplateStatus.APPROVED;
            }
            assertEq(r.canMint(token, _adapters[i]), can, "canMint");
        }
    }
}
