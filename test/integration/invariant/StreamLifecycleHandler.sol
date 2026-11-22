// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { Role, Statement } from "src/interfaces/IStatementLog.sol";
import {
    Facts,
    Outcome,
    PendingModule,
    Slots,
    Work as CoreWork
} from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
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
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { ContentAddresses } from "../../helpers/ContentAddresses.sol";
import { MockRenderer } from "../../mocks/core/CoreMocks.sol";
import { IntegrationBase } from "../IntegrationBase.sol";
import { LifecycleHostileActor } from "./StreamLifecycleHostile.sol";

/// @notice The handler of the Stream lifecycle invariant suite: one actor set driving 6529
///         Stream, the package registry (the mint policy), `StreamWorkFacts6529` and its RECORDS
///         module `WorkRules`, the delivery contract, the English auction and the accounts module
///         on the plain-core stack deployed by `DeployCore` with the committed genesis
///         (`IntegrationBase`).
/// @dev The invariant test targets itself (it inherits this contract), so every action runs with
///      the integration helpers. Every action is bounded and never reverts (`fail_on_revert`):
///      it finds a subject in the right state from its seed, predicts the outcome from the
///      protocol's rules, runs the call (inside `try` when the prediction is a refusal) and
///      records any disagreement in `violations`.
///
///      Actors: three artists (each with six works in one package, two of which copy another
///      artist's media), one collaborator credited on some works, three ETH bidders, a hostile
///      contract that bids and receives works (it reverts, burns its gas or re-enters the auction
///      when paid or handed a work), the network (one key holding every network role), the
///      pauser, curator and platform keys, a stranger, and the keys that replacements install.
///      Packages are built in `setUp`; artist 0's is approved and accepted there, the others by
///      the `register` and `accept` actions.
abstract contract StreamLifecycleHandler is IntegrationBase {
    uint256 internal constant ARTISTS = 3;
    uint256 internal constant WORKS_PER_ARTIST = 6;
    uint256 internal constant BIDDERS = 3;
    uint256 internal constant SPARE_RECORDS = 3;
    /// @dev Locators each side may add per file before finalize, and both together.
    uint256 internal constant SIDE_QUOTA = 8;
    uint256 internal constant FILE_QUOTA = 16;
    /// @dev `Accounts.FREEZE_PERIOD`.
    uint256 internal constant FREEZE = 14 days;

    /// @dev One package item, with what a start and `open` need.
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
        uint256 beneficiary;
        bool pauseUsed;
        bool opened;
        bool finalized;
        bool cc0;
        bool unbid;
        Outcome outcome;
        bytes32 mintFacts;
        bytes32 recordFileId;
        bytes32 mediaDigest;
        address pinned;
        bytes32 pinnedCodeHash;
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

    /// @dev The aged-credit model of one account (the spec's rule): the money that started the
    ///      running wait (`aged`, since `since`) and everything credited (`total`).
    struct CreditGhost {
        uint256 total;
        uint256 aged;
        uint256 since;
    }

    /// @dev One credit as it arrived: its amount and arrival time.
    struct Lot {
        uint256 amount;
        uint256 arrivedAt;
    }

    address[ARTISTS] internal lcArtists;
    address internal lcCollaborator;
    address[BIDDERS] internal lcBidders;
    address internal lcStranger;
    LifecycleHostileActor internal lcHostile;
    /// @dev Every account that can hold a Stream token.
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
    /// @dev The renderer modules governance may install, the genesis one first.
    address[3] internal rendererChoices;

    mapping(uint256 tokenId => TokenGhost) internal tok;
    mapping(uint256 tokenId => Locator[]) internal ghostLocators;
    uint256 internal ghostMinted;
    uint256 internal ghostBurned;
    /// @dev ETH into the auction (bids) and out of it (settlements, claims, expiries).
    uint256 internal ghostEthIn;
    uint256 internal ghostEthOut;
    mapping(address account => CreditGhost) internal credit;
    mapping(address account => Lot[]) internal lots;
    mapping(address account => uint256) internal lotHead;
    /// @dev The RENDERER module and a pending one's ready time, as governance set them.
    address internal ghostRenderer;
    uint256 internal ghostRendererReadyAt;
    /// @dev The key a pending replacement would install, and a freeze's end, by account ID.
    mapping(uint256 artistId => address) internal reservedKey;
    mapping(uint256 artistId => uint256) internal frozenUntil;
    uint256 internal recoveries;
    bool internal recoveryPending;
    uint256 internal locatorNonce;
    /// @dev Every disagreement between an action's prediction and the protocol.
    string[] internal violations;
    /// @dev How often each path really ran (successes, and refusals of negative attempts).
    mapping(bytes32 path => uint256) public hits;

    /// @dev Every action ends by reading the credits the auction holds: what grew arrived now.
    modifier tracked() {
        _;
        _syncCredits();
    }

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
        lcStranger = makeAddr("lifecycleStranger");
        lcHostile = new LifecycleHostileActor();
        holders.push(address(lcHostile));
        holders.push(address(auction));
        holders.push(museum);
        rendererChoices =
            [address(renderer), address(new MockRenderer()), address(new MockRenderer())];
        ghostRenderer = address(renderer);
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
        // Work 4 of each artist copies work 0 of the artist before it, and work 5 work 0 of the
        // artist after it (cyclically): same media, same content hash, another record and item.
        // Every original therefore has two copies by two other artists.
        for (uint256 i; i < ARTISTS; ++i) {
            for (uint256 j = 4; j < 6; ++j) {
                uint256 from = j == 4 ? (i + ARTISTS - 1) % ARTISTS : (i + 1) % ARTISTS;
                Work memory original = packages[from][0];
                Work memory copy = packages[i][j];
                copy.media = original.media;
                copy.item.contentHash = original.item.contentHash;
                copy.item.mediaHash = original.item.mediaHash;
                rightfulOf[original.item.contentHash] = lcArtists[from];
            }
        }
        for (uint256 i; i < ARTISTS; ++i) {
            _addPackage(i, packages[i]);
        }
        _approve(packageOf[0]);
        _accept(packageOf[0], lcArtists[0]);
        _accept(packageOf[0], lcCollaborator);
    }

    // ------------------------------------------------------------------ setup helpers

    /// @dev Six works by artist `i`: CC0; CC-BY with the collaborator; an ARTIST seed; CC0 with
    ///      the collaborator; and two CC0 works whose media `setUp` replaces with copies.
    function _artistWorks(uint256 i) internal returns (Work[] memory works) {
        address lead = lcArtists[i];
        works = new Work[](WORKS_PER_ARTIST);
        for (uint256 j; j < WORKS_PER_ARTIST; ++j) {
            works[j] = _work(lead, collectionId);
        }
        _lcCollaborator(works[1].item, lead);
        works[1].item.license = License("CC-BY-4.0", byTextFileId);
        works[2].item.seedPolicy = uint8(SeedPolicy.ARTIST);
        works[2].item.seed = keccak256(abi.encode("artist seed", i));
        _lcCollaborator(works[3].item, lead);
    }

    /// @dev Adds the collaborator as a second party paid 30% as an artist-resolved payee, with
    ///      the payees in canonical (ascending artist ID) order.
    function _lcCollaborator(PackageItem memory item, address lead) internal view {
        item.parties = new Party[](2);
        item.parties[0] = Party(lead, uint8(PartyRole.ARTIST));
        item.parties[1] = Party(lcCollaborator, uint8(PartyRole.COLLABORATOR));
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
    function register(uint256 seed) external tracked {
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
        } catch (bytes memory reason) {
            if (bytes4(reason) != IPackageRegistry.PackageExists.selector) {
                _violation("a second registration failed for another reason");
            }
            ++hits["registerRefused"];
        }
    }

    /// @notice A party of a registered package accepts it, signed by itself (first acceptance)
    ///         or its authority. A restrained party's acceptance must be refused.
    function accept(uint256 seed, uint256 partySeed) external tracked {
        for (uint256 k; k < roots.length; ++k) {
            uint256 lead = (seed % ARTISTS + k) % ARTISTS;
            bytes32 root = packageOf[lead];
            if (_status(root) != IPackageRegistry.PackageStatus.APPROVED) continue;
            address[2] memory parties = [lcArtists[lead], lcCollaborator];
            for (uint256 j; j < 2; ++j) {
                address account = parties[(partySeed % 2 + j) % 2];
                if (registry.acceptedAs(root, account) != 0) continue;
                uint256 id = accounts.artistIdOf(account);
                if (id != 0 && _restrained(id)) {
                    _restrainedAcceptance(root, account, accounts.authorityOf(id));
                    return;
                }
                _accept(root, account);
                ++hits["accept"];
                return;
            }
        }
    }

    // ------------------------------------------------------------------ actions: the auction

    /// @notice Moves an approved, accepted item to Stream: the lead's authority signs the move
    ///         and anyone starts the auction (a third of the time with a first bid). Refusals are
    ///         predicted: a content hash a live work holds, a burned work's content not released,
    ///         a release reserving the content for another artist, a barred item, a restrained
    ///         lead, a revoked move, or starts paused.
    function start(uint256 seed, uint256 bidSeed) external tracked {
        (bool found, uint256 p) = _startable(seed);
        if (!found) {
            _startConsumed(seed);
            return;
        }
        if (auction.paused()) {
            _pausedStart(p);
            return;
        }
        StartCase memory c = _startCase(p, bidSeed);
        bytes memory data = _mintRequest(p, accounts.authorityOf(c.leadId), c.nonce);
        (bool ok, uint256 saleId, uint256 paid) = _startAuction(data, bidSeed);
        if (ok != c.expected) {
            _violation(ok ? "a start succeeded that the rules refuse" : "a valid start failed");
        }
        if (!ok) {
            if (c.restrained) ++hits["restrainedStart"];
            else if (c.revoked) ++hits["revokedMove"];
            else if (c.reserved) ++hits["reserved"];
            else ++hits["contentUsed"];
            return;
        }
        if (c.reserved) ++hits["reconsume"];
        _minted(p, saleId, paid);
    }

    /// @notice A bidder outbids the high bid of a live auction in ETH.
    function bid(uint256 seed, uint256 bidderSeed, uint256 amountSeed) external tracked {
        (bool found, uint256 tokenId) = _sale(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found) return;
        uint256 saleId = tok[tokenId].saleId;
        uint256 minimum = auction.minimumBid(saleId);
        uint256 amount = _bound(amountSeed, minimum, minimum + 3 ether);
        _ethBid(saleId, lcBidders[bidderSeed % BIDDERS], amount);
        ghostEthIn += amount;
        ++hits["bid"];
        if (auction.paused()) ++hits["pausedBid"];
    }

    /// @notice Settles an ended auction (a quarter of the time, warping to the end of a live one
    ///         when none has ended): the winner receives the work, or the museum when nobody bid
    ///         (UNSOLD), at once, whatever the artist's standing. Every settlement must go
    ///         through.
    function settle(uint256 seed) external tracked {
        (bool found, uint256 tokenId) = _sale(seed, IEnglishAuction.AuctionState.ENDED);
        if (!found) {
            if (seed % 4 != 0) return;
            (found, tokenId) = _sale(seed, IEnglishAuction.AuctionState.ACTIVE);
            if (!found) return;
            vm.warp(auction.auction(tok[tokenId].saleId).endTime);
        }
        TokenGhost storage t = tok[tokenId];
        IEnglishAuction.Auction memory a = auction.auction(t.saleId);
        bool restrained = _restrained(stream.workOf(tokenId).artistId);
        // A hostile recipient re-enters on delivery: re-arm it, so a refusal seen below is this
        // settlement's and not an earlier operation's.
        if (a.recipient == address(lcHostile)) _armHostileReentry();
        try auction.settle(t.saleId) {
            if (auction.paused()) ++hits["pausedSettle"];
            if (a.bidder != address(0)) {
                ghostEthOut += a.bid;
                t.owner = a.recipient;
                t.outcome = Outcome.SOLD;
                if (auction.pendingDelivery(t.saleId) != address(0)) {
                    // Only the hostile recipient refuses a work; it stays in custody, pending.
                    if (a.recipient != address(lcHostile)) _violation("a delivery failed");
                    t.owner = address(auction);
                    ++hits["deliveryPending"];
                } else if (a.recipient == address(lcHostile)) {
                    // It accepts the work only when set to re-enter, so it must have tried.
                    if (!_reentryRefusedByGuard()) {
                        _violation("a delivery's re-entry was not refused by the guard");
                    }
                    ++hits["hostileReceived"];
                }
            } else {
                t.owner = museum;
                t.unbid = true;
                t.outcome = Outcome.UNSOLD;
                if (stream.ownerOf(tokenId) != museum) {
                    _violation("an unbid work did not reach the museum");
                }
                ++hits[restrained ? bytes32("restrainedMuseum") : bytes32("museum")];
            }
            ++hits["settle"];
        } catch {
            _violation("a settlement failed");
        }
    }

    /// @notice A pauser key pauses a live auction for a dispute, a copied work's first; a second
    ///         pause of the same auction must be refused.
    function disputePause(uint256 seed) external tracked {
        (bool found, uint256 tokenId) = _copyOnSale(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found) (found, tokenId) = _sale(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        bytes32 ref = keccak256(abi.encode("lifecycle dispute", tokenId));
        if (t.pauseUsed) {
            vm.prank(pauser1);
            try auction.pause(t.saleId, ref) {
                _violation("an auction was paused twice");
            } catch (bytes memory reason) {
                if (
                    keccak256(reason)
                        != keccak256(
                            abi.encodeWithSelector(
                                IEnglishAuction.PauseExhausted.selector, t.saleId
                            )
                        )
                ) _violation("a second pause failed for another reason");
                ++hits["pauseExhausted"];
            }
            return;
        }
        vm.prank(pauser1);
        auction.pause(t.saleId, ref);
        t.pauseUsed = true;
        ++hits["disputePause"];
    }

    /// @notice Decides a paused auction's dispute: upheld for a copied work, rejected for an
    ///         original. Upheld: PLATFORM records the outcome and the network's `cancel` credits
    ///         the bid back and burns the work. Rejected: the high bidder may withdraw, and the
    ///         network's `resume` restarts the clock.
    function resolveDispute(uint256 seed, uint256 mode) external tracked {
        (bool found, uint256 tokenId) = _copyOnSale(seed, IEnglishAuction.AuctionState.PAUSED);
        if (!found) (found, tokenId) = _sale(seed, IEnglishAuction.AuctionState.PAUSED);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        IEnglishAuction.Auction memory a = auction.auction(t.saleId);
        if (_isCopy(t.item)) {
            bytes32 outcome = _platformStatement(
                address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://lifecycle-outcome"
            );
            _asNetwork(address(auction), abi.encodeCall(auction.cancel, (t.saleId, outcome)));
            t.burned = true;
            t.owner = address(0);
            ++ghostBurned;
            ++hits["cancel"];
            return;
        }
        if (a.bidder != address(0) && mode % 3 != 0) {
            vm.prank(a.bidder);
            auction.withdrawBid(t.saleId);
            ++hits["withdraw"];
        }
        _asNetwork(address(auction), abi.encodeCall(auction.resume, (t.saleId)));
        ++hits["resume"];
    }

    /// @notice The network's `releaseContent` (24 hours) of a burned work's content hash to the
    ///         rightful artist: a copy's original artist once registered, else any registered
    ///         artist. Right after, another artist's copy racing for the content is refused.
    function releaseContent(uint256 seed, uint256 beneficiarySeed) external tracked {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            TokenGhost storage t = tok[tokenId];
            if (!t.burned || t.released) continue;
            bytes32 contentHash = pool[t.item].contentHash;
            uint256 beneficiary = _beneficiary(contentHash, beneficiarySeed);
            if (beneficiary == 0) continue;
            _govern(
                network,
                address(registry),
                abi.encodeCall(
                    registry.releaseContent, (address(stream), tokenId, contentHash, beneficiary)
                )
            );
            t.released = true;
            t.beneficiary = beneficiary;
            ++hits["release"];
            _raceReservedContent(contentHash, beneficiary);
            return;
        }
    }

    /// @dev Right after a release, another artist's copy of the same content tries to take it:
    ///      the release reserves it for the beneficiary (`ContentReserved`).
    function _raceReservedContent(bytes32 contentHash, uint256 beneficiary) internal {
        if (auction.paused()) return;
        for (uint256 p; p < pool.length; ++p) {
            PoolItem storage it = pool[p];
            uint256 leadId = uint160(lcArtists[it.lead]);
            if (it.contentHash != contentHash || leadId == beneficiary || !_ready(p)) continue;
            if (_restrained(leadId)) continue;
            bytes memory data =
                _mintRequest(p, accounts.authorityOf(leadId), nextMoveNonce[leadId]++);
            try auction.start(address(stream), data) {
                _violation("released content was taken by another artist");
            } catch (bytes memory reason) {
                if (
                    keccak256(reason)
                        != keccak256(
                            abi.encodeWithSelector(
                                IMintPolicy.ContentReserved.selector, contentHash, beneficiary
                            )
                        )
                ) _violation("a racing copy failed for another reason");
                ++hits["reserved"];
            }
            return;
        }
    }

    /// @notice The current owner of a delivered work transfers it to another holder.
    function transfer(uint256 seed, uint256 toSeed) external tracked {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            TokenGhost storage t = tok[tokenId];
            // The museum keeps the unbid works it receives, and receives nothing else.
            if (t.burned || t.owner == address(auction) || t.owner == museum) continue;
            address to = holders[toSeed % holders.length];
            if (to == address(auction) || to == museum || to == t.owner) {
                to = lcBidders[toSeed % BIDDERS];
            }
            if (to == t.owner) to = lcBidders[(toSeed % BIDDERS + 1) % BIDDERS];
            vm.prank(t.owner);
            stream.transferFrom(t.owner, to, tokenId);
            t.owner = to;
            ++hits["transfer"];
            return;
        }
    }

    /// @notice Time passes: a minute to twelve hours (an auction runs a day).
    function warp(uint256 secondsSeed) external tracked {
        vm.warp(block.timestamp + _bound(secondsSeed, 1 minutes, 12 hours));
        ++hits["warp"];
    }

    /// @notice The start pause: a pauser key pauses (immediate) a third of the time it is not
    ///         paused, and the network unpauses when it is. Only starts stop: live auctions bid,
    ///         settle and claim on.
    function toggleStartPause(uint256 seed) external tracked {
        if (!auction.paused()) {
            if (seed % 3 != 0) return;
            vm.prank(pauser1);
            auction.pause();
            ++hits["startPaused"];
            return;
        }
        _asNetwork(address(auction), abi.encodeCall(auction.unpause, ()));
        if (auction.paused()) _violation("the network's unpause did not land");
        ++hits["startUnpaused"];
    }

    // ------------------------------------------------------------------ actions: credits

    /// @notice A bidder claims all its credit to itself.
    function claimCredit(uint256 seed) external tracked {
        for (uint256 k; k < BIDDERS; ++k) {
            address bidder = lcBidders[(seed % BIDDERS + k) % BIDDERS];
            uint256 owed = auction.claimable(bidder);
            if (owed == 0) continue;
            uint256 before = bidder.balance;
            vm.prank(bidder);
            auction.claim(bidder);
            if (bidder.balance != before + owed) {
                _violation("a claim did not pay the whole credit");
            }
            ghostEthOut += owed;
            _clearCredit(bidder);
            ++hits["claim"];
            return;
        }
    }

    /// @notice A stranger sends an account's aged credit to the network's fee recipient. The
    ///         outcome is predicted from the aged-credit rule under the unclaimed period in
    ///         force: refused with nothing credited or before the waiting money's period ends;
    ///         otherwise exactly the waiting money goes, and none of it arrived less than a
    ///         period ago.
    function expireCredit(uint256 seed) external tracked {
        address account = _creditAccount(seed);
        // Credits that arrived in this very call frame are not yet in the model.
        _syncCredits();
        CreditGhost storage g = credit[account];
        uint256 period = directory.unclaimedPeriod();
        uint256 feeBefore = networkFee.balance;
        vm.prank(lcStranger);
        try auction.expireCredit(account) returns (uint256 amount) {
            if (g.total == 0 || block.timestamp < g.since + period) {
                _violation("a credit expired before its money waited the period");
                return;
            }
            if (amount != g.aged) _violation("an expiry sent other than the waiting money");
            if (amount > _agedLots(account, period)) {
                _violation("an expiry took money younger than the unclaimed period");
            }
            if (networkFee.balance != feeBefore + amount) {
                _violation("expired money did not reach the network's fee recipient");
            }
            ghostEthOut += amount;
            _expireLots(account, amount);
            uint256 rest = g.total - g.aged;
            (g.total, g.aged, g.since) = (rest, rest, rest == 0 ? 0 : block.timestamp);
            ++hits["expired"];
        } catch (bytes memory reason) {
            bytes memory expected = g.total == 0
                ? abi.encodeWithSelector(IEnglishAuction.NothingToClaim.selector, account)
                : abi.encodeWithSelector(
                    IEnglishAuction.CreditNotExpired.selector, account, g.since + period
                );
            if (g.total != 0 && block.timestamp >= g.since + period) {
                _violation("a due expiry was refused");
            } else if (keccak256(reason) != keccak256(expected)) {
                _violation("an early expiry failed for another reason");
            }
            ++hits[g.total == 0 ? bytes32("expireNothing") : bytes32("expireEarly")];
        }
    }

    /// @notice The network changes the unclaimed period at once (zero allowed): it applies to
    ///         waits already running.
    function setUnclaimedPeriod(uint256 seed) external tracked {
        uint48[6] memory periods = [uint48(0), 1 hours, 1 days, 7 days, 30 days, 180 days];
        _asNetwork(
            address(directory),
            abi.encodeCall(directory.setUnclaimedPeriod, (periods[seed % periods.length]))
        );
        ++hits["setPeriod"];
    }

    // ------------------------------------------------------------------ actions: the hostile

    /// @notice A hostile contract takes part in a live auction: it outbids for itself, or a
    ///         bidder names it as the recipient. When it later receives ETH or the work it
    ///         reverts, burns all its gas or re-enters the auction, as `modeSeed` sets.
    function hostileBid(uint256 seed, uint256 modeSeed, uint256 amountSeed) external tracked {
        (bool found, uint256 tokenId) = _sale(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found) return;
        uint256 saleId = tok[tokenId].saleId;
        _configureHostile(modeSeed);
        uint256 minimum = auction.minimumBid(saleId);
        uint256 amount = _bound(amountSeed, minimum, minimum + 3 ether);
        if (modeSeed % 2 == 0) {
            address hostile = address(lcHostile);
            vm.deal(hostile, hostile.balance + amount);
            lcHostile.execute(
                address(auction), amount, abi.encodeCall(auction.bid, (saleId, hostile))
            );
            ++hits["hostileBid"];
        } else {
            address bidder = lcBidders[(modeSeed >> 8) % BIDDERS];
            vm.deal(bidder, bidder.balance + amount);
            vm.prank(bidder);
            auction.bid{ value: amount }(saleId, address(lcHostile));
            ++hits["hostileRecipient"];
        }
        ghostEthIn += amount;
    }

    /// @notice The hostile contract claims its credit to itself, within a bounded gas budget:
    ///         reverting or burning its gas, it keeps the credit (`ClaimFailed`); re-entering, it
    ///         is refused the re-entry and paid.
    function hostileClaim(uint256 modeSeed) external tracked {
        address hostile = address(lcHostile);
        uint256 owed = auction.claimable(hostile);
        if (owed == 0) return;
        _configureHostile(modeSeed);
        bool reenters = lcHostile.onEth() == LifecycleHostileActor.Behaviour.REENTER;
        try lcHostile.execute{ gas: 2_000_000 }(
            address(auction), 0, abi.encodeCall(auction.claim, (hostile))
        ) {
            if (!reenters) _violation("a refusing receiver was paid");
            if (!_reentryRefusedByGuard()) {
                _violation("a claim's re-entry was not refused by the guard");
            }
            ghostEthOut += owed;
            _clearCredit(hostile);
            ++hits["hostileReentryRefused"];
        } catch (bytes memory reason) {
            if (
                reenters
                    || keccak256(reason)
                        != keccak256(
                            abi.encodeWithSelector(IEnglishAuction.ClaimFailed.selector, hostile)
                        )
            ) _violation("a claim failed for another reason");
            if (auction.claimable(hostile) != owed) _violation("a credit was lost");
            ++hits["hostileClaimKept"];
        }
    }

    /// @notice A pending delivery (the hostile recipient refused the work) is claimed. A third
    ///         party first routes a claim through the hostile recipient to itself, which must be
    ///         refused before 14 days after the end unless the hostile is also the winning
    ///         bidder; then the winning bidder claims, to itself or, as the hostile, to another.
    function claimDelivery(uint256 seed) external tracked {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            TokenGhost storage t = tok[tokenId];
            if (t.burned || t.owner != address(auction)) continue;
            uint256 saleId = t.saleId;
            if (auction.pendingDelivery(saleId) == address(0)) continue;
            IEnglishAuction.Auction memory a = auction.auction(saleId);
            address winner = a.bidder;
            address stranger = lcBidders[seed % BIDDERS];
            if (stranger == winner) stranger = lcBidders[(seed % BIDDERS + 1) % BIDDERS];
            bytes memory toStranger = abi.encodeCall(auction.claimDelivery, (saleId, stranger));
            if (winner != address(lcHostile) && block.timestamp >= uint256(a.endTime) + 14 days) {
                // The recipient's own redirect, open from 14 days after the end.
                vm.prank(stranger);
                lcHostile.execute(address(auction), 0, toStranger);
                t.owner = stranger;
                ++hits["recipientRedirect"];
            } else if (winner != address(lcHostile)) {
                vm.prank(stranger);
                try lcHostile.execute(address(auction), 0, toStranger) {
                    _violation("a forwarding recipient sent the work elsewhere");
                } catch (bytes memory reason) {
                    if (
                        keccak256(reason)
                            != keccak256(
                                abi.encodeWithSelector(
                                    IEnglishAuction.InvalidRecipient.selector, stranger
                                )
                            )
                    ) _violation("a forwarded claim failed for another reason");
                    ++hits["forwardedClaimRefused"];
                }
                vm.prank(winner);
                auction.claimDelivery(saleId, winner);
                t.owner = winner;
            } else {
                lcHostile.execute(address(auction), 0, toStranger);
                t.owner = stranger;
            }
            ++hits["deliveryClaimed"];
            return;
        }
    }

    /// @dev Sets what the hostile contract does on receiving ETH and on receiving a work, and
    ///      re-arms its re-entry: a claim of its own credit, which the guard must refuse.
    function _configureHostile(uint256 modeSeed) internal {
        LifecycleHostileActor.Behaviour[3] memory modes = [
            LifecycleHostileActor.Behaviour.REVERT,
            LifecycleHostileActor.Behaviour.BURN_GAS,
            LifecycleHostileActor.Behaviour.REENTER
        ];
        lcHostile.configure(modes[(modeSeed >> 16) % 3], modes[(modeSeed >> 24) % 3]);
        _armHostileReentry();
    }

    function _armHostileReentry() internal {
        lcHostile.setReentry(address(auction), abi.encodeCall(auction.claim, (address(lcHostile))));
    }

    /// @dev Whether the hostile contract attempted its armed re-entry and the auction's
    ///      reentrancy guard refused it with its own error, not any other failure.
    function _reentryRefusedByGuard() internal view returns (bool) {
        return lcHostile.reentered() && !lcHostile.reentryOk()
            && keccak256(lcHostile.reentryResult())
                == keccak256(
                abi.encodeWithSelector(
                ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
            )
            );
    }

    /// @dev While starts are paused every start is refused (`SalePaused`), whatever its item;
    ///      the move's nonce is not consumed.
    function _pausedStart(uint256 p) internal {
        uint256 leadId = uint160(lcArtists[pool[p].lead]);
        bytes memory data = _mintRequest(p, accounts.authorityOf(leadId), nextMoveNonce[leadId]);
        try auction.start(address(stream), data) {
            _violation("a start succeeded while starts were paused");
        } catch (bytes memory reason) {
            if (bytes4(reason) != IEnglishAuction.SalePaused.selector) {
                _violation("a paused start failed for another reason");
            }
            ++hits["pausedStart"];
        }
    }

    // ------------------------------------------------------------------ actions: records

    /// @notice Anyone opens a minted work's record from its approved item and media.
    function openRecord(uint256 seed) external tracked {
        (bool found, uint256 tokenId) = _token(seed, false, false);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        PoolItem storage it = pool[t.item];
        vm.prank(lcBidders[seed % BIDDERS]);
        facts.open(
            address(stream),
            tokenId,
            abi.decode(it.item, (PackageItem)),
            abi.decode(it.media, (MediaFile[]))
        );
        Facts memory f = facts.factsOf(address(stream), tokenId);
        t.opened = true;
        t.cc0 = it.cc0;
        t.recordFileId = abi.decode(it.item, (PackageItem)).recordFileId;
        t.mediaDigest = keccak256(abi.encode(f.media));
        if (f.recordFileId != t.recordFileId) _violation("a record opened with another file");
        ++hits["openRecord"];
    }

    /// @notice The artist points an open, unfinalized record at another record file. Now and
    ///         then the artist of a finalized work tries the same: refused, the record is fixed.
    function setRecord(uint256 seed, uint256 fileSeed) external tracked {
        bytes32 file = spareRecords[fileSeed % SPARE_RECORDS];
        if (fileSeed % 4 == 3 && _setFinalizedRecord(seed, file)) return;
        (bool found, uint256 tokenId) = _token(seed, true, true);
        if (!found) return;
        address artist = accounts.activeAuthorityOf(stream.workOf(tokenId).artistId);
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        vm.prank(artist);
        rules.setRecord(address(stream), tokenId, file, state);
        tok[tokenId].recordFileId = file;
        ++hits["setRecord"];
    }

    /// @dev The unrestrained artist of a finalized live work tries to replace its record file
    ///      with another: it must be refused (`WorkIsFinalized`). False when there is no such
    ///      work.
    function _setFinalizedRecord(uint256 seed, bytes32 file) internal returns (bool) {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            TokenGhost storage t = tok[tokenId];
            if (t.burned || !t.finalized || t.recordFileId == file) continue;
            uint256 id = stream.workOf(tokenId).artistId;
            if (_restrained(id)) continue;
            bytes32 state = rules.workStateHash(address(stream), tokenId);
            vm.prank(accounts.authorityOf(id));
            try rules.setRecord(address(stream), tokenId, file, state) {
                _violation("a finalized record was replaced");
            } catch (bytes memory reason) {
                if (
                    keccak256(reason)
                        != keccak256(
                            abi.encodeWithSelector(
                                IWorkFacts.WorkIsFinalized.selector, address(stream), tokenId
                            )
                        )
                ) _violation("a finalized record's change failed for another reason");
                ++hits["finalizedRecordRefused"];
            }
            return true;
        }
        return false;
    }

    /// @notice The artist finalizes an open record, pinning the RENDERER module in force.
    function finalize(uint256 seed) external tracked {
        (bool found, uint256 tokenId) = _token(seed, true, true);
        if (!found) return;
        address artist = accounts.activeAuthorityOf(stream.workOf(tokenId).artistId);
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        vm.prank(artist);
        rules.finalize(address(stream), tokenId, state);
        _finalized(tokenId);
        ++hits["finalize"];
    }

    /// @notice The artist (before finalize) or the platform adds an Arweave or IPFS locator to a
    ///         work's primary file. The quotas and the URI rule are predicted; a URI with a path
    ///         must be refused.
    function addLocator(uint256 seed, uint256 kindSeed) external tracked {
        (bool found, uint256 tokenId) = _token(seed, true, false);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        uint256 id = stream.workOf(tokenId).artistId;
        address artist = _restrained(id) ? address(0) : accounts.authorityOf(id);
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
        try delivery.addLocator(address(stream), tokenId, pool[t.item].fileId, locator) {
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

    /// @notice The network's relicense (3 days) with every party's consent. A CC0 work must stay
    ///         CC0 with the pinned text (both moves refused); another license moves to CC0 or
    ///         MIT, unless a party is restrained and so cannot consent.
    function relicense(uint256 seed, uint256 choice) external tracked {
        (bool found, uint256 tokenId) = _token(seed, true, false);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        Facts memory f = facts.factsOf(address(stream), tokenId);
        License memory next = t.cc0
            ? (choice % 2 == 0
                    ? License("CC-BY-4.0", byTextFileId)
                    : License("CC0-1.0", altCc0TextFileId))
            : (choice % 2 == 0 ? License("CC0-1.0", cc0TextFileId) : License("MIT", mitTextFileId));
        bool same = WorksHashing.licenseKey(f.licenseId) == WorksHashing.licenseKey(next.spdxId)
            && f.licenseTextFileId == next.textFileId;
        bytes memory call = _relicenseCall(tokenId, next);
        // The network's call lands 3 days after it is scheduled: the parties' standing then
        // decides whether their consents count.
        _networkSchedule(address(rules), call);
        bool restrainedParty = _anyPartyRestrained(tokenId);
        bool expected = same || (!t.cc0 && !restrainedParty);
        bool ok = _networkExecute(address(rules), call);
        if (ok != expected) {
            _violation(ok ? "a refused relicense applied" : "a valid relicense failed");
        }
        if (!ok) {
            ++hits[t.cc0 ? bytes32("cc0Held") : bytes32("restrainedRelicense")];
            return;
        }
        if (!same) t.cc0 = WorksHashing.licenseKey(next.spdxId) == WorksHashing.CC0_LICENSE_KEY;
        ++hits["relicense"];
    }

    /// @notice Governance swaps the RENDERER module: it proposes one (it waits the module
    ///         delay in force at the proposal) and anyone activates it once ready. A pending
    ///         module keeps the time it was given when the network changes the delay; an early
    ///         activation is refused. A finalized work keeps its pinned renderer.
    function swapRenderer(uint256 seed) external tracked {
        PendingModule memory p = stream.pendingModule(Slots.RENDERER);
        if (p.readyAt != 0) {
            if (p.readyAt != ghostRendererReadyAt) _violation("a pending module's time changed");
            if (block.timestamp >= p.readyAt) {
                stream.activateModule(Slots.RENDERER);
                ghostRenderer = p.module;
                ghostRendererReadyAt = 0;
                ++hits["rendererSwapped"];
                return;
            }
            try stream.activateModule(Slots.RENDERER) {
                _violation("a module activated before its time");
            } catch {
                ++hits["moduleNotReady"];
            }
            uint48[3] memory delays = [uint48(0), 1 hours, 7 days];
            _asNetwork(address(stream), abi.encodeCall(stream.setModuleDelay, (delays[seed % 3])));
            return;
        }
        address candidate = rendererChoices[seed % 3];
        if (candidate == ghostRenderer) candidate = rendererChoices[(seed % 3 + 1) % 3];
        _asNetwork(
            address(stream), abi.encodeCall(stream.proposeModule, (Slots.RENDERER, candidate))
        );
        ghostRendererReadyAt = block.timestamp + stream.moduleDelay();
        ++hits["rendererProposed"];
    }

    // ------------------------------------------------------------------ actions: identity

    /// @notice The network stages a replacement (24 hours) moving an artist's or the
    ///         collaborator's authority to a fresh key: from then until it ends, nobody acts as
    ///         that party.
    function stageRecovery(uint256 seed) external tracked {
        if (recoveryPending) return;
        for (uint256 k; k <= ARTISTS; ++k) {
            address account = _party((seed % (ARTISTS + 1) + k) % (ARTISTS + 1));
            uint256 id = uint160(account);
            if (accounts.artistIdOf(account) == 0) continue;
            if (accounts.pendingChange(id).kind != ChangeKind.NONE) continue;
            address next = _actor(string.concat("lifecycleRecovered", vm.toString(++recoveries)));
            holders.push(next);
            ArtistIdentity memory identity =
                ArtistIdentity(next, next, _profileId(account), _profileDoc(account));
            bytes32 evidence = keccak256(abi.encode("lifecycle recovery evidence", recoveries));
            uint64 deadline = uint64(block.timestamp + 60 days);
            bytes memory acceptance =
                _sign(next, accounts.replacementDigest(id, identity, evidence, deadline));
            _govern(
                network,
                address(accounts),
                abi.encodeCall(
                    accounts.stageReplacement, (id, identity, evidence, deadline, acceptance)
                )
            );
            reservedKey[id] = next;
            recoveryPending = true;
            ++hits["stageRecovery"];
            return;
        }
    }

    /// @notice A pending replacement ends: the network cancels it, or it executes once its
    ///         notice has passed and the new key becomes the authority (now and then the
    ///         handler waits the notice out first). Execution is refused before the notice ends
    ///         (the replacement stays pending) and while the account is frozen.
    function endRecovery(uint256 seed, uint256 mode) external tracked {
        for (uint256 k; k <= ARTISTS; ++k) {
            uint256 id = uint160(_party((seed % (ARTISTS + 1) + k) % (ARTISTS + 1)));
            if (reservedKey[id] == address(0)) continue;
            bool vetoed = mode % 2 == 0;
            if (!vetoed) {
                PendingChange memory p = accounts.pendingChange(id);
                if (block.timestamp < p.executableAt) {
                    if (mode % 4 == 3) {
                        try accounts.executeChange(id) {
                            _violation("a replacement executed before its notice ended");
                        } catch (bytes memory reason) {
                            if (
                                keccak256(reason)
                                    != keccak256(
                                        abi.encodeWithSelector(
                                            IArtistRegistry.ChangeNotDue.selector,
                                            id,
                                            p.executableAt
                                        )
                                    )
                            ) _violation("an early execution failed for another reason");
                            ++hits["earlyExecuteRefused"];
                        }
                        return;
                    }
                    vm.warp(p.executableAt);
                }
                if (frozenUntil[id] > block.timestamp) {
                    try accounts.executeChange(id) {
                        _violation("a replacement executed while the account was frozen");
                    } catch (bytes memory reason) {
                        if (bytes4(reason) != IArtistRegistry.AccountIsFrozen.selector) {
                            _violation("a frozen execution failed for another reason");
                        }
                        ++hits["frozenExecuteRefused"];
                    }
                    vetoed = true;
                } else {
                    accounts.executeChange(id);
                    if (accounts.authorityOf(id) != reservedKey[id]) {
                        _violation("an executed replacement did not install its key");
                    }
                    ++hits["recovered"];
                }
            }
            if (vetoed) {
                _asNetwork(address(accounts), abi.encodeCall(accounts.cancelReplacement, (id)));
                ++hits["veto"];
            }
            reservedKey[id] = address(0);
            recoveryPending = false;
            return;
        }
    }

    /// @notice The network freezes a party (14 days, at once) or lifts its freeze; a second
    ///         freeze while one runs is refused.
    function freezeAccount(uint256 seed, uint256 mode) external tracked {
        address account = _party(seed % (ARTISTS + 1));
        uint256 id = uint160(account);
        if (accounts.artistIdOf(account) == 0) return;
        if (frozenUntil[id] > block.timestamp) {
            if (mode % 2 == 0) {
                vm.prank(network);
                try accounts.freeze(id) {
                    _violation("an account was frozen twice at once");
                } catch {
                    ++hits["freezeRefused"];
                }
                return;
            }
            _asNetwork(address(accounts), abi.encodeCall(accounts.unfreeze, (id)));
            frozenUntil[id] = 0;
            ++hits["unfreeze"];
            return;
        }
        _asNetwork(address(accounts), abi.encodeCall(accounts.freeze, (id)));
        frozenUntil[id] = block.timestamp + FREEZE;
        ++hits["freeze"];
    }

    /// @notice While an artist is restrained (frozen, or a replacement pending), its key, or the
    ///         key a pending replacement reserves, tries to act as the artist: start a work,
    ///         change or finalize a record, add an artist locator, append an ARTIST statement,
    ///         accept a package or revoke a move. Every attempt must be refused.
    function restrainedAct(uint256 seed, uint256 which) external tracked {
        for (uint256 k; k < ARTISTS; ++k) {
            uint256 lead = (seed % ARTISTS + k) % ARTISTS;
            uint256 id = uint160(lcArtists[lead]);
            if (accounts.artistIdOf(lcArtists[lead]) == 0 || !_restrained(id)) continue;
            address actor = which % 2 == 0 || reservedKey[id] == address(0)
                ? accounts.authorityOf(id)
                : reservedKey[id];
            if (_actAsArtist(lead, id, actor, (which >> 1) % 6, seed)) {
                _violation("a restrained artist acted");
            }
            ++hits["restrainedAct"];
            return;
        }
    }

    // ------------------------------------------------------------------ internals

    /// @dev The artists, then the collaborator.
    function _party(uint256 i) internal view returns (address) {
        return i < ARTISTS ? lcArtists[i] : lcCollaborator;
    }

    function _status(bytes32 root) internal view returns (IPackageRegistry.PackageStatus status) {
        (status,,) = registry.packageOf(root);
    }

    /// @dev Restrained: registered, and frozen or with a replacement pending, so the accounts
    ///      module reports no active authority. Zero (no account) is never restrained.
    function _restrained(uint256 artistId) internal view returns (bool) {
        if (artistId == 0 || accounts.artistIdOf(address(uint160(artistId))) == 0) return false;
        return accounts.activeAuthorityOf(artistId) == address(0);
    }

    function _violation(string memory what) internal {
        violations.push(what);
    }

    /// @dev Schedules a delayed network call and waits its delay out (nothing for an immediate
    ///      one).
    function _networkSchedule(address target, bytes memory data) internal {
        (bool immediate, uint32 delay) = manager.canCall(network, target, bytes4(data));
        if (immediate) return;
        vm.prank(network);
        manager.schedule(target, data, 0);
        vm.warp(block.timestamp + delay);
    }

    /// @dev Runs a network call scheduled by `_networkSchedule`; a refusal by the target returns
    ///      false and withdraws the schedule.
    function _networkExecute(address target, bytes memory data) internal returns (bool) {
        (bool immediate,) = manager.canCall(network, target, bytes4(data));
        vm.prank(network);
        if (immediate) {
            (bool ok,) = target.call(data);
            return ok;
        }
        try manager.execute(target, data) {
            return true;
        } catch {
            vm.prank(network);
            manager.cancel(network, target, data);
            return false;
        }
    }

    /// @dev Whether a party of the token's item is restrained now.
    function _anyPartyRestrained(uint256 tokenId) internal view returns (bool) {
        PackageItem memory item = abi.decode(pool[tok[tokenId].item].item, (PackageItem));
        for (uint256 i; i < item.parties.length; ++i) {
            if (_restrained(uint160(item.parties[i].account))) return true;
        }
        return false;
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
                    registry.releasedTo(address(stream), it.contentHash)
                        == uint160(lcArtists[it.lead])
                ) {
                    return (true, p);
                }
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

    /// @dev Predicts a start of item `p` from the ghost: refused when a live work holds its
    ///      content hash, a burned work's content is not released (or released to another
    ///      artist), the item is barred, the lead is restrained, or (one time in seven) the lead
    ///      revoked the move's nonce first.
    function _startCase(uint256 p, uint256 bidSeed) internal returns (StartCase memory c) {
        PoolItem storage it = pool[p];
        c.leadId = uint160(lcArtists[it.lead]);
        uint256 prior = _ghostHolderOf(it.contentHash);
        bool free = prior == 0;
        if (prior != 0 && tok[prior].burned && tok[prior].released) {
            c.reserved = true;
            free = tok[prior].beneficiary == c.leadId && !_barred(it.itemHash);
        }
        c.restrained = _restrained(c.leadId);
        c.revoked = !c.restrained && bidSeed % 7 == 1;
        c.nonce = nextMoveNonce[c.leadId]++;
        if (c.revoked) {
            vm.prank(accounts.authorityOf(c.leadId));
            registry.revokeMove(c.leadId, c.nonce);
        }
        c.expected = free && !c.restrained && !c.revoked;
    }

    /// @dev The last token the ghost minted with `contentHash`, or zero.
    function _ghostHolderOf(bytes32 contentHash) internal view returns (uint256 last) {
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            if (pool[tok[tokenId].item].contentHash == contentHash) last = tokenId;
        }
    }

    /// @dev Whether a release barred `itemHash`: it was the item of a released burned token.
    function _barred(bytes32 itemHash) internal view returns (bool) {
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            if (tok[tokenId].released && pool[tok[tokenId].item].itemHash == itemHash) return true;
        }
        return false;
    }

    /// @dev With nothing left to start, a minted item is moved again: refused, whether its work
    ///      is live, burned or released (a live content is held and a released item is barred).
    function _startConsumed(uint256 seed) internal {
        PoolItem storage it = pool[seed % pool.length];
        if (it.tokenId == 0 || auction.paused()) return;
        uint256 leadId = uint160(lcArtists[it.lead]);
        bytes memory data =
            _mintRequest(seed % pool.length, accounts.authorityOf(leadId), nextMoveNonce[leadId]++);
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
        MoveAuthorization memory move =
            MoveAuthorization(nonce, deadline, abi.encodePacked(signer, _sign(signer, digest)));
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
        paid = _bound(bidSeed >> 16, OPENING_BID, 2 ether);
        vm.deal(bidder, bidder.balance + paid);
        vm.prank(bidder);
        try auction.startWithBid{ value: paid }(address(stream), data, address(0)) returns (
            uint256 id
        ) {
            return (true, id, paid);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Records a new token: IDs are assigned in order, once; the facts fixed at mint are
    ///      kept to compare against later.
    function _minted(uint256 p, uint256 saleId, uint256 paid) internal {
        uint256 tokenId = stream.totalMinted();
        if (tokenId != ghostMinted + 1) _violation("token IDs are not sequential");
        if (saleId != auction.saleIdOf(address(stream), tokenId)) _violation("sale ID");
        ghostMinted = tokenId;
        pool[p].tokenId = tokenId;
        TokenGhost storage t = tok[tokenId];
        t.item = p;
        t.saleId = saleId;
        t.owner = address(auction);
        t.mintFacts = _mintFactsOf(tokenId);
        ghostEthIn += paid;
        ++hits["start"];
    }

    /// @dev The facts a token fixed at mint: item, artist, collection, serial, kind, seed policy
    ///      and seed.
    function _mintFactsOf(uint256 tokenId) internal view returns (bytes32) {
        CoreWork memory w = stream.workOf(tokenId);
        return keccak256(
            abi.encode(
                w.itemHash, w.artistId, w.collectionId, w.serial, w.kind, w.seedPolicy, w.seed
            )
        );
    }

    /// @dev Records a finalize: the record file it froze and the renderer it pinned (the
    ///      RENDERER module in force).
    function _finalized(uint256 tokenId) internal {
        TokenGhost storage t = tok[tokenId];
        Facts memory f = facts.factsOf(address(stream), tokenId);
        t.finalized = true;
        t.pinned = f.renderer;
        t.pinnedCodeHash = f.rendererCodeHash;
        if (f.renderer != ghostRenderer) _violation("finalize pinned another renderer");
        if (f.recordFileId != t.recordFileId) _violation("finalize changed the record file");
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
    ///      false); with `amendable`, also unfinalized and with an unrestrained artist.
    function _token(uint256 seed, bool open, bool amendable) internal view returns (bool, uint256) {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            TokenGhost storage t = tok[tokenId];
            if (t.burned || t.opened != open) continue;
            if (amendable) {
                if (t.finalized) continue;
                if (_restrained(stream.workOf(tokenId).artistId)) continue;
            }
            return (true, tokenId);
        }
        return (false, 0);
    }

    /// @dev The rightful artist of a copied content hash, once registered; for any other
    ///      content, a registered artist from `seed`. Zero when the release must wait.
    function _beneficiary(bytes32 contentHash, uint256 seed) internal view returns (uint256) {
        address rightful = rightfulOf[contentHash];
        if (rightful != address(0)) {
            return accounts.artistIdOf(rightful) != 0 ? uint160(rightful) : 0;
        }
        for (uint256 k; k < ARTISTS; ++k) {
            address account = lcArtists[(seed % ARTISTS + k) % ARTISTS];
            if (accounts.artistIdOf(account) != 0) return uint160(account);
        }
        return 0;
    }

    function _newLocator(uint256 kind) internal returns (Locator memory) {
        string memory seed = string.concat("lifecycle locator ", vm.toString(++locatorNonce));
        if (kind % 3 == 0) return ContentAddresses.ar(seed);
        if (kind % 3 == 1) return ContentAddresses.ipfsLocator(seed);
        return Locator(LocatorKind.IPFS, ContentAddresses.ipfsRoot(seed));
    }

    /// @dev The relicense call with every party's consent, each signed by its authority (a
    ///      restrained party's authority is not a wallet of its account while restrained).
    function _relicenseCall(uint256 tokenId, License memory next)
        internal
        view
        returns (bytes memory)
    {
        PackageItem memory item = abi.decode(pool[tok[tokenId].item].item, (PackageItem));
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest = _typedDigest(
            address(rules),
            keccak256(
                abi.encode(
                    rules.RELICENSE_TYPEHASH(),
                    address(stream),
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
            address signer = accounts.authorityOf(uint160(item.parties[i].account));
            sigs[i] = abi.encodePacked(signer, _sign(signer, digest));
        }
        return abi.encodeCall(
            rules.relicense, (address(stream), tokenId, next, item, state, deadline, sigs)
        );
    }

    function _restrainedAcceptance(bytes32 root, address account, address signer) internal {
        PartyAcceptance memory a = PartyAcceptance(
            account, _profileId(account), _profileDoc(account), uint64(block.timestamp + 1 days)
        );
        bytes memory signature =
            abi.encodePacked(signer, _sign(signer, registry.acceptanceDigest(root, a)));
        try registry.acceptPackage(root, a, signature) {
            _violation("a restrained party accepted a package");
        } catch {
            ++hits["restrainedAccept"];
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
            if (startable && !auction.paused()) {
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
                bytes memory signature = abi.encodePacked(
                    actor, _sign(actor, registry.acceptanceDigest(packageOf[lead], a))
                );
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
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        bytes32 fileId = pool[tok[tokenId].item].fileId;
        Locator memory locator = _newLocator(0);
        bytes32 recordFile = spareRecords[tokenId % SPARE_RECORDS];
        // Anyone may finalize the record as it stands once a recorded notice is due.
        uint256 notice = rules.finalizeNoticeAt(address(stream), tokenId);
        bool dueToAnyone = notice != 0 && block.timestamp >= notice + FINALIZE_NOTICE;
        vm.prank(actor);
        if (power == 1) {
            try rules.setRecord(address(stream), tokenId, recordFile, state) {
                return true;
            } catch {
                return false;
            }
        }
        if (power == 2) {
            // Anyone may record a finalize notice once the first sale has an outcome, and
            // finalize once it is due; acting as the artist means finalizing at once, without a
            // due notice, so only that counts. A due finalize must go through, as for anyone.
            try rules.finalize(address(stream), tokenId, state) {
                bool done = facts.factsOf(address(stream), tokenId).finalized;
                if (!dueToAnyone) return done;
                if (!done) _violation("a due finalize did not finalize");
                _finalized(tokenId);
                ++hits["dueFinalize"];
                return false;
            } catch {
                if (dueToAnyone) _violation("a due finalize was refused");
                return false;
            }
        }
        try delivery.addLocator(address(stream), tokenId, fileId, locator) {
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

    // ------------------------------------------------------------------ the credit model

    /// @dev The accounts the auction can owe: the bidders and the hostile contract.
    function _creditAccount(uint256 seed) internal view returns (address) {
        uint256 i = seed % (BIDDERS + 1);
        return i < BIDDERS ? lcBidders[i] : address(lcHostile);
    }

    /// @dev Reads every account's credit: an increase is a credit that arrived now (it joins a
    ///      running wait, or starts one on an empty account); a decrease outside a claim or an
    ///      expiry is a violation.
    function _syncCredits() internal {
        for (uint256 i; i <= BIDDERS; ++i) {
            address account = _creditAccount(i);
            CreditGhost storage g = credit[account];
            uint256 owed = auction.claimable(account);
            if (owed == g.total) continue;
            if (owed < g.total) {
                _violation("a credit shrank outside a claim or an expiry");
                (g.total, g.aged, g.since) = (owed, owed, block.timestamp);
                continue;
            }
            uint256 amount = owed - g.total;
            if (g.total == 0) (g.aged, g.since) = (amount, block.timestamp);
            g.total = owed;
            lots[account].push(Lot(amount, block.timestamp));
        }
    }

    function _clearCredit(address account) internal {
        delete credit[account];
        lotHead[account] = lots[account].length;
    }

    /// @dev The account's unclaimed money that arrived at least `period` ago.
    function _agedLots(address account, uint256 period) internal view returns (uint256 sum) {
        Lot[] storage list = lots[account];
        for (uint256 i = lotHead[account]; i < list.length; ++i) {
            if (list[i].arrivedAt + period <= block.timestamp) sum += list[i].amount;
        }
    }

    /// @dev Removes `amount` from the account's oldest money first.
    function _expireLots(address account, uint256 amount) internal {
        Lot[] storage list = lots[account];
        uint256 i = lotHead[account];
        while (amount != 0 && i < list.length) {
            uint256 take = amount < list[i].amount ? amount : list[i].amount;
            list[i].amount -= take;
            amount -= take;
            if (list[i].amount == 0) ++i;
        }
        lotHead[account] = i;
    }

    // ------------------------------------------------------------------ the invariants

    /// @dev Every invariant of the suite; see `StreamLifecycleInvariantTest`.
    function _assertLifecycle() internal view {
        assertEq(violations.length, 0, violations.length == 0 ? "" : violations[0]);
        _assertOwnership();
        _assertIds();
        _assertFixedFacts();
        _assertContent();
        _assertRecords();
        _assertRenderers();
        _assertRestraint();
        _assertAuctionEth();
        _assertCredits();
        _assertMuseum();
    }

    /// @dev 1. Every token has exactly one owner, a known holder, and is in auction custody
    ///      exactly while its sale is unsettled or its delivery pending; a burned token has none.
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
            bool settled = state == IEnglishAuction.AuctionState.SETTLED;
            assertEq(
                t.owner == address(auction),
                !settled || auction.pendingDelivery(t.saleId) != address(0),
                "custody exactly while the sale is unsettled or its delivery pending"
            );
        }
    }

    /// @dev 2. Token IDs run from 1 without gaps, each assigned once to one item; burned IDs
    ///      are never reused; supply is minted minus burned.
    function _assertIds() internal view {
        assertEq(stream.totalMinted(), ghostMinted, "every start assigned one new ID");
        assertEq(stream.totalBurned(), ghostBurned, "every cancel burned one token");
        assertEq(stream.totalSupply(), ghostMinted - ghostBurned, "supply is minted minus burned");
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            assertEq(pool[t.item].tokenId, tokenId, "one item, one token ID");
        }
    }

    /// @dev 3. The facts fixed at mint never change, burned or not, and the outcome is NONE
    ///      until the sale records it, then SOLD or UNSOLD for good.
    function _assertFixedFacts() internal view {
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            assertEq(_mintFactsOf(tokenId), t.mintFacts, "the facts fixed at mint never change");
            assertEq(
                stream.workOf(tokenId).itemHash,
                pool[t.item].itemHash,
                "a token keeps the item it was minted from"
            );
            assertEq(uint8(stream.workOf(tokenId).outcome), uint8(t.outcome), "the outcome");
        }
    }

    /// @dev 4. A content hash is held by at most one live work. A burned work holds its content
    ///      until released; a released item is barred and only the release's beneficiary mints
    ///      the content again.
    function _assertContent() internal view {
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            PoolItem storage it = pool[t.item];
            uint256 last = stream.tokenOfContent(it.contentHash);
            assertEq(last, _ghostHolderOf(it.contentHash), "the content's last token");
            if (!t.burned) {
                assertEq(last, tokenId, "a live work holds its content hash");
                assertEq(registry.consumedItemOf(it.contentHash), it.itemHash, "consumed");
                for (uint256 other = tokenId + 1; other <= ghostMinted; ++other) {
                    if (!tok[other].burned && pool[tok[other].item].contentHash == it.contentHash) {
                        revert("two live works hold one content hash");
                    }
                }
            } else if (!t.released) {
                assertEq(last, tokenId, "a burned work holds its content until released");
                assertEq(registry.consumedItemOf(it.contentHash), it.itemHash, "held");
                assertFalse(registry.isBarred(it.itemHash), "an unreleased item is not barred");
            } else {
                assertTrue(registry.isBarred(it.itemHash), "a released item is barred");
                if (last == tokenId) {
                    assertEq(
                        registry.releasedTo(address(stream), it.contentHash),
                        t.beneficiary,
                        "released content is reserved for its beneficiary"
                    );
                    assertEq(registry.consumedItemOf(it.contentHash), bytes32(0), "released");
                } else if (last > tokenId) {
                    assertEq(
                        stream.workOf(last).artistId,
                        t.beneficiary,
                        "released content is minted again only by its beneficiary"
                    );
                }
            }
        }
    }

    /// @dev 5. Records: the media never change; the record file is the opened one or the
    ///      artist's last `setRecord`, and never changes after finalize; a CC0 work stays CC0
    ///      with the pinned text; locators are append-only.
    function _assertRecords() internal view {
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            if (!t.opened) continue;
            Facts memory f = facts.factsOf(address(stream), tokenId);
            assertEq(keccak256(abi.encode(f.media)), t.mediaDigest, "the media never change");
            assertEq(f.finalized, t.finalized, "finalized exactly when finalize ran");
            assertEq(f.recordFileId, t.recordFileId, "the record file, fixed after finalize");
            if (t.finalized) {
                assertEq(f.renderer, t.pinned, "a finalized work keeps its pinned renderer");
                assertEq(f.rendererCodeHash, t.pinnedCodeHash, "and the pinned code hash");
            }
            if (t.cc0) {
                assertEq(
                    WorksHashing.licenseKey(f.licenseId), WorksHashing.CC0_LICENSE_KEY, "CC0 stays"
                );
                assertEq(f.licenseTextFileId, cc0TextFileId, "CC0 keeps the pinned text");
            }
            Locator[] memory stored =
                delivery.locators(address(stream), tokenId, pool[t.item].fileId);
            Locator[] storage expected = ghostLocators[tokenId];
            assertEq(stored.length, expected.length, "locators are append-only");
            for (uint256 i; i < stored.length; ++i) {
                assertEq(uint8(stored[i].kind), uint8(expected[i].kind), "locator kind");
                assertEq(stored[i].uri, expected[i].uri, "locator URI");
            }
        }
    }

    /// @dev 6. The RENDERER module is the one governance last activated, a pending one keeps
    ///      its time, and a live work is drawn by its pinned renderer once finalized, by the
    ///      module before.
    function _assertRenderers() internal view {
        assertEq(stream.moduleOf(Slots.RENDERER), ghostRenderer, "the RENDERER module");
        assertEq(
            stream.pendingModule(Slots.RENDERER).readyAt,
            ghostRendererReadyAt,
            "a pending module keeps its time"
        );
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            if (t.burned) continue;
            assertEq(
                stream.rendererOf(tokenId),
                t.finalized ? t.pinned : ghostRenderer,
                "a finalized work is drawn by its pinned renderer"
            );
        }
    }

    /// @dev 7. Restraint: a registered party has no active authority exactly while it is frozen
    ///      or a replacement is pending, and nothing its keys try as the artist goes through
    ///      (checked by `restrainedAct`).
    function _assertRestraint() internal view {
        for (uint256 i; i <= ARTISTS; ++i) {
            address account = _party(i);
            if (accounts.artistIdOf(account) == 0) continue;
            uint256 id = uint160(account);
            bool replacing = reservedKey[id] != address(0);
            if (replacing) {
                PendingChange memory p = accounts.pendingChange(id);
                assertTrue(p.kind == ChangeKind.REPLACEMENT, "the replacement is pending");
                assertEq(p.next.root, reservedKey[id], "the reserved key");
            }
            bool restrained = replacing || frozenUntil[id] > block.timestamp;
            assertEq(
                accounts.activeAuthorityOf(id),
                restrained ? address(0) : accounts.authorityOf(id),
                "a party is restrained exactly while frozen or being replaced"
            );
        }
    }

    /// @dev 8. The auction holds exactly the live high bids and the credits.
    function _assertAuctionEth() internal view {
        uint256 owed;
        for (uint256 i; i <= BIDDERS; ++i) {
            owed += auction.claimable(_creditAccount(i));
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

    /// @dev 9. Every credit follows the aged-credit rule: the claimable amount is everything
    ///      credited and not claimed or expired, and its expiry is due one unclaimed period (as
    ///      it stands now) after the waiting money started to wait.
    function _assertCredits() internal view {
        uint256 period = directory.unclaimedPeriod();
        for (uint256 i; i <= BIDDERS; ++i) {
            address account = _creditAccount(i);
            CreditGhost storage g = credit[account];
            assertEq(auction.claimable(account), g.total, "a credit is what was credited");
            assertEq(
                auction.expiresAt(account),
                g.total == 0 ? 0 : g.since + period,
                "a credit's money expires one period after it started to wait"
            );
        }
    }

    /// @dev 10. An unbid work ends with the museum: every work settled without a bid is held by
    ///      the museum, and the museum holds nothing else.
    function _assertMuseum() internal view {
        uint256 unbid;
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            if (!tok[tokenId].unbid) continue;
            assertEq(stream.ownerOf(tokenId), museum, "an unbid work ends with the museum");
            ++unbid;
        }
        assertEq(stream.balanceOf(museum), unbid, "the museum holds only unbid works");
    }
}
