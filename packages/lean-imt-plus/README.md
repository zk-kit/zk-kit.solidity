<p align="center">
    <h1 align="center">
         Lean Incremental Merkle Tree + (Solidity)
    </h1>
    <p align="center">Lean Incremental Merkle tree with membership <b>and</b> non-membership proofs implementation in Solidity.</p>
</p>

<p align="center">
    <a href="https://github.com/privacy-scaling-explorations/zk-kit.solidity">
        <img src="https://img.shields.io/badge/project-zk--kit-blue.svg?style=flat-square">
    </a>
    <a href="https://github.com/privacy-scaling-explorations/zk-kit.solidity/tree/main/packages/lean-imt-plus/contracts/LICENSE">
        <img alt="NPM license" src="https://img.shields.io/npm/l/%40zk-kit%2Flean-imt-plus.sol?style=flat-square">
    </a>
    <a href="https://www.npmjs.com/package/@zk-kit/lean-imt-plus.sol">
        <img alt="NPM version" src="https://img.shields.io/npm/v/@zk-kit/lean-imt-plus.sol?style=flat-square" />
    </a>
    <a href="https://npmjs.org/package/@zk-kit/lean-imt-plus.sol">
        <img alt="Downloads" src="https://img.shields.io/npm/dm/@zk-kit/lean-imt-plus.sol.svg?style=flat-square" />
    </a>
    <a href="https://prettier.io/">
        <img alt="Code style prettier" src="https://img.shields.io/badge/code%20style-prettier-f8bc45?style=flat-square&logo=prettier" />
    </a>
</p>

LeanIMT+ extends the [LeanIMT](https://github.com/privacy-scaling-explorations/zk-kit.solidity/tree/main/packages/lean-imt) with the indexed-leaf design of the Indexed Merkle Tree, so it can prove that a value is **not** in the tree without revealing the full leaf set.

It keeps everything that makes the LeanIMT efficient: dynamic depth `ceil(log2(n))` and no zero hashes (an unpaired node is promoted unchanged). It adds a **sorted implicit linked list** over the inserted values, so a single Merkle proof of a value's predecessor proves the value is absent. See the [contracts README](./contracts/README.md) for the full design and security notes.

---

## 🛠 Install

### npm or yarn

Install the `@zk-kit/lean-imt-plus.sol` package with npm:

```bash
npm i @zk-kit/lean-imt-plus.sol --save
```

or yarn:

```bash
yarn add @zk-kit/lean-imt-plus.sol
```

## 📜 Usage

Please, see the [test contracts](./test) for guidance on utilizing the libraries.
