// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {PoseidonT4} from "poseidon-solidity/PoseidonT4.sol";
import {SNARK_SCALAR_FIELD, TAG_LEAF} from "./Constants.sol";

/// @dev An indexed leaf. Leaves form an *implicit* sorted singly-linked list:
/// a leaf whose `nextValue` is `v` logically points to the leaf whose `value`
/// is `v` (leaves are linked by value, not by physical index).
///
/// Three states are encoded purely by the field values, no separate type flag:
///  - sentinel  (always physical index 0): `value = 0`, `nextValue = firstReal > 0`;
///  - active user leaf:                     `value > 0`;
///  - tombstone (after `remove`):           `value = 0`, `nextValue = 0`.
struct LeanIMTPlusLeaf {
    uint256 value;
    uint256 nextValue;
}

/// @dev A unified membership / non-membership proof.
///
/// `leafValue`, `leafNextValue`, `leafIndex` and `siblings` form a standard
/// LeanIMT Merkle proof of `hashLeaf(leafValue, leafNextValue, TAG_LEAF)` against
/// `root`. `proofType` selects the extra check the verifier must run:
///  - `0` (membership):     `leafValue == value`;
///  - `1` (non-membership): the leaf is the *low leaf* of `value`
///                          (`leafValue < value < leafNextValue`, or `leafNextValue == 0`).
///
/// `leafIndex` is the *compacted* path: because LeanIMT promotes unpaired (odd)
/// nodes unchanged instead of hashing them against a zero, levels where the leaf's
/// ancestor had no sibling are skipped entirely, both in `siblings` and in the
/// packed bits of `leafIndex`. Bit `i` of `leafIndex` is the direction taken at the
/// `i`-th recorded sibling (`0` = current node is the left child, `1` = right).
struct LeanIMTPlusProof {
    uint8 proofType;
    uint256 root;
    uint256 value;
    uint256 leafValue;
    uint256 leafNextValue;
    uint256 leafIndex;
    uint256[] siblings;
}

/// @dev In-storage state of a LeanIMT+.
///
/// The full node table is stored on-chain rather
/// than only the append-path side nodes (like the LeanIMT). LeanIMT+ must rewrite
/// an arbitrary *low leaf* on every insertion, so its sibling paths cannot be
/// reconstructed from side nodes alone; keeping every node lets the library
/// recompute affected paths and build proofs entirely on-chain, without trusting
/// caller-supplied sibling data. This is the most gas-efficient design for on-chain
/// mutation and proof generation, at the cost of `O(n)` storage.
struct LeanIMTPlusData {
    // Indexed-leaf records, parallel to `nodes[0]`. Index 0 is always the sentinel.
    LeanIMTPlusLeaf[] leaves;
    // level => node hashes. `nodes[0]` holds the leaf commitments; the root lives
    // at `nodes[depth][0]`. Node counts follow LeanIMT: `nodes[l].length ==
    // ceil(nodes[l-1].length / 2)`, and unpaired nodes are promoted unchanged.
    mapping(uint256 level => uint256[] hashes) nodes;
    // Number of levels above the leaves. `depth == 0` while the tree holds <= 1 leaf.
    uint256 depth;
    // value => (physical index in `leaves` + 1); 0 means the value is absent.
    // Only active (value > 0) leaves are tracked; the sentinel and tombstones are not.
    mapping(uint256 value => uint256 indexPlusOne) valueIndex;
    // Number of active user values (excludes the sentinel and every tombstone).
    uint256 size;
}

error LeafCannotBeZero();
error LeafGreaterThanSnarkScalarField();
error LeafAlreadyExists();
error LeafDoesNotExist();
error NewLeafCannotEqualOldLeaf();
error InvalidLowLeaf();
error WrongPredecessor();
error MismatchedArrayLengths();
error BatchTooLarge();

