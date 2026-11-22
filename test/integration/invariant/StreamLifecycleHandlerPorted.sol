// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { Facts, Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { ArtistIdentity, ChangeKind } from "src/interfaces/types/IdentityTypes.sol";
import { License, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { ContentAddresses } from "../../helpers/ContentAddresses.sol";
import { IntegrationBase } from "../IntegrationBase.sol";

/// @notice A bidder and recipient that reverts, burns its gas or re-enters the auction when it
///         receives ETH or a work, as the handler sets it.
contract LifecycleHostile {
    enum Behaviour {
        REVERT,
        BURN_GAS,
        REENTER
    }

    Behaviour public onEth;
    Behaviour public onToken;
    address public target;
    bytes public reentry;
    bool public reentered;
    bool public reentryOk;
    bytes public reentryResult;

    function configure(Behaviour eth, Behaviour token) external {
        (onEth, onToken) = (eth, token);
    }

    function arm(address target_, bytes calldata data) external {
        (target, reentry, reentered, reentryOk) = (target_, data, false, false);
        delete reentryResult;
    }

    function execute(address to, uint256 value, bytes calldata data)
        external
        returns (bytes memory)
    {
        (bool ok, bytes memory result) = to.call{ value: value }(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }

    receive() external payable {
        _react(onEth);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        _react(onToken);
        return this.onERC721Received.selector;
    }

    function _react(Behaviour b) private {
        if (b == Behaviour.REVERT) revert("hostile");
        if (b == Behaviour.BURN_GAS) {
            uint256 x;
            while (true) {
                ++x;
            }
        }
        reentered = true;
        (reentryOk, reentryResult) = target.call(reentry);
    }
}

/// @notice The handler of the Stream lifecycle invariant suite, re-ported from the retired
///         `StreamLifecycleHandler` onto the deployed plain-core stack (`IntegrationBase`):
///         6529 Stream, the package registry (its mint policy), `WorkFacts`, `WorkRules`,
///         `WorkDelivery`, the English auction and `Accounts`.
/// @dev The invariant test targets itself (it inherits this contract). Every action is bounded
///      and never reverts (`fail_on_revert`): it finds a subject in the right state from its
///      seed, predicts the outcome from the protocol's rules, runs the call (inside `try` when
///      the prediction is a refusal) and records any disagreement in `violations`.
///
///      Actors: three artists (six works each in one package: CC0, CC-BY with the
///      collaborator, an ARTIST seed, CC0 with the collaborator, and two works copying another
///      artist's media), one collaborator, three ETH bidders, a hostile contract, the genesis
///      holders (curation signer, curator, platform, pauser, network) and the keys that
///      recoveries install. Artist 0's package is approved and accepted in `setUp`, the others
///      by the `register` and `accept` actions.
abstract contract StreamLifecycleHandlerPorted is IntegrationBase {
    uint256 internal constant ARTISTS = 3;
    uint256 internal constant WORKS_PER_ARTIST = 6;
    uint256 internal constant BIDDERS = 3;
    uint256 internal constant SPARE_RECORDS = 3;
    /// @dev Locators each side may add per file (`WorkDelivery.LOCATOR_QUOTA`).
    uint256 internal constant SIDE_QUOTA = 8;

    struct PoolItem {
        bytes32 root;
        uint256 index;
        uint256 lead;
        bool collaborator;
        bytes32 itemHash;
        bytes32 contentHash;
        bytes32 fileId;
        bool cc0;
        uint256 tokenId;
    }

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
        bytes32 recordFileId;
        bytes32 mediaDigest;
        uint8 artistLocators;
        uint8 platformLocators;
        bool unbid;
    }

    struct StartCase {
        uint256 leadId;
        uint256 nonce;
        bool restrained;
        bool revoked;
        bool paused;
        bool reconsume;
        uint256 reservedFor;
        bool expected;
    }

    address[ARTISTS] internal lcArtists;
    address internal lcCollaborator;
    address[BIDDERS] internal lcBidders;
    LifecycleHostile internal lcHostile;
    address[] internal holders;
    PoolItem[] internal pool;
    bytes32[ARTISTS] internal packageOf;
    bytes32[] internal spareRecords;
    bytes32 internal byTextFileId;
    mapping(bytes32 contentHash => address) internal rightfulOf;

    mapping(uint256 tokenId => TokenGhost) internal tok;
    mapping(uint256 tokenId => Locator[]) internal ghostLocators;
    uint256 internal ghostMinted;
    uint256 internal ghostBurned;
    uint256 internal ghostEthIn;
    uint256 internal ghostEthOut;
    /// @dev The key a pending recovery would install, by artist ID.
    mapping(uint256 artistId => address) internal reservedKey;
    uint256 internal recoveries;
    uint256 internal locatorNonce;
    string[] internal violations;
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
        lcHostile = new LifecycleHostile();
        holders.push(address(lcHostile));
        holders.push(address(auction));
        holders.push(museum);
        byTextFileId = _storeText("Creative Commons Attribution 4.0 (fixture)", "text/plain");
        for (uint256 i; i < SPARE_RECORDS; ++i) {
            spareRecords.push(_record(string.concat("Spare record ", vm.toString(i))));
        }
        Work[][] memory packages = new Work[][](ARTISTS);
        for (uint256 i; i < ARTISTS; ++i) {
            packages[i] = _artistWorks(i);
        }
        // Work 4 of each artist copies work 0 of the artist before it, work 5 work 0 of the
        // artist after it: same media and content hash, another record and item.
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
        for (uint256 i; i < BIDDERS; ++i) {
            vm.deal(lcBidders[i], 1_000 ether);
        }
    }

    // ------------------------------------------------------------------ setup helpers

    function _artistWorks(uint256 i) internal returns (Work[] memory works) {
        address lead = lcArtists[i];
        works = new Work[](WORKS_PER_ARTIST);
        for (uint256 j; j < WORKS_PER_ARTIST; ++j) {
            works[j] = _work(lead, collectionId);
        }
        works[1] = _withCollaborator(works[1], lcCollaborator, 30_000);
        works[1].item.license = License("CC-BY-4.0", byTextFileId);
        works[2].item.seedPolicy = uint8(SeedPolicy.ARTIST);
        works[2].item.seed = keccak256(abi.encode("artist seed", i));
        works[3] = _withCollaborator(works[3], lcCollaborator, 50_000);
    }

    function _addPackage(uint256 lead, Work[] memory works) internal {
        bytes32 root = _rootOf(works);
        packageOf[lead] = root;
        _keep(root, works);
        for (uint256 j; j < works.length; ++j) {
            pool.push(
                PoolItem(
                    root,
                    j,
                    lead,
                    works[j].item.parties.length > 1,
                    WorksHashing.itemHash(works[j].item),
                    works[j].item.contentHash,
                    works[j].media[0].fileId,
                    keccak256(bytes(works[j].item.license.spdxId)) == keccak256("CC0-1.0"),
                    0
                )
            );
        }
    }

    // ------------------------------------------------------------------ actions: packages

    /// @notice The curation signer approves another artist's package (refused twice).
    function register(uint256 seed) external {
        bytes32 root = packageOf[seed % ARTISTS];
        if (_approved(root)) {
            bytes memory signature = _sign(
                signer1,
                verifier.approvalDigest(root, _evidence(root), verifier.signerEpoch(signer1))
            );
            try registry.registerPackage(root, _evidence(root), abi.encode(signer1, signature)) {
                _violation("a package was registered twice");
            } catch {
                ++hits["registerRefused"];
            }
            return;
        }
        _approve(root);
        ++hits["register"];
    }

    /// @notice A party of an approved package accepts it (registering its account on first
    ///         acceptance); a restrained artist's acceptance is refused.
    function accept(uint256 seed, uint256 partySeed) external {
        uint256 lead = seed % ARTISTS;
        bytes32 root = packageOf[lead];
        if (!_approved(root)) return;
        address party = partySeed % 2 == 0 ? lcArtists[lead] : lcCollaborator;
        if (registry.acceptedAs(root, party) != 0) return;
        uint256 id = accounts.artistIdOf(party);
        if (id != 0 && _restrained(id)) {
            try this.acceptAs(root, party) {
                _violation("a restrained account accepted");
            } catch {
                ++hits["restrainedAccept"];
            }
            return;
        }
        _accept(root, party);
        ++hits["accept"];
    }

    /// @dev External so the handler can catch its refusal.
    function acceptAs(bytes32 root, address party) external {
        require(msg.sender == address(this), "self only");
        _accept(root, party);
    }

    // ------------------------------------------------------------------ actions: the auction

    /// @notice Moves an approved, accepted item to Stream and starts its auction (a third of the
    ///         time with a first bid). Refusals are predicted: content a work holds, a burned
    ///         item's content not released to its lead, a barred item, a restrained lead, a
    ///         revoked move, or the starts paused.
    function start(uint256 seed, uint256 bidSeed) external {
        (bool found, uint256 p) = _startable(seed);
        if (!found) {
            _startConsumed(seed);
            return;
        }
        StartCase memory c = _startCase(p, bidSeed);
        PoolItem storage it = pool[p];
        bytes memory data = _mintDataSignedBy(
            it.root, _package(it.root), it.index, accounts.authorityOf(c.leadId), c.nonce
        );
        (bool ok, uint256 saleId, uint256 paid) = _startAuction(data, bidSeed);
        if (ok != c.expected) {
            _violation(ok ? "a start succeeded that the rules refuse" : "a valid start failed");
        }
        if (!ok) {
            if (c.paused) ++hits["pausedStart"];
            else if (c.restrained) ++hits["restrainedStart"];
            else if (c.revoked) ++hits["revokedMove"];
            else if (c.reservedFor != 0 && c.reservedFor != c.leadId) ++hits["reserved"];
            else ++hits["contentUsed"];
            return;
        }
        if (c.reconsume) ++hits["reconsume"];
        _minted(p, saleId, paid);
    }

    /// @dev A start's subject and its predicted outcome; one time in seven the lead revokes
    ///      the move's nonce first.
    function _startCase(uint256 p, uint256 bidSeed) internal returns (StartCase memory c) {
        PoolItem storage it = pool[p];
        c.leadId = accounts.artistIdOf(lcArtists[it.lead]);
        c.restrained = _restrained(c.leadId);
        c.revoked = !c.restrained && bidSeed % 7 == 1;
        c.nonce = nextMoveNonce[c.leadId]++;
        if (c.revoked) {
            vm.prank(accounts.authorityOf(c.leadId));
            registry.revokeMove(c.leadId, c.nonce);
        }
        c.paused = auction.paused();
        c.reconsume = stream.tokenOfContent(it.contentHash) != 0;
        c.reservedFor = registry.releasedTo(address(stream), it.contentHash);
        c.expected = _contentFree(it, c.leadId) && !c.restrained && !c.revoked && !c.paused;
    }

    /// @notice A bidder outbids the high bid of a live auction.
    function bid(uint256 seed, uint256 bidderSeed, uint256 amountSeed) external {
        (bool found, uint256 tokenId) = _sale(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found) return;
        uint256 saleId = tok[tokenId].saleId;
        uint256 minimum = auction.minimumBid(saleId);
        uint256 amount = _bound(amountSeed, minimum, minimum + 3 ether);
        address bidder = lcBidders[bidderSeed % BIDDERS];
        vm.prank(bidder);
        auction.bid{ value: amount }(saleId, address(0));
        ghostEthIn += amount;
        ++hits["bid"];
        if (auction.paused()) ++hits["pausedBid"];
    }

    /// @notice Settles an ended auction (a quarter of the time warping a live one to its end):
    ///         the winner receives the work (the hostile recipient may refuse it: pending), or
    ///         the museum when nobody bid, at once, even while the artist is restrained.
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
        bool restrained = _restrained(stream.workOf(tokenId).artistId);
        if (a.recipient == address(lcHostile)) _armHostileReentry();
        try auction.settle(t.saleId) {
            if (auction.paused()) ++hits["pausedSettle"];
            if (a.bidder != address(0)) {
                ghostEthOut += a.bid;
                t.owner = a.recipient;
                if (auction.pendingDelivery(t.saleId) != address(0)) {
                    if (a.recipient != address(lcHostile)) _violation("a delivery failed");
                    t.owner = address(auction);
                    ++hits["deliveryPending"];
                } else if (a.recipient == address(lcHostile)) {
                    if (!_reentryRefusedByGuard()) {
                        _violation("a delivery's re-entry was not refused by the guard");
                    }
                    ++hits["hostileReceived"];
                }
            } else {
                t.owner = museum;
                t.unbid = true;
                ++hits[restrained ? bytes32("restrainedMuseum") : bytes32("museum")];
            }
            ++hits["settle"];
        } catch {
            _violation("a settlement failed");
        }
    }

    /// @notice A pauser pauses a live auction for a dispute, a copied work's first; a second
    ///         pause of the same auction is refused.
    function disputePause(uint256 seed) external {
        (bool found, uint256 tokenId) = _copyOnSale(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found) (found, tokenId) = _sale(seed, IEnglishAuction.AuctionState.ACTIVE);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        bytes32 ref = keccak256(abi.encode("lifecycle dispute", tokenId));
        vm.prank(pauser1);
        if (t.pauseUsed) {
            try auction.pause(t.saleId, ref) {
                _violation("an auction was paused twice");
            } catch {
                ++hits["pauseExhausted"];
            }
            return;
        }
        auction.pause(t.saleId, ref);
        t.pauseUsed = true;
        ++hits["disputePause"];
    }

    /// @notice Decides a paused auction's dispute: upheld for a copied work (PLATFORM records
    ///         the outcome and the network cancels: the bid is credited back and the work
    ///         burned), rejected for an original (the high bidder may withdraw; the network
    ///         resumes).
    function resolveDispute(uint256 seed, uint256 mode) external {
        (bool found, uint256 tokenId) = _copyOnSale(seed, IEnglishAuction.AuctionState.PAUSED);
        if (!found) (found, tokenId) = _sale(seed, IEnglishAuction.AuctionState.PAUSED);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        IEnglishAuction.Auction memory a = auction.auction(t.saleId);
        if (_isCopy(t.item)) {
            bytes32 outcome = _platformStatement(
                address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://lifecycle-outcome"
            );
            vm.prank(network);
            auction.cancel(t.saleId, outcome);
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
        vm.prank(network);
        auction.resume(t.saleId);
        ++hits["resume"];
    }

    /// @notice The governed (24 hours) `releaseContent` of a burned copy's content to its
    ///         rightful artist, once registered; another artist's copy then races for it and is
    ///         refused.
    function releaseContent(uint256 seed, uint256) external {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            TokenGhost storage t = tok[tokenId];
            if (!t.burned || t.released) continue;
            bytes32 contentHash = pool[t.item].contentHash;
            uint256 beneficiary = accounts.artistIdOf(rightfulOf[contentHash]);
            if (beneficiary == 0 || stream.tokenOfContent(contentHash) != tokenId) continue;
            _govern(
                network,
                address(registry),
                abi.encodeCall(
                    IMintPolicy.releaseContent, (address(stream), tokenId, contentHash, beneficiary)
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
            uint256 leadId = accounts.artistIdOf(lcArtists[it.lead]);
            if (it.contentHash != contentHash || leadId == beneficiary || !_ready(p)) continue;
            if (_restrained(leadId) || registry.isBarred(it.itemHash)) continue;
            bytes memory data = _mintDataSignedBy(
                it.root,
                _package(it.root),
                it.index,
                accounts.authorityOf(leadId),
                nextMoveNonce[leadId]++
            );
            try auction.start(address(stream), data) {
                _violation("released content was taken by another artist");
            } catch (bytes memory reason) {
                if (bytes4(reason) != IMintPolicy.ContentReserved.selector) {
                    _violation("a racing copy failed for another reason");
                }
                ++hits["reserved"];
            }
            return;
        }
    }

    /// @notice The owner of a delivered work transfers it to another holder.
    function transfer(uint256 seed, uint256 toSeed) external {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            TokenGhost storage t = tok[tokenId];
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
    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + _bound(secondsSeed, 1 minutes, 12 hours));
        ++hits["warp"];
    }

    /// @notice The auction's emergency pause: a pauser pauses (a third of the time it is not
    ///         paused) and the network unpauses at once. Only starts stop.
    function toggleStartPause(uint256 seed) external {
        if (!auction.paused()) {
            if (seed % 3 != 0) return;
            vm.prank(pauser1);
            auction.pause();
            ++hits["startPaused"];
            return;
        }
        vm.prank(network);
        auction.unpause();
        if (auction.paused()) _violation("an unpause did not land");
        ++hits["startUnpaused"];
    }

    /// @notice The hostile contract outbids for itself, or a bidder names it as the recipient.
    function hostileBid(uint256 seed, uint256 modeSeed, uint256 amountSeed) external {
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
                address(auction), amount, abi.encodeCall(IEnglishAuction.bid, (saleId, hostile))
            );
            ++hits["hostileBid"];
        } else {
            address bidder = lcBidders[(modeSeed >> 8) % BIDDERS];
            vm.prank(bidder);
            auction.bid{ value: amount }(saleId, address(lcHostile));
            ++hits["hostileRecipient"];
        }
        ghostEthIn += amount;
    }

    /// @notice The hostile contract claims its credit, within a bounded gas budget: reverting or
    ///         burning its gas, it keeps the credit (`ClaimFailed`); re-entering, it is refused
    ///         the re-entry and paid.
    function hostileClaim(uint256 modeSeed) external {
        address hostile = address(lcHostile);
        uint256 owed = auction.claimable(hostile);
        if (owed == 0) return;
        _configureHostile(modeSeed);
        bool reenters = lcHostile.onEth() == LifecycleHostile.Behaviour.REENTER;
        try lcHostile.execute{ gas: 2_000_000 }(
            address(auction), 0, abi.encodeCall(IEnglishAuction.claim, (hostile))
        ) {
            if (!reenters) _violation("a refusing receiver was paid");
            if (!_reentryRefusedByGuard()) {
                _violation("a claim's re-entry was not refused by the guard");
            }
            ghostEthOut += owed;
            ++hits["hostileReentryRefused"];
        } catch (bytes memory reason) {
            if (reenters || bytes4(reason) != IEnglishAuction.ClaimFailed.selector) {
                _violation("a claim failed for another reason");
            }
            if (auction.claimable(hostile) != owed) _violation("a credit was lost");
            ++hits["hostileClaimKept"];
        }
    }

    /// @notice A pending delivery (the hostile recipient refused the work) is claimed. A third
    ///         party first routes a claim through the hostile recipient to itself: refused unless
    ///         the hostile is the winning bidder or the redirect delay has passed; then the
    ///         winning bidder claims.
    function claimDelivery(uint256 seed) external {
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
            bytes memory toStranger =
                abi.encodeCall(IEnglishAuction.claimDelivery, (saleId, stranger));
            bool late = block.timestamp >= uint256(a.endTime) + auction.REDIRECT_DELAY();
            if (winner != address(lcHostile) && late) {
                lcHostile.execute(address(auction), 0, toStranger);
                t.owner = stranger;
                ++hits["recipientRedirect"];
            } else if (winner != address(lcHostile)) {
                try lcHostile.execute(address(auction), 0, toStranger) {
                    _violation("a forwarding recipient sent the work elsewhere");
                } catch (bytes memory reason) {
                    if (bytes4(reason) != ISaleAdapter.InvalidRecipient.selector) {
                        _violation("a forwarded claim failed for another reason");
                    }
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

    function _configureHostile(uint256 modeSeed) internal {
        LifecycleHostile.Behaviour[3] memory modes = [
            LifecycleHostile.Behaviour.REVERT,
            LifecycleHostile.Behaviour.BURN_GAS,
            LifecycleHostile.Behaviour.REENTER
        ];
        lcHostile.configure(modes[(modeSeed >> 16) % 3], modes[(modeSeed >> 24) % 3]);
        _armHostileReentry();
    }

    /// @dev Arms the hostile contract's one re-entry: a claim of its own credits.
    function _armHostileReentry() internal {
        lcHostile.arm(address(auction), abi.encodeCall(IEnglishAuction.claim, (address(lcHostile))));
    }

    function _reentryRefusedByGuard() internal view returns (bool) {
        return lcHostile.reentered() && !lcHostile.reentryOk()
            && keccak256(lcHostile.reentryResult())
                == keccak256(
                abi.encodeWithSelector(
                ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
            )
            );
    }

    // ------------------------------------------------------------------ actions: records

    /// @notice Anyone opens a minted work's record from its approved item and media.
    function openRecord(uint256 seed) external {
        (bool found, uint256 tokenId) = _token(seed, false, false);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        PoolItem storage it = pool[t.item];
        Work memory w = _package(it.root)[it.index];
        vm.prank(lcBidders[seed % BIDDERS]);
        facts.open(address(stream), tokenId, w.item, w.media);
        t.opened = true;
        t.mediaDigest = keccak256(abi.encode(facts.factsOf(address(stream), tokenId).media));
        ++hits["openRecord"];
    }

    /// @notice The artist points an open, unfinalized record at another record file.
    function setRecord(uint256 seed, uint256 fileSeed) external {
        (bool found, uint256 tokenId) = _token(seed, true, true);
        if (!found) return;
        address artist = accounts.activeAuthorityOf(stream.workOf(tokenId).artistId);
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        vm.prank(artist);
        rules.setRecord(address(stream), tokenId, spareRecords[fileSeed % SPARE_RECORDS], state);
        ++hits["setRecord"];
    }

    /// @notice The artist finalizes an open record.
    function finalize(uint256 seed) external {
        (bool found, uint256 tokenId) = _token(seed, true, true);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        address artist = accounts.activeAuthorityOf(stream.workOf(tokenId).artistId);
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        vm.prank(artist);
        rules.finalize(address(stream), tokenId, state);
        _finalized(tokenId, t);
        ++hits["finalize"];
    }

    /// @notice The artist (before finalize) or the platform adds an Arweave or IPFS locator to a
    ///         work's primary file; the quotas and the URI rule are predicted, and a URI that is
    ///         not a bare content address is refused.
    function addLocator(uint256 seed, uint256 kindSeed) external {
        (bool found, uint256 tokenId) = _token(seed, true, false);
        if (!found) return;
        TokenGhost storage t = tok[tokenId];
        bytes32 fileId = pool[t.item].fileId;
        address artist = accounts.activeAuthorityOf(stream.workOf(tokenId).artistId);
        bool byArtist = !t.finalized && artist != address(0) && kindSeed % 2 == 0;
        address caller = byArtist ? artist : platform;
        if (kindSeed % 5 == 4) {
            Locator memory bad =
                Locator(LocatorKind.ARWEAVE, string.concat("ar://", vm.toString(kindSeed), "/x"));
            vm.prank(caller);
            try delivery.addLocator(address(stream), tokenId, fileId, bad) {
                _violation("a locator with a path was accepted");
            } catch {
                ++hits["locatorRefused"];
            }
            return;
        }
        uint256 used = byArtist ? t.artistLocators : t.platformLocators;
        uint256 quota = SIDE_QUOTA;
        if (t.finalized) (used, quota) = (t.artistLocators + t.platformLocators, 2 * SIDE_QUOTA);
        Locator memory l = _newLocator(kindSeed >> 8);
        vm.prank(caller);
        try delivery.addLocator(address(stream), tokenId, fileId, l) {
            if (used >= quota) _violation("a locator over the quota was accepted");
            ghostLocators[tokenId].push(l);
            if (byArtist) ++t.artistLocators;
            else ++t.platformLocators;
            ++hits["addLocator"];
        } catch {
            if (used < quota) _violation("a locator within the quota was refused");
            ++hits["locatorRefused"];
        }
    }

    function _newLocator(uint256 kind) internal returns (Locator memory) {
        string memory seed = string.concat("lifecycle locator ", vm.toString(++locatorNonce));
        if (kind % 3 == 0) return ContentAddresses.ar(seed);
        if (kind % 3 == 1) return ContentAddresses.ipfsLocator(seed);
        return Locator(LocatorKind.IPFS, ContentAddresses.ipfsRoot(seed));
    }

    function _finalized(uint256 tokenId, TokenGhost storage t) internal {
        t.finalized = true;
        t.recordFileId = facts.factsOf(address(stream), tokenId).recordFileId;
    }

    // ------------------------------------------------------------------ actions: identity

    /// @notice The network stages a replacement of an artist's root to a fresh key (24 hours
    ///         scheduled): the account is restrained until the replacement ends.
    function stageRecovery(uint256 seed) external {
        uint256 lead = seed % ARTISTS;
        uint256 id = accounts.artistIdOf(lcArtists[lead]);
        if (id == 0 || accounts.pendingChange(id).kind != ChangeKind.NONE) return;
        address next = _actor(string.concat("lifecycleKey", vm.toString(++recoveries)));
        ArtistIdentity memory identity =
            ArtistIdentity(next, next, _profileId(next), _profileDoc(next));
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes memory acceptance = _sign(
            next,
            accounts.replacementDigest(id, identity, keccak256("lifecycle recovery"), deadline)
        );
        _govern(
            network,
            address(accounts),
            abi.encodeCall(
                Accounts.stageReplacement,
                (id, identity, keccak256("lifecycle recovery"), deadline, acceptance)
            )
        );
        reservedKey[id] = next;
        ++hits["stageRecovery"];
    }

    /// @notice Ends a pending recovery: the network withdraws it at once, or it executes at
    ///         the end of its notice.
    function endRecovery(uint256 seed, uint256 mode) external {
        for (uint256 k; k < ARTISTS; ++k) {
            uint256 id = accounts.artistIdOf(lcArtists[(seed % ARTISTS + k) % ARTISTS]);
            if (id == 0 || reservedKey[id] == address(0)) continue;
            if (mode % 2 == 0) {
                vm.prank(network);
                accounts.cancelReplacement(id);
                ++hits["veto"];
            } else {
                uint256 at = accounts.pendingChange(id).executableAt;
                if (block.timestamp < at) vm.warp(at);
                accounts.executeChange(id);
                if (accounts.authorityOf(id) != reservedKey[id]) {
                    _violation("a recovery installed another key");
                }
                ++hits["recovered"];
            }
            delete reservedKey[id];
            return;
        }
    }

    /// @notice While a recovery is pending, the old root or the reserved key tries to act for
    ///         the artist: a start, a record change or a finalize. Nothing an artist alone may
    ///         do goes through; a finalize of a work whose sale has an outcome is anyone's (a
    ///         notice, then due 14 days later).
    function restrainedAct(uint256 seed, uint256 which) external {
        for (uint256 k; k < ARTISTS; ++k) {
            uint256 lead = (seed % ARTISTS + k) % ARTISTS;
            uint256 id = accounts.artistIdOf(lcArtists[lead]);
            if (id == 0 || reservedKey[id] == address(0)) continue;
            address actor = which % 2 == 0 ? accounts.authorityOf(id) : reservedKey[id];
            uint256 power = (which >> 1) % 3;
            if (power == 0) _restrainedStart(lead, id, actor);
            else _restrainedRecord(lead, id, actor, power == 2, seed);
            return;
        }
    }

    function _restrainedStart(uint256 lead, uint256 id, address actor) internal {
        for (uint256 p; p < pool.length; ++p) {
            if (pool[p].lead != lead || !_ready(p)) continue;
            PoolItem storage it = pool[p];
            bytes memory data =
                _mintDataSignedBy(it.root, _package(it.root), it.index, actor, nextMoveNonce[id]++);
            try auction.start(address(stream), data) {
                _violation("a restrained artist's key started a sale");
            } catch {
                ++hits["restrainedAct"];
            }
            return;
        }
    }

    function _restrainedRecord(uint256 lead, uint256 id, address actor, bool fin, uint256 seed)
        internal
    {
        for (uint256 k; k < ghostMinted; ++k) {
            uint256 tokenId = (seed % ghostMinted + k) % ghostMinted + 1;
            TokenGhost storage t = tok[tokenId];
            if (t.burned || !t.opened || t.finalized || pool[t.item].lead != lead) continue;
            bytes32 state = rules.workStateHash(address(stream), tokenId);
            if (!fin) {
                vm.prank(actor);
                try rules.setRecord(address(stream), tokenId, spareRecords[seed % 3], state) {
                    _violation("a restrained artist's key changed a record");
                } catch {
                    ++hits["restrainedAct"];
                }
                return;
            }
            bool outcome = stream.workOf(tokenId).outcome != Outcome.NONE;
            uint256 notice = rules.finalizeNoticeAt(address(stream), tokenId);
            bool due = notice != 0 && block.timestamp >= notice + FINALIZE_NOTICE;
            vm.prank(actor);
            try rules.finalize(address(stream), tokenId, state) {
                if (!outcome) _violation("a restrained key finalized an unsold work");
                if (due) {
                    _finalized(tokenId, t);
                    ++hits["dueFinalize"];
                } else if (rules.finalizeNoticeAt(address(stream), tokenId) == 0) {
                    _violation("a finalize by a stranger recorded nothing");
                } else {
                    ++hits["finalizeNotice"];
                }
            } catch {
                if (outcome && (notice == 0 || due)) _violation("an open finalize was refused");
                ++hits["restrainedAct"];
            }
            id;
            return;
        }
    }

    // ------------------------------------------------------------------ helpers

    function _violation(string memory what) internal {
        violations.push(what);
    }

    function _approved(bytes32 root) internal view returns (bool) {
        (IPackageRegistry.PackageStatus status,,) = registry.packageOf(root);
        return status == IPackageRegistry.PackageStatus.APPROVED;
    }

    function _restrained(uint256 artistId) internal view returns (bool) {
        return artistId != 0 && accounts.activeAuthorityOf(artistId) == address(0);
    }

    /// @dev Item `p` is not minted, and its package is approved and accepted by its parties.
    function _ready(uint256 p) internal view returns (bool) {
        PoolItem storage it = pool[p];
        return it.tokenId == 0 && _approved(it.root)
            && registry.acceptedAs(it.root, lcArtists[it.lead]) != 0
            && (!it.collaborator || registry.acceptedAs(it.root, lcCollaborator) != 0);
    }

    /// @dev The first ready item from `seed`; an item whose released content is reserved for
    ///      its own lead comes first.
    function _startable(uint256 seed) internal view returns (bool, uint256) {
        for (uint256 pass; pass < 2; ++pass) {
            for (uint256 k; k < pool.length; ++k) {
                uint256 p = (seed % pool.length + k) % pool.length;
                if (!_ready(p)) continue;
                if (pass == 1) return (true, p);
                PoolItem storage it = pool[p];
                uint256 to = registry.releasedTo(address(stream), it.contentHash);
                if (to != 0 && to == accounts.artistIdOf(lcArtists[it.lead])) return (true, p);
            }
        }
        return (false, 0);
    }

    /// @dev The content rule: free when no token ever held it; a burned token's content only
    ///      when released to this lead and the item is not barred.
    function _contentFree(PoolItem storage it, uint256 leadId) internal view returns (bool) {
        uint256 prior = stream.tokenOfContent(it.contentHash);
        if (prior == 0) return true;
        uint256 to = registry.releasedTo(address(stream), it.contentHash);
        return to != 0 && to == leadId && !registry.isBarred(it.itemHash);
    }

    /// @dev With nothing left to start, a minted item is moved again: refused.
    function _startConsumed(uint256 seed) internal {
        PoolItem storage it = pool[seed % pool.length];
        if (it.tokenId == 0 || auction.paused()) return;
        uint256 leadId = accounts.artistIdOf(lcArtists[it.lead]);
        if (_restrained(leadId)) return;
        bytes memory data = _mintDataSignedBy(
            it.root,
            _package(it.root),
            it.index,
            accounts.authorityOf(leadId),
            nextMoveNonce[leadId]++
        );
        try auction.start(address(stream), data) {
            _violation("an item was consumed twice");
        } catch {
            ++hits["contentUsed"];
        }
    }

    /// @dev `start`, or a third of the time `startWithBid` with a first ETH bid.
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
        vm.prank(bidder);
        try auction.startWithBid{ value: paid }(address(stream), data, address(0)) returns (
            uint256 id
        ) {
            return (true, id, paid);
        } catch {
            return (false, 0, 0);
        }
    }

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

    function _isCopy(uint256 p) internal view returns (bool) {
        address rightful = rightfulOf[pool[p].contentHash];
        return rightful != address(0) && rightful != lcArtists[pool[p].lead];
    }

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

    /// @dev The first live token from `seed` whose record is open (or not); with `amendable`,
    ///      also unfinalized with an active artist.
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

    // ------------------------------------------------------------------ the invariants

    function _assertLifecycle() internal view {
        assertEq(violations.length, 0, violations.length == 0 ? "" : violations[0]);
        _assertOwnership();
        _assertIds();
        _assertContent();
        _assertRecords();
        _assertRestraint();
        _assertAuctionEth();
        _assertMuseum();
    }

    /// @dev An unbid work ends with the museum, and the museum holds nothing else.
    function _assertMuseum() internal view {
        uint256 unbid;
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            if (!tok[tokenId].unbid) continue;
            assertEq(stream.ownerOf(tokenId), museum, "an unbid work ends with the museum");
            assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.UNSOLD));
            ++unbid;
        }
        assertEq(stream.balanceOf(museum), unbid, "the museum holds only unbid works");
    }

    /// @dev Every token has one known owner, in auction custody exactly while its sale is
    ///      unsettled or its delivery pending, with an outcome exactly once settled.
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
            assertEq(
                stream.workOf(tokenId).outcome != Outcome.NONE, settled, "an outcome once settled"
            );
        }
    }

    /// @dev IDs run from 1 without gaps, each assigned once to one item, never reused.
    function _assertIds() internal view {
        assertEq(stream.totalMinted(), ghostMinted, "every start assigned one new ID");
        assertEq(stream.totalSupply(), ghostMinted - ghostBurned, "supply is minted minus burned");
        assertEq(stream.totalBurned(), ghostBurned);
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            assertEq(pool[t.item].tokenId, tokenId, "one item, one token ID");
            assertEq(
                stream.workOf(tokenId).itemHash, pool[t.item].itemHash, "a token keeps its item"
            );
        }
    }

    /// @dev A content hash is held by at most one work: a live work holds its own; a burned
    ///      work holds it until released; a released item is barred and its content consumed
    ///      again only by the release's beneficiary.
    function _assertContent() internal view {
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            PoolItem storage it = pool[t.item];
            bytes32 holder = registry.consumedItemOf(it.contentHash);
            if (!t.burned) {
                assertEq(holder, it.itemHash, "a live work holds its content hash");
                assertEq(stream.tokenOfContent(it.contentHash), tokenId);
            } else if (!t.released) {
                assertEq(holder, it.itemHash, "a burned work holds its content until released");
            } else {
                assertTrue(registry.isBarred(it.itemHash), "a released item is barred");
                assertTrue(holder != it.itemHash, "a released item no longer holds its content");
                if (holder != 0) {
                    uint256 p = _itemIndex(holder);
                    assertEq(
                        accounts.artistIdOf(lcArtists[pool[p].lead]),
                        t.beneficiary,
                        "released content is consumed only by its beneficiary"
                    );
                }
            }
        }
    }

    /// @dev Media fixed at open; a finalized record keeps its file; a CC0 work stays CC0 with
    ///      the deployment's text; locators are append-only.
    function _assertRecords() internal view {
        for (uint256 tokenId = 1; tokenId <= ghostMinted; ++tokenId) {
            TokenGhost storage t = tok[tokenId];
            if (!t.opened || t.burned) continue;
            Facts memory f = facts.factsOf(address(stream), tokenId);
            assertEq(keccak256(abi.encode(f.media)), t.mediaDigest, "the media never change");
            assertEq(f.finalized, t.finalized, "finalized exactly when finalize ran");
            if (t.finalized) {
                assertEq(f.recordFileId, t.recordFileId, "a finalized record keeps its file");
            }
            if (pool[t.item].cc0) {
                assertEq(f.licenseId, "CC0-1.0", "CC0 stays CC0");
                assertEq(f.licenseTextFileId, cc0TextFileId, "CC0 keeps the deployment's text");
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

    /// @dev While a recovery is pending the artist has no active authority.
    function _assertRestraint() internal view {
        for (uint256 i; i < ARTISTS; ++i) {
            uint256 id = accounts.artistIdOf(lcArtists[i]);
            if (id == 0 || reservedKey[id] == address(0)) continue;
            assertTrue(
                accounts.pendingChange(id).kind == ChangeKind.REPLACEMENT, "the recovery is pending"
            );
            assertEq(
                accounts.activeAuthorityOf(id), address(0), "a recovering artist is restrained"
            );
        }
    }

    /// @dev The auction holds exactly the live high bids and the bidders' credits.
    function _assertAuctionEth() internal view {
        uint256 owed;
        for (uint256 i; i < BIDDERS; ++i) {
            owed += auction.claimable(lcBidders[i]);
        }
        owed += auction.claimable(address(lcHostile));
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
