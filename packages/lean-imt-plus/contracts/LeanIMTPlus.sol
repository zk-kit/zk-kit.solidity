// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {InternalLeanIMTPlus, LeanIMTPlusData, LeanIMTPlusProof} from "./InternalLeanIMTPlus.sol";

/// @title LeanIMT+ public library.
/// @notice Deployable, `delegatecall`-linked wrapper around {InternalLeanIMTPlus}.
/// Consumers that only need the internal (inlined) functions can import
/// {InternalLeanIMTPlus} directly; this library exposes the same API as `public`
/// functions so a single on-chain deployment can be shared across contracts.
library LeanIMTPlus {
    /// @notice Inserts `value`, creating the sentinel on the first insertion.
    /// @param self The LeanIMT+ tree instance.
    /// @param value The value to insert; must be non-zero and `< SNARK_SCALAR_FIELD`.
    /// @param lowLeafIndex Physical index of `value`'s predecessor (its low leaf),
    /// found off-chain and validated on-chain; ignored on the first insertion.
    /// @return The physical index of the newly inserted leaf.
    function insert(LeanIMTPlusData storage self, uint256 value, uint256 lowLeafIndex) public returns (uint256) {
        return InternalLeanIMTPlus._insert(self, value, lowLeafIndex);
    }

    /// @notice Inserts many values in one call, cheaper than one `insert` per value
    /// because every affected internal node is rehashed at most once.
    /// @param self The LeanIMT+ tree instance.
    /// @param values The values to insert, in order; each must be non-zero, `< SNARK_SCALAR_FIELD`,
    /// and not already present (including earlier in the same batch).
    /// @param lowLeafIndices For each value, the physical index of its low leaf in the
    /// list after the earlier batch values are inserted; ignored for the value that
    /// creates the sentinel. Must be the same length as `values`. At most
    /// {InternalLeanIMTPlus.MAX_INSERT_MANY_BATCH} values per call.
    function insertMany(
        LeanIMTPlusData storage self,
        uint256[] calldata values,
        uint256[] calldata lowLeafIndices
    ) public {
        InternalLeanIMTPlus._insertMany(self, values, lowLeafIndices);
    }

    /// @notice Removes `value`, relinking the list and tombstoning its slot.
    /// @param self The LeanIMT+ tree instance.
    /// @param value The active value to remove.
    /// @param predecessorIndex Physical index of the leaf whose `nextValue` is `value`.
    function remove(LeanIMTPlusData storage self, uint256 value, uint256 predecessorIndex) public {
        InternalLeanIMTPlus._remove(self, value, predecessorIndex);
    }

    /// @notice Replaces `oldValue` with `newValue` in place, reusing the old slot.
    /// @param self The LeanIMT+ tree instance.
    /// @param oldValue The existing value to replace.
    /// @param newValue The new value; must be non-zero, `< SNARK_SCALAR_FIELD`, and absent.
    /// @param oldPredecessorIndex Physical index of `oldValue`'s predecessor.
    /// @param newPredecessorIndex Physical index of `newValue`'s predecessor in the list
    /// after `oldValue` is unlinked.
    function update(
        LeanIMTPlusData storage self,
        uint256 oldValue,
        uint256 newValue,
        uint256 oldPredecessorIndex,
        uint256 newPredecessorIndex
    ) public {
        InternalLeanIMTPlus._update(self, oldValue, newValue, oldPredecessorIndex, newPredecessorIndex);
    }

    /// @notice Verifies `proof` against this tree, pinning it to the tree's current
    /// root. This is the safe overload for on-chain verification.
    /// @param self The LeanIMT+ tree instance.
    /// @param proof The proof to verify.
    /// @return True iff the proof is internally consistent and its root matches the tree.
    function verifyProof(LeanIMTPlusData storage self, LeanIMTPlusProof memory proof) public view returns (bool) {
        return InternalLeanIMTPlus._verifyProofAgainstTree(self, proof);
    }

    /// @notice Stateless verification. It checks only that the proof is internally
    /// consistent with the `root` carried inside `proof`; it does NOT bind the proof
    /// to any real tree.
    /// @dev SECURITY: the caller supplies `proof.root`, so on its own this returns
    /// true for an attacker-crafted claim against an attacker-chosen root. Only use it
    /// if you independently compare `proof.root` against a root you trust (e.g. the
    /// current or a historical root of a specific tree). When in doubt, prefer the
    /// `verifyProof(self, proof)` overload, which pins the root for you.
    /// @param proof The proof to verify against its own embedded `root`.
    /// @return True iff the proof is internally consistent with `proof.root`.
    function verifyProof(LeanIMTPlusProof memory proof) public pure returns (bool) {
        return InternalLeanIMTPlus._verifyProof(proof);
    }

    /// @notice Returns the current Merkle root (0 for an empty tree).
    /// @param self The LeanIMT+ tree instance.
    /// @return The current root.
    function root(LeanIMTPlusData storage self) public view returns (uint256) {
        return InternalLeanIMTPlus._root(self);
    }

    /// @notice Returns whether `value` is an active value in the tree.
    /// @param self The LeanIMT+ tree instance.
    /// @param value The value to look up.
    /// @return True iff `value` is present.
    function has(LeanIMTPlusData storage self, uint256 value) public view returns (bool) {
        return InternalLeanIMTPlus._has(self, value);
    }

    /// @notice Returns the physical leaf index holding `value`; reverts if absent.
    /// @param self The LeanIMT+ tree instance.
    /// @param value The value to look up.
    /// @return The physical index of `value`'s leaf.
    function indexOf(LeanIMTPlusData storage self, uint256 value) public view returns (uint256) {
        return InternalLeanIMTPlus._indexOf(self, value);
    }
}