/// @title LeanIMT+ internal library.
/// @notice A Lean Incremental Merkle Tree extended with non-membership proofs by
/// adopting the indexed-leaf design of the Indexed Merkle Tree.
///
/// @dev LeanIMT+ keeps every property that makes the LeanIMT efficient: dynamic
/// depth (`ceil(log2(n))`), no zero hashes (unpaired nodes are promoted unchanged),
/// and a small leaf commitment, and adds a sorted implicit linked list over the
/// inserted values so that a single Merkle proof of a value's *predecessor* proves
/// the value is absent.
///
/// Predecessor ("low leaf") lookups are served off-chain: the caller passes the
/// physical index of the low leaf and the library validates it in O(1). This keeps every mutation at O(depth) storage
/// writes while the contract still fully verifies the ordering invariant.
///
/// Hashing is domain-separated: leaf commitments use a 3-input Poseidon hash
/// (`PoseidonT4`) mixing in `TAG_LEAF`, internal nodes use a 2-input Poseidon hash
/// (`PoseidonT3`). See {Constants}.
library InternalLeanIMTPlus {
    /// @dev Upper bound on the number of values a single {_insertMany} call accepts.
    /// The batched {_recompute} sorts a working set of up to `2 * batch` indices, so a
    /// cap keeps that cost bounded on chains with high block gas limits (on Ethereum
    /// L1 the per-value Poseidon hashing already limits a batch to far fewer than this).
    /// Larger inputs must be split across calls.
    uint256 internal constant MAX_INSERT_MANY_BATCH = 256;

    // ─────────────────────────────────────────────────────────────────────────
    // Mutations
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Inserts `value`. `lowLeafIndex` must be the physical index of the
    /// value's predecessor in the sorted list (its "low leaf"); it is validated
    /// and ignored only for the very first insertion, which additionally creates
    /// the sentinel leaf `{0, value}` at index 0. Returns the physical index of
    /// the newly inserted leaf.
    function _insert(LeanIMTPlusData storage self, uint256 value, uint256 lowLeafIndex) internal returns (uint256) {
        _validateValue(self, value);

        // First-ever insertion: create the sentinel {0, value} and the first leaf.
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

        LeanIMTPlusLeaf storage low = self.leaves[lowLeafIndex];
        uint256 lowValue = low.value;
        uint256 lowNext = low.nextValue;
        if (!_isLowLeaf(lowLeafIndex, lowValue, lowNext, value)) {
            revert InvalidLowLeaf();
        }

        // The new leaf inherits the low leaf's successor; the low leaf now points
        // at `value`.
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

    /// @dev Inserts many values in one pass. Equivalent in effect to calling {_insert}
    /// once per value in array order, but every affected internal node is rehashed at
    /// most once (a single {_recompute} at the end instead of one per value), so a
    /// batch is cheaper than the same inserts made one by one. `lowLeafIndices[i]` is
    /// the physical index of `values[i]`'s low leaf in the list *after* `values[0..i-1]`
    /// have been inserted; it is ignored for the value that creates the sentinel (the
    /// first insert into an empty tree). At most {MAX_INSERT_MANY_BATCH} values per
    /// call. Reverts, rolling back the whole batch, on any invalid value or low leaf.
    function _insertMany(
        LeanIMTPlusData storage self,
        uint256[] calldata values,
        uint256[] calldata lowLeafIndices
    ) internal {
        uint256 n = values.length;
        if (n != lowLeafIndices.length) revert MismatchedArrayLengths();
        if (n > MAX_INSERT_MANY_BATCH) revert BatchTooLarge();
        if (n == 0) return;

        // Each value modifies exactly two level-0 slots: its low leaf (or the sentinel)
        // and the newly appended leaf. `_recompute` sorts and de-duplicates these.
        uint256[] memory modified = new uint256[](2 * n);
        uint256 m = 0;

        for (uint256 i = 0; i < n; ) {
            uint256 value = values[i];
            _validateValue(self, value);

            if (self.leaves.length == 0) {
                // First-ever insertion: create the sentinel {0, value} and first leaf.
                _appendLeaf(self, 0, value);
                uint256 firstIndex = _appendLeaf(self, value, 0);
                self.valueIndex[value] = firstIndex + 1;
                modified[m] = 0;
                modified[m + 1] = firstIndex;
            } else {
                uint256 lowIdx = lowLeafIndices[i];
                LeanIMTPlusLeaf storage low = self.leaves[lowIdx];
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

        // Single batched recompute over the union of every modified path.
        _recompute(self, modified);
    }

    /// @dev Removes `value`. The slot is *tombstoned* (`{0, 0}`) rather than
    /// physically deleted (Merkle positions are addressable, so shifting them
    /// would invalidate every outstanding proof) and it is never reused.
    /// `predecessorIndex` must be the physical index of the leaf whose `nextValue`
    /// equals `value` (the sentinel when `value` is the smallest active value).
    function _remove(LeanIMTPlusData storage self, uint256 value, uint256 predecessorIndex) internal {
        uint256 slotPlusOne = self.valueIndex[value];
        if (slotPlusOne == 0) revert LeafDoesNotExist();
        uint256 slot = slotPlusOne - 1;

        LeanIMTPlusLeaf storage pred = self.leaves[predecessorIndex];
        if (pred.nextValue != value) revert WrongPredecessor();

        // Relink the list around the removed leaf, then tombstone it.
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

    /// @dev Replaces `oldValue` with `newValue` in place, reusing `oldValue`'s
    /// physical slot: no tombstone is created and the leaf array does not grow, so
    /// this is strictly cheaper than a `remove` followed by an `insert`.
    ///
    /// `oldPredecessorIndex` is the index of `oldValue`'s predecessor; `newPredecessorIndex`
    /// is the index of `newValue`'s predecessor in the list *after* `oldValue` is
    /// unlinked. All preconditions are checked before any mutation, so the call
    /// either succeeds fully or reverts without touching state.
    function _update(
        LeanIMTPlusData storage self,
        uint256 oldValue,
        uint256 newValue,
        uint256 oldPredecessorIndex,
        uint256 newPredecessorIndex
    ) internal {
        _validateValue(self, newValue);
        if (oldValue == newValue) revert NewLeafCannotEqualOldLeaf();

        uint256 slotPlusOne = self.valueIndex[oldValue];
        if (slotPlusOne == 0) revert LeafDoesNotExist();
        if (self.valueIndex[newValue] != 0) revert LeafAlreadyExists();
        uint256 slot = slotPlusOne - 1;

        LeanIMTPlusLeaf storage oldPred = self.leaves[oldPredecessorIndex];
        if (oldPred.nextValue != oldValue) revert WrongPredecessor();

        // `newValue`'s predecessor cannot be `oldValue`'s own slot: that slot is
        // being repurposed for `newValue`, and until the splice below it still holds
        // the (now unlinked) old record, which `_isLowLeaf` would not reject as a
        // tombstone. Rejecting it prevents the double-write from corrupting the slot.
        if (newPredecessorIndex == slot) revert InvalidLowLeaf();

        // Unlink `oldValue`: its predecessor takes over its successor. The physical
        // slot itself is left for the splice below (no tombstone commitment written).
        uint256 removedNext = self.leaves[slot].nextValue;
        _writeLeaf(self, oldPredecessorIndex, oldPred.value, removedNext);
        self.valueIndex[oldValue] = 0;

        // Splice `newValue` into the (post-unlink) list at its predecessor.
        LeanIMTPlusLeaf storage newLow = self.leaves[newPredecessorIndex];
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
    // Proof verification
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Proofs are *generated off-chain* by a client that mirrors the tree (see the
    // TypeScript reference `@zk-kit/lean-imt-plus`), exactly as with the LeanIMT.
    // The library only verifies them.

    /// @dev Verifies `proof` against this tree instance: the proof must be
    /// internally consistent (see {_verifyProof}) and its `root` must equal the
    /// tree's current root.
    function _verifyProofAgainstTree(
        LeanIMTPlusData storage self,
        LeanIMTPlusProof memory proof
    ) internal view returns (bool) {
        return proof.root == _root(self) && _verifyProof(proof);
    }

    /// @dev Stateless verification of a LeanIMT+ proof. Runs every structural,
    /// field-range and ordering check and recomputes the Merkle root from the leaf
    /// and siblings. Returns false (never reverts) on any failure.
    ///
    /// SECURITY: this checks the proof against the `root` embedded in `proof`, which
    /// the caller controls. It does not bind the proof to any real tree. Callers must
    /// separately verify `proof.root` is a trusted root, or use
    /// {_verifyProofAgainstTree}, which pins it to the tree's current root.
    function _verifyProof(LeanIMTPlusProof memory proof) internal pure returns (bool) {
        uint256 nSiblings = proof.siblings.length;

        // Structural sanity: `leafIndex`'s meaningful bits live in [0, nSiblings);
        // any higher bit must be zero so the encoding is canonical. A real tree's
        // depth (hence the sibling count) can never exceed 256, so a larger array is
        // rejected outright rather than iterated.
        if (proof.proofType > 1) return false;
        if (nSiblings > 256) return false;
        if (nSiblings < 256 && proof.leafIndex >= (uint256(1) << nSiblings)) return false;

        uint256 value = proof.value;
        uint256 leafValue = proof.leafValue;
        uint256 leafNext = proof.leafNextValue;

        // Every field element in a legitimate proof is < SNARK_SCALAR_FIELD. Rejecting
        // out-of-field inputs closes a malleability: Poseidon reduces its inputs mod the
        // field, so `v + FIELD` would hash identically to `v`, and the ordering checks
        // below use raw uint256 comparisons. Enforcing the range makes both consistent.
        if (value >= SNARK_SCALAR_FIELD || leafValue >= SNARK_SCALAR_FIELD || leafNext >= SNARK_SCALAR_FIELD) {
            return false;
        }

        // The zero value is reserved for the sentinel and tombstones; it can never
        // be a queried value for either proof type.
        if (value == 0) return false;

        if (proof.proofType == 0) {
            // Membership: the leaf carries exactly the queried value. Active values
            // are > 0, so this also rules out sentinel/tombstone leaves.
            if (leafValue != value) return false;
        } else {
            // Non-membership: the leaf is the low leaf of `value`.
            if (!(leafValue < value)) return false;
            if (leafNext != 0 && !(value < leafNext)) return false;
            // Tombstone replay guard: only the sentinel (index 0) may carry value 0.
            // Any other value-0 leaf is a tombstone and must not pass as a low leaf.
            if (leafValue == 0 && proof.leafIndex != 0) return false;
        }

        uint256 node = PoseidonT4.hash([leafValue, leafNext, TAG_LEAF]);
        uint256 index = proof.leafIndex;
        for (uint256 i = 0; i < nSiblings; ) {
            uint256 sibling = proof.siblings[i];
            if (sibling >= SNARK_SCALAR_FIELD) return false;
            if ((index >> i) & 1 == 1) {
                node = PoseidonT3.hash([sibling, node]);
            } else {
                node = PoseidonT3.hash([node, sibling]);
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

    function _root(LeanIMTPlusData storage self) internal view returns (uint256) {
        if (self.leaves.length == 0) return 0;
        return self.nodes[self.depth][0];
    }

    function _has(LeanIMTPlusData storage self, uint256 value) internal view returns (bool) {
        return value != 0 && self.valueIndex[value] != 0;
    }

    /// @dev Physical index of the leaf holding `value`. Reverts if `value` is absent.
    function _indexOf(LeanIMTPlusData storage self, uint256 value) internal view returns (uint256) {
        uint256 idxPlusOne = self.valueIndex[value];
        if (idxPlusOne == 0) revert LeafDoesNotExist();
        return idxPlusOne - 1;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _validateValue(LeanIMTPlusData storage self, uint256 value) private view {
        if (value == 0) revert LeafCannotBeZero();
        if (value >= SNARK_SCALAR_FIELD) revert LeafGreaterThanSnarkScalarField();
        if (self.valueIndex[value] != 0) revert LeafAlreadyExists();
    }

    /// @dev A leaf at `index` is a valid low leaf ("insertion point") for `value`
    /// iff `leafValue < value` and either the leaf is the tail (`leafNext == 0`) or
    /// `leafNext > value`. Value 0 is only legitimate for the sentinel at index 0;
    /// a value-0 leaf anywhere else is a tombstone and is rejected.
    function _isLowLeaf(uint256 index, uint256 leafValue, uint256 leafNext, uint256 value) private pure returns (bool) {
        if (leafValue == 0 && index != 0) return false;
        return leafValue < value && (leafNext == 0 || leafNext > value);
    }

    /// @dev Appends a fresh leaf and its commitment. Returns the physical index.
    function _appendLeaf(
        LeanIMTPlusData storage self,
        uint256 value,
        uint256 nextValue
    ) private returns (uint256 index) {
        index = self.leaves.length;
        self.leaves.push(LeanIMTPlusLeaf({value: value, nextValue: nextValue}));
        self.nodes[0].push(PoseidonT4.hash([value, nextValue, TAG_LEAF]));
    }

    /// @dev Overwrites the leaf at `index` and its level-0 commitment.
    function _writeLeaf(LeanIMTPlusData storage self, uint256 index, uint256 value, uint256 nextValue) private {
        self.leaves[index] = LeanIMTPlusLeaf({value: value, nextValue: nextValue});
        self.nodes[0][index] = PoseidonT4.hash([value, nextValue, TAG_LEAF]);
    }

    /// @dev Recomputes every internal node affected by the given modified level-0
    /// indices, growing the tree structure as needed. `modifiedLeaves` holds 2 indices
    /// for insert/remove, 3 for update, or up to `2 * MAX_INSERT_MANY_BATCH` for a
    /// batch insert; it is sorted and de-duplicated so each affected node is rehashed
    /// at most once. Level-0 commitments must already be written.
    function _recompute(LeanIMTPlusData storage self, uint256[] memory modifiedLeaves) private {
        uint256 leafCount = self.nodes[0].length;
        uint256 targetDepth = _depthForLeaves(leafCount);

        // Grow each level to its correct length (ceil of the level below). Every
        // append in this library extends the leaf array contiguously and every
        // appended leaf's index is included in `modifiedLeaves`, so each newly
        // created internal slot lies on the path of a modified leaf and is filled
        // by the loop below (no stale zero is left behind).
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
                uint256 p = parents[j];
                uint256 leftIdx = p << 1;
                uint256 left = self.nodes[level - 1][leftIdx];
                uint256 rightIdx = leftIdx + 1;
                // Odd-node promotion: a node without a right child is promoted unchanged.
                self.nodes[level][p] = rightIdx < childCount
                    ? PoseidonT3.hash([left, self.nodes[level - 1][rightIdx]])
                    : left;
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

    /// @dev `ceil(log2(n))` for `n >= 2`, and 0 for `n <= 1`. This is the LeanIMT
    /// dynamic depth: the minimum number of levels needed to hold `n` leaves.
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

    /// @dev Sorts a memory array ascending and removes duplicates. Sorting groups the
    /// duplicates that {_dedupeSorted} then collapses (it only removes adjacent equals),
    /// so each affected node is recomputed once. The array is tiny for single mutations
    /// (<= 3) and bounded by `2 * MAX_INSERT_MANY_BATCH` for a batch.
    function _sortDedupe(uint256[] memory arr) private pure returns (uint256[] memory) {
        uint256 n = arr.length;
        // Insertion sort: fine for the small, batch-capped working set here.
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

    /// @dev Maps each (sorted, unique) child index to its parent `child >> 1` and
    /// removes the duplicates that arise when two children share a parent.
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

    /// @dev Removes adjacent duplicates from the first `n` (sorted) entries of `arr`.
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
}
