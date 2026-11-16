<p align="center">
    <h1 align="center">LeanIMT+ SHA-256 (Solidity)</h1>
    <p align="center">A Lean Incremental Merkle Tree with membership <b>and</b> non-membership proofs, hashed with SHA-256.</p>
</p>

LeanIMT+ extends the [LeanIMT](https://github.com/zk-kit/zk-kit.solidity/tree/main/packages/lean-imt)
with the indexed-leaf design of the Indexed Merkle Tree,
so it can prove that a value is **not** in the tree without revealing the full
leaf set.

This package is the **SHA-256** variant of
[`@zk-kit/lean-imt-plus.sol`](https://github.com/zk-kit/zk-kit.solidity/tree/main/packages/lean-imt-plus)
(Poseidon). The tree logic, physical layout, proof format and API are identical;
only the hash function and the value range differ:

|                 | Poseidon (`lean-imt-plus.sol`)          | SHA-256 (this package)                 |
| --------------- | --------------------------------------- | -------------------------------------- |
| Leaf commitment | `Poseidon3(value, nextValue, TAG_LEAF)` | `sha256(value ‖ nextValue ‖ TAG_LEAF)` |
| Internal node   | `Poseidon2(left, right)`                | `sha256(left ‖ right)`                 |
| Values          | `0 < value < SNARK_SCALAR_FIELD`        | any non-zero `uint256`                 |
| Hash libraries  | `PoseidonT3`, `PoseidonT4` (linked)     | SHA-256 precompile (nothing to link)   |

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

Three leaf states are encoded purely by the values:

| State         | `value` | `nextValue`                      | Where                     |
| ------------- | ------- | -------------------------------- | ------------------------- |
| **sentinel**  | `0`     | smallest active value (`> 0`)    | always physical index `0` |
| **active**    | `> 0`   | next-larger value, or `0` (tail) | any index `>= 1`          |
| **tombstone** | `0`     | `0`                              | a slot left by `remove`   |

### Hashing

Every input is encoded as a **32-byte big-endian** word, and digests are the
**full, untruncated** 256-bit SHA-256 output (read as a big-endian `uint256`):

-   leaf commitment: `sha256(value ‖ nextValue ‖ TAG_LEAF)`, a **96-byte** message, with
    `TAG_LEAF = 1`;
-   internal node: `sha256(left ‖ right)`, a **64-byte** message.

Leaf and node messages have different lengths, and SHA-256 padding encodes the
length, so a leaf commitment can only equal an internal-node hash through a SHA-256
collision. This **domain separation** closes a second-preimage attack where an
internal node is repackaged as a leaf. `TAG_LEAF` keeps the leaf encoding aligned with
the Poseidon variant. See [`Constants.sol`](./Constants.sol).

Both hashes call the SHA-256 precompile (address `0x02`) directly: one call per leaf
and one per internal node.

**Test vector:** inserting `[10, 25, 7, 3, 41, 18]` in this order into an empty tree
gives the root
`0xd6cdf7216f379c8564e8eb285e9529e5df7e206cff0fdbe98df072518bed4e17`
(see the [test suite](https://github.com/zk-kit/zk-kit.solidity/blob/main/packages/lean-imt-plus-sha256/test/LeanIMTPlusSha256.ts)).

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
it recompute the affected paths entirely on-chain, without trusting
caller-supplied sibling data. This is the most gas-efficient design for on-chain
mutation; the tradeoff is `O(n)` on-chain storage.

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
    addressable), so the other leaves keep their indices. The root still changes,
    so proofs generated before the removal must be regenerated.
-   **`update(oldValue, newValue, oldPredecessorIndex, newPredecessorIndex)`**:
    replaces a value **in place**, reusing the old slot: no tombstone, the leaf array
    does not grow, cheaper than `remove` + `insert`. Any failed check reverts the
    whole call, so it is all-or-nothing.
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

| File                                                               | Purpose                                           |
| ------------------------------------------------------------------ | ------------------------------------------------- |
| [`Constants.sol`](./Constants.sol)                                 | `TAG_LEAF`.                                       |
| [`InternalLeanIMTPlusSha256.sol`](./InternalLeanIMTPlusSha256.sol) | Core library (all logic, `internal` functions).   |
| [`LeanIMTPlusSha256.sol`](./LeanIMTPlusSha256.sol)                 | `public` wrapper for a single shared deployment.  |
| [`test/LeanIMTPlusSha256Test.sol`][test-harness]                   | Harness used by the test suite and gas benchmark. |

## Usage

```solidity
import { LeanIMTPlusSha256 } from "@zk-kit/lean-imt-plus-sha256.sol/LeanIMTPlusSha256.sol";
import { LeanIMTPlusSha256Data, LeanIMTPlusSha256Proof } from "@zk-kit/lean-imt-plus-sha256.sol/InternalLeanIMTPlusSha256.sol";

contract Registry {
    using LeanIMTPlusSha256 for LeanIMTPlusSha256Data;

    LeanIMTPlusSha256Data internal tree;

    function add(uint256 value, uint256 lowLeafIndex) external {
        tree.insert(value, lowLeafIndex); // lowLeafIndex is found off-chain
    }

    function isNotRevoked(LeanIMTPlusSha256Proof calldata proof) external view returns (bool) {
        return proof.proofType == 1 && tree.verifyProof(proof);
    }
}
```

`InternalLeanIMTPlusSha256`'s functions are `internal`, so importing and `using` it
inlines the code (no deployment). `LeanIMTPlusSha256` exposes the same API as
`public` functions, so it can be deployed once and shared. It has no libraries of its
own to link. See [`test/LeanIMTPlusSha256Test.sol`][test-harness]
and the [test suite](https://github.com/zk-kit/zk-kit.solidity/blob/main/packages/lean-imt-plus-sha256/test/LeanIMTPlusSha256.ts) for the linking pattern.

Off-chain, use [`@zk-kit/lean-imt-plus`](https://www.npmjs.com/package/@zk-kit/lean-imt-plus)
with the same hashes:

```ts
import { createHash } from "crypto"
import { LeanIMTPlus } from "@zk-kit/lean-imt-plus"

const be32 = (x: bigint) => Buffer.from(x.toString(16).padStart(64, "0"), "hex")
const sha256 = (...words: bigint[]) =>
    BigInt(
        `0x${createHash("sha256")
            .update(Buffer.concat(words.map(be32)))
            .digest("hex")}`
    )

const tree = new LeanIMTPlus<bigint>({
    leaf: (value, nextValue, tag) => sha256(value, nextValue, tag),
    internal: (left, right) => sha256(left, right)
})
```

### Gas

Average gas from the test suite (`yarn test:report-gas`), using the `public` library:

| Operation    | Average gas |
| ------------ | ----------- |
| `insert`     | ~240k       |
| `insertMany` | ~543k       |
| `remove`     | ~118k       |
| `update`     | ~172k       |

Deploying `LeanIMTPlusSha256` costs ~1.5M gas. Most of each operation's cost is
storage writes; a SHA-256 hash costs only a few hundred gas.

## Security notes

-   All values must be non-zero. Any `uint256` is accepted: there is no field bound.
-   Second-preimage resistance via leaf/internal domain separation (message length
    96 vs 64 bytes, plus `TAG_LEAF`).
-   Tombstone replay guard on non-membership proofs.
-   Low-leaf and predecessor indices supplied by the caller are always validated
    on-chain; a wrong index reverts.
-   No value-range check is needed in `verifyProof`: SHA-256 hashes every bit of each
    32-byte input, so the values compared by the ordering checks are exactly the values
    committed in the tree (unlike Poseidon, which reduces inputs mod the field).
-   The stateless `verifyProof(proof)` overload trusts the caller-supplied `proof.root`;
    integrators must compare it against a trusted root, or use the root-pinned
    `verifyProof(self, proof)` overload.
-   The only external call is a `staticcall` to the SHA-256 precompile, so there is no
    reentrancy surface. Because of it, the stateless `verifyProof(proof)` is `view`
    rather than `pure`.

## Integration security (must-do for safe use)

The library is a data structure with **no access control of its own** and does not
constrain how proofs are consumed. A safe deployment must:

1. **Gate the mutations.** Anyone able to reach a function that calls `insert` /
   `insertMany` / `remove` / `update` can mutate the tree. Add your own authorization.
   Do **not** deploy `test/LeanIMTPlusSha256Test.sol`; it is an unguarded test harness.
2. **Pin the root when verifying.** Prefer `verifyProof(self, proof)`, which checks
   against the tree's current root. The stateless `verifyProof(proof)` trusts the
   caller-supplied `proof.root`, so only use it after comparing that root against one
   you trust (e.g. a current or historical root you stored yourself).
3. **Match the hash encoding off-chain and in circuits.** Roots only agree if every
   implementation uses the exact encoding above (32-byte big-endian words, 96-byte
   leaf messages, full 256-bit digests). Values and hashes are full 256-bit numbers,
   which do not fit in a single BN254 field element, so circuits must represent them
   as bits or limbs. Check your implementation against the test vector.
4. **Prefer `update` over `remove` + `insert`.** Removed slots are tombstoned and never
   reused, so heavy remove/insert churn grows the tree depth (and per-op gas) over time;
   an in-place `update` avoids the tombstone.
5. **Batch within the cap and the transaction gas limit.** `insertMany` accepts at most
   `MAX_INSERT_MANY_BATCH` (256) values per call, but gas runs out first: a batch costs
   roughly 125k gas per value (about 16.1M for 128 values), so under Ethereum L1's
   per-transaction gas cap (2^24, about 16.78M, since EIP-7825) a batch tops out around
   130 values. Split larger inputs across calls.

[test-harness]: https://github.com/zk-kit/zk-kit.solidity/blob/main/packages/lean-imt-plus-sha256/contracts/test/LeanIMTPlusSha256Test.sol
