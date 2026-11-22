// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { MintFacts } from "src/interfaces/core/CoreTypes.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";

/// @notice One federated pair built straight on `CoreFixture`'s directory, whose modules are the
///         pass-through mocks: `gate` (FEDERATION) admits `sale` for both tokens, `accounts`
///         (ACCOUNTS) answers `artistWallet` and `artistWallet2` for the artist, and `terms` and
///         `records` are the shared FEDERATED_TERMS and FEDERATED_RECORDS. The test contract is
///         the network (the AccessManager's admin), so it may call the network's token functions.
abstract contract FederatedTokenFixture is CoreFixture {
    uint256 internal constant FED_ARTIST = uint160(0xF00D);

    FederatedStream internal fs;
    FederatedEditions internal fe;
    address internal artistWallet = makeAddr("artistWallet");
    address internal artistWallet2 = makeAddr("artistWallet2");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual override {
        super.setUp();
        fs = new FederatedStream(
            "Fed Works",
            "FED",
            address(facts),
            address(directory),
            FED_ARTIST,
            marketOwner,
            address(renderer)
        );
        fe = new FederatedEditions(
            "Fed Editions", "FEDED", address(fs), address(directory), FED_ARTIST, marketOwner
        );
        gate.setMinter(address(fs), address(sale), true);
        gate.setMinter(address(fe), address(sale), true);
        accounts.setWallet(FED_ARTIST, artistWallet, true);
        accounts.setWallet(FED_ARTIST, artistWallet2, true);
    }

    /// @dev Mint facts for work `n` of the federated artist (a federated token takes only its
    ///      own artist).
    function _ffacts(uint256 n) internal pure returns (MintFacts memory f) {
        f = _facts(n);
        f.artistId = FED_ARTIST;
    }

    /// @dev Mints work `n` into the sale contract's custody in the federated stream.
    function _fmint(uint256 n) internal returns (uint256) {
        return sale.mint(address(fs), _ffacts(n));
    }

    /// @dev Mints work `n`, records it sold and delivers it to `to`.
    function _fsell(uint256 n, address to) internal returns (uint256 tokenId) {
        tokenId = _fmint(n);
        sale.record(address(fs), tokenId, true, to, 1 ether);
        sale.send(address(fs), tokenId, to);
    }

    /// @dev The federation module removes `minter` at `when` and stops it minting.
    function _gateRemove(address minter, uint256 when) internal {
        gate.setMinter(address(fs), minter, false);
        gate.setMinter(address(fe), minter, false);
        gate.remove(minter, when);
    }
}
