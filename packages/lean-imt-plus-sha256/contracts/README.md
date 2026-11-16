<p align="center">
    <h1 align="center">LeanIMT+ SHA-256 (Solidity)</h1>
    <p align="center">A Lean Incremental Merkle Tree with membership <b>and</b> non-membership proofs, hashed with SHA-256.</p>
</p>

SHA-256 variant of [`@zk-kit/lean-imt-plus.sol`](https://github.com/zk-kit/zk-kit.solidity/tree/main/packages/lean-imt-plus).
Leaves are `{ value, nextValue }` records forming a sorted linked list, so a Merkle
proof of a value's predecessor ("low leaf") proves the value is absent. The tree
logic, proof format and API are the same as the Poseidon version; only the hash and
the value range differ:

|                 | Poseidon (`lean-imt-plus.sol`)          | SHA-256 (this package)                 |
| --------------- | --------------------------------------- | -------------------------------------- |
| Leaf commitment | `Poseidon3(value, nextValue, TAG_LEAF)` | `sha256(value ‖ nextValue ‖ TAG_LEAF)` |
| Internal node   | `Poseidon2(left, right)`                | `sha256(left ‖ right)`                 |
| Values          | `0 < value < SNARK_SCALAR_FIELD`        | any non-zero `uint256`                 |
| Hash libraries  | `PoseidonT3`, `PoseidonT4` (linked)     | SHA-256 precompile (nothing to link)   |

## Hashing

Inputs are **32-byte big-endian** words and digests are the **full 256-bit** output,
with `TAG_LEAF = 1`. Leaf messages (96 bytes) and node messages (64 bytes) have
different lengths, which keeps leaf and node hashes separate.

**Test vector:** inserting `[10, 25, 7, 3, 41, 18]` in this order gives the root
`0xd6cdf7216f379c8564e8eb285e9529e5df7e206cff0fdbe98df072518bed4e17`.

Compatible with the [`lean-imt-plus-sha256`](https://github.com/zk-kit/zk-kit.circom/tree/main/packages/lean-imt-plus-sha256)
circom circuit. Values and roots don't fit in a single field element, so circuits
take them as `[hi, lo]` 128-bit limbs (`x = hi << 128 | lo`).

## Operations

-   **`insert(value, lowLeafIndex)`** / **`insertMany(values, lowLeafIndices)`**: the
    caller finds each low leaf off-chain and the library validates it on-chain.
-   **`remove(value, predecessorIndex)`**: unlinks `value` and tombstones its slot
    (`{0, 0}`). Slots are never reused.
-   **`update(oldValue, newValue, oldPredecessorIndex, newPredecessorIndex)`**: replaces
    a value in place, cheaper than `remove` + `insert`.
-   **`verifyProof(self, proof)`**: verifies against the tree's current root.
    **`verifyProof(proof)`** is stateless and trusts `proof.root`.
-   **`has(value)`**, **`indexOf(value)`**, **`root()`**: views.

Proofs are generated off-chain; the library only verifies them. `proofType = 0` is
membership, `proofType = 1` is non-membership.

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

Use `InternalLeanIMTPlusSha256` to inline the code, or `LeanIMTPlusSha256` to deploy
it once as a shared `public` library.

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

## Security

The library has **no access control**. To use it safely:

1. **Gate the mutations** (`insert`, `insertMany`, `remove`, `update`) with your own
   authorization. Never deploy the test harness in `contracts/test/`.
2. **Pin the root.** Prefer `verifyProof(self, proof)`, or compare `proof.root`
   against a root you trust before using the stateless overload.
3. **Match the encoding** off-chain and in circuits, and check against the test vector.
4. **Prefer `update` over `remove` + `insert`.** Tombstones are never reused, so churn
   grows the tree depth and gas.
5. **Keep batches small.** `insertMany` accepts up to 256 values, but at roughly
   125k gas per value, the L1 transaction gas cap (2^24) limits a batch to about 130.
