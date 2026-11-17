// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {MAX_DEPTH} from "./Constants.sol";

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

error ValueGreaterThanHasherLimit();
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
    /// @param hasher: Address of the contract/library implements the hash function with hasher.
    /// @param hasherLimit: To check inputs for the hasher to never exceed inputs past this limit (ex the SNARK_SCALAR_FIELD).
    function _init(
        QuinaryIMTData storage self,
        uint256 depth,
        uint256 zero,
        function(uint256[5] memory) view returns (uint256) hasher,
        uint256 hasherLimit
    ) internal {
        if (zero >= hasherLimit) {
            revert ValueGreaterThanHasherLimit();
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

            zero = hasher(zeroChildren);

            unchecked {
                ++i;
            }
        }

        self.root = zero;
    }

    /// @dev Inserts a leaf in the tree.
    /// @param self: Tree data.
    /// @param leaf: Leaf to be inserted.
    /// @param hasher: Address of the contract/library implements the hash function with hasher.
    /// @param hasherLimit: To check inputs for the hasher to never exceed inputs past this limit (ex the SNARK_SCALAR_FIELD).
    function _insert(
        QuinaryIMTData storage self,
        uint256 leaf,
        function(uint256[5] memory) view returns (uint256) hasher,
        uint256 hasherLimit
    ) internal {
        uint256 depth = self.depth;

        if (leaf >= hasherLimit) {
            revert ValueGreaterThanHasherLimit();
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

            hash = hasher(self.lastSubtrees[i]);
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
    /// @param hasher: Address of the contract/library implements the hash function with hasher.
    /// @param hasherLimit: To check inputs for the hasher to never exceed inputs past this limit (ex the SNARK_SCALAR_FIELD).
    function _update(
        QuinaryIMTData storage self,
        uint256 leaf,
        uint256 newLeaf,
        uint256[4][] calldata proofSiblings,
        uint8[] calldata proofPathIndices,
        function(uint256[5] memory) view returns (uint256) hasher,
        uint256 hasherLimit
    ) internal {
        if (newLeaf == leaf) {
            revert NewLeafCannotEqualOldLeaf();
        } else if (newLeaf >= hasherLimit) {
            revert ValueGreaterThanHasherLimit();
        } else if (!_verify(self, leaf, proofSiblings, proofPathIndices, hasher, hasherLimit)) {
            revert LeafDoesNotExist();
        }

        uint256 depth = self.depth;
        uint256 hash = newLeaf;
        uint256 updateIndex;

        for (uint8 i = 0; i < depth; ) {
            uint256[5] memory nodes;
            updateIndex += proofPathIndices[i] * 5 ** i;

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

            if (nodes[0] == self.lastSubtrees[i][0] || nodes[4] == self.lastSubtrees[i][4]) {
                self.lastSubtrees[i][proofPathIndices[i]] = hash;
            }

            hash = hasher(nodes);

            unchecked {
                ++i;
            }
        }

        if (updateIndex >= self.numberOfLeaves) {
            revert LeafIndexOutOfRange();
        }

        self.root = hash;
    }

    /// @dev Removes a leaf from the tree.
    /// @param self: Tree data.
    /// @param leaf: Leaf to be removed.
    /// @param proofSiblings: Array of the sibling nodes of the proof of membership.
    /// @param proofPathIndices: Path of the proof of membership.
    /// @param hasher: Address of the contract/library implements the hash function with hasher.
    /// @param hasherLimit: To check inputs for the hasher to never exceed inputs past this limit (ex the SNARK_SCALAR_FIELD).
    function _remove(
        QuinaryIMTData storage self,
        uint256 leaf,
        uint256[4][] calldata proofSiblings,
        uint8[] calldata proofPathIndices,
        function(uint256[5] memory) view returns (uint256) hasher,
        uint256 hasherLimit
    ) internal {
        _update(self, leaf, self.zeroes[0], proofSiblings, proofPathIndices, hasher, hasherLimit);
    }

    /// @dev Verify if the path is correct and the leaf is part of the tree.
    /// @param self: Tree data.
    /// @param leaf: Leaf to be removed.
    /// @param proofSiblings: Array of the sibling nodes of the proof of membership.
    /// @param proofPathIndices: Path of the proof of membership.
    /// @param hasher: Address of the contract/library implements the hash function with hasher.
    /// @param hasherLimit: To check inputs for the hasher to never exceed inputs past this limit (ex the SNARK_SCALAR_FIELD).
    /// @return True or false.
    function _verify(
        QuinaryIMTData storage self,
        uint256 leaf,
        uint256[4][] calldata proofSiblings,
        uint8[] calldata proofPathIndices,
        function(uint256[5] memory) view returns (uint256) hasher,
        uint256 hasherLimit
    ) internal view returns (bool) {
        uint256 depth = self.depth;

        if (leaf >= hasherLimit) {
            revert ValueGreaterThanHasherLimit();
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
                    require(proofSiblings[i][j] < hasherLimit, "QuinaryIMT: sibling node must be < hasherLimit");

                    nodes[j] = proofSiblings[i][j];
                } else if (j == proofPathIndices[i]) {
                    nodes[j] = hash;
                } else {
                    require(proofSiblings[i][j - 1] < hasherLimit, "QuinaryIMT: sibling node must be < hasherLimit");

                    nodes[j] = proofSiblings[i][j - 1];
                }

                unchecked {
                    ++j;
                }
            }

            hash = hasher(nodes);

            unchecked {
                ++i;
            }
        }

        return hash == self.root;
    }
}
