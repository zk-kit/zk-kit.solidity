// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {MAX_DEPTH} from "./Constants.sol";

// Each incremental tree has certain properties and data that will
// be used to add new leaves.
struct BinaryIMTData {
    uint256 depth; // Depth of the tree (levels - 1).
    uint256 root; // Root hash of the tree.
    uint256 numberOfLeaves; // Number of leaves of the tree.
    mapping(uint256 => uint256) zeroes; // Zero hashes used for empty nodes (level -> zero hash).
    // The nodes of the subtrees used in the last addition of a leaf (level -> [left node, right node]).
    mapping(uint256 => uint256[2]) lastSubtrees; // Caching these values is essential to efficient appends.
    bool useDefaultZeroes;
}

error ValueGreaterThanHasherLimit();
error DepthNotSupported();
error TreeIsFull();
error NewLeafCannotEqualOldLeaf();
error LeafDoesNotExist();
error LeafIndexOutOfRange();
error WrongMerkleProofPath();

/// @title Incremental binary Merkle tree.
/// @dev The incremental tree allows to calculate the root hash each time a leaf is added, ensuring
/// the integrity of the tree.
library InternalBinaryIMT {
    /// @dev Initializes a tree.
    /// @param self: Tree data.
    /// @param depth: Depth of the tree.
    /// @param zero: Zero value to be used.
    function _init(
        BinaryIMTData storage self,
        uint256 depth,
        uint256 zero,
        function(uint256[2] memory) view returns (uint256) hasher,
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
            zero = hasher([zero, zero]);

            unchecked {
                ++i;
            }
        }

        self.root = zero;
    }
    /// @dev Use pre calculated default zeros
    /// @param self: Tree data.
    /// @param depth: Depth of the tree.
    /// @param _defaultZero: a function that return the default zeros
    function _initWithDefaultZeroes(
        BinaryIMTData storage self,
        uint256 depth,
        function(uint256) pure returns (uint256) _defaultZero
    ) internal {
        if (depth <= 0 || depth > MAX_DEPTH) {
            revert DepthNotSupported();
        }

        self.depth = depth;
        self.useDefaultZeroes = true;

        self.root = _defaultZero(depth);
    }

    /// @dev Inserts a leaf in the tree.
    /// @param self: Tree data.
    /// @param leaf: Leaf to be inserted.
    /// @param hasher: Address of the contract/library implements the hash function with IHasherT3.
    /// @param hasherLimit: To check inputs for the hasher to never exceed inputs past this limit (ex the SNARK_SCALAR_FIELD)
    /// @param _defaultZero: a function that return the default zeros
    function _insert(
        BinaryIMTData storage self,
        uint256 leaf,
        function(uint256[2] memory) view returns (uint256) hasher,
        uint256 hasherLimit,
        function(uint256) pure returns (uint256) _defaultZero
    ) internal returns (uint256) {
        uint256 depth = self.depth;

        if (leaf >= hasherLimit) {
            revert ValueGreaterThanHasherLimit();
        } else if (self.numberOfLeaves >= 2 ** depth) {
            revert TreeIsFull();
        }

        uint256 index = self.numberOfLeaves;
        uint256 hash = leaf;
        bool useDefaultZeroes = self.useDefaultZeroes;

        for (uint8 i = 0; i < depth; ) {
            if (index & 1 == 0) {
                self.lastSubtrees[i] = [hash, useDefaultZeroes ? _defaultZero(i) : self.zeroes[i]];
            } else {
                self.lastSubtrees[i][1] = hash;
            }

            hash = hasher(self.lastSubtrees[i]);
            index >>= 1;

            unchecked {
                ++i;
            }
        }

        self.root = hash;
        self.numberOfLeaves += 1;
        return hash;
    }

    /// @dev Updates a leaf in the tree.
    /// @param self: Tree data.
    /// @param leaf: Leaf to be updated.
    /// @param newLeaf: New leaf.
    /// @param proofSiblings: Array of the sibling nodes of the proof of membership.
    /// @param proofPathIndices: Path of the proof of membership.
    /// @param hasher: Address of the contract/library implements the hash function with IHasherT3.
    /// @param hasherLimit: To check inputs for the hasher to never exceed inputs past this limit (ex the SNARK_SCALAR_FIELD)
    function _update(
        BinaryIMTData storage self,
        uint256 leaf,
        uint256 newLeaf,
        uint256[] calldata proofSiblings,
        uint8[] calldata proofPathIndices,
        function(uint256[2] memory) view returns (uint256) hasher,
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
            updateIndex |= uint256(proofPathIndices[i]) << uint256(i);

            if (proofPathIndices[i] == 0) {
                if (proofSiblings[i] == self.lastSubtrees[i][1]) {
                    self.lastSubtrees[i][0] = hash;
                }

                hash = hasher([hash, proofSiblings[i]]);
            } else {
                if (proofSiblings[i] == self.lastSubtrees[i][0]) {
                    self.lastSubtrees[i][1] = hash;
                }

                hash = hasher([proofSiblings[i], hash]);
            }

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
    /// @param hasher: Address of the contract/library implements the hash function with IHasherT3.
    /// @param hasherLimit: To check inputs for the hasher to never exceed inputs past this limit (ex the SNARK_SCALAR_FIELD)
    /// @param defaultZeroLeafs: the zero value for a leaf (same as _defaultZero(0))
    function _remove(
        BinaryIMTData storage self,
        uint256 leaf,
        uint256[] calldata proofSiblings,
        uint8[] calldata proofPathIndices,
        function(uint256[2] memory) view returns (uint256) hasher,
        uint256 hasherLimit,
        uint256 defaultZeroLeafs
    ) internal {
        _update(
            self,
            leaf,
            self.useDefaultZeroes ? defaultZeroLeafs : self.zeroes[0],
            proofSiblings,
            proofPathIndices,
            hasher,
            hasherLimit
        );
    }

    /// @dev Verify if the path is correct and the leaf is part of the tree.
    /// @param self: Tree data.
    /// @param leaf: Leaf to be removed.
    /// @param proofSiblings: Array of the sibling nodes of the proof of membership.
    /// @param proofPathIndices: Path of the proof of membership.
    /// @param hasher: Address of the contract/library implements the hash function with IHasherT3.
    /// @param hasherLimit: To check inputs for the hasher to never exceed inputs past this limit (ex the SNARK_SCALAR_FIELD)
    /// @return True or false.
    function _verify(
        BinaryIMTData storage self,
        uint256 leaf,
        uint256[] calldata proofSiblings,
        uint8[] calldata proofPathIndices,
        function(uint256[2] memory) view returns (uint256) hasher,
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
            if (proofSiblings[i] >= hasherLimit) {
                revert ValueGreaterThanHasherLimit();
            } else if (proofPathIndices[i] != 1 && proofPathIndices[i] != 0) {
                revert WrongMerkleProofPath();
            }

            if (proofPathIndices[i] == 0) {
                hash = hasher([hash, proofSiblings[i]]);
            } else {
                hash = hasher([proofSiblings[i], hash]);
            }

            unchecked {
                ++i;
            }
        }

        return hash == self.root;
    }
}
