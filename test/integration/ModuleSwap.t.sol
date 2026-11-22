// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { PackageRegistry } from "src/curation/PackageRegistry.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { WorkRules } from "src/records/WorkRules.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { StreamTerms } from "src/terms/StreamTerms.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFederatedMembership } from "src/interfaces/IFederatedMembership.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { Outcome, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IModules, IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { FederatedIntegrationBase } from "./FederatedIntegrationBase.sol";

/// @notice Replacing modules mid-life on the real deployed stack: WorkRules, StreamTerms,
///         Accounts, 6529 Stream's mint policy (a new PackageRegistry through `setStreamPolicy`)
///         and the English auction (a new one added as minter and sale contract) are replaced,
///         each a new instance built with its real constructor, while works exist in every state
///         (sold and finalized, sold and open, unsold at the museum, in a running sale with an
///         outbid credit, federated sold, federated unsold in custody). Tokens (owner, Work
///         facts, royalty), finalized facts and owed money (auction credits, escrow, split vault
///         balances) are unaffected; new behaviour comes only from the new module.
contract ModuleSwapTest is FederatedIntegrationBase {
    /// @dev A token's permanent state, read back before and after a replacement.
    struct TokenState {
        address owner;
        bytes32 itemHash;
        uint256 artistId;
        uint8 outcome;
        address royaltyReceiver;
        uint256 royalty;
        bool finalized;
        address pinned;
    }

    /// @dev Owed money, read back before and after a replacement.
    struct Owed {
        uint256 credit;
        uint256 escrowed;
        uint256 sellerVault;
        uint256 royaltyVault;
        uint256 fedSellerVault;
        uint256 auctionBalance;
        uint256 escrowBalance;
    }

    uint256 internal constant STREAM_SHARE = 25_000;

    address internal artistA;
    address internal fedArtist;
    address internal collector = makeAddr("swapCollector");
    address internal bidderA = makeAddr("swapBidderA");
    address internal bidderB = makeAddr("swapBidderB");
    FederatedStream internal fStream;

    bytes32 internal rootA;
    uint256 internal a1; // sold, finalized
    uint256 internal a2; // sold, record open
    uint256 internal a3; // unsold, at the museum
    uint256 internal a4; // in a running sale, an outbid credit
    uint256 internal sale4;
    uint256 internal f1; // federated, sold
    uint256 internal f2; // federated, unsold in the auction's custody
    uint256 internal fedSale2;
    address internal sellerA;
    address internal royaltyA;
    address internal fedSeller;
    ISplitWallet.Payee[] internal payeesA;

    function setUp() public override {
        super.setUp();
        artistA = _actor("swapArtist");
        fedArtist = _actor("swapFedArtist");
        _populate();
    }

    // ------------------------------------------------------------------ one module at a time

    function test_ModuleSwap_TermsComeOnlyFromTheNewModule() public {
        (TokenState[6] memory before, Owed memory owed) = _snapshot();
        address old = address(terms);
        address next = _newStreamTerms();
        _install(address(stream), Slots.TERMS, next);
        _install(address(editions), Slots.TERMS, next);
        _install(address(directory), Slots.FEDERATED_TERMS, next);
        _assertUnchanged(before, owed);

        // The old module no longer reaches a token; the new one does.
        bytes memory lower = abi.encodeCall(
            StreamTerms.lowerFeeShare,
            (address(stream), a1, sellerA, networkFee, uint32(STREAM_SHARE), 10_000)
        );
        _governExpectRevert(
            old, lower, abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.TERMS, old)
        );
        _asNetwork(next, lower);
        (address receiver,) = stream.royaltyInfo(a1, 1 ether);
        assertEq(receiver, ledger.walletFor(Splits.royaltyPayees(sellerA, networkFee, 10_000), 0));
        (receiver,) = stream.royaltyInfo(a2, 1 ether);
        assertEq(receiver, before[1].royaltyReceiver, "only the work it was asked about");

        bytes memory lowerFed = abi.encodeCall(
            StreamTerms.lowerFeeShare, (address(fStream), f1, fedSeller, networkFee, FED_SHARE, 0)
        );
        _governExpectRevert(
            old, lowerFed, abi.encodeWithSelector(IModuleSlots.NotModule.selector, Slots.TERMS, old)
        );
        _asNetwork(next, lowerFed);
        (receiver,) = fStream.royaltyInfo(f1, 1 ether);
        assertEq(receiver, fedSeller, "a zero share pays the seller vault");
    }

    function test_ModuleSwap_RulesComeOnlyFromTheNewModule() public {
        (TokenState[6] memory before, Owed memory owed) = _snapshot();
        WorkRules old = rules;
        WorkRules next = WorkRules(
            _deployArtifact(
                "WorkRules.sol:WorkRules",
                abi.encode(address(manager), address(facts), address(directory), address(delivery))
            )
        );
        _install(address(stream), Slots.RECORDS, address(next));
        _install(address(directory), Slots.FEDERATED_RECORDS, address(next));
        _assertUnchanged(before, owed);
        assertEq(fStream.moduleOf(Slots.RECORDS), address(next));

        bytes32 state = old.workStateHash(address(stream), a2);
        vm.prank(artistA);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.NotRecordsModule.selector, address(stream), old)
        );
        old.finalize(address(stream), a2, state);

        state = next.workStateHash(address(stream), a2);
        vm.prank(artistA);
        next.finalize(address(stream), a2, state);
        assertTrue(facts.factsOf(address(stream), a2).finalized);
        assertEq(facts.rendererOf(address(stream), a2), address(renderer));
        // The work finalized under the old module stays as it was.
        vm.prank(artistA);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.WorkIsFinalized.selector, address(stream), a1)
        );
        next.finalize(address(stream), a1, bytes32(0));
    }

    function test_ModuleSwap_AccountsComeOnlyFromTheNewModule() public {
        (TokenState[6] memory before, Owed memory owed) = _snapshot();
        Accounts old = accounts;
        Accounts next = _newAccounts(address(registry));
        _asNetwork(address(old), abi.encodeCall(Accounts.freeze, (uint256(uint160(fedArtist)))));
        vm.prank(fedArtist);
        vm.expectRevert(abi.encodeWithSelector(IFederatedMembership.NotArtist.selector, fedArtist));
        fStream.setContractURI("ar://frozen");
        _install(address(directory), Slots.ACCOUNTS, address(next));
        _assertUnchanged(before, owed);

        // Payouts and artist powers are answered by the new module, which does not know these
        // artists yet: the money stays in the vault, owed and unmoved.
        uint256 idA = uint256(uint160(artistA));
        assertEq(old.payoutAddress(idA), artistA, "the old module still knows the artist");
        assertEq(directory.payoutAddress(idA), address(0), "nobody reads the old module");
        vm.prank(artistA);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, idA));
        ledger.release(payeesA, bytes32(0), address(0), 0);
        assertEq(sellerA.balance, owed.sellerVault, "held, not lost");

        // Artist powers are the new module's too: a freeze recorded by the old module no longer
        // reaches the token, and the new module, which has no record of the account, answers
        // for its root address alone (and cannot freeze an account it does not know).
        vm.prank(fedArtist);
        fStream.setContractURI("ar://unfrozen under the new module");
        assertEq(fStream.contractURI(), "ar://unfrozen under the new module");
        bytes memory freeze = abi.encodeCall(Accounts.freeze, (uint256(uint160(fedArtist))));
        _governExpectRevert(
            address(next),
            freeze,
            abi.encodeWithSelector(
                IArtistRegistry.UnknownArtist.selector, uint256(uint160(fedArtist))
            )
        );
    }

    function test_ModuleSwap_TheMintPolicyComesOnlyFromTheNewRegistry() public {
        (TokenState[6] memory before, Owed memory owed) = _snapshot();
        // A package approved under the old registry and not started yet.
        Work[] memory pending = _one(_work(artistA, collectionId));
        bytes32 pendingRoot = _publish(pending);
        bytes memory pendingRequest = _mintData(pendingRoot, pending, 0);

        PackageRegistry next = _installRegistry(address(accounts));
        _assertUnchanged(before, owed);
        assertEq(auction.streamPolicy(), address(next));
        assertEq(auction.policyOf(address(stream)), address(next));

        vm.expectRevert(
            abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, pendingRoot)
        );
        auction.start(address(stream), pendingRequest);

        // A package approved under the new registry starts.
        registry = next;
        Work[] memory works = _one(_work(_actor("newRegistryArtist"), collectionId));
        bytes32 root = _publish(works);
        uint256 tokenId = _sell(root, works, 0, collector, 1 ether);
        assertEq(stream.ownerOf(tokenId), collector);
    }

    function test_ModuleSwap_ANewAuctionMintsWhileTheOldOneFinishes() public {
        (TokenState[6] memory before, Owed memory owed) = _snapshot();
        EnglishAuction old = auction;
        EnglishAuction next = EnglishAuction(payable(_installAuction(address(registry))));
        _assertUnchanged(before, owed);

        // The old auction mints nothing new, finishes its running sale and pays its credits.
        assertFalse(stream.isMinter(address(old)));
        assertFalse(fStream.isMinter(address(old)));
        old.settle(sale4);
        assertEq(stream.ownerOf(a4), bidderB);
        assertEq(uint8(stream.workOf(a4).outcome), uint8(Outcome.SOLD));
        vm.prank(bidderA);
        old.claim(bidderA);
        assertEq(bidderA.balance, owed.credit, "the outbid credit is paid by the old auction");
        // Its unsold federated work can still be offered again there, in the auction that
        // minted it, for as long as the token is served.
        old.restart(fedSale2);

        // New sales run through the new auction only.
        auction = next;
        Work[] memory works = _one(_work(_actor("newAuctionArtist"), collectionId));
        bytes32 root = _publish(works);
        uint256 tokenId = _sell(root, works, 0, collector, 1 ether);
        assertEq(stream.ownerOf(tokenId), collector);
        (,, uint256 fedToken) = _fedApproveAndStart(address(fStream), fedArtist);
        assertEq(fStream.ownerOf(fedToken), address(next));
        Work memory w = _fedWork(fedArtist);
        _approveFed(address(fStream), fedArtist, w, FED_RATE);
        vm.expectRevert(
            abi.encodeWithSelector(IMintPolicy.NotSaleContract.selector, address(fStream), old)
        );
        _startOn(old, address(fStream), w);
    }

    // ------------------------------------------------------------------ everything at once

    function test_ModuleSwap_EveryModuleReplacedLeavesTokensFactsAndOwedMoney() public {
        (TokenState[6] memory before, Owed memory owed) = _snapshot();

        Accounts nextAccounts = _newAccounts(address(registry));
        address nextTerms = _newStreamTerms();
        address nextRules = _deployArtifact(
            "WorkRules.sol:WorkRules",
            abi.encode(address(manager), address(facts), address(directory), address(delivery))
        );
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.ACCOUNTS, address(nextAccounts)))
        );
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.FEDERATED_TERMS, nextTerms))
        );
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.FEDERATED_RECORDS, nextRules))
        );
        _asNetwork(
            address(stream), abi.encodeCall(IModuleSlots.proposeModule, (Slots.TERMS, nextTerms))
        );
        _asNetwork(
            address(stream), abi.encodeCall(IModuleSlots.proposeModule, (Slots.RECORDS, nextRules))
        );
        _asNetwork(
            address(editions), abi.encodeCall(IModuleSlots.proposeModule, (Slots.TERMS, nextTerms))
        );
        vm.warp(block.timestamp + stream.moduleDelay());
        directory.activateModule(Slots.ACCOUNTS);
        directory.activateModule(Slots.FEDERATED_TERMS);
        directory.activateModule(Slots.FEDERATED_RECORDS);
        stream.activateModule(Slots.TERMS);
        stream.activateModule(Slots.RECORDS);
        editions.activateModule(Slots.TERMS);
        accounts = nextAccounts;
        PackageRegistry nextRegistry = _installRegistry(address(nextAccounts));
        address nextAuction = _installAuction(address(nextRegistry));
        _assertUnchanged(before, owed);

        // The old auction still finishes and pays what it owes.
        auction.settle(sale4);
        vm.prank(bidderA);
        auction.claim(bidderA);
        assertEq(bidderA.balance, owed.credit);
        assertEq(escrow.owed(sellerA, address(0)), owed.escrowed, "the escrow keeps its credit");

        // The artist's money waits in the vault until the new accounts module knows the artist:
        // accepting a package under the new registry registers it there, and the vault pays in
        // full.
        vm.prank(artistA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISplitWallet.PayoutUnresolved.selector, uint256(uint160(artistA))
            )
        );
        ledger.release(payeesA, bytes32(0), address(0), 0);
        registry = nextRegistry;
        auction = EnglishAuction(payable(nextAuction));
        Work[] memory works = _one(_work(artistA, collectionId));
        bytes32 root = _publish(works);
        assertEq(directory.payoutAddress(uint256(uint160(artistA))), artistA);
        uint256 vault = sellerA.balance;
        ledger.createWallet(payeesA, bytes32(0)); // anyone deploys the vault
        vm.prank(artistA);
        ledger.release(payeesA, bytes32(0), address(0), 0);
        assertEq(artistA.balance, vault, "every wei the vault held");
        nextMoveNonce[uint256(uint160(artistA))] = 0;
        uint256 tokenId = _sell(root, works, 0, collector, 1 ether);
        assertEq(stream.ownerOf(tokenId), collector);
        assertEq(stream.moduleOf(Slots.TERMS), nextTerms);
        assertEq(stream.moduleOf(Slots.RECORDS), nextRules);
    }

    // ------------------------------------------------------------------ setup

    /// @dev Works in every state, money owed in every place.
    function _populate() internal {
        Work[] memory works = new Work[](4);
        for (uint256 i; i < 4; ++i) {
            works[i] = _work(artistA, collectionId);
        }
        rootA = _publish(works);
        a1 = _sell(rootA, works, 0, collector, 1 ether);
        _open(a1, works[0]);
        bytes32 state = rules.workStateHash(address(stream), a1);
        vm.prank(artistA);
        rules.finalize(address(stream), a1, state);
        a2 = _sell(rootA, works, 1, collector, 2 ether);
        _open(a2, works[1]);
        uint256 sale3;
        (sale3, a3) = _start(rootA, works, 2);
        _settleAtEnd(sale3);
        (sale4, a4) = _start(rootA, works, 3);
        _ethBid(sale4, bidderA, 1 ether);
        _ethBid(sale4, bidderB, 2 ether);

        for (uint256 i; i < works[0].item.payees.length; ++i) {
            payeesA.push(works[0].item.payees[i]);
        }
        sellerA = ledger.walletFor(works[0].item.payees, bytes32(0));
        royaltyA = ledger.walletFor(
            Splits.royaltyPayees(sellerA, networkFee, uint32(STREAM_SHARE)), bytes32(0)
        );
        vm.deal(address(this), 1 ether);
        escrow.depositETH{ value: 0.3 ether }(sellerA);
        vm.deal(royaltyA, 0.2 ether); // a marketplace paid royalties

        (fStream,) = _listPair(fedArtist);
        Work memory fw;
        uint256 fedSale1;
        (fw, fedSale1, f1) = _fedApproveAndStart(address(fStream), fedArtist);
        _ethBid(fedSale1, collector, 1 ether);
        _settleAtEnd(fedSale1);
        fedSeller = ledger.walletFor(fw.item.payees, bytes32(0));
        (, fedSale2, f2) = _fedApproveAndStart(address(fStream), fedArtist);
        _settleAtEnd(fedSale2);

        assertEq(stream.ownerOf(a3), museum);
        assertEq(fStream.ownerOf(f2), address(auction));
        assertTrue(facts.factsOf(address(stream), a1).finalized);
    }

    function _tokenState(address token, uint256 id) internal view returns (TokenState memory s) {
        FederatedStream t = FederatedStream(token);
        s.owner = t.ownerOf(id);
        s.itemHash = t.workOf(id).itemHash;
        s.artistId = t.workOf(id).artistId;
        s.outcome = uint8(t.workOf(id).outcome);
        (s.royaltyReceiver, s.royalty) = t.royaltyInfo(id, 1 ether);
        s.finalized = facts.factsOf(token, id).finalized;
        s.pinned = facts.rendererOf(token, id);
    }

    function _snapshot() internal view returns (TokenState[6] memory s, Owed memory o) {
        s[0] = _tokenState(address(stream), a1);
        s[1] = _tokenState(address(stream), a2);
        s[2] = _tokenState(address(stream), a3);
        s[3] = _tokenState(address(stream), a4);
        s[4] = _tokenState(address(fStream), f1);
        s[5] = _tokenState(address(fStream), f2);
        o.credit = auction.claimable(bidderA);
        o.escrowed = escrow.owed(sellerA, address(0));
        o.sellerVault = sellerA.balance;
        o.royaltyVault = royaltyA.balance;
        o.fedSellerVault = fedSeller.balance;
        o.auctionBalance = address(auction).balance;
        o.escrowBalance = address(escrow).balance;
        assertEq(o.credit, 1 ether);
        assertGt(o.sellerVault, 0);
        assertGt(o.fedSellerVault, 0);
        assertEq(o.escrowed, 0.3 ether);
    }

    function _assertUnchanged(TokenState[6] memory before, Owed memory owed) internal view {
        (TokenState[6] memory nowState, Owed memory nowOwed) = _snapshot();
        for (uint256 i; i < 6; ++i) {
            assertEq(nowState[i].owner, before[i].owner, "owner");
            assertEq(nowState[i].itemHash, before[i].itemHash, "item hash");
            assertEq(nowState[i].artistId, before[i].artistId, "artist");
            assertEq(nowState[i].outcome, before[i].outcome, "outcome");
            assertEq(nowState[i].royaltyReceiver, before[i].royaltyReceiver, "royalty receiver");
            assertEq(nowState[i].royalty, before[i].royalty, "royalty");
            assertEq(nowState[i].finalized, before[i].finalized, "finalized");
            assertEq(nowState[i].pinned, before[i].pinned, "pinned renderer");
        }
        assertEq(keccak256(abi.encode(nowOwed)), keccak256(abi.encode(owed)), "owed money");
    }

    // ------------------------------------------------------------------ replacements

    /// @dev The network announces `module` in `slot` of `target`, waits `moduleDelay` and anyone
    ///      installs it.
    function _install(address target, bytes32 slot, address module) internal {
        _asNetwork(target, abi.encodeCall(IModuleSlots.proposeModule, (slot, module)));
        vm.warp(block.timestamp + IModuleSlots(target).moduleDelay());
        IModuleSlots(target).activateModule(slot);
        assertEq(IModuleSlots(target).moduleOf(slot), module);
    }

    function _newAccounts(address packageRegistry) internal returns (Accounts) {
        return Accounts(
            _deployArtifact(
                "Accounts.sol:Accounts",
                abi.encode(
                    address(manager),
                    address(consolidation),
                    address(consolidation).codehash,
                    address(directory),
                    address(stream),
                    address(editions),
                    address(ledger),
                    address(statements),
                    packageRegistry
                )
            )
        );
    }

    /// @dev A new PackageRegistry (its genesis constructor arguments; it reads the accounts
    ///      module from the Directory), bound to Stream, named by `accountsModule` and set as the
    ///      auction's 6529 Stream policy, each at its role's delay.
    function _installRegistry(address accountsModule) internal returns (PackageRegistry next) {
        next = PackageRegistry(
            _deployArtifact(
                "PackageRegistry.sol:PackageRegistry",
                abi.encode(
                    address(manager),
                    address(verifier),
                    address(verifier).codehash,
                    address(directory),
                    address(economics),
                    address(0),
                    cc0TextFileId
                )
            )
        );
        _asNetwork(address(next), abi.encodeCall(PackageRegistry.bindStream, (address(stream))));
        _asNetwork(
            accountsModule,
            abi.encodeCall(
                Accounts.setPackageRegistry,
                (Accounts(accountsModule).packageRegistry(), address(next))
            )
        );
        _asNetwork(
            address(auction),
            abi.encodeCall(EnglishAuction.setStreamPolicy, (address(registry), address(next)))
        );
    }

    /// @dev A new EnglishAuction (genesis constructor arguments, `policy` for 6529 Stream) added
    ///      as Stream's minter and the federation's sale contract; the old one removed from both.
    function _installAuction(address policy) internal returns (address next) {
        next = _newEnglishAuction(policy);
        _asNetwork(address(stream), abi.encodeCall(IModules.addMinter, (next)));
        _asNetwork(
            address(federation),
            abi.encodeCall(federation.setAdapter, (next, IFederationRegistry.Form.ERC721, true))
        );
        vm.warp(stream.minterOf(next).activeFrom);
        _asNetwork(address(stream), abi.encodeCall(IModules.removeMinter, (address(auction))));
        _asNetwork(
            address(federation),
            abi.encodeCall(
                federation.setAdapter, (address(auction), IFederationRegistry.Form.ERC721, false)
            )
        );
        assertTrue(stream.isMinter(next));
        assertTrue(fStream.isMinter(next));
    }

    function _startOn(EnglishAuction on, address token, Work memory w) internal {
        on.start(token, _fedRequest(w, new bytes[](0)));
    }
}
