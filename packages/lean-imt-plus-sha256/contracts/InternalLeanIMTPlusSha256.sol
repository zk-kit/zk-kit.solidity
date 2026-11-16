// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// TAG_LEAF is only used in inline assembly, which solhint does not see.
// solhint-disable-next-line no-unused-import
import {TAG_LEAF} from "./Constants.sol";

/// @dev Indexed leaf. Leaves form a sorted linked list by value (`nextValue` points
/// to the leaf whose `value` equals it). States:
///  - sentinel (always index 0): `value = 0`, `nextValue` = smallest value;
///  - active:                    `value > 0`;
///  - tombstone (removed):       `value = 0`, `nextValue = 0`.
struct LeanIMTPlusSha256Leaf {
    uint256 value;
    uint256 nextValue;
}

/// @dev Membership (`proofType = 0`) or non-membership (`proofType = 1`) proof.
/// `leafIndex` is the compacted path: levels without a sibling (promoted odd nodes)
/// are skipped, and bit `i` is 1 if the node is the right child at `siblings[i]`.
struct LeanIMTPlusSha256Proof {
    uint8 proofType;
    uint256 root;
    uint256 value;
    uint256 leafValue;
    uint256 leafNextValue;
    uint256 leafIndex;
    uint256[] siblings;
}

/// @dev Tree state. Stores the full node table (`O(n)` storage) because inserts
/// rewrite an arbitrary low leaf, so paths cannot be rebuilt from side nodes.
struct LeanIMTPlusSha256Data {
    // Leaf records, parallel to `nodes[0]`. Index 0 is the sentinel.
    LeanIMTPlusSha256Leaf[] leaves;
    // level => hashes; `nodes[0]` are leaf commitments, the root is `nodes[depth][0]`.
    mapping(uint256 level => uint256[] hashes) nodes;
    uint256 depth;
    // value => index + 1 (0 = absent). Only active values are tracked.
    mapping(uint256 value => uint256 indexPlusOne) valueIndex;
    // Number of active values.
    uint256 size;
}

error LeafCannotBeZero();
error LeafAlreadyExists();
error LeafDoesNotExist();
error NewLeafCannotEqualOldLeaf();
error InvalidLowLeaf();
error WrongPredecessor();
error MismatchedArrayLengths();
error BatchTooLarge();

