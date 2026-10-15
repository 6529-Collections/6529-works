// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { Role, Statement } from "src/interfaces/IStatementLog.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import {
    License,
    MoveAuthorization,
    PackageItem,
    Party,
    PartyAcceptance,
    PartyRole,
    SeedPolicy,
    StreamMintRequest
} from "src/interfaces/types/PackageTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { ContentAddresses } from "../../helpers/ContentAddresses.sol";
import { IntegrationBase } from "../IntegrationBase.sol";

/// @notice The handler of the Stream lifecycle invariant suite: one actor set driving 6529 Stream,
///         the package registry, the records satellite, the English auction and the artist
///         registry on the real stack deployed by `DeployV1` (`IntegrationBase`).
/// @dev The invariant test targets itself (it inherits this contract), so every action runs with
///      the integration helpers and no handler contract hits the EIP-170 limit. Every action is
///      bounded and never reverts (`fail_on_revert`): it finds a subject in the right state from
///      its seed, predicts the outcome from the protocol's rules, runs the call (inside
///      `try` when the prediction is a refusal) and records any disagreement in `violations`.
///
///      Actors: three artists (each with five works in one package, one of which copies another
///      artist's media), one collaborator credited on some works, three ETH bidders, the genesis
///      holders (curation signer, curator, platform, guardians, hot admin) and the keys that
///      recoveries install. Packages are built in `setUp`; artist 0's is approved and accepted
///      there, the others by the `register` and `accept` actions.
abstract contract StreamLifecycleHandler is IntegrationBase {
    uint256 internal constant ARTISTS = 3;
    uint256 internal constant WORKS_PER_ARTIST = 5;
    uint256 internal constant BIDDERS = 3;
    uint256 internal constant SPARE_RECORDS = 3;
    /// @dev Locators each side may add per file (`WorkRecords.LOCATOR_QUOTA`), and both together.
    uint256 internal constant SIDE_QUOTA = 8;
    uint256 internal constant FILE_QUOTA = 16;

    /// @dev One approved-to-be package item, with what a start and `openRecord` need.
    struct PoolItem {
        bytes32 root;
        uint256 lead;
        bool collaborator;
        bytes32 itemHash;
        bytes32 contentHash;
        bytes32 mediaHash;
        bytes32 fileId;
        bool cc0;
        uint256 tokenId;
        bytes item;
        bytes media;
        bytes32[] proof;
    }

    /// @dev What the handler expects of one token ID.
    struct TokenGhost {
        uint256 item;
        uint256 saleId;
        address owner;
        bool burned;
        bool released;
        bool pauseUsed;
        bool opened;
        bool finalized;
        bool cc0;
        bytes32 recordFileId;
        bytes32 mediaDigest;
        uint8 artistLocators;
        uint8 platformLocators;
    }

    /// @dev A start's subject and its predicted outcome.
    struct StartCase {
        uint256 leadId;
        uint256 nonce;
        bool restrained;
        bool revoked;
        bool reserved;
        bool expected;
    }

    address[ARTISTS] internal lcArtists;
    address internal lcCollaborator;
    address[BIDDERS] internal lcBidders;
    /// @dev Every account that can hold a Stream token: actors, recovered keys and the auction.
    address[] internal holders;
    bytes32[] internal roots;
    PoolItem[] internal pool;
    bytes32[ARTISTS] internal packageOf;
    bytes32[] internal spareRecords;
    bytes32 internal byTextFileId;
    bytes32 internal mitTextFileId;
    bytes32 internal altCc0TextFileId;
    /// @dev The artist whose work a copied content hash belongs to.
    mapping(bytes32 contentHash => address) internal rightfulOf;

    mapping(uint256 tokenId => TokenGhost) internal tok;
    mapping(uint256 tokenId => Locator[]) internal ghostLocators;
    uint256 internal ghostMinted;
    uint256 internal ghostBurned;
    /// @dev ETH bid into the auction and paid out of it at settlement.
    uint256 internal ghostEthIn;
    uint256 internal ghostEthOut;
    /// @dev The key a pending recovery override would install, by artist ID.
    mapping(uint256 artistId => address) internal reservedKey;
    uint256 internal recoveries;
    bool internal recoveryPending;
    uint256 internal locatorNonce;
    /// @dev Every disagreement between an action's prediction and the protocol.
    string[] internal violations;
    /// @dev How often each path really ran (successes, and refusals of negative attempts).
    mapping(bytes32 path => uint256) public hits;

    function setUp() public virtual override {
        super.setUp();
        for (uint256 i; i < ARTISTS; ++i) {
            lcArtists[i] = _actor(string.concat("lifecycleArtist", vm.toString(i)));
            holders.push(lcArtists[i]);
        }
        lcCollaborator = _actor("lifecycleCollaborator");
        holders.push(lcCollaborator);
        for (uint256 i; i < BIDDERS; ++i) {
            lcBidders[i] = makeAddr(string.concat("lifecycleBidder", vm.toString(i)));
            holders.push(lcBidders[i]);
        }
        holders.push(address(auction));
        byTextFileId = _storeText("Creative Commons Attribution 4.0 (fixture)", "text/plain");
        mitTextFileId = _storeText("MIT License (fixture)", "text/plain");
        altCc0TextFileId = _storeText("CC0 1.0 Universal (another copy)", "text/plain");
        for (uint256 i; i < SPARE_RECORDS; ++i) {
            spareRecords.push(_record(string.concat("Spare record ", vm.toString(i))));
        }
        Work[][] memory packages = new Work[][](ARTISTS);
        for (uint256 i; i < ARTISTS; ++i) {
            packages[i] = _artistWorks(i);
        }
        // Work 4 of each artist copies work 0 of the artist before it (cyclically): same media,
        // same content hash, another record and item.
        for (uint256 i; i < ARTISTS; ++i) {
            Work memory original = packages[(i + ARTISTS - 1) % ARTISTS][0];
            Work memory copy = packages[i][4];
            copy.media = original.media;
            copy.item.contentHash = original.item.contentHash;
            copy.item.mediaHash = original.item.mediaHash;
            rightfulOf[original.item.contentHash] = lcArtists[(i + ARTISTS - 1) % ARTISTS];
        }
        for (uint256 i; i < ARTISTS; ++i) {
            _addPackage(i, packages[i]);
        }
        // Artist 0's package is approved and accepted at genesis; the others go through the
        // `register` and `accept` actions.
        _approve(packageOf[0]);
        _accept(packageOf[0], lcArtists[0]);
        _accept(packageOf[0], lcCollaborator);
    }

    // ------------------------------------------------------------------ setup helpers

    /// @dev Five works by artist `i`: CC0; CC-BY with the collaborator; an ARTIST seed; CC0 with
    ///      the collaborator; and a CC0 work whose media `setUp` replaces with a copy.
    function _artistWorks(uint256 i) internal returns (Work[] memory works) {
        address lead = lcArtists[i];
        works = new Work[](WORKS_PER_ARTIST);
        for (uint256 j; j < WORKS_PER_ARTIST; ++j) {
            works[j] = _work(lead, collectionId);
        }
        _withCollaborator(works[1].item, lead);
        works[1].item.license = License("CC-BY-4.0", byTextFileId);
        works[2].item.seedPolicy = SeedPolicy.ARTIST;
        works[2].item.seed = keccak256(abi.encode("artist seed", i));
        _withCollaborator(works[3].item, lead);
    }

    /// @dev Adds the collaborator as a second party paid 30% as an artist-resolved payee, with
    ///      the payees in canonical (ascending artist ID) order.
    function _withCollaborator(PackageItem memory item, address lead) internal view {
        item.parties = new Party[](2);
        item.parties[0] = Party(lead, PartyRole.ARTIST);
        item.parties[1] = Party(lcCollaborator, PartyRole.COLLABORATOR);
        ISplitWallet.Payee memory a = ISplitWallet.Payee(uint160(lead), address(0), 70_000);
        ISplitWallet.Payee memory b =
            ISplitWallet.Payee(uint160(lcCollaborator), address(0), 30_000);
        item.payees = new ISplitWallet.Payee[](2);
        (item.payees[0], item.payees[1]) = uint160(lead) < uint160(lcCollaborator) ? (a, b) : (b, a);
    }

    function _addPackage(uint256 lead, Work[] memory works) internal {
        bytes32 root = _rootOf(works);
        roots.push(root);
        packageOf[lead] = root;
        for (uint256 j; j < works.length; ++j) {
            PoolItem storage p = pool.push();
            p.root = root;
            p.lead = lead;
            p.collaborator = works[j].item.parties.length == 2;
            p.itemHash = WorksHashing.itemHash(works[j].item);
            p.contentHash = works[j].item.contentHash;
            p.mediaHash = works[j].item.mediaHash;
            p.fileId = works[j].media[0].fileId;
            p.cc0 = works[j].item.license.textFileId == cc0TextFileId;
            p.item = abi.encode(works[j].item);
            p.media = abi.encode(works[j].media);
            p.proof = _proofOf(works, j);
        }
    }

    // ------------------------------------------------------------------ actions: curation

    /// @notice The curation signer attests a package and anyone registers it (with the
    ///         curator's evidence statement). Once every package is registered, a second
    ///         registration of one must be refused.
    function register(uint256 seed) external {
        for (uint256 k; k < roots.length; ++k) {
            bytes32 root = roots[(seed % roots.length + k) % roots.length];
            if (_status(root) != IPackageRegistry.PackageStatus.NONE) continue;
            _approve(root);
            ++hits["register"];
            return;
        }
        bytes32 again = roots[seed % roots.length];
        bytes32 evidence = _evidence(again);
        bytes memory signature = _sign(
            signer1, verifier.approvalDigest(again, evidence, verifier.signerEpoch(signer1))
        );
        try registry.registerPackage(again, evidence, abi.encode(signer1, signature)) {
            _violation("a package registered twice");
        } catch {
            ++hits["registerRefused"];
        }
    }

    /// @notice A party of a registered package accepts it, signed by itself (first acceptance)
    ///         or its active authority. A restrained artist's acceptance must be refused.
    function accept(uint256 seed, uint256 partySeed) external {
        for (uint256 k; k < roots.length; ++k) {
            uint256 lead = (seed % ARTISTS + k) % ARTISTS;
            bytes32 root = packageOf[lead];
            if (_status(root) != IPackageRegistry.PackageStatus.APPROVED) continue;
            address[2] memory parties = [lcArtists[lead], lcCollaborator];
            for (uint256 j; j < 2; ++j) {
                address account = parties[(partySeed % 2 + j) % 2];
                if (registry.acceptedAs(root, account) != 0) continue;
                uint256 id = artists.artistIdOf(account);
                if (id != 0 && _restrained(id)) {
                    _restrainedAcceptance(root, account, artists.authorityOf(id));
                    return;
                }
                _accept(root, account);
                ++hits["accept"];
                return;
            }
        }
    }

    // ------------------------------------------------------------------ actions: the auction

    /// @notice Moves an approved, accepted item to Stream: the lead's active authority signs the
    ///         move and anyone starts the auction (a third of the time with a first bid).
    ///         Refusals are predicted: a content hash a live work holds, a burned item, a release
    ///         reserving the content for another artist, a restrained lead, or a revoked move.
    function start(uint256 seed, uint256 bidSeed) external {
        (bool found, uint256 p) = _startable(seed);
        if (!found) {
            _startConsumed(seed);
            return;
        }
        StartCase memory c = _startCase(p, bidSeed);
        bytes memory data = _mintRequest(p, artists.authorityOf(c.leadId), c.nonce);
        (bool ok, uint256 saleId, uint256 paid) = _startAuction(data, bidSeed);
        if (ok != c.expected) {
            _violation(ok ? "a start succeeded that the rules refuse" : "a valid start failed");
        }
        if (!ok) {
            if (c.restrained) ++hits["restrained"];
            else if (c.revoked) ++hits["revokedMove"];
            else if (c.reserved) ++hits["reserved"];
            else ++hits["contentUsed"];
            return;
        }
        if (c.reserved) ++hits["reconsume"];
        _minted(p, saleId, paid);
    }

    /// @notice A bidder outbids the high bid of a live auction in ETH.
    function bid(uint256 seed, uint256 bidderSeed, uint256 amountSeed) external {
        (bool found, uint256 tokenId) = _sale(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found) return;
        uint256 saleId = tok[tokenId].saleId;
        uint256 minimum = auction.minimumBid(saleId);
        uint256 amount = _bound(amountSeed, minimum, minimum + 3 ether);
        _ethBid(saleId, lcBidders[bidderSeed % BIDDERS], amount);
        ghostEthIn += amount;
        ++hits["bid"];
    }

    /// @notice Settles an ended auction (a quarter of the time, warping to the end of a live one
    ///         when none has ended):
    ///         the winner receives the work, or the artist's active authority when nobody bid.
    ///         A no-bid settlement while the artist is restrained must wait (revert).
    function settle(uint256 seed) external {
        (bool found, uint256 tokenId) = _sale(seed, IEnglishAuction.AuctionState.ENDED);
        if (!found) {
            if (seed % 4 != 0) return;
            (found, tokenId) = _sale(seed, IEnglishAuction.AuctionState.ACTIVE);
            if (!found) return;
            vm.warp(auction.auction(tok[tokenId].saleId).endTime);
        }
        TokenGhost storage t = tok[tokenId];
        IEnglishAuction.Auction memory a = auction.auction(t.saleId);
        address creator = artists.activeAuthorityOf(stream.artistOf(tokenId));
        try auction.settle(t.saleId) {
            if (a.bidder == address(0) && creator == address(0)) {
                _violation("a no-bid auction settled to a restrained artist");
            }
            t.owner = a.bidder != address(0) ? a.recipient : creator;
            ghostEthOut += a.bidder != address(0) ? a.bid : 0;
            ++hits["settle"];
        } catch {
            if (a.bidder != address(0) || creator != address(0)) {
                _violation("a settlement failed");
            }
            ++hits["restrainedWait"];
        }
    }

    /// @notice The guardian pauses a live auction for a dispute, a copied work's first; a
    ///         second pause of the same auction must be refused.
    function disputePause(uint256 seed) external {
        (bool found, uint256 tokenId) = _copyOnSale(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found) (found, tokenId) = _sale(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        bytes32 ref = keccak256(abi.encode("lifecycle dispute", tokenId));
        if (t.pauseUsed) {
            vm.prank(guardian1);
            try auction.pause(t.saleId, ref) {
                _violation("an auction was paused twice");
            } catch {
                ++hits["pauseExhausted"];
            }
            return;
        }
        vm.prank(guardian1);
        auction.pause(t.saleId, ref);
        t.pauseUsed = true;
        ++hits["disputePause"];
    }

    /// @notice Decides a paused auction's dispute: upheld for a copied work, rejected for an
    ///         original. Upheld: PLATFORM records the outcome and the governed 48-hour `cancel`
    ///         refunds the bid and burns the work. Rejected: the high bidder may withdraw, and
    ///         the governed `resume` restarts the clock.
    function resolveDispute(uint256 seed, uint256 mode) external {
        (bool found, uint256 tokenId) = _copyOnSale(seed, IEnglishAuction.AuctionState.PAUSED);
        if (!found) (found, tokenId) = _sale(seed, IEnglishAuction.AuctionState.PAUSED);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        IEnglishAuction.Auction memory a = auction.auction(t.saleId);
        // A governed decision lands 48 hours after scheduling; past the 7-day allowance the
        // pause lapses by itself instead.
        if (block.timestamp + Roles.STANDARD > a.pausedAt + auction.MAX_PAUSE()) return;
        if (_isCopy(t.item)) {
            bytes32 outcome = _platformStatement(
                address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://lifecycle-outcome"
            );
            _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (t.saleId, outcome)));
            t.burned = true;
            t.owner = address(0);
            ++ghostBurned;
            ++hits["cancel"];
            return;
        }
        if (a.bidder != address(0) && mode % 2 == 1) {
            vm.prank(a.bidder);
            auction.withdrawBid(t.saleId);
            ++hits["withdraw"];
        }
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.resume, (t.saleId)));
        ++hits["resume"];
    }

    /// @notice The governed 48-hour `releaseContent` of a burned work's content hash to the
    ///         rightful artist: a copy's original artist once registered, else any registered
    ///         artist.
    function releaseContent(uint256 seed, uint256 beneficiarySeed) external {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            TokenGhost storage t = tok[tokenId];
            if (!t.burned || t.released) continue;
            bytes32 contentHash = pool[t.item].contentHash;
            uint256 beneficiary = _beneficiary(contentHash, beneficiarySeed);
            if (beneficiary == 0) continue;
            _govern(
                hotAdmin,
                address(stream),
                abi.encodeCall(stream.releaseContent, (tokenId, contentHash, beneficiary))
            );
            t.released = true;
            ++hits["release"];
            return;
        }
    }

    /// @notice The current owner of a delivered work transfers it to another holder.
    function transfer(uint256 seed, uint256 toSeed) external {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            TokenGhost storage t = tok[tokenId];
            if (t.burned || t.owner == address(auction)) continue;
            address to = holders[toSeed % holders.length];
            if (to == address(auction) || to == t.owner) to = lcBidders[toSeed % BIDDERS];
            if (to == t.owner) to = lcBidders[(toSeed % BIDDERS + 1) % BIDDERS];
            vm.prank(t.owner);
            stream.transferFrom(t.owner, to, tokenId);
            t.owner = to;
            ++hits["transfer"];
            return;
        }
    }

    /// @notice Time passes: a minute to twelve hours (an auction runs a day).
    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + _bound(secondsSeed, 1 minutes, 12 hours));
        ++hits["warp"];
    }

    // ------------------------------------------------------------------ actions: records

    /// @notice Anyone opens a minted work's record from its approved item and media.
    function openRecord(uint256 seed) external {
        (bool found, uint256 tokenId) = _token(seed, false, false);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        PoolItem storage it = pool[t.item];
        vm.prank(lcBidders[seed % BIDDERS]);
        records.openRecord(
            tokenId, abi.decode(it.item, (PackageItem)), abi.decode(it.media, (MediaFile[]))
        );
        t.opened = true;
        t.cc0 = it.cc0;
        t.mediaDigest = keccak256(abi.encode(records.mediaOf(tokenId)));
        ++hits["openRecord"];
    }

    /// @notice The artist points an open, unfinalized record at another record file.
    function setRecord(uint256 seed, uint256 fileSeed) external {
        (bool found, uint256 tokenId) = _token(seed, true, true);
        if (!found) return;
        address artist = artists.activeAuthorityOf(stream.artistOf(tokenId));
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.setRecord(tokenId, spareRecords[fileSeed % SPARE_RECORDS], state);
        ++hits["setRecord"];
    }

    /// @notice The artist finalizes an open record, pinning the renderer.
    function finalize(uint256 seed) external {
        (bool found, uint256 tokenId) = _token(seed, true, true);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        address artist = artists.activeAuthorityOf(stream.artistOf(tokenId));
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        t.finalized = true;
        t.recordFileId = records.record(tokenId).recordFileId;
        ++hits["finalize"];
    }

    /// @notice The artist (before finalize) or the platform adds an Arweave or IPFS locator to a
    ///         work's primary file. The quotas and the URI rule are predicted; a URI with a path
    ///         must be refused.
    function addLocator(uint256 seed, uint256 kindSeed) external {
        (bool found, uint256 tokenId) = _token(seed, true, false);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        address artist = artists.activeAuthorityOf(stream.artistOf(tokenId));
        bool byArtist = !t.finalized && artist != address(0) && kindSeed % 2 == 0;
        Locator memory locator = _newLocator(kindSeed >> 1);
        bool malformed = kindSeed % 7 == 0;
        if (malformed) locator.uri = string.concat(locator.uri, "/index.html");
        bool room = byArtist
            ? t.artistLocators < SIDE_QUOTA
            : t.finalized
                ? uint256(t.platformLocators) + t.artistLocators < FILE_QUOTA
                : t.platformLocators < SIDE_QUOTA;
        vm.prank(byArtist ? artist : platform);
        try records.addLocator(tokenId, pool[t.item].fileId, locator) {
            if (malformed || !room) _violation("a locator past its quota or rule was added");
            ghostLocators[tokenId].push(locator);
            if (byArtist) ++t.artistLocators;
            else ++t.platformLocators;
            ++hits["addLocator"];
        } catch {
            if (!malformed && room) _violation("a valid locator was refused");
            ++hits["locatorRefused"];
        }
    }

    /// @notice A governed 48-hour relicense with every party's consent. A CC0 work must stay
    ///         CC0 with the pinned text (both moves refused); another license moves to CC0 or
    ///         MIT, unless a party is restrained and so cannot consent.
    function relicense(uint256 seed, uint256 choice) external {
        (bool found, uint256 tokenId) = _token(seed, true, false);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        License memory current = records.licenseOf(tokenId);
        License memory next = t.cc0
            ? (choice % 2 == 0
                    ? License("CC-BY-4.0", byTextFileId)
                    : License("CC0-1.0", altCc0TextFileId))
            : (choice % 2 == 0 ? License("CC0-1.0", cc0TextFileId) : License("MIT", mitTextFileId));
        bool same = WorksHashing.licenseKey(current.spdxId) == WorksHashing.licenseKey(next.spdxId)
            && current.textFileId == next.textFileId;
        (bytes memory call, bool restrainedParty) = _relicenseCall(tokenId, next);
        bool expected = same || (!t.cc0 && !restrainedParty);
        bool ok = _governTry(hotAdmin, address(records), call);
        if (ok != expected) {
            _violation(ok ? "a refused relicense applied" : "a valid relicense failed");
        }
        if (!ok) {
            ++hits[t.cc0 ? bytes32("cc0Held") : bytes32("restrained")];
            return;
        }
        if (!same) t.cc0 = WorksHashing.licenseKey(next.spdxId) == WorksHashing.CC0_LICENSE_KEY;
        ++hits["relicense"];
    }

    // ------------------------------------------------------------------ actions: identity

    /// @notice Governance stages a CONTESTED recovery override (48 hours) moving an artist's
    ///         authority to a fresh key: from then until it ends, nobody acts as the artist
    ///         (IDENTITY-1).
    function stageRecovery(uint256 seed) external {
        // Recoveries are rare: at most one is pending at a time.
        if (recoveryPending) return;
        for (uint256 k; k < ARTISTS; ++k) {
            address account = lcArtists[(seed % ARTISTS + k) % ARTISTS];
            uint256 id = uint160(account);
            if (artists.artistIdOf(account) == 0) continue;
            if (artists.pendingChange(id).kind != ChangeKind.NONE) continue;
            address next = _actor(string.concat("lifecycleRecovered", vm.toString(++recoveries)));
            holders.push(next);
            ArtistIdentity memory identity =
                ArtistIdentity(next, next, _profileId(account), _profileDoc(account));
            bytes32 evidence = keccak256(abi.encode("lifecycle recovery evidence", recoveries));
            uint64 deadline = uint64(block.timestamp + 7 days);
            bytes memory acceptance = _sign(
                next, artists.overrideDigest(id, ChangeKind.CONTESTED, identity, evidence, deadline)
            );
            _govern(
                hotAdmin,
                address(artists),
                abi.encodeCall(
                    artists.stageOverride,
                    (id, ChangeKind.CONTESTED, identity, evidence, deadline, acceptance)
                )
            );
            reservedKey[id] = next;
            recoveryPending = true;
            ++hits["stageRecovery"];
            return;
        }
    }

    /// @notice A pending recovery ends: the guardian vetoes it, or it executes after its
    ///         180-day notice and the new key becomes the artist's authority.
    function endRecovery(uint256 seed, uint256 mode) external {
        for (uint256 k; k < ARTISTS; ++k) {
            uint256 id = uint160(lcArtists[(seed % ARTISTS + k) % ARTISTS]);
            if (reservedKey[id] == address(0)) continue;
            if (mode % 2 == 0) {
                vm.prank(guardian2);
                artists.vetoChange(id);
                ++hits["veto"];
            } else {
                PendingChange memory p = artists.pendingChange(id);
                if (block.timestamp < p.executableAt) vm.warp(p.executableAt);
                artists.executeChange(id);
                if (artists.authorityOf(id) != reservedKey[id]) {
                    _violation("an executed recovery did not install its key");
                }
                ++hits["recovered"];
            }
            reservedKey[id] = address(0);
            recoveryPending = false;
            return;
        }
    }

    /// @notice While a recovery is pending, the key being recovered from or the reserved new key
    ///         tries to act as the artist: start a work, change or finalize a record, add an
    ///         artist locator, append an ARTIST statement, accept a package or revoke a move.
    ///         Every attempt must be refused.
    function restrainedAct(uint256 seed, uint256 which) external {
        for (uint256 k; k < ARTISTS; ++k) {
            uint256 lead = (seed % ARTISTS + k) % ARTISTS;
            uint256 id = uint160(lcArtists[lead]);
            if (reservedKey[id] == address(0) || !_restrained(id)) continue;
            address actor = which % 2 == 0 ? artists.authorityOf(id) : reservedKey[id];
            if (_actAsArtist(lead, id, actor, (which >> 1) % 6, seed)) {
                _violation("a restrained artist acted");
            }
            ++hits["restrained"];
            return;
        }
    }

    // ------------------------------------------------------------------ internals

    function _status(bytes32 root) internal view returns (IPackageRegistry.PackageStatus status) {
        (status,,) = registry.packageOf(root);
    }

    /// @dev Restrained: registered, with a pending override that moves the authority, so the
    ///      registry reports no active authority (IDENTITY-1).
    function _restrained(uint256 artistId) internal view returns (bool) {
        return
            reservedKey[artistId] != address(0) && artists.activeAuthorityOf(artistId) == address(0);
    }

    function _violation(string memory what) internal {
        violations.push(what);
    }

    /// @dev The first item, from `seed`, that is not minted and whose package is approved and
    ///      accepted by every party it names. An item whose released content is reserved for its
    ///      own lead comes first: the rightful artist mints once a copy's content is released.
    function _startable(uint256 seed) internal view returns (bool, uint256) {
        for (uint256 pass; pass < 2; ++pass) {
            for (uint256 k; k < pool.length; ++k) {
                uint256 p = (seed % pool.length + k) % pool.length;
                if (!_ready(p)) continue;
                if (pass == 1) return (true, p);
                PoolItem storage it = pool[p];
                if (
                    registry.consumedItemOf(it.contentHash) == 0
                        && registry.releasedTo(it.contentHash) == uint160(lcArtists[it.lead])
                ) return (true, p);
            }
        }
        return (false, 0);
    }

    /// @dev Item `p` is not minted, and its package is approved and accepted by its parties.
    function _ready(uint256 p) internal view returns (bool) {
        PoolItem storage it = pool[p];
        return it.tokenId == 0 && _status(it.root) == IPackageRegistry.PackageStatus.APPROVED
            && registry.acceptedAs(it.root, lcArtists[it.lead]) != 0
            && (!it.collaborator || registry.acceptedAs(it.root, lcCollaborator) != 0);
    }

    /// @dev Predicts a start of item `p`: refused when a work holds its content hash, the item
    ///      was burned and released (tombstoned), a release reserves the content for another
    ///      artist, the lead is restrained, or (one time in seven) the lead revoked the move's
    ///      nonce first.
    function _startCase(uint256 p, uint256 bidSeed) internal returns (StartCase memory c) {
        PoolItem storage it = pool[p];
        c.leadId = uint160(lcArtists[it.lead]);
        bytes32 prior = registry.consumedItemOf(it.contentHash);
        uint256 reservedFor = registry.releasedTo(it.contentHash);
        c.reserved = prior == 0 && reservedFor != 0;
        c.restrained = _restrained(c.leadId);
        c.revoked = !c.restrained && bidSeed % 7 == 1;
        c.nonce = nextMoveNonce[c.leadId]++;
        if (c.revoked) {
            vm.prank(artists.activeAuthorityOf(c.leadId));
            registry.revokeMove(c.leadId, c.nonce);
        }
        c.expected = prior == 0 && !registry.isReleased(it.itemHash)
            && (!c.reserved || reservedFor == c.leadId) && !c.restrained && !c.revoked;
    }

    /// @dev With nothing left to start, a minted item is moved again: refused, whether its work
    ///      is live, burned or released (an item is single-use and a burned one is tombstoned).
    function _startConsumed(uint256 seed) internal {
        PoolItem storage it = pool[seed % pool.length];
        if (it.tokenId == 0) return;
        uint256 leadId = uint160(lcArtists[it.lead]);
        address signer = artists.authorityOf(leadId);
        bytes memory data = _mintRequest(seed % pool.length, signer, nextMoveNonce[leadId]++);
        try auction.start(address(stream), data) {
            _violation("an item was consumed twice");
        } catch {
            ++hits["contentUsed"];
        }
    }

    function _mintRequest(uint256 p, address signer, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        PoolItem storage it = pool[p];
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = registry.moveDigest(it.root, it.itemHash, nonce, deadline);
        MoveAuthorization memory move = MoveAuthorization(nonce, deadline, _sign(signer, digest));
        return abi.encode(
            StreamMintRequest(it.root, abi.decode(it.item, (PackageItem)), it.proof, move)
        );
    }

    /// @dev `start`, or a third of the time `startWithBid` with a first ETH bid; never reverts.
    function _startAuction(bytes memory data, uint256 bidSeed)
        internal
        returns (bool ok, uint256 saleId, uint256 paid)
    {
        if (bidSeed % 3 != 0) {
            try auction.start(address(stream), data) returns (uint256 id) {
                return (true, id, 0);
            } catch {
                return (false, 0, 0);
            }
        }
        address bidder = lcBidders[(bidSeed >> 8) % BIDDERS];
        paid = _bound(bidSeed >> 16, 1, 2 ether);
        vm.deal(bidder, bidder.balance + paid);
        vm.prank(bidder);
        try auction.startWithBid{ value: paid }(
            address(stream), data, address(0), Payment(PaymentMethod.DIRECT, bidder, paid, 0, 0, "")
        ) returns (
            uint256 id
        ) {
            return (true, id, paid);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Records a new token: IDs are assigned in order, once.
    function _minted(uint256 p, uint256 saleId, uint256 paid) internal {
        uint256 tokenId = stream.totalMinted();
        if (tokenId != ghostMinted + 1) _violation("token IDs are not sequential");
        ghostMinted = tokenId;
        pool[p].tokenId = tokenId;
        TokenGhost storage t = tok[tokenId];
        t.item = p;
        t.saleId = saleId;
        t.owner = address(auction);
        ghostEthIn += paid;
        ++hits["start"];
    }

    /// @dev The first token, from `seed`, whose sale is in `state`.
    function _sale(uint256 seed, IEnglishAuction.AuctionState state)
        internal
        view
        returns (bool, uint256)
    {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            if (tok[tokenId].burned) continue;
            if (auction.auction(tok[tokenId].saleId).state == state) return (true, tokenId);
        }
        return (false, 0);
    }

    /// @dev Whether pool item `p` copies another artist's media.
    function _isCopy(uint256 p) internal view returns (bool) {
        address rightful = rightfulOf[pool[p].contentHash];
        return rightful != address(0) && rightful != lcArtists[pool[p].lead];
    }

    /// @dev The first token, from `seed`, of a copied work whose sale is in `state`.
    function _copyOnSale(uint256 seed, IEnglishAuction.AuctionState state)
        internal
        view
        returns (bool, uint256)
    {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            if (tok[tokenId].burned || !_isCopy(tok[tokenId].item)) continue;
            if (auction.auction(tok[tokenId].saleId).state == state) return (true, tokenId);
        }
        return (false, 0);
    }

    /// @dev The first live token, from `seed`, whose record is open (or not, when `open` is
    ///      false); with `amendable`, also unfinalized and with an active artist.
    function _token(uint256 seed, bool open, bool amendable) internal view returns (bool, uint256) {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            TokenGhost storage t = tok[tokenId];
            if (t.burned || t.opened != open) continue;
            if (amendable) {
                if (t.finalized) continue;
                if (artists.activeAuthorityOf(stream.artistOf(tokenId)) == address(0)) continue;
            }
            return (true, tokenId);
        }
        return (false, 0);
    }

    /// @dev The rightful artist of a copied content hash, once registered (the release waits
    ///      for the rightful artist's identity); for any other content, a registered artist from
    ///      `seed`. Zero when the release must wait.
    function _beneficiary(bytes32 contentHash, uint256 seed) internal view returns (uint256) {
        address rightful = rightfulOf[contentHash];
        if (rightful != address(0)) {
            return artists.artistIdOf(rightful) != 0 ? uint160(rightful) : 0;
        }
        for (uint256 k; k < ARTISTS; ++k) {
            address account = lcArtists[(seed % ARTISTS + k) % ARTISTS];
            if (artists.artistIdOf(account) != 0) return uint160(account);
        }
        return 0;
    }

    function _newLocator(uint256 kind) internal returns (Locator memory) {
        string memory seed = string.concat("lifecycle locator ", vm.toString(++locatorNonce));
        if (kind % 3 == 0) return ContentAddresses.ar(seed);
        if (kind % 3 == 1) return ContentAddresses.ipfsLocator(seed);
        return Locator(LocatorKind.IPFS, ContentAddresses.ipfsRoot(seed));
    }

    /// @dev The relicense call with every party's consent, each signed by its active authority
    ///      or, for a restrained party, by the key being recovered from.
    function _relicenseCall(uint256 tokenId, License memory next)
        internal
        view
        returns (bytes memory call, bool restrainedParty)
    {
        PackageItem memory item = abi.decode(pool[tok[tokenId].item].item, (PackageItem));
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest = _typedDigest(
            address(records),
            keccak256(
                abi.encode(
                    Typehashes.RELICENSE,
                    tokenId,
                    WorksHashing.licenseKey(next.spdxId),
                    next.textFileId,
                    state,
                    deadline
                )
            )
        );
        bytes[] memory sigs = new bytes[](item.parties.length);
        for (uint256 i; i < sigs.length; ++i) {
            uint256 id = artists.artistIdOf(item.parties[i].account);
            address signer = artists.activeAuthorityOf(id);
            if (signer == address(0)) {
                restrainedParty = true;
                signer = artists.authorityOf(id);
            }
            sigs[i] = _sign(signer, digest);
        }
        call = abi.encodeCall(records.relicense, (tokenId, next, item, state, deadline, sigs));
    }

    /// @dev `_govern` that reports whether the governed call executed instead of reverting; a
    ///      failed operation is cancelled so the same call can be scheduled again.
    function _governTry(address caller, address target, bytes memory data)
        internal
        returns (bool ok)
    {
        (, uint32 delay) = manager.canCall(caller, target, bytes4(data));
        vm.prank(caller);
        manager.schedule(target, data, 0);
        vm.warp(block.timestamp + delay);
        vm.prank(caller);
        try manager.execute(target, data) {
            ok = true;
        } catch {
            vm.prank(caller);
            manager.cancel(caller, target, data);
        }
    }

    function _restrainedAcceptance(bytes32 root, address account, address signer) internal {
        PartyAcceptance memory a = PartyAcceptance(
            account, _profileId(account), _profileDoc(account), uint64(block.timestamp + 1 days)
        );
        bytes memory signature = _sign(signer, registry.acceptanceDigest(root, a));
        try registry.acceptPackage(root, a, signature) {
            _violation("a restrained artist accepted a package");
        } catch {
            ++hits["restrained"];
        }
    }

    /// @dev One artist power exercised by `actor` for artist `lead`; returns whether the
    ///      protocol let it through. Falls back to an ARTIST statement or a move revocation when
    ///      the chosen power has no subject.
    function _actAsArtist(uint256 lead, uint256 id, address actor, uint256 power, uint256 seed)
        internal
        returns (bool)
    {
        (bool found, uint256 tokenId) = _tokenOf(lead, seed);
        if (power == 0) {
            (bool startable, uint256 p) = _startableOf(lead, seed);
            if (startable) {
                bytes memory data = _mintRequest(p, actor, nextMoveNonce[id]++);
                try auction.start(address(stream), data) {
                    return true;
                } catch {
                    return false;
                }
            }
        } else if (power <= 3 && found && tok[tokenId].opened && !tok[tokenId].finalized) {
            return _amendAs(actor, tokenId, power);
        } else if (power == 5 && registry.acceptedAs(packageOf[lead], lcArtists[lead]) == 0) {
            if (_status(packageOf[lead]) == IPackageRegistry.PackageStatus.APPROVED) {
                PartyAcceptance memory a = PartyAcceptance(
                    lcArtists[lead],
                    _profileId(lcArtists[lead]),
                    _profileDoc(lcArtists[lead]),
                    uint64(block.timestamp + 1 days)
                );
                bytes memory signature = _sign(actor, registry.acceptanceDigest(packageOf[lead], a));
                try registry.acceptPackage(packageOf[lead], a, signature) {
                    return true;
                } catch {
                    return false;
                }
            }
        }
        if (found) {
            vm.prank(actor);
            try statements.append(Role.ARTIST, _artistStatement(tokenId)) {
                return true;
            } catch {
                return false;
            }
        }
        vm.prank(actor);
        try registry.revokeMove(id, type(uint128).max) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev `setRecord` (1), `finalize` (2) or an artist locator (3) on an open record.
    function _amendAs(address actor, uint256 tokenId, uint256 power) internal returns (bool) {
        bytes32 state = records.workStateHash(tokenId);
        bytes32 fileId = pool[tok[tokenId].item].fileId;
        Locator memory locator = _newLocator(0);
        bytes32 recordFile = spareRecords[tokenId % SPARE_RECORDS];
        vm.prank(actor);
        if (power == 1) {
            try records.setRecord(tokenId, recordFile, state) {
                return true;
            } catch {
                return false;
            }
        }
        if (power == 2) {
            try records.finalize(tokenId, state) {
                return true;
            } catch {
                return false;
            }
        }
        try records.addLocator(tokenId, fileId, locator) {
            return true;
        } catch {
            return false;
        }
    }

    function _tokenOf(uint256 lead, uint256 seed) internal view returns (bool, uint256) {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            if (!tok[tokenId].burned && pool[tok[tokenId].item].lead == lead) {
                return (true, tokenId);
            }
        }
        return (false, 0);
    }

    /// @dev The first unminted item of artist `lead`, from `seed`, whose package is approved and
    ///      accepted by every party it names.
    function _startableOf(uint256 lead, uint256 seed) internal view returns (bool, uint256) {
        for (uint256 k; k < WORKS_PER_ARTIST; ++k) {
            uint256 p = lead * WORKS_PER_ARTIST + (seed % WORKS_PER_ARTIST + k) % WORKS_PER_ARTIST;
            if (_ready(p)) return (true, p);
        }
        return (false, 0);
    }

    function _artistStatement(uint256 tokenId) internal view returns (Statement memory) {
        return Statement(
            address(stream),
            tokenId,
            StatementKinds.ARTIST_STATEMENT,
            keccak256("6529-works/artist-statement/1"),
            HashRef(HASH_SHA256, keccak256("a restrained statement")),
            "ar://lifecycle-artist-statement",
            bytes32(0),
            bytes32(0)
        );
    }

    // ------------------------------------------------------------------ the invariants

    /// @dev Every invariant of the suite; see `StreamLifecycleInvariantTest`.
    function _assertLifecycle() internal view {
        assertEq(violations.length, 0, violations.length == 0 ? "" : violations[0]);
        _assertOwnership();
        _assertIds();
        _assertContent();
        _assertRecords();
        _assertRestraint();
        _assertAuctionEth();
    }

    /// @dev Every token has exactly one owner, or is in auction custody while its sale runs.
    function _assertOwnership() internal view {
        uint256 held;
        for (uint256 h; h < holders.length; ++h) {
            held += stream.balanceOf(holders[h]);
        }
        assertEq(held, stream.totalSupply(), "every live token is held by one known holder");
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            IEnglishAuction.AuctionState state = auction.auction(t.saleId).state;
            if (t.burned) {
                try stream.ownerOf(tokenId) returns (address) {
                    revert("a burned token has an owner");
                } catch { }
                assertEq(uint8(state), uint8(IEnglishAuction.AuctionState.CANCELLED), "burned");
                continue;
            }
            assertEq(stream.ownerOf(tokenId), t.owner, "the token is where its sale put it");
            bool custody = t.owner == address(auction);
            assertEq(
                custody,
                state != IEnglishAuction.AuctionState.SETTLED,
                "custody exactly while the sale is unsettled"
            );
            assertEq(stream.primarySaleSettled(tokenId), !custody, "settled exactly once sold");
        }
    }

    /// @dev Token IDs run from 1 without gaps, each assigned once to one item; burned IDs are
    ///      never reused.
    function _assertIds() internal view {
        assertEq(stream.totalMinted(), ghostMinted, "every start assigned one new ID");
        assertEq(stream.totalSupply(), ghostMinted - ghostBurned, "supply is minted minus burned");
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            assertEq(pool[t.item].tokenId, tokenId, "one item, one token ID");
            if (t.burned) continue;
            (bytes32 itemHash,,,,,) = stream.coreOf(tokenId);
            assertEq(itemHash, pool[t.item].itemHash, "a token keeps the item it was minted from");
        }
    }

    /// @dev A content hash is held by at most one live work: each live work holds its own
    ///      content's slot. A burned work holds it until released; a released item is tombstoned
    ///      and the slot reserved for the beneficiary.
    function _assertContent() internal view {
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            PoolItem storage it = pool[t.item];
            bytes32 holder = registry.consumedItemOf(it.contentHash);
            if (!t.burned) {
                assertEq(holder, it.itemHash, "a live work holds its content hash");
            } else if (!t.released) {
                assertEq(holder, it.itemHash, "a burned work holds its content until released");
            } else {
                assertTrue(registry.isReleased(it.itemHash), "a released item is tombstoned");
                assertTrue(holder != it.itemHash, "a released item no longer holds its content");
                if (holder != 0) {
                    assertEq(
                        uint160(lcArtists[pool[_itemIndex(holder)].lead]),
                        registry.releasedTo(it.contentHash),
                        "released content is consumed only by its beneficiary"
                    );
                }
            }
        }
    }

    /// @dev Records: media fixed by approval; a finalized record keeps its record file; a CC0
    ///      work stays CC0 with the pinned text; locators are append-only.
    function _assertRecords() internal view {
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            if (!t.opened) continue;
            IWorkRecords.RecordInfo memory r = records.record(tokenId);
            assertEq(r.mediaHash, pool[t.item].mediaHash, "media is fixed by approval");
            assertEq(
                keccak256(abi.encode(records.mediaOf(tokenId))),
                t.mediaDigest,
                "the media list never changes"
            );
            assertEq(r.finalized, t.finalized, "finalized exactly when finalize ran");
            if (t.finalized) {
                assertEq(r.recordFileId, t.recordFileId, "a finalized record keeps its file");
            }
            if (t.cc0) {
                License memory l = records.licenseOf(tokenId);
                assertEq(r.licenseKey, WorksHashing.CC0_LICENSE_KEY, "CC0 stays CC0");
                assertEq(l.textFileId, cc0TextFileId, "CC0 keeps the pinned text");
            }
            Locator[] memory stored = records.locators(tokenId, pool[t.item].fileId);
            Locator[] storage expected = ghostLocators[tokenId];
            assertEq(stored.length, expected.length, "locators are append-only");
            for (uint256 i; i < stored.length; ++i) {
                assertEq(uint8(stored[i].kind), uint8(expected[i].kind), "locator kind");
                assertEq(stored[i].uri, expected[i].uri, "locator URI");
            }
        }
    }

    /// @dev While a recovery override that moves the authority is pending, the artist has no
    ///      active authority.
    function _assertRestraint() internal view {
        for (uint256 i; i < ARTISTS; ++i) {
            uint256 id = uint160(lcArtists[i]);
            if (reservedKey[id] == address(0)) continue;
            PendingChange memory p = artists.pendingChange(id);
            assertTrue(p.kind == ChangeKind.CONTESTED, "the recovery is pending");
            assertEq(artists.activeAuthorityOf(id), address(0), "a recovering artist is restrained");
        }
    }

    /// @dev The auction holds exactly the live high bids and the bidders' credits.
    function _assertAuctionEth() internal view {
        uint256 owed;
        for (uint256 i; i < BIDDERS; ++i) {
            owed += auction.claimable(lcBidders[i], CURRENCY_ETH);
        }
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            IEnglishAuction.Auction memory a = auction.auction(tok[tokenId].saleId);
            if (
                a.bidder != address(0) && a.state != IEnglishAuction.AuctionState.SETTLED
                    && a.state != IEnglishAuction.AuctionState.CANCELLED
            ) owed += a.bid;
        }
        assertEq(address(auction).balance, ghostEthIn - ghostEthOut, "ETH in minus ETH paid out");
        assertEq(address(auction).balance, owed, "the auction holds the live bids and credits");
    }

    function _itemIndex(bytes32 itemHash) internal view returns (uint256) {
        for (uint256 p; p < pool.length; ++p) {
            if (pool[p].itemHash == itemHash) return p;
        }
        revert("unknown item");
    }
}
