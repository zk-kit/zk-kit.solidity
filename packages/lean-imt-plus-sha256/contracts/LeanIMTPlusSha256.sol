// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// solhint-disable-next-line max-line-length
import {InternalLeanIMTPlusSha256, LeanIMTPlusSha256Data, LeanIMTPlusSha256Proof} from "./InternalLeanIMTPlusSha256.sol";

/// @title LeanIMT+ public library (SHA-256).
/// @notice `public` wrapper around {InternalLeanIMTPlusSha256}, deployable once and
/// shared via linking. Import {InternalLeanIMTPlusSha256} to inline the code instead.
library LeanIMTPlusSha256 {
    /// @notice Inserts `value`, creating the sentinel on the first insertion.
    /// @param self The tree.
    /// @param value The value to insert; must be non-zero.
    /// @param lowLeafIndex Index of `value`'s low leaf (found off-chain); ignored on the
    /// first insertion.
    /// @return The index of the new leaf.
    function insert(LeanIMTPlusSha256Data storage self, uint256 value, uint256 lowLeafIndex) public returns (uint256) {
        return InternalLeanIMTPlusSha256._insert(self, value, lowLeafIndex);
    }

    /// @notice Inserts many values, cheaper than one `insert` per value.
    /// @param self The tree.
    /// @param values The values to insert, in order; non-zero and not already present.
    /// @param lowLeafIndices Each value's low leaf after the earlier values are inserted.
    /// At most {InternalLeanIMTPlusSha256.MAX_INSERT_MANY_BATCH} values per call.
    function insertMany(
        LeanIMTPlusSha256Data storage self,
        uint256[] calldata values,
        uint256[] calldata lowLeafIndices
    ) public {
        InternalLeanIMTPlusSha256._insertMany(self, values, lowLeafIndices);
    }

    /// @notice Removes `value` and tombstones its slot.
    /// @param self The tree.
    /// @param value The value to remove.
    /// @param predecessorIndex Index of the leaf whose `nextValue` is `value`.
    function remove(LeanIMTPlusSha256Data storage self, uint256 value, uint256 predecessorIndex) public {
        InternalLeanIMTPlusSha256._remove(self, value, predecessorIndex);
    }

    /// @notice Replaces `oldValue` with `newValue` in place.
    /// @param self The tree.
    /// @param oldValue The value to replace.
    /// @param newValue The new value; non-zero and not present.
    /// @param oldPredecessorIndex Index of `oldValue`'s predecessor.
    /// @param newPredecessorIndex Index of `newValue`'s low leaf after `oldValue` is unlinked.
    function update(
        LeanIMTPlusSha256Data storage self,
        uint256 oldValue,
        uint256 newValue,
        uint256 oldPredecessorIndex,
        uint256 newPredecessorIndex
    ) public {
        InternalLeanIMTPlusSha256._update(self, oldValue, newValue, oldPredecessorIndex, newPredecessorIndex);
    }

    /// @notice Verifies `proof` against the tree's current root. Prefer this overload.
    /// @param self The tree.
    /// @param proof The proof.
    /// @return True if the proof is valid for the current root.
    function verifyProof(
        LeanIMTPlusSha256Data storage self,
        LeanIMTPlusSha256Proof memory proof
    ) public view returns (bool) {
        return InternalLeanIMTPlusSha256._verifyProofAgainstTree(self, proof);
    }

    /// @notice Verifies `proof` against its own `proof.root`.
    /// @dev SECURITY: `proof.root` is caller-supplied. Only use this after checking it
    /// is a root you trust.
    /// @param proof The proof.
    /// @return True if the proof is valid for `proof.root`.
    function verifyProof(LeanIMTPlusSha256Proof memory proof) public view returns (bool) {
        return InternalLeanIMTPlusSha256._verifyProof(proof);
    }

    /// @notice Returns the current root (0 only before the first insert: a tree emptied by
    /// removals keeps its sentinel and tombstoned leaves, so its root is non-zero).
    /// @param self The tree.
    /// @return The root.
    function root(LeanIMTPlusSha256Data storage self) public view returns (uint256) {
        return InternalLeanIMTPlusSha256._root(self);
    }

    /// @notice Returns whether `value` is in the tree.
    /// @param self The tree.
    /// @param value The value.
    /// @return True if present.
    function has(LeanIMTPlusSha256Data storage self, uint256 value) public view returns (bool) {
        return InternalLeanIMTPlusSha256._has(self, value);
    }

    /// @notice Returns the index of the leaf holding `value`; reverts if absent.
    /// @param self The tree.
    /// @param value The value.
    /// @return The leaf index.
    function indexOf(LeanIMTPlusSha256Data storage self, uint256 value) public view returns (uint256) {
        return InternalLeanIMTPlusSha256._indexOf(self, value);
    }
}
