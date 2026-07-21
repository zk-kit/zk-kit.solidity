// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// Internal test harness, not part of the public API.
// solhint-disable use-natspec

import {LeanIMTPlus} from "../LeanIMTPlus.sol";
import {LeanIMTPlusData, LeanIMTPlusLeaf, LeanIMTPlusProof} from "../InternalLeanIMTPlus.sol";

/// @dev Thin harness that exposes the {LeanIMTPlus} library over a single stored
/// tree, used by the test suite and gas benchmarks.
contract LeanIMTPlusTest {
    using LeanIMTPlus for LeanIMTPlusData;

    LeanIMTPlusData internal data;

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

    function verifyProof(LeanIMTPlusProof calldata proof) external view returns (bool) {
        return data.verifyProof(proof);
    }

    function verifyProofStatic(LeanIMTPlusProof calldata proof) external pure returns (bool) {
        return LeanIMTPlus.verifyProof(proof);
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

    // getLeaf / leavesCount are read straight from storage here (the library no longer
    // exposes them) so the off-chain test helpers can scan the physical leaf layout.
    function getLeaf(uint256 index) external view returns (LeanIMTPlusLeaf memory) {
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
