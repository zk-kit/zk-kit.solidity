<p align="center">
    <h1 align="center">LeanIMT SHA-256 (Solidity)</h1>
    <p align="center">A Lean Incremental Merkle Tree hashed with SHA-256.</p>
</p>

SHA-256 variant of [`@zk-kit/lean-imt.sol`](https://github.com/zk-kit/zk-kit.solidity/tree/main/packages/lean-imt).
The tree logic, storage layout and API are the same as the Poseidon version; only the
hash and the leaf range differ:

|                | Poseidon (`lean-imt.sol`)       | SHA-256 (this package)               |
| -------------- | ------------------------------- | ------------------------------------ |
| Internal node  | `Poseidon2(left, right)`        | `sha256(left ‖ right)`               |
| Leaves         | `0 < leaf < SNARK_SCALAR_FIELD` | any non-zero `uint256`               |
| Hash libraries | `PoseidonT3` (linked)           | SHA-256 precompile (nothing to link) |

## Usage

```solidity
import { LeanIMTSha256 } from "@zk-kit/lean-imt-sha256.sol/LeanIMTSha256.sol";
import { LeanIMTSha256Data } from "@zk-kit/lean-imt-sha256.sol/InternalLeanIMTSha256.sol";

contract Registry {
    using LeanIMTSha256 for LeanIMTSha256Data;

    LeanIMTSha256Data internal tree;

    function add(uint256 leaf) external {
        tree.insert(leaf);
    }
}
```

Use `InternalLeanIMTSha256` to inline the code, or `LeanIMTSha256` to deploy it once
as a shared `public` library.

Off-chain, use [`@zk-kit/lean-imt`](https://www.npmjs.com/package/@zk-kit/lean-imt)
with the same hash:

```ts
import { createHash } from "crypto"
import { LeanIMT } from "@zk-kit/lean-imt"

const be32 = (x: bigint) => Buffer.from(x.toString(16).padStart(64, "0"), "hex")
const sha256 = (left: bigint, right: bigint) =>
    BigInt(
        `0x${createHash("sha256")
            .update(Buffer.concat([be32(left), be32(right)]))
            .digest("hex")}`
    )

const tree = new LeanIMT<bigint>(sha256)
```

> [!NOTE]
> Match the encoding off-chain and in circuits.
