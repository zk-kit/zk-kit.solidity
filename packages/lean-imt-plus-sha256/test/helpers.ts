import { run } from "hardhat"
import { LeanIMTPlusSha256Test } from "../typechain-types"
import type { LeanIMTPlusProof } from "./reference"

/** Deploys the LeanIMTPlusSha256 library and a fresh test harness. */
export async function deployTree(): Promise<LeanIMTPlusSha256Test> {
    const { contract } = await run("deploy:imt-plus-sha256-test", { logs: false })

    return contract
}

/**
 * Finds the physical index of the low leaf (predecessor) of `value` by scanning
 * the on-chain leaves, exactly what an off-chain client would do before calling
 * `insert`. Returns the sentinel (index 0) when `value` is
 * smaller than every active value. Ignores tombstones.
 *
 * `excluded` (optional) is treated as already removed from the list, which is what
 * `update` needs: the new value's predecessor must be computed against the list
 * *after* the old value is unlinked.
 */
export async function findLowLeafIndex(tree: any, value: bigint, excluded: bigint | null = null): Promise<bigint> {
    const count: bigint = await tree.leavesCount()
    let bestIndex = 0n // sentinel is always a candidate (value 0 < everything)
    let bestValue = -1n
    for (let i = 1n; i < count; i += 1n) {
        const leaf = await tree.getLeaf(i)
        const v: bigint = leaf.value
        if (v === 0n) continue // tombstone
        if (excluded !== null && v === excluded) continue // pretend it is unlinked
        if (v < value && v > bestValue) {
            bestValue = v
            bestIndex = i
        }
    }
    return bestIndex
}

/** Finds the predecessor of `value` (the leaf whose nextValue === value). */
export async function findPredecessorIndex(tree: any, value: bigint): Promise<bigint> {
    const count: bigint = await tree.leavesCount()
    for (let i = 0n; i < count; i += 1n) {
        const leaf = await tree.getLeaf(i)
        if (leaf.nextValue === value) return i
    }
    throw new Error(`No predecessor found for ${value}`)
}

/**
 * Copies a proof struct (e.g. from {@link refProofToStruct}) into a plain,
 * mutable object that can be passed into `verifyProof`. Optional `overrides`
 * let tests tamper with individual fields.
 */
export function toProofStruct(proof: any, overrides: Record<string, unknown> = {}) {
    return {
        proofType: Number(proof.proofType),
        root: proof.root,
        value: proof.value,
        leafValue: proof.leafValue,
        leafNextValue: proof.leafNextValue,
        leafIndex: proof.leafIndex,
        siblings: [...proof.siblings],
        ...overrides
    }
}

/**
 * Converts a proof produced by the reference `LeanIMTPlus` (`@zk-kit/lean-imt-plus`)
 * into the Solidity `LeanIMTPlusProof` struct shape, so a proof generated off-chain
 * can be verified on-chain.
 */
export function refProofToStruct(proof: LeanIMTPlusProof<bigint>) {
    return {
        proofType: proof.proofType,
        root: proof.root,
        value: proof.value,
        leafValue: proof.leaf.value,
        leafNextValue: proof.leaf.nextValue,
        leafIndex: BigInt(proof.leafIndex),
        siblings: [...proof.siblings]
    }
}
