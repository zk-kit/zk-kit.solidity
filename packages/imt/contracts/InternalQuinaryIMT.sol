// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {PoseidonT6} from "poseidon-solidity/PoseidonT6.sol";
import {SNARK_SCALAR_FIELD, MAX_DEPTH} from "./Constants.sol";

// Each incremental tree has certain properties and data that will
// be used to add new leaves.
struct QuinaryIMTData {
    uint256 depth; // Depth of the tree (levels - 1).
    uint256 root; // Root hash of the tree.
    uint256 numberOfLeaves; // Number of leaves of the tree.
    mapping(uint256 => uint256) zeroes; // Zero hashes used for empty nodes (level -> zero hash).
    // The nodes of the subtrees used in the last addition of a leaf (level -> [nodes]).
    mapping(uint256 => uint256[5]) lastSubtrees; // Caching these values is essential to efficient appends.
}

error ValueGreaterThanSnarkScalarField();
error DepthNotSupported();
error TreeIsFull();
error NewLeafCannotEqualOldLeaf();
error LeafDoesNotExist();
error LeafIndexOutOfRange();
error WrongMerkleProofPath();

/// @title Incremental quinary Merkle tree.
/// @dev The incremental tree allows to calculate the root hash each time a leaf is added, ensuring
/// the integrity of the tree.
library InternalQuinaryIMT {
    /// @dev Initializes a tree.
    /// @param self: Tree data.
    /// @param depth: Depth of the tree.
    /// @param zero: Zero value to be used.
    function _init(QuinaryIMTData storage self, uint256 depth, uint256 zero) internal {
        if (zero >= SNARK_SCALAR_FIELD) {
            revert ValueGreaterThanSnarkScalarField();
        } else if (depth <= 0 || depth > MAX_DEPTH) {
            revert DepthNotSupported();
        }

        self.depth = depth;

        for (uint8 i = 0; i < depth; ) {
            self.zeroes[i] = zero;
            uint256[5] memory zeroChildren;

            for (uint8 j = 0; j < 5; ) {
                zeroChildren[j] = zero;
                unchecked {
                    ++j;
                }
            }

            zero = PoseidonT6.hash(zeroChildren);

            unchecked {
                ++i;
            }
        }

        self.root = zero;
    }

    /// @dev Inserts a leaf in the tree.
    /// @param self: Tree data.
    /// @param leaf: Leaf to be inserted.
    function _insert(QuinaryIMTData storage self, uint256 leaf) internal {
        uint256 depth = self.depth;

        if (leaf >= SNARK_SCALAR_FIELD) {
            revert ValueGreaterThanSnarkScalarField();
        } else if (self.numberOfLeaves >= 5 ** depth) {
            revert TreeIsFull();
        }

        uint256 index = self.numberOfLeaves;
        uint256 hash = leaf;

        for (uint8 i = 0; i < depth; ) {
            uint8 position = uint8(index % 5);

            self.lastSubtrees[i][position] = hash;

            if (position == 0) {
                for (uint8 j = 1; j < 5; ) {
                    self.lastSubtrees[i][j] = self.zeroes[i];
                    unchecked {
                        ++j;
                    }
                }
            }

            hash = PoseidonT6.hash(self.lastSubtrees[i]);
            index /= 5;

            unchecked {
                ++i;
            }
        }

        self.root = hash;
        self.numberOfLeaves += 1;
    }

    /// @dev Updates a leaf in the tree.
    /// @param self: Tree data.
    /// @param leaf: Leaf to be updated.
    /// @param newLeaf: New leaf.
    /// @param proofSiblings: Array of the sibling nodes of the proof of membership.
    /// @param proofPathIndices: Path of the proof of membership.
    function _update(
        QuinaryIMTData storage self,
        uint256 leaf,
        uint256 newLeaf,
        uint256[4][] calldata proofSiblings,
        uint8[] calldata proofPathIndices
    ) internal {
        if (newLeaf == leaf) {
            revert NewLeafCannotEqualOldLeaf();
        } else if (newLeaf >= SNARK_SCALAR_FIELD) {
            revert ValueGreaterThanSnarkScalarField();
        } else if (!_verify(self, leaf, proofSiblings, proofPathIndices)) {
            revert LeafDoesNotExist();
        }

        uint256 depth = self.depth;
        uint256 hash = newLeaf;

        uint256 updateLeafIndex;
        for (uint8 i = 0; i < depth; ) {
            updateLeafIndex += uint256(proofPathIndices[i]) * (5 ** i);
            unchecked {
                ++i;
            }
        }

        uint256 numberOfLeaves = self.numberOfLeaves;

        if (updateLeafIndex >= numberOfLeaves) {
            revert LeafIndexOutOfRange();
        }

        // Track parent indices incrementally (dividing by 5 each level)
        uint256 lastParentIndex = numberOfLeaves - 1;
        uint256 updateParentIndex = updateLeafIndex;

        for (uint8 i = 0; i < depth; ) {
            uint256[5] memory nodes;

            for (uint8 j = 0; j < 5; ) {
                if (j < proofPathIndices[i]) {
                    nodes[j] = proofSiblings[i][j];
                } else if (j == proofPathIndices[i]) {
                    nodes[j] = hash;
                } else {
                    nodes[j] = proofSiblings[i][j - 1];
                }
                unchecked {
                    ++j;
                }
            }

            lastParentIndex /= 5;
            updateParentIndex /= 5;

            // Update lastSubtrees only when update and last insertion
            // share the same parent node at level i+1
            if (lastParentIndex == updateParentIndex) {
                self.lastSubtrees[i][proofPathIndices[i]] = hash;
            }

            hash = PoseidonT6.hash(nodes);

            unchecked {
                ++i;
            }
        }

        self.root = hash;
    }

    /// @dev Removes a leaf from the tree.
    /// @param self: Tree data.
    /// @param leaf: Leaf to be removed.
    /// @param proofSiblings: Array of the sibling nodes of the proof of membership.
    /// @param proofPathIndices: Path of the proof of membership.
    function _remove(
        QuinaryIMTData storage self,
        uint256 leaf,
        uint256[4][] calldata proofSiblings,
        uint8[] calldata proofPathIndices
    ) internal {
        _update(self, leaf, self.zeroes[0], proofSiblings, proofPathIndices);
    }

    /// @dev Verify if the path is correct and the leaf is part of the tree.
    /// @param self: Tree data.
    /// @param leaf: Leaf to be removed.
    /// @param proofSiblings: Array of the sibling nodes of the proof of membership.
    /// @param proofPathIndices: Path of the proof of membership.
    /// @return True or false.
    function _verify(
        QuinaryIMTData storage self,
        uint256 leaf,
        uint256[4][] calldata proofSiblings,
        uint8[] calldata proofPathIndices
    ) internal view returns (bool) {
        uint256 depth = self.depth;

        if (leaf >= SNARK_SCALAR_FIELD) {
            revert ValueGreaterThanSnarkScalarField();
        } else if (proofPathIndices.length != depth || proofSiblings.length != depth) {
            revert WrongMerkleProofPath();
        }

        uint256 hash = leaf;

        for (uint8 i = 0; i < depth; ) {
            uint256[5] memory nodes;

            if (proofPathIndices[i] < 0 || proofPathIndices[i] >= 5) {
                revert WrongMerkleProofPath();
            }

            for (uint8 j = 0; j < 5; ) {
                if (j < proofPathIndices[i]) {
                    require(
                        proofSiblings[i][j] < SNARK_SCALAR_FIELD,
                        "QuinaryIMT: sibling node must be < SNARK_SCALAR_FIELD"
                    );

                    nodes[j] = proofSiblings[i][j];
                } else if (j == proofPathIndices[i]) {
                    nodes[j] = hash;
                } else {
                    require(
                        proofSiblings[i][j - 1] < SNARK_SCALAR_FIELD,
                        "QuinaryIMT: sibling node must be < SNARK_SCALAR_FIELD"
                    );

                    nodes[j] = proofSiblings[i][j - 1];
                }

                unchecked {
                    ++j;
                }
            }

            hash = PoseidonT6.hash(nodes);

            unchecked {
                ++i;
            }
        }

        return hash == self.root;
    }
}
