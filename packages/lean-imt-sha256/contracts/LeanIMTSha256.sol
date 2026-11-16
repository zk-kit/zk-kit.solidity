// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {InternalLeanIMTSha256, LeanIMTSha256Data} from "./InternalLeanIMTSha256.sol";

/// @title LeanIMT public library (SHA-256).
/// @notice `public` wrapper around {InternalLeanIMTSha256}, deployable once and
/// shared via linking. Import {InternalLeanIMTSha256} to inline the code instead.
library LeanIMTSha256 {
    function insert(LeanIMTSha256Data storage self, uint256 leaf) public returns (uint256) {
        return InternalLeanIMTSha256._insert(self, leaf);
    }

    function insertMany(LeanIMTSha256Data storage self, uint256[] calldata leaves) public returns (uint256) {
        return InternalLeanIMTSha256._insertMany(self, leaves);
    }

    function update(
        LeanIMTSha256Data storage self,
        uint256 oldLeaf,
        uint256 newLeaf,
        uint256[] calldata siblingNodes
    ) public returns (uint256) {
        return InternalLeanIMTSha256._update(self, oldLeaf, newLeaf, siblingNodes);
    }

    function remove(
        LeanIMTSha256Data storage self,
        uint256 oldLeaf,
        uint256[] calldata siblingNodes
    ) public returns (uint256) {
        return InternalLeanIMTSha256._remove(self, oldLeaf, siblingNodes);
    }

    function has(LeanIMTSha256Data storage self, uint256 leaf) public view returns (bool) {
        return InternalLeanIMTSha256._has(self, leaf);
    }

    function indexOf(LeanIMTSha256Data storage self, uint256 leaf) public view returns (uint256) {
        return InternalLeanIMTSha256._indexOf(self, leaf);
    }

    function root(LeanIMTSha256Data storage self) public view returns (uint256) {
        return InternalLeanIMTSha256._root(self);
    }
}
