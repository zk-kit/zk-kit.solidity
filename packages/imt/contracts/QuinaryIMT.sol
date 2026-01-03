// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {InternalQuinaryIMT, QuinaryIMTData} from "./InternalQuinaryIMT.sol";
import {SNARK_SCALAR_FIELD} from "./Constants.sol";
import {IHasherT6} from "./interfaces/IHasherT6.sol";

library QuinaryIMT {
    using InternalQuinaryIMT for *;

    // The function used for hashing. Passed as a function parameter in functions from InternalLazyIMT
    function _hasher(uint256[5] memory input) internal view returns (uint256) {
        return IHasherT6(HASHER_ADDRESS).hash(input);
    }

    address internal constant HASHER_ADDRESS = 0x666333F371685334CdD69bdDdaFBABc87CE7c7Db;

    function init(QuinaryIMTData storage self, uint256 depth, uint256 zero) public {
        InternalQuinaryIMT._init(self, depth, zero, _hasher, SNARK_SCALAR_FIELD);
    }

    function insert(QuinaryIMTData storage self, uint256 leaf) public {
        InternalQuinaryIMT._insert(self, leaf, _hasher, SNARK_SCALAR_FIELD);
    }

    function update(
        QuinaryIMTData storage self,
        uint256 leaf,
        uint256 newLeaf,
        uint256[4][] calldata proofSiblings,
        uint8[] calldata proofPathIndices
    ) public {
        InternalQuinaryIMT._update(self, leaf, newLeaf, proofSiblings, proofPathIndices, _hasher, SNARK_SCALAR_FIELD);
    }

    function remove(
        QuinaryIMTData storage self,
        uint256 leaf,
        uint256[4][] calldata proofSiblings,
        uint8[] calldata proofPathIndices
    ) public {
        InternalQuinaryIMT._remove(self, leaf, proofSiblings, proofPathIndices, _hasher, SNARK_SCALAR_FIELD);
    }

    function verify(
        QuinaryIMTData storage self,
        uint256 leaf,
        uint256[4][] calldata proofSiblings,
        uint8[] calldata proofPathIndices
    ) private view returns (bool) {
        return InternalQuinaryIMT._verify(self, leaf, proofSiblings, proofPathIndices, _hasher, SNARK_SCALAR_FIELD);
    }
}
