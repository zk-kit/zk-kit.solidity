// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// Internal test harness, not part of the public API.
// solhint-disable use-natspec

import {LeanIMTPlusSha256} from "../LeanIMTPlusSha256.sol";
import {LeanIMTPlusSha256Data, LeanIMTPlusSha256Leaf, LeanIMTPlusSha256Proof} from "../InternalLeanIMTPlusSha256.sol";

/// @dev Test harness exposing {LeanIMTPlusSha256} over one stored tree.
contract LeanIMTPlusSha256Test {
    using LeanIMTPlusSha256 for LeanIMTPlusSha256Data;

    LeanIMTPlusSha256Data internal data;

    function insert(uint256 value, uint256 lowLeafIndex) external returns (uint256) {
        return data.insert(value, lowLeafIndex);
    }

    function insertMany(uint256[] calldata values, uint256[] calldata lowLeafIndices) external {
        data.insertMany(values, lowLeafIndices);
    }

    function remove(uint256 value, uint256 predecessorIndex) external {
        data.remove(value, predecessorIndex);
    }

    function update(
        uint256 oldValue,
        uint256 newValue,
        uint256 oldPredecessorIndex,
        uint256 newPredecessorIndex
    ) external {
        data.update(oldValue, newValue, oldPredecessorIndex, newPredecessorIndex);
    }

    function verifyProof(LeanIMTPlusSha256Proof calldata proof) external view returns (bool) {
        return data.verifyProof(proof);
    }

    function verifyProofStatic(LeanIMTPlusSha256Proof calldata proof) external view returns (bool) {
        return LeanIMTPlusSha256.verifyProof(proof);
    }

    function root() external view returns (uint256) {
        return data.root();
    }

    function has(uint256 value) external view returns (bool) {
        return data.has(value);
    }

    function indexOf(uint256 value) external view returns (uint256) {
        return data.indexOf(value);
    }

    // Raw leaf access for the test helpers (not part of the library API).
    function getLeaf(uint256 index) external view returns (LeanIMTPlusSha256Leaf memory) {
        return data.leaves[index];
    }

    function leavesCount() external view returns (uint256) {
        return data.leaves.length;
    }

    function size() external view returns (uint256) {
        return data.size;
    }

    function depth() external view returns (uint256) {
        return data.depth;
    }
}