/// @title LeanIMT+ internal library (SHA-256).
/// @notice LeanIMT with indexed leaves, supporting membership and non-membership proofs.
/// @dev SHA-256 variant of the Poseidon LeanIMT+: same logic and proof format, full
/// 256-bit digests, and any non-zero `uint256` as a value. Inputs are 32-byte
/// big-endian words:
///  - leaf: `sha256(value || nextValue || TAG_LEAF)` (96 bytes);
///  - node: `sha256(left || right)` (64 bytes).
/// The different message lengths domain-separate leaves from nodes.
/// Low-leaf indices are found off-chain and validated on-chain in O(1).
library InternalLeanIMTPlusSha256 {
    /// @dev Max values per {_insertMany} call, bounding the batch's sort cost.
    uint256 internal constant MAX_INSERT_MANY_BATCH = 256;

    // ─────────────────────────────────────────────────────────────────────────
    // Mutations
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Inserts `value` after its low leaf (`lowLeafIndex`, ignored on the first
    /// insert, which also creates the sentinel). Returns the new leaf's index.
    function _insert(
        LeanIMTPlusSha256Data storage self,
        uint256 value,
        uint256 lowLeafIndex
    ) internal returns (uint256) {
        _validateValue(self, value);

        if (self.leaves.length == 0) {
            _appendLeaf(self, 0, value);
            uint256 firstIndex = _appendLeaf(self, value, 0);
            self.valueIndex[value] = firstIndex + 1;
            unchecked {
                ++self.size;
            }

            uint256[] memory modifiedFirst = new uint256[](2);
            modifiedFirst[0] = 0;
            modifiedFirst[1] = firstIndex;
            _recompute(self, modifiedFirst);
            return firstIndex;
        }

        LeanIMTPlusSha256Leaf storage low = self.leaves[lowLeafIndex];
        uint256 lowValue = low.value;
        uint256 lowNext = low.nextValue;
        if (!_isLowLeaf(lowLeafIndex, lowValue, lowNext, value)) {
            revert InvalidLowLeaf();
        }

        uint256 newIndex = _appendLeaf(self, value, lowNext);
        _writeLeaf(self, lowLeafIndex, lowValue, value);
        self.valueIndex[value] = newIndex + 1;
        unchecked {
            ++self.size;
        }

        uint256[] memory modified = new uint256[](2);
        modified[0] = lowLeafIndex;
        modified[1] = newIndex;
        _recompute(self, modified);
        return newIndex;
    }

    /// @dev Same as calling {_insert} per value, but each affected node is rehashed
    /// once. `lowLeafIndices[i]` is `values[i]`'s low leaf after the earlier values are
    /// inserted. Reverts the whole batch on any invalid value or low leaf.
    function _insertMany(
        LeanIMTPlusSha256Data storage self,
        uint256[] calldata values,
        uint256[] calldata lowLeafIndices
    ) internal {
        uint256 n = values.length;
        if (n != lowLeafIndices.length) revert MismatchedArrayLengths();
        if (n > MAX_INSERT_MANY_BATCH) revert BatchTooLarge();
        if (n == 0) return;

        // Each value modifies two level-0 slots: its low leaf and the new leaf.
        uint256[] memory modified = new uint256[](2 * n);
        uint256 m = 0;

        for (uint256 i = 0; i < n; ) {
            uint256 value = values[i];
            _validateValue(self, value);

            if (self.leaves.length == 0) {
                _appendLeaf(self, 0, value);
                uint256 firstIndex = _appendLeaf(self, value, 0);
                self.valueIndex[value] = firstIndex + 1;
                modified[m] = 0;
                modified[m + 1] = firstIndex;
            } else {
                uint256 lowIdx = lowLeafIndices[i];
                LeanIMTPlusSha256Leaf storage low = self.leaves[lowIdx];
                uint256 lowValue = low.value;
                uint256 lowNext = low.nextValue;
                if (!_isLowLeaf(lowIdx, lowValue, lowNext, value)) {
                    revert InvalidLowLeaf();
                }
                uint256 newIndex = _appendLeaf(self, value, lowNext);
                _writeLeaf(self, lowIdx, lowValue, value);
                self.valueIndex[value] = newIndex + 1;
                modified[m] = lowIdx;
                modified[m + 1] = newIndex;
            }

            unchecked {
                ++self.size;
                m += 2;
                ++i;
            }
        }

        _recompute(self, modified);
    }

    /// @dev Removes `value` and tombstones its slot, which is never reused (shifting
    /// leaves would invalidate existing proofs). `predecessorIndex` is the leaf whose
    /// `nextValue` is `value`.
    function _remove(LeanIMTPlusSha256Data storage self, uint256 value, uint256 predecessorIndex) internal {
        uint256 slotPlusOne = self.valueIndex[value];
        if (slotPlusOne == 0) revert LeafDoesNotExist();
        uint256 slot = slotPlusOne - 1;

        LeanIMTPlusSha256Leaf storage pred = self.leaves[predecessorIndex];
        if (pred.nextValue != value) revert WrongPredecessor();

        uint256 removedNext = self.leaves[slot].nextValue;
        _writeLeaf(self, predecessorIndex, pred.value, removedNext);
        _writeLeaf(self, slot, 0, 0);
        self.valueIndex[value] = 0;
        unchecked {
            --self.size;
        }

        uint256[] memory modified = new uint256[](2);
        modified[0] = predecessorIndex;
        modified[1] = slot;
        _recompute(self, modified);
    }

    /// @dev Replaces `oldValue` with `newValue` in its slot (no tombstone, cheaper than
    /// remove + insert). `newPredecessorIndex` is `newValue`'s low leaf after `oldValue`
    /// is unlinked, so it is validated after that write (it may equal
    /// `oldPredecessorIndex`); a failed check reverts the whole call.
    function _update(
        LeanIMTPlusSha256Data storage self,
        uint256 oldValue,
        uint256 newValue,
        uint256 oldPredecessorIndex,
        uint256 newPredecessorIndex
    ) internal {
        _validateValue(self, newValue);
        if (oldValue == newValue) revert NewLeafCannotEqualOldLeaf();

        uint256 slotPlusOne = self.valueIndex[oldValue];
        if (slotPlusOne == 0) revert LeafDoesNotExist();
        uint256 slot = slotPlusOne - 1;

        LeanIMTPlusSha256Leaf storage oldPred = self.leaves[oldPredecessorIndex];
        if (oldPred.nextValue != oldValue) revert WrongPredecessor();

        // The reused slot still holds the old record, which `_isLowLeaf` would accept,
        // so it must be rejected explicitly as the new predecessor.
        if (newPredecessorIndex == slot) revert InvalidLowLeaf();

        uint256 removedNext = self.leaves[slot].nextValue;
        _writeLeaf(self, oldPredecessorIndex, oldPred.value, removedNext);
        self.valueIndex[oldValue] = 0;

        LeanIMTPlusSha256Leaf storage newLow = self.leaves[newPredecessorIndex];
        uint256 newLowValue = newLow.value;
        uint256 newLowNext = newLow.nextValue;
        if (!_isLowLeaf(newPredecessorIndex, newLowValue, newLowNext, newValue)) {
            revert InvalidLowLeaf();
        }

        _writeLeaf(self, slot, newValue, newLowNext);
        _writeLeaf(self, newPredecessorIndex, newLowValue, newValue);
        self.valueIndex[newValue] = slot + 1;

        uint256[] memory modified = new uint256[](3);
        modified[0] = oldPredecessorIndex;
        modified[1] = slot;
        modified[2] = newPredecessorIndex;
        _recompute(self, modified);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Proof verification (proofs are generated off-chain)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Verifies `proof` and requires its root to be the tree's current root.
    function _verifyProofAgainstTree(
        LeanIMTPlusSha256Data storage self,
        LeanIMTPlusSha256Proof memory proof
    ) internal view returns (bool) {
        return proof.root == _root(self) && _verifyProof(proof);
    }

    /// @dev Verifies `proof` against its own `proof.root`. Returns false on failure.
    /// SECURITY: `proof.root` is caller-controlled; check it is a trusted root, or use
    /// {_verifyProofAgainstTree}.
    function _verifyProof(LeanIMTPlusSha256Proof memory proof) internal view returns (bool) {
        uint256 nSiblings = proof.siblings.length;

        // Structural checks; `leafIndex` must not have bits beyond the sibling count.
        if (proof.proofType > 1) return false;
        if (nSiblings > 256) return false;
        if (nSiblings < 256 && proof.leafIndex >= (uint256(1) << nSiblings)) return false;

        uint256 value = proof.value;
        uint256 leafValue = proof.leafValue;
        uint256 leafNext = proof.leafNextValue;

        // Zero is reserved for the sentinel and tombstones.
        if (value == 0) return false;

        if (proof.proofType == 0) {
            if (leafValue != value) return false;
        } else {
            // The leaf must be the low leaf of `value`.
            if (!(leafValue < value)) return false;
            if (leafNext != 0 && !(value < leafNext)) return false;
            // Tombstone replay guard: only the sentinel (index 0) may have value 0.
            if (leafValue == 0 && proof.leafIndex != 0) return false;
        }

        uint256 node = _hashLeaf(leafValue, leafNext);
        uint256 index = proof.leafIndex;
        for (uint256 i = 0; i < nSiblings; ) {
            uint256 sibling = proof.siblings[i];
            if ((index >> i) & 1 == 1) {
                node = _hashNode(sibling, node);
            } else {
                node = _hashNode(node, sibling);
            }
            unchecked {
                ++i;
            }
        }

        return node == proof.root;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    function _root(LeanIMTPlusSha256Data storage self) internal view returns (uint256) {
        if (self.leaves.length == 0) return 0;
        return self.nodes[self.depth][0];
    }

    function _has(LeanIMTPlusSha256Data storage self, uint256 value) internal view returns (bool) {
        return self.valueIndex[value] != 0;
    }

    /// @dev Index of the leaf holding `value`. Reverts if absent.
    function _indexOf(LeanIMTPlusSha256Data storage self, uint256 value) internal view returns (uint256) {
        uint256 idxPlusOne = self.valueIndex[value];
        if (idxPlusOne == 0) revert LeafDoesNotExist();
        return idxPlusOne - 1;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _validateValue(LeanIMTPlusSha256Data storage self, uint256 value) private view {
        if (value == 0) revert LeafCannotBeZero();
        if (self.valueIndex[value] != 0) revert LeafAlreadyExists();
    }

    /// @dev True if the leaf brackets `value` (`leafValue < value < leafNext`, or tail).
    /// A value-0 leaf is only valid at index 0 (sentinel); elsewhere it is a tombstone.
    function _isLowLeaf(uint256 index, uint256 leafValue, uint256 leafNext, uint256 value) private pure returns (bool) {
        if (leafValue == 0 && index != 0) return false;
        return leafValue < value && (leafNext == 0 || leafNext > value);
    }

    function _appendLeaf(
        LeanIMTPlusSha256Data storage self,
        uint256 value,
        uint256 nextValue
    ) private returns (uint256 index) {
        index = self.leaves.length;
        self.leaves.push(LeanIMTPlusSha256Leaf({value: value, nextValue: nextValue}));
        self.nodes[0].push(_hashLeaf(value, nextValue));
    }

    function _writeLeaf(LeanIMTPlusSha256Data storage self, uint256 index, uint256 value, uint256 nextValue) private {
        self.leaves[index] = LeanIMTPlusSha256Leaf({value: value, nextValue: nextValue});
        self.nodes[0][index] = _hashLeaf(value, nextValue);
    }

    /// @dev Grows the levels as needed and rehashes every node above the modified
    /// level-0 indices, each at most once.
    function _recompute(LeanIMTPlusSha256Data storage self, uint256[] memory modifiedLeaves) private {
        uint256 leafCount = self.nodes[0].length;
        uint256 targetDepth = _depthForLeaves(leafCount);

        // New slots are zero-filled here; every one lies on a modified path, so the loop
        // below overwrites it.
        for (uint256 level = 1; level <= targetDepth; ) {
            uint256 want = (self.nodes[level - 1].length + 1) >> 1;
            uint256 have = self.nodes[level].length;
            while (have < want) {
                self.nodes[level].push(0);
                unchecked {
                    ++have;
                }
            }
            unchecked {
                ++level;
            }
        }
        self.depth = targetDepth;

        if (targetDepth == 0) return;

        uint256[] memory current = _sortDedupe(modifiedLeaves);

        for (uint256 level = 1; level <= targetDepth; ) {
            uint256[] memory parents = _parentsOf(current);
            uint256 childCount = self.nodes[level - 1].length;
            for (uint256 j = 0; j < parents.length; ) {
                _recomputeNode(self, level, parents[j], childCount);
                unchecked {
                    ++j;
                }
            }
            current = parents;
            unchecked {
                ++level;
            }
        }
    }

    /// @dev Rehashes `nodes[level][p]`. A separate function to avoid "stack too deep"
    /// without viaIR.
    function _recomputeNode(LeanIMTPlusSha256Data storage self, uint256 level, uint256 p, uint256 childCount) private {
        uint256 leftIdx = p << 1;
        uint256 left = self.nodes[level - 1][leftIdx];
        uint256 rightIdx = leftIdx + 1;
        // A node without a right child is promoted unchanged.
        self.nodes[level][p] = rightIdx < childCount ? _hashNode(left, self.nodes[level - 1][rightIdx]) : left;
    }

    /// @dev `ceil(log2(n))`, or 0 for `n <= 1`.
    function _depthForLeaves(uint256 n) private pure returns (uint256 depth) {
        if (n <= 1) return 0;
        uint256 capacity = 1;
        while (capacity < n) {
            capacity <<= 1;
            unchecked {
                ++depth;
            }
        }
    }

    /// @dev Insertion sort + dedupe. Fine for the small, batch-capped input.
    function _sortDedupe(uint256[] memory arr) private pure returns (uint256[] memory) {
        uint256 n = arr.length;
        for (uint256 a = 1; a < n; ) {
            uint256 key = arr[a];
            uint256 b = a;
            while (b > 0 && arr[b - 1] > key) {
                arr[b] = arr[b - 1];
                unchecked {
                    --b;
                }
            }
            arr[b] = key;
            unchecked {
                ++a;
            }
        }
        return _dedupeSorted(arr, n);
    }

    /// @dev Unique parent indices (`child >> 1`) of sorted child indices.
    function _parentsOf(uint256[] memory sortedChildren) private pure returns (uint256[] memory) {
        uint256 n = sortedChildren.length;
        uint256[] memory parents = new uint256[](n);
        for (uint256 i = 0; i < n; ) {
            parents[i] = sortedChildren[i] >> 1;
            unchecked {
                ++i;
            }
        }
        return _dedupeSorted(parents, n);
    }

    /// @dev Removes adjacent duplicates from the first `n` sorted entries of `arr`.
    function _dedupeSorted(uint256[] memory arr, uint256 n) private pure returns (uint256[] memory) {
        if (n == 0) return new uint256[](0);
        uint256 unique = 1;
        for (uint256 i = 1; i < n; ) {
            if (arr[i] != arr[i - 1]) {
                arr[unique] = arr[i];
                unchecked {
                    ++unique;
                }
            }
            unchecked {
                ++i;
            }
        }
        uint256[] memory out = new uint256[](unique);
        for (uint256 i = 0; i < unique; ) {
            out[i] = arr[i];
            unchecked {
                ++i;
            }
        }
        return out;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Hashing (SHA-256 precompile at address 0x02)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev `sha256(value || nextValue || TAG_LEAF)`.
    function _hashLeaf(uint256 value, uint256 nextValue) private view returns (uint256 result) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            // 96 bytes exceed the scratch space: use free memory without allocating it.
            let ptr := mload(0x40)
            mstore(ptr, value)
            mstore(add(ptr, 0x20), nextValue)
            mstore(add(ptr, 0x40), TAG_LEAF)
            if iszero(staticcall(gas(), 0x02, ptr, 0x60, 0x00, 0x20)) {
                revert(0, 0)
            }
            result := mload(0x00)
        }
    }

    /// @dev `sha256(left || right)`, built in the scratch space.
    function _hashNode(uint256 left, uint256 right) private view returns (uint256 result) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            mstore(0x00, left)
            mstore(0x20, right)
            if iszero(staticcall(gas(), 0x02, 0x00, 0x40, 0x00, 0x20)) {
                revert(0, 0)
            }
            result := mload(0x00)
        }
    }
}
