// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {InternalLeanIMT, LeanIMTData, Hasher} from "./InternalLeanIMT.sol";
import {SNARK_SCALAR_FIELD} from "./Constants.sol";
import {IHasherT3} from "./interfaces/IHasherT3.sol";

library LeanIMT {
    // The create2 address of poseidonT3 from: https://github.com/chancehudson/poseidon-solidity?tab=readme-ov-file#benchmark
    address internal constant HASHER_ADDRESS = 0x3333333C0A88F9BE4fd23ed0536F9B6c427e3B93;
    // Hasher internal constant HASHER = Hasher(_hasher, SNARK_SCALAR_FIELD); constants on types that are function is not implemented yet in solidity (caused by HASHER.func)

    // The function used for hashing. Passed as a function parameter in functions from InternalLazyIMT
    function _hasher(uint256[2] memory leaves) internal view returns (uint256) {
        return IHasherT3(HASHER_ADDRESS).hash([leaves[0], leaves[1]]);
    }

    using InternalLeanIMT for *;

    function insert(LeanIMTData storage self, uint256 leaf) public returns (uint256) {
        return InternalLeanIMT._insert(self, leaf, Hasher(_hasher, SNARK_SCALAR_FIELD));
    }

    function insertMany(LeanIMTData storage self, uint256[] calldata leaves) public returns (uint256) {
        return InternalLeanIMT._insertMany(self, leaves, Hasher(_hasher, SNARK_SCALAR_FIELD));
    }

    function update(
        LeanIMTData storage self,
        uint256 oldLeaf,
        uint256 newLeaf,
        uint256[] calldata siblingNodes
    ) public returns (uint256) {
        return InternalLeanIMT._update(self, oldLeaf, newLeaf, siblingNodes, Hasher(_hasher, SNARK_SCALAR_FIELD));
    }

    function remove(
        LeanIMTData storage self,
        uint256 oldLeaf,
        uint256[] calldata siblingNodes
    ) public returns (uint256) {
        return InternalLeanIMT._remove(self, oldLeaf, siblingNodes, Hasher(_hasher, SNARK_SCALAR_FIELD));
    }

    function has(LeanIMTData storage self, uint256 leaf) public view returns (bool) {
        return InternalLeanIMT._has(self, leaf);
    }

    function indexOf(LeanIMTData storage self, uint256 leaf) public view returns (uint256) {
        return InternalLeanIMT._indexOf(self, leaf);
    }

    function root(LeanIMTData storage self) public view returns (uint256) {
        return InternalLeanIMT._root(self);
    }
}
