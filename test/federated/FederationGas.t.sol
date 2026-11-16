// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { FederatedEditionAuction } from "src/federated/FederatedEditionAuction.sol";
import { FederatedEditionAuctionLens } from "src/federated/FederatedEditionAuctionLens.sol";
import { FederatedDeployer } from "src/federated/FederatedDeployer.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IFederatedEditions } from "src/interfaces/IFederatedEditions.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { Splits } from "src/economics/Splits.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { StateGrowth } from "../helpers/StateGrowth.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice Federated gas rows (Prague; their own rows and ceilings, ADR 0008 and ADR 0004's
///         table): each template's deployment, joining, approval, starts, bids, settlements and
///         the pair's edition sale. Each asserts its exact new slots and accounts and a ceiling.
///         Glamsterdam figures are estimates from ADR 0004's unit prices (the ADR shows the
///         arithmetic); Foundry cannot measure them.
contract FederationGasTest is FederationBase {
    uint256 internal constant DEPLOY_721_CEILING = 5_500_000;
    uint256 internal constant DEPLOY_1155_CEILING = 3_870_000;
    uint256 internal constant JOIN_CEILING = 345_000;
    uint256 internal constant APPROVE_CEILING = 61_000;
    uint256 internal constant FIRST_START_CEILING = 700_000;
    uint256 internal constant STEADY_START_CEILING = 425_000;
    uint256 internal constant BID_CEILING = 196_000;
    uint256 internal constant SETTLE_SOLD_CEILING = 182_000;
    uint256 internal constant SETTLE_UNBID_CEILING = 156_000;
    uint256 internal constant RESTART_CEILING = 253_000;
    uint256 internal constant EDITION_OPEN_CEILING = 380_000;
    uint256 internal constant CREATE_EDITION_CEILING = 90_000;
    uint256 internal constant EDITION_SETTLE_CEILING = 162_000;

    FederatedEditionAuction internal fea;
    FederatedEditionAuctionLens internal feaLens;
    FederatedStream internal ps;
    FederatedEditions internal pe;
    address internal collector = makeAddr("gasCollector");

    function setUp() public override {
        super.setUp();
        feaLens = new FederatedEditionAuctionLens(
            address(auction), address(escrow), address(artists), address(economics)
        );
        fea = new FederatedEditionAuction(
            address(manager),
            address(escrow),
            address(auction),
            address(feaLens),
            address(feaLens).codehash,
            DeployV1.editionAuctionDefaults(),
            DeployV1.editionAuctionLimits()
        );
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(fea), true))
        );
        // A join asks the template's deployer whether it recorded the copy.
        _extra.push(address(deployment.federatedStreamDeployer));
    }

    address[] internal _extra;

    function _probeSet() internal override returns (address[] memory accounts) {
        address[] memory base = super._probeSet();
        accounts = new address[](base.length + _extra.length);
        for (uint256 i; i < base.length; ++i) {
            accounts[i] = base[i];
        }
        for (uint256 i; i < _extra.length; ++i) {
            accounts[base.length + i] = _extra[i];
        }
    }

    /// @dev Probes the vaults a work's sale reaches.
    function _probeVaults(Work memory w) internal {
        address seller = splitFactory.walletFor(w.item.payees, 0);
        _extra.push(seller);
        _extra.push(splitFactory.walletFor(Splits.royaltyPayees(seller, networkFee, FED_SHARE), 0));
    }

    function _cooled() internal view override returns (address[] memory all) {
        address[] memory base = super._cooled();
        all = new address[](base.length + 8);
        for (uint256 i; i < base.length; ++i) {
            all[i] = base[i];
        }
        (all[base.length], all[base.length + 1], all[base.length + 2]) =
        (address(fed), address(fedRegistry), address(fea));
        (all[base.length + 3], all[base.length + 4], all[base.length + 5]) =
        (address(feaLens), address(ps), address(pe));
        (all[base.length + 6], all[base.length + 7]) =
        (address(deployment.federatedStreamDeployer), address(deployment.federatedEditionsDeployer));
    }

    // ------------------------------------------------------------------ deployment

    /// @dev Whole-transaction Prague gas of deploying `initcode` (21,000 + 32,000, the calldata,
    ///      EIP-3860's 2 per word, the constructor and the 200-per-byte deposit) and the storage
    ///      slots the constructor wrote.
    function _deploy(bytes memory initcode)
        internal
        returns (address deployed, uint256 total, uint256 slots, uint256 runtime)
    {
        vm.startStateDiffRecording();
        uint256 before = gasleft();
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        uint256 frame = before - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        require(deployed != address(0), "deploy failed");
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != deployed) continue;
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = accesses[i].storageAccesses[j];
                if (s.isWrite && s.previousValue == 0 && s.newValue != 0) ++slots;
            }
        }
        runtime = deployed.code.length;
        // The frame includes CREATE's 32,000 and the 2-per-word initcode charge; add the
        // transaction base and its calldata.
        (uint256 calldataGas,) = _calldataGas(initcode);
        total = 21_000 + calldataGas + frame;
    }

    /// @dev The cold-account surcharge for the template's renderer (EIP-2929: 2,600 cold against
    ///      100 warm, as `_measureGrowth` adds for any account the test warmed). The constructor
    ///      reads the renderer's code hash; `_streamConfig` reads it first, so the measured run
    ///      reaches it warm, while the artist's real transaction reaches it cold (the config is
    ///      built off-chain). Foundry cannot cool an account, so the cost is added: 2,500 when the
    ///      probe, run from a snapshot so it warms nothing, finds the renderer warm.
    function _rendererSurcharge() internal returns (uint256) {
        uint256 snapshot = vm.snapshotState();
        bool warm = _isWarm(address(renderer));
        vm.revertToStateAndDelete(snapshot);
        return warm ? COLD_ACCOUNT_SURCHARGE : 0;
    }

    /// @dev Each deployment row is measured in its own test, before any state-diff recording:
    ///      once a test has recorded, Foundry prices every later access warm, so a second row
    ///      would come out low.
    function test_Gas_DeployFederatedStream() public {
        bytes memory initcode = abi.encodePacked(
            type(FederatedStream).creationCode, abi.encode(_streamConfig(fedArtist))
        );
        uint256 surcharge = _rendererSurcharge();
        (, uint256 total, uint256 slots, uint256 runtime) = _deploy(initcode);
        total += surcharge;
        emit log_named_uint("FederatedStream deploy (tx, Prague)", total);
        emit log_named_uint("FederatedStream runtime bytes", runtime);
        emit log_named_uint("FederatedStream constructor slots", slots);
        // Ten, plus the one collection's name at the `StreamLayout` slot the renderer reads.
        assertEq(slots, 11);
        assertLe(total, DEPLOY_721_CEILING);
    }

    function test_Gas_DeployFederatedEditions() public {
        (, uint256 total, uint256 slots, uint256 runtime) = _deploy(
            abi.encodePacked(
                type(FederatedEditions).creationCode,
                abi.encode(_editionsConfig(fedArtist, address(fed)))
            )
        );
        emit log_named_uint("FederatedEditions deploy (tx, Prague)", total);
        emit log_named_uint("FederatedEditions runtime bytes", runtime);
        emit log_named_uint("FederatedEditions constructor slots", slots);
        assertEq(slots, 8);
        assertLe(total, DEPLOY_1155_CEILING);
    }

    /// @dev Review G (G3): an artist deploys through the template's deployer, which reads the
    ///      creation code from its data contracts (no 25 KB of calldata), CREATE2s it and records
    ///      the copy (one new slot) with an event. The deployer call is measured first, with
    ///      nothing recorded; the plain CREATE of the same initcode follows it, so its
    ///      constructor's accounts are already warm and its figure is a lower bound, which only
    ///      makes the comparison stricter (its own row is `test_Gas_DeployFederatedStream`).
    function test_Gas_DeployStreamThroughItsDeployer() public {
        bytes memory config = abi.encode(_streamConfig(fedArtist));
        FederatedDeployer d = deployment.federatedStreamDeployer;
        uint256 surcharge = _rendererSurcharge();
        (uint256 total,) = _measure(
            fedArtist, address(d), abi.encodeCall(d.deploy, (bytes32(uint256(0x6529)), config)), 0
        );
        total += surcharge;
        emit log_named_uint("FederatedStream deploy, through its deployer (tx, Prague)", total);
        assertLe(total, DEPLOY_721_CEILING);
        (, uint256 direct,,) = _deploy(abi.encodePacked(type(FederatedStream).creationCode, config));
        direct += surcharge;
        assertLt(total, direct, "the deployer path costs less than sending the code");
    }

    /// @dev As `test_Gas_DeployStreamThroughItsDeployer`, for the editions template.
    function test_Gas_DeployEditionsThroughItsDeployer() public {
        bytes memory config = abi.encode(_editionsConfig(fedArtist, address(fed)));
        FederatedDeployer d = deployment.federatedEditionsDeployer;
        (uint256 total,) = _measure(
            fedArtist, address(d), abi.encodeCall(d.deploy, (bytes32(uint256(0x6529)), config)), 0
        );
        emit log_named_uint("FederatedEditions deploy, through its deployer (tx, Prague)", total);
        assertLe(total, DEPLOY_1155_CEILING);
        (, uint256 direct,,) =
            _deploy(abi.encodePacked(type(FederatedEditions).creationCode, config));
        assertLt(total, direct, "the deployer path costs less than sending the code");
    }

    // ------------------------------------------------------------------ the 1/1 path

    function test_Gas_JoinCreatingTheIdentity() public {
        (uint256 total,, StateGrowth.Growth memory g) = _measureGrowth(
            fedArtist,
            address(fed),
            abi.encodeCall(fed.joinFederation, (_joinRequest(address(fed), fedArtist))),
            0
        );
        _row("join, creating the identity", total, g);
        assertEq(g.slots, 7);
        assertLe(total, JOIN_CEILING);
    }

    function test_Gas_ApproveItem() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        (uint256 total,, StateGrowth.Growth memory g) = _measureGrowth(
            fedArtist, address(fed), abi.encodeCall(fed.approveItem, (_itemHash(w), RATE)), 0
        );
        _row("approveItem", total, g);
        assertEq(g.slots, 1);
        assertLe(total, APPROVE_CEILING);
    }

    function test_Gas_FirstStartDeploysTheVaults() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        (uint256 total,, StateGrowth.Growth memory g) = _measureGrowth(
            address(this),
            address(auction),
            abi.encodeCall(auction.start, (address(fed), _mintData(w))),
            0
        );
        _row("federated start, first work (two vaults deployed)", total, g);
        assertEq(g.slots, 18);
        assertEq(g.accounts, 2, "the seller and royalty vaults");
        assertLe(total, FIRST_START_CEILING);
    }

    function test_Gas_SteadyStart() public {
        _joinedFed();
        _startFed(_fedWork(fedArtist));
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        (uint256 total,, StateGrowth.Growth memory g) = _measureGrowth(
            address(this),
            address(auction),
            abi.encodeCall(auction.start, (address(fed), _mintData(w))),
            0
        );
        _row("federated start, steady", total, g);
        assertEq(g.slots, 10);
        assertEq(g.accounts, 0);
        assertLe(total, STEADY_START_CEILING);
    }

    function test_Gas_Bid() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        (uint256 saleId,) = _startFed(w);
        _probeVaults(w);
        vm.deal(collector, 1 ether);
        (uint256 bidGas,, StateGrowth.Growth memory gb) = _measureGrowth(
            collector,
            address(auction),
            abi.encodeCall(
                auction.bid,
                (saleId, address(0), Payment(PaymentMethod.DIRECT, collector, 1 ether, 0, 0, ""))
            ),
            1 ether
        );
        _row("federated first bid", bidGas, gb);
        assertEq(gb.slots, 5);
        assertLe(bidGas, BID_CEILING);
    }

    function test_Gas_SettleSold() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        (uint256 saleId,) = _startFed(w);
        _probeVaults(w);
        _ethBid(saleId, collector, 1 ether);
        _extra.push(collector);
        vm.warp(auction.auction(saleId).endTime);
        (uint256 settleGas,, StateGrowth.Growth memory gs) = _measureGrowth(
            address(this), address(auction), abi.encodeCall(auction.settle, (saleId)), 0
        );
        _row("federated settle, sold", settleGas, gs);
        assertEq(gs.slots, 2);
        assertLe(settleGas, SETTLE_SOLD_CEILING);
    }

    function test_Gas_SettleUnbid() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        (uint256 saleId,) = _startFed(w);
        _probeVaults(w);
        vm.warp(auction.auction(saleId).endTime);
        (uint256 settleGas,, StateGrowth.Growth memory gs) = _measureGrowth(
            address(this), address(auction), abi.encodeCall(auction.settle, (saleId)), 0
        );
        _row("federated settle, unbid (to the template)", settleGas, gs);
        assertEq(gs.slots, 2);
        assertLe(settleGas, SETTLE_UNBID_CEILING);
    }

    function test_Gas_Restart() public {
        _joinedFed();
        Work memory w = _fedWork(fedArtist);
        (uint256 saleId,) = _startFed(w);
        _probeVaults(w);
        _settleAtEnd(saleId);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        (uint256 total,, StateGrowth.Growth memory g) = _measureGrowth(
            address(this),
            address(auction),
            abi.encodeCall(auction.start, (address(fed), _mintData(w))),
            0
        );
        _row("federated restart", total, g);
        assertEq(g.slots, 4);
        assertLe(total, RESTART_CEILING);
    }

    // ------------------------------------------------------------------ the pair

    function _pairSale(bool open)
        internal
        returns (Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId)
    {
        (ps, pe) = _pair(fedArtist);
        w = _fedMaster(fedArtist, 0);
        (oneSaleId, tokenId) = _startFed(ps, fedArtist, w, RATE);
        _probeVaults(w);
        if (open) saleId = fea.open(address(pe), tokenId, abi.encode(w.item));
    }

    function test_Gas_EditionOpen() public {
        (Work memory w,, uint256 tokenId,) = _pairSale(false);
        (uint256 openGas,, StateGrowth.Growth memory go) = _measureGrowth(
            address(this),
            address(fea),
            abi.encodeCall(fea.open, (address(pe), tokenId, abi.encode(w.item))),
            0
        );
        _row("federated edition open", openGas, go);
        assertEq(go.slots, 7);
        assertLe(openGas, EDITION_OPEN_CEILING);
    }

    function test_Gas_CreateEdition() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId,) = _pairSale(true);
        _settleAtEnd(oneSaleId);
        (uint256 createGas,, StateGrowth.Growth memory gc) = _measureGrowth(
            address(this), address(pe), abi.encodeCall(pe.createEdition, (tokenId, w.item)), 0
        );
        _row("federated createEdition", createGas, gc);
        assertEq(gc.slots, 1);
        assertLe(createGas, CREATE_EDITION_CEILING);
    }

    function test_Gas_EditionSettle() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _pairSale(true);
        IUniformEditionAuctionLens fl = IUniformEditionAuctionLens(address(fea));
        uint256 amount = 2 * fl.stepPrice(saleId, 100);
        vm.deal(collector, amount);
        vm.prank(collector);
        fea.bid{ value: amount }(saleId, 100, 2);
        _settleAtEnd(oneSaleId);
        pe.createEdition(tokenId, w.item);
        vm.warp(fl.endTimes(saleId).endTime);
        (uint256 settleGas,, StateGrowth.Growth memory gs) = _measureGrowth(
            address(this), address(fea), abi.encodeCall(fea.settle, (saleId, new uint256[](0))), 0
        );
        _row("federated edition settle", settleGas, gs);
        assertEq(gs.slots, 1);
        assertLe(settleGas, EDITION_SETTLE_CEILING);
    }

    function _row(string memory name, uint256 total, StateGrowth.Growth memory g) internal {
        emit log_named_uint(string.concat(name, ": gas"), total);
        emit log_named_uint(string.concat(name, ": new slots"), g.slots);
        emit log_named_uint(string.concat(name, ": new accounts"), g.accounts);
    }
}
