import { poseidon2, poseidon3 } from "poseidon-lite"
import { deployTree, findLowLeafIndex, findPredecessorIndex, refProofToStruct } from "./helpers"
import { LeanIMTPlus, type LeanIMTPlusHashFunctions } from "./reference"

const hashes: LeanIMTPlusHashFunctions<bigint> = {
    leaf: (a, b, c) => poseidon3([a, b, c]),
    internal: (a, b) => poseidon2([a, b])
}

// Lightweight gas benchmark. Not an assertion suite, it inserts a batch of values
// and prints the gas used by a representative insert / update / remove / proof once
// the tree has some depth, so regressions are easy to spot. Proofs are generated
// off-chain by the reference (the contract no longer builds proofs on-chain).
describe("LeanIMTPlus gas", () => {
    it("reports gas for insert / update / remove / verify", async () => {
        const tree = await deployTree()
        const ref = new LeanIMTPlus<bigint>(hashes)

        const N = 64
        let insertGas = 0n
        for (let k = 1; k <= N; k += 1) {
            const v = BigInt(k * 7 + 1) // spread-out, insertion order is not sorted order
            const low = await findLowLeafIndex(tree, v)
            const receipt = await (await tree.insert(v, low)).wait()
            ref.insert(v)
            if (k === N) insertGas = receipt!.gasUsed
        }

        const someValue = 8n // == 1*7+1, present
        const updGas = await (async () => {
            const oldPred = await findPredecessorIndex(tree, someValue)
            const newV = 9999n
            const newPred = await findLowLeafIndex(tree, newV, someValue)
            const r = await (await tree.update(someValue, newV, oldPred, newPred)).wait()
            ref.update(someValue, newV)
            return r!.gasUsed
        })()

        const remValue = 15n // == 2*7+1
        const remGas = await (async () => {
            const pred = await findPredecessorIndex(tree, remValue)
            const r = await (await tree.remove(remValue, pred)).wait()
            ref.remove(remValue)
            return r!.gasUsed
        })()

        const memProof = refProofToStruct(ref.generateProof(22n))
        const memProofGas = await tree.verifyProof.estimateGas(memProof)
        const nonProof = refProofToStruct(ref.generateProof(100000n))
        const nonProofGas = await tree.verifyProof.estimateGas(nonProof)

        const depth = await tree.depth()
        // eslint-disable-next-line no-console
        console.log(
            `\n    LeanIMTPlus gas (n=${N}, depth=${depth}):\n` +
                `      insert          : ${insertGas}\n` +
                `      update (in place): ${updGas}\n` +
                `      remove          : ${remGas}\n` +
                `      verify membership   : ${memProofGas}\n` +
                `      verify non-membership: ${nonProofGas}`
        )
    })
})
