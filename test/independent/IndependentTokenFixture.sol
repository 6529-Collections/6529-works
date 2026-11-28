// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { MintFacts } from "src/interfaces/core/CoreTypes.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";

/// @notice One Independent Stream pair built straight on `CoreFixture`'s directory, whose modules
///         are the pass-through mocks: `gate` (INDEPENDENT_STREAM) admits `sale` for both tokens,
///         `accounts` (ACCOUNTS) answers `artistWallet` and `artistWallet2` for the artist, and
///         `terms` and `records` are the shared INDEPENDENT_TERMS and INDEPENDENT_RECORDS. The test
///         contract is the network (the AccessManager's admin), so it may call the network's token
///         functions.
abstract contract IndependentTokenFixture is CoreFixture {
    uint256 internal constant IND_ARTIST = uint160(0xF00D);

    IndependentStream6529 internal fs;
    IndependentStreamEditions6529 internal fe;
    address internal artistWallet = makeAddr("artistWallet");
    address internal artistWallet2 = makeAddr("artistWallet2");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual override {
        super.setUp();
        fs = new IndependentStream6529(
            "Ind Works",
            "IND",
            address(facts),
            address(directory),
            IND_ARTIST,
            marketOwner,
            address(renderer)
        );
        fe = new IndependentStreamEditions6529(
            "Ind Editions", "INDED", address(fs), address(directory), IND_ARTIST, marketOwner
        );
        gate.setMinter(address(fs), address(sale), true);
        gate.setMinter(address(fe), address(sale), true);
        accounts.setWallet(IND_ARTIST, artistWallet, true);
        accounts.setWallet(IND_ARTIST, artistWallet2, true);
    }

    /// @dev Mint facts for work `n` of the Independent Stream artist (an Independent Stream token
    ///      takes only its own artist).
    function _ffacts(uint256 n) internal pure returns (MintFacts memory f) {
        f = _facts(n);
        f.artistId = IND_ARTIST;
    }

    /// @dev Mints work `n` into the sale contract's custody in the Independent Stream contract.
    function _fmint(uint256 n) internal returns (uint256) {
        return sale.mint(address(fs), _ffacts(n));
    }

    /// @dev Mints work `n`, records it sold and delivers it to `to`.
    function _fsell(uint256 n, address to) internal returns (uint256 tokenId) {
        tokenId = _fmint(n);
        sale.record(address(fs), tokenId, true, to, 1 ether);
        sale.send(address(fs), tokenId, to);
    }

    /// @dev The Independent Stream module removes `minter` at `when` and stops it minting.
    function _gateRemove(address minter, uint256 when) internal {
        gate.setMinter(address(fs), minter, false);
        gate.setMinter(address(fe), minter, false);
        gate.remove(minter, when);
    }
}
