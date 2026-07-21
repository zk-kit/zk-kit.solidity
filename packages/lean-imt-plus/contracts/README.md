<p align="center">
    <h1 align="center">LeanIMT+ (Solidity)</h1>
    <p align="center">A Lean Incremental Merkle Tree with membership <b>and</b> non-membership proofs.</p>
</p>

LeanIMT+ extends the [LeanIMT](https://github.com/zk-kit/zk-kit.solidity/tree/main/packages/lean-imt)
with the indexed-leaf design of the Indexed Merkle Tree,
so it can prove that a value is **not** in the tree without revealing the full
leaf set.

It keeps everything that makes the LeanIMT efficient:

-   **Dynamic depth** `ceil(log2(n))` that grows only as needed.
-   **No zero hashes**: an unpaired (odd) node is promoted unchanged to the next
    level instead of being hashed against a precomputed zero.

and adds a **sorted implicit linked list** over the inserted values, so a single
Merkle proof of a value's predecessor proves the value is absent.

---

## How it works

Each leaf is a record `{ value, nextValue }`. The leaves form an implicit sorted
singly-linked list: a leaf whose `nextValue` is `v` logically points to the leaf
whose `value` is `v` (leaves are linked **by value**, not by physical index).

Three leaf states are encoded purely by the field values:

| State         | `value` | `nextValue`                      | Where                     |
| ------------- | ------- | -------------------------------- | ------------------------- |
| **sentinel**  | `0`     | smallest active value (`> 0`)    | always physical index `0` |
| **active**    | `> 0`   | next-larger value, or `0` (tail) | any index `>= 1`          |
| **tombstone** | `0`     | `0`                              | a slot left by `remove`   |

The level-0 commitment of a leaf is `H_leaf(value, nextValue, TAG_LEAF)`, a
**3-input** Poseidon hash (`PoseidonT4`). Internal nodes use a **2-input**
Poseidon hash (`PoseidonT3`): `H_internal(left, right)`. The different arity plus
the `TAG_LEAF` constant give **domain separation** (a leaf commitment can never
collide with an internal-node hash), which closes a second-preimage attack where
an internal node is repackaged as a leaf. See [`Constants.sol`](./Constants.sol).

### Low-leaf lookups are served off-chain

Finding a value's predecessor ("low leaf") on-chain would be `O(n)`. Instead the
caller passes the physical index of the low leaf and the library validates it in
`O(1)` (`value_low < value < value_low.next`, or the low leaf is the tail),
exactly as the Indexed Merkle Tree does. Every mutation therefore costs
`O(depth)` storage writes while the contract still fully enforces the sorted-list
invariant. An off-chain client finds the low leaf with any ordered index (an AVL
tree, a sorted array + binary search, ...); see the TypeScript reference
[`@zk-kit/lean-imt-plus`](https://www.npmjs.com/package/@zk-kit/lean-imt-plus).

### Full node table on-chain

Unlike the append-only LeanIMT (which stores only side nodes), LeanIMT+ rewrites
an arbitrary low leaf on every insert, so its sibling paths cannot be
reconstructed from side nodes. The library keeps the full node table, which lets
it recompute the affected paths and build proofs entirely on-chain, without
trusting caller-supplied sibling data. This is the most gas-efficient design for
on-chain mutation and proof generation; the tradeoff is `O(n)` on-chain storage.

---

## Operations

-   **`insert(value, lowLeafIndex)`**: appends `{value, low.nextValue}`, rewires the
    low leaf to point at `value`. The first insert also creates the sentinel.
-   **`insertMany(values, lowLeafIndices)`**: inserts a batch in one call. Same effect
    as one `insert` per value, but every affected internal node is rehashed at most once
    (a single recompute at the end), so it is cheaper than the equivalent loop.
    `lowLeafIndices[i]` is `values[i]`'s low leaf in the list after the earlier batch
    values are inserted. Reverts atomically on any bad value or low leaf.
-   **`remove(value, predecessorIndex)`**: relinks the list around `value`, then
    **tombstones** its slot (`{0, 0}`). Slots are never reused (Merkle positions are
    addressable), so proofs stay valid.
-   **`update(oldValue, newValue, oldPredecessorIndex, newPredecessorIndex)`**:
    replaces a value **in place**, reusing the old slot: no tombstone, the leaf array
    does not grow, cheaper than `remove` + `insert`. All checks run before any
    mutation, so it is all-or-nothing.
-   **`verifyProof(proof)` / `verifyProof(self, proof)`**: stateless verification, or
    verification pinned to the tree's current root.
-   **`has(value)`, `indexOf(value)`, `root()`**: views, matching the LeanIMT surface.

The on-chain API mirrors the LeanIMT (mutations + `has` / `indexOf` / `root`) plus
`verifyProof`. Proofs are **generated off-chain** by a client that mirrors the tree
(the TypeScript reference [`@zk-kit/lean-imt-plus`](https://www.npmjs.com/package/@zk-kit/lean-imt-plus)),
exactly as with the LeanIMT; the library only verifies them.

## Non-membership verification checks

For `proofType = 1` the verifier requires, on top of a valid Merkle path:

-   `leaf.value < value` and (`leaf.nextValue == 0` or `value < leaf.nextValue`);
-   the **tombstone replay guard**: a `value == 0` leaf is only accepted at index `0`
    (the sentinel). Any other `value == 0` leaf is a tombstone and is rejected, so a
    removed slot cannot be replayed to forge non-membership of an arbitrary value.

The zero value is rejected for both proof types (it is reserved for the sentinel
and tombstones), and `leafIndex` is range-checked so its bit encoding is canonical.

---

## Files

| File                                                     | Purpose                                           |
| -------------------------------------------------------- | ------------------------------------------------- |
| [`Constants.sol`](./Constants.sol)                       | `SNARK_SCALAR_FIELD`, `TAG_LEAF`.                 |
| [`InternalLeanIMTPlus.sol`](./InternalLeanIMTPlus.sol)   | Core library (all logic, `internal` functions).   |
| [`LeanIMTPlus.sol`](./LeanIMTPlus.sol)                   | `public` wrapper for a single shared deployment.  |
| [`test/LeanIMTPlusTest.sol`](./test/LeanIMTPlusTest.sol) | Harness used by the test suite and gas benchmark. |

## Usage

```solidity
import { LeanIMTPlus } from "@zk-kit/lean-imt-plus.sol/LeanIMTPlus.sol";
import { LeanIMTPlusData, LeanIMTPlusProof } from "@zk-kit/lean-imt-plus.sol/InternalLeanIMTPlus.sol";

contract Registry {
    using LeanIMTPlus for LeanIMTPlusData;

    LeanIMTPlusData internal tree;

    function add(uint256 value, uint256 lowLeafIndex) external {
        tree.insert(value, lowLeafIndex); // lowLeafIndex is found off-chain
    }

    function isNotRevoked(LeanIMTPlusProof calldata proof) external view returns (bool) {
        return proof.proofType == 1 && tree.verifyProof(proof);
    }
}
```

`InternalLeanIMTPlus`'s functions are `internal`, so importing and `using` it
inlines the code (no deployment). `LeanIMTPlus` exposes the same API as `public`
functions and links to the `PoseidonT3` / `PoseidonT4` libraries, so it can be
deployed once and shared. See [`test/LeanIMTPlusTest.sol`](./test/LeanIMTPlusTest.sol)
and the [test suite](../test/LeanIMTPlus.ts) for the linking pattern.

## Security notes

-   All values must be non-zero and `< SNARK_SCALAR_FIELD`.
-   Second-preimage resistance via leaf/internal domain separation (arity + `TAG_LEAF`).
-   Tombstone replay guard on non-membership proofs.
-   Low-leaf and predecessor indices supplied by the caller are always validated
    on-chain; a wrong index reverts.
-   `verifyProof` rejects any `value`, `leafValue`, `leafNextValue` or sibling that is
    `>= SNARK_SCALAR_FIELD`. Poseidon reduces its inputs mod the field, so without this
    an attacker could add `FIELD` to a proof field to break the (raw `uint256`)
    ordering checks while keeping the commitment unchanged, forging non-membership of a
    present value. Legitimate proofs are always in-field, so the check is transparent.
-   The stateless `verifyProof(proof)` overload trusts the caller-supplied `proof.root`;
    integrators must compare it against a trusted root, or use the root-pinned
    `verifyProof(self, proof)` overload.
-   No external calls except to the pure/`view` Poseidon libraries, so there is no
    reentrancy surface.

## Integration security (must-do for safe use)

The library is a data structure with **no access control of its own** and does not
constrain how proofs are consumed. A safe deployment must:

1. **Gate the mutations.** Anyone able to reach a function that calls `insert` /
   `insertMany` / `remove` / `update` can mutate the tree. Add your own authorization.
   Do **not** deploy `test/LeanIMTPlusTest.sol`; it is an unguarded test harness.
2. **Pin the root when verifying.** Prefer `verifyProof(self, proof)`, which checks
   against the tree's current root. The stateless `verifyProof(proof)` trusts the
   caller-supplied `proof.root`, so only use it after comparing that root against one
   you trust (e.g. a current or historical root you stored yourself).
3. **Link the genuine Poseidon libraries.** All commitments come from the linked
   `PoseidonT3` / `PoseidonT4`; link the audited `poseidon-solidity` build.
4. **Prefer `update` over `remove` + `insert`.** Removed slots are tombstoned and never
   reused, so heavy remove/insert churn grows the tree depth (and per-op gas) over time;
   an in-place `update` avoids the tombstone.
5. **Batch within the cap.** `insertMany` accepts at most `MAX_INSERT_MANY_BATCH` (256)
   values per call; split larger inputs across calls.
