import { expect } from "chai"
import { poseidon2, poseidon3 } from "poseidon-lite"
import { LeanIMTPlus, type LeanIMTPlusHashFunctions } from "./reference"
import { deployTree, findLowLeafIndex, findPredecessorIndex, toProofStruct, refProofToStruct } from "./helpers"

// Correctness strategy: the Solidity tree is run in lockstep with the reference
// LeanIMT+ implementation from `@zk-kit/lean-imt-plus` (the single source of truth for
// the construction). The reference uses the SAME Poseidon hashes (3-input leaf,
// 2-input node) and the SAME physical layout (sentinel at index 0, append-on-insert,
// tombstone-on-remove), so after every mutation the two roots must match. Proofs are
// additionally cross-verified between the two implementations.

const hashes: LeanIMTPlusHashFunctions<bigint> = {
    leaf: (a, b, c) => poseidon3([a, b, c]),
    internal: (a, b) => poseidon2([a, b])
}

const FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n

const newReference = () => new LeanIMTPlus<bigint>(hashes)

describe("LeanIMTPlus (Solidity)", () => {
    // Apply the same value to both the contract and the reference. The contract
    // needs the low-leaf index (found off-chain); the reference finds it itself.
    async function insertBoth(tree: any, ref: LeanIMTPlus<bigint>, v: bigint) {
        await (await tree.insert(v, await findLowLeafIndex(tree, v))).wait()
        ref.insert(v)
    }

    async function removeBoth(tree: any, ref: LeanIMTPlus<bigint>, v: bigint) {
        await (await tree.remove(v, await findPredecessorIndex(tree, v))).wait()
        ref.remove(v)
    }

    async function updateBoth(tree: any, ref: LeanIMTPlus<bigint>, oldV: bigint, newV: bigint) {
        const oldPred = await findPredecessorIndex(tree, oldV)
        const newPred = await findLowLeafIndex(tree, newV, oldV) // predecessor after oldV is unlinked
        await (await tree.update(oldV, newV, oldPred, newPred)).wait()
        ref.update(oldV, newV)
    }

    async function expectRootMatchesReference(tree: any, ref: LeanIMTPlus<bigint>) {
        expect(await tree.root()).to.equal(ref.root)
    }

    // Reads the sorted list of active values by walking the implicit linked list.
    async function walkList(tree: any): Promise<bigint[]> {
        const count: bigint = await tree.leavesCount()
        const nextOf = new Map<bigint, bigint>()
        for (let i = 0n; i < count; i += 1n) {
            const leaf = await tree.getLeaf(i)
            if (leaf.value === 0n && i !== 0n) continue // tombstone
            nextOf.set(leaf.value, leaf.nextValue)
        }
        const out: bigint[] = []
        let cursor = nextOf.get(0n)
        while (cursor !== undefined && cursor !== 0n) {
            out.push(cursor)
            cursor = nextOf.get(cursor)
        }
        return out
    }

    describe("insert", () => {
        it("creates the sentinel and first leaf on the first insert", async () => {
            const tree = await deployTree()
            const ref = newReference()
            await insertBoth(tree, ref, 5n)

            expect(await tree.leavesCount()).to.equal(2n)
            expect(await tree.size()).to.equal(1n)
            const sentinel = await tree.getLeaf(0n)
            expect(sentinel.value).to.equal(0n)
            expect(sentinel.nextValue).to.equal(5n)
            const first = await tree.getLeaf(1n)
            expect(first.value).to.equal(5n)
            expect(first.nextValue).to.equal(0n)
            await expectRootMatchesReference(tree, ref)
        })

        it("matches the reference root across a shuffled insertion sequence", async () => {
            const tree = await deployTree()
            const ref = newReference()
            const values = [42n, 7n, 100n, 3n, 21n, 55n, 1n, 88n, 13n, 64n]

            for (const v of values) {
                await insertBoth(tree, ref, v)
                await expectRootMatchesReference(tree, ref)
            }
            expect(await tree.size()).to.equal(BigInt(values.length))
            expect(await walkList(tree)).to.deep.equal([...values].sort((a, b) => (a < b ? -1 : 1)))
        })

        it("keeps the implicit linked list sorted", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [50n, 20n, 80n, 10n, 30n]) await insertBoth(tree, ref, v)
            expect(await walkList(tree)).to.deep.equal([10n, 20n, 30n, 50n, 80n])
            await expectRootMatchesReference(tree, ref)
        })

        it("reverts on zero, duplicate, and out-of-field values", async () => {
            const tree = await deployTree()
            await (await tree.insert(5n, 0n)).wait()

            await expect(tree.insert(0n, 0n)).to.be.reverted
            await expect(tree.insert(5n, await findLowLeafIndex(tree, 5n))).to.be.reverted
            const FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n
            await expect(tree.insert(FIELD, 0n)).to.be.reverted
        })

        it("reverts when the supplied low leaf is wrong", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            // Insert 25 but point at the sentinel (index 0) instead of the leaf holding 20.
            await expect(tree.insert(25n, 0n)).to.be.reverted
        })

        it("reverts when the supplied low leaf is a tombstone", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            const slot20 = await tree.indexOf(20n)
            await removeBoth(tree, ref, 20n) // slot20 is now a tombstone {0, 0}
            // A tombstoned slot must never be accepted as a low leaf, even at a value
            // (25) it would otherwise bracket.
            await expect(tree.insert(25n, slot20)).to.be.reverted
        })
    })

    describe("insertMany", () => {
        it("matches the reference and a per-value insert loop, and costs less gas", async () => {
            const values = [42n, 7n, 100n, 3n, 21n, 55n, 1n, 88n, 13n, 64n, 200n, 5n, 77n, 30n, 9n, 150n]

            // Per-value loop, recording the low-leaf index used at each step and the gas.
            const loopTree = await deployTree()
            const refLoop = newReference()
            const lowIndices: bigint[] = []
            let loopGas = 0n
            for (const v of values) {
                const idx = await findLowLeafIndex(loopTree, v)
                lowIndices.push(idx)
                const r = await (await loopTree.insert(v, idx)).wait()
                loopGas += r!.gasUsed
                refLoop.insert(v)
            }

            // The physical layout after k inserts is identical whether done one by one or
            // in a batch (same values, same order), so the recorded indices are reusable.
            const batchTree = await deployTree()
            const refBatch = newReference()
            const r = await (await batchTree.insertMany(values, lowIndices)).wait()
            const manyGas = r!.gasUsed
            refBatch.insertMany(values)

            // Correctness: identical root three ways (batch, loop, reference).
            const root = await batchTree.root()
            expect(root).to.equal(await loopTree.root())
            expect(root).to.equal(refBatch.root)
            expect(refBatch.root).to.equal(refLoop.root)
            expect(await batchTree.size()).to.equal(BigInt(values.length))

            // Efficiency: the batch is cheaper than the equivalent loop.
            expect(manyGas).to.be.lessThan(loopGas)
            const saved = (Number(loopGas - manyGas) * 100) / Number(loopGas)
            // eslint-disable-next-line no-console
            console.log(
                `\n    insertMany(${values.length}): ${manyGas} gas vs loop ${loopGas} gas ` +
                    `(${saved.toFixed(1)}% cheaper, ${(Number(loopGas) / values.length).toFixed(0)} vs ` +
                    `${(Number(manyGas) / values.length).toFixed(0)} gas/value)`
            )
        })

        it("reverts (rolling back the whole batch) on a duplicate within the batch", async () => {
            const tree = await deployTree()
            // 5 (creates sentinel), 7 (low leaf = leaf holding 5 at index 1), 5 (duplicate).
            await expect(tree.insertMany([5n, 7n, 5n], [0n, 1n, 0n])).to.be.reverted
            expect(await tree.leavesCount()).to.equal(0n) // nothing inserted
        })

        it("reverts on mismatched array lengths", async () => {
            const tree = await deployTree()
            await expect(tree.insertMany([5n, 7n], [0n])).to.be.reverted
        })

        it("reverts when the batch exceeds the max size", async () => {
            const tree = await deployTree()
            const tooMany = 257 // MAX_INSERT_MANY_BATCH is 256
            const values = Array.from({ length: tooMany }, (_, i) => BigInt(i + 1))
            const idx = new Array<bigint>(tooMany).fill(0n)
            await expect(tree.insertMany(values, idx)).to.be.reverted
        })

        it("reverts when a batch entry supplies a wrong low leaf on a non-empty tree", async () => {
            const tree = await deployTree()
            // Seed the tree so the next batch runs the non-first-insert path.
            await (await tree.insertMany([10n, 20n, 30n], [0n, 1n, 2n])).wait()
            // 25's low leaf is the leaf holding 20, not the sentinel (index 0), which
            // points at 10; the sentinel does not bracket 25 so the batch reverts.
            await expect(tree.insertMany([25n], [0n])).to.be.reverted
            expect(await tree.size()).to.equal(3n) // batch rolled back, nothing added
        })

        it("is a no-op for an empty batch", async () => {
            const tree = await deployTree()
            await (await tree.insertMany([], [])).wait()
            expect(await tree.leavesCount()).to.equal(0n)
            expect(await tree.size()).to.equal(0n)
        })

        it("stays root-identical to a per-value loop across random batches", async () => {
            // Fuzz coverage for insertMany: random batch sizes and values applied to a
            // growing tree, cross-checked against a per-value loop and the reference.
            const loopTree = await deployTree()
            const batchTree = await deployTree()
            const refLoop = newReference()
            const refBatch = newReference()
            const present = new Set<bigint>()

            let seed = 987654321n
            const rand = (n: bigint) => {
                seed = (seed * 1103515245n + 12345n) % 2147483648n
                return seed % n
            }

            for (let round = 0; round < 8; round += 1) {
                // A batch of distinct, not-yet-present values.
                const batchSize = Number(rand(6n)) + 1
                const values: bigint[] = []
                const seen = new Set<bigint>()
                while (values.length < batchSize) {
                    const v = rand(1000n) + 1n
                    if (present.has(v) || seen.has(v)) continue
                    seen.add(v)
                    values.push(v)
                }

                // The loop tree gives the low-leaf index used at each step; the batch tree is
                // in the same physical state, so those indices are valid for insertMany too.
                const lowIndices: bigint[] = []
                for (const v of values) {
                    const idx = await findLowLeafIndex(loopTree, v)
                    lowIndices.push(idx)
                    await (await loopTree.insert(v, idx)).wait()
                    refLoop.insert(v)
                }
                await (await batchTree.insertMany(values, lowIndices)).wait()
                refBatch.insertMany(values)
                for (const v of values) present.add(v)

                const root = await batchTree.root()
                expect(root).to.equal(await loopTree.root())
                expect(root).to.equal(refBatch.root)
                expect(refBatch.root).to.equal(refLoop.root)
                expect(await batchTree.size()).to.equal(BigInt(present.size))
            }
        })
    })

    describe("membership proofs", () => {
        it("verifies reference-generated membership proofs on-chain", async () => {
            const tree = await deployTree()
            const ref = newReference()
            const values = [42n, 7n, 100n, 3n, 21n]
            for (const v of values) await insertBoth(tree, ref, v)

            for (const v of values) {
                // Proofs are generated off-chain by the reference, then verified on-chain.
                const proof = refProofToStruct(ref.generateProof(v))
                expect(proof.proofType).to.equal(0)
                expect(proof.leafValue).to.equal(v)
                expect(await tree.verifyProof(proof)).to.equal(true)
                expect(await tree.verifyProofStatic(proof)).to.equal(true)
            }
        })

        it("rejects a membership proof whose value was swapped", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            const tampered = toProofStruct(refProofToStruct(ref.generateProof(20n)), {
                value: 30n,
                leafValue: 30n
            })
            expect(await tree.verifyProofStatic(tampered)).to.equal(false)
        })
    })

    describe("non-membership proofs", () => {
        it("verifies non-membership proofs (below-min, interior, tail) on-chain", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n, 40n]) await insertBoth(tree, ref, v)

            for (const absent of [5n, 25n, 100n]) {
                const proof = refProofToStruct(ref.generateProof(absent))
                expect(proof.proofType).to.equal(1)
                expect(proof.leafValue).to.be.lessThan(absent)
                expect(await tree.verifyProof(proof)).to.equal(true)
            }
        })

        it("rejects a tampered non-membership proof", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            // Claim non-membership of 15, but the low leaf (20) does not bracket 15.
            const tampered = toProofStruct(refProofToStruct(ref.generateProof(25n)), {
                value: 15n
            })
            expect(await tree.verifyProofStatic(tampered)).to.equal(false)
        })
    })

    describe("field-range hardening", () => {
        it("rejects a proof whose value/leaf are out of the field", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            const outOfField = toProofStruct(refProofToStruct(ref.generateProof(20n)), {
                value: 20n + FIELD,
                leafValue: 20n + FIELD
            })
            expect(await tree.verifyProofStatic(outOfField)).to.equal(false)
        })

        // Regression tests for the mod-F forgery: Poseidon reduces inputs mod the
        // field, so before the range check a value shifted by FIELD hashed
        // identically while breaking the raw-uint256 ordering comparison.
        it("cannot forge non-membership of a PRESENT value via its predecessor", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            const forged = toProofStruct(refProofToStruct(ref.generateProof(10n)), {
                proofType: 1,
                value: 20n,
                leafNextValue: 20n + FIELD
            })
            expect(await tree.verifyProofStatic(forged)).to.equal(false)
            expect(await tree.verifyProof(forged)).to.equal(false)
        })

        it("cannot forge non-membership of a PRESENT value via the sentinel", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            const forged = toProofStruct(refProofToStruct(ref.generateProof(5n)), {
                value: 20n,
                leafNextValue: 10n + FIELD
            })
            expect(await tree.verifyProofStatic(forged)).to.equal(false)
            expect(await tree.verifyProof(forged)).to.equal(false)
        })

        it("rejects a proof with an out-of-field sibling", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n, 40n]) await insertBoth(tree, ref, v)
            const proof = refProofToStruct(ref.generateProof(20n))
            expect(proof.siblings.length).to.be.greaterThan(0)
            proof.siblings[0] = proof.siblings[0] + FIELD
            expect(await tree.verifyProofStatic(proof)).to.equal(false)
        })

        it("rejects a proof whose leafValue alone is out of the field", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            // value stays in-field so the check falls through to the leafValue operand.
            const bad = toProofStruct(refProofToStruct(ref.generateProof(20n)), {
                leafValue: 20n + FIELD
            })
            expect(await tree.verifyProofStatic(bad)).to.equal(false)
        })

        it("rejects a proof whose leafNextValue alone is out of the field", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            const bad = toProofStruct(refProofToStruct(ref.generateProof(20n)), {
                leafNextValue: FIELD
            })
            expect(await tree.verifyProofStatic(bad)).to.equal(false)
        })
    })

    describe("proof structural validation", () => {
        // Seeds a tree with a handful of leaves (so proofs have a non-trivial sibling
        // path) and returns it alongside a reference that mirrors it.
        async function seedTree() {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n, 40n]) await insertBoth(tree, ref, v)
            return { tree, ref }
        }

        it("rejects a proof with an unknown proofType", async () => {
            const { tree, ref } = await seedTree()
            const bad = toProofStruct(refProofToStruct(ref.generateProof(20n)), { proofType: 2 })
            expect(await tree.verifyProofStatic(bad)).to.equal(false)
        })

        it("rejects a proof with more than 256 siblings", async () => {
            const { tree, ref } = await seedTree()
            const bad = toProofStruct(refProofToStruct(ref.generateProof(20n)), {
                siblings: new Array(257).fill(1n)
            })
            expect(await tree.verifyProofStatic(bad)).to.equal(false)
        })

        it("rejects a non-canonical leafIndex (bits set beyond the sibling count)", async () => {
            const { tree, ref } = await seedTree()
            const proof = refProofToStruct(ref.generateProof(20n))
            // Any bit at position >= siblings.length makes the packed path non-canonical.
            const bad = toProofStruct(proof, { leafIndex: 1n << BigInt(proof.siblings.length) })
            expect(await tree.verifyProofStatic(bad)).to.equal(false)
        })

        it("rejects a proof for the zero value", async () => {
            const { tree, ref } = await seedTree()
            const bad = toProofStruct(refProofToStruct(ref.generateProof(20n)), { value: 0n })
            expect(await tree.verifyProofStatic(bad)).to.equal(false)
        })

        it("rejects a membership proof whose leaf does not carry the value", async () => {
            const { tree, ref } = await seedTree()
            // proofType 0, but leafValue (20) != value (30).
            const bad = toProofStruct(refProofToStruct(ref.generateProof(20n)), { value: 30n })
            expect(await tree.verifyProofStatic(bad)).to.equal(false)
        })

        it("rejects a non-membership proof whose value is not below leafNextValue", async () => {
            const { tree, ref } = await seedTree()
            // Non-membership proof for 25: low leaf 20, leafNext 30. 35 clears the lower
            // bound (20 < 35) but not the upper one (35 is not < 30).
            const proof = refProofToStruct(ref.generateProof(25n))
            expect(proof.proofType).to.equal(1)
            const bad = toProofStruct(proof, { value: 35n })
            expect(await tree.verifyProofStatic(bad)).to.equal(false)
        })

        it("rejects a non-membership proof whose low leaf is a tombstone (index != 0)", async () => {
            const { tree } = await seedTree()
            // A value-0 leaf is only legitimate at index 0 (the sentinel). Here it sits
            // at a non-zero index with a matching (length-1) sibling path, so it clears
            // the canonical-index check and is caught by the tombstone replay guard.
            const bad = {
                proofType: 1,
                root: 0n,
                value: 5n,
                leafValue: 0n,
                leafNextValue: 0n,
                leafIndex: 1n,
                siblings: [1n]
            }
            expect(await tree.verifyProofStatic(bad)).to.equal(false)
        })
    })

    describe("views", () => {
        it("root is 0 for an empty tree", async () => {
            const tree = await deployTree()
            expect(await tree.root()).to.equal(0n)
        })

        it("indexOf reverts for an absent value", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n]) await insertBoth(tree, ref, v)
            await expect(tree.indexOf(999n)).to.be.reverted
        })
    })

    describe("remove", () => {
        it("tombstones the slot, relinks the list, and matches the reference", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [42n, 7n, 100n, 3n, 21n]) await insertBoth(tree, ref, v)

            const beforeCount = await tree.leavesCount()
            await removeBoth(tree, ref, 21n)

            await expectRootMatchesReference(tree, ref)
            expect(await tree.has(21n)).to.equal(false)
            expect(await tree.size()).to.equal(4n)
            expect(await tree.leavesCount()).to.equal(beforeCount) // slot stays as a tombstone
            expect(await walkList(tree)).to.deep.equal([3n, 7n, 42n, 100n])

            // A removed value now has a valid non-membership proof.
            const proof = refProofToStruct(ref.generateProof(21n))
            expect(proof.proofType).to.equal(1)
            expect(await tree.verifyProof(proof)).to.equal(true)
        })

        it("supports draining the whole tree and re-inserting", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            for (const v of [10n, 20n, 30n]) {
                await removeBoth(tree, ref, v)
                await expectRootMatchesReference(tree, ref)
            }
            expect(await tree.size()).to.equal(0n)

            await insertBoth(tree, ref, 99n)
            await expectRootMatchesReference(tree, ref)
            expect(await tree.has(99n)).to.equal(true)
            expect(await walkList(tree)).to.deep.equal([99n])
        })

        it("reverts on a wrong predecessor or a missing value", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            await expect(tree.remove(999n, 0n)).to.be.reverted // missing
            await expect(tree.remove(20n, 0n)).to.be.reverted // sentinel is not 20's predecessor
        })
    })

    describe("update", () => {
        it("replaces a value in place, matches the reference, does not grow the tree", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n, 40n]) await insertBoth(tree, ref, v)

            const countBefore = await tree.leavesCount()
            await updateBoth(tree, ref, 20n, 25n)

            await expectRootMatchesReference(tree, ref)
            expect(await tree.has(20n)).to.equal(false)
            expect(await tree.has(25n)).to.equal(true)
            expect(await tree.leavesCount()).to.equal(countBefore) // no tombstone created
            expect(await tree.size()).to.equal(4n)
            expect(await walkList(tree)).to.deep.equal([10n, 25n, 30n, 40n])
        })

        it("reverts when updating to an existing value or from a missing value", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            const pred20 = await findPredecessorIndex(tree, 20n)
            await expect(tree.update(20n, 30n, pred20, 0n)).to.be.reverted // 30 exists
            await expect(tree.update(999n, 50n, 0n, 0n)).to.be.reverted // 999 missing
        })

        it("reverts when the new value equals the old value", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            // Use an absent value for both: a present value would revert earlier in the
            // shared value validation, never reaching the old-equals-new guard.
            await expect(tree.update(50n, 50n, 0n, 0n)).to.be.reverted
        })

        it("reverts when the old predecessor is wrong", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            // The sentinel (index 0) points at 10, not at 20, so it is not 20's predecessor.
            const newPred = await findLowLeafIndex(tree, 25n, 20n)
            await expect(tree.update(20n, 25n, 0n, newPred)).to.be.reverted
        })

        it("reverts when the new predecessor is the old value's own slot", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            const slot = await tree.indexOf(20n)
            const pred20 = await findPredecessorIndex(tree, 20n)
            await expect(tree.update(20n, 25n, pred20, slot)).to.be.reverted
        })

        it("reverts when the new predecessor does not bracket the new value", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            const pred20 = await findPredecessorIndex(tree, 20n)
            // Replace 20 with 25. After 20 is unlinked the list is {10, 30}, so 25's low
            // leaf is the leaf holding 10; the leaf holding 30 (30 > 25) does not bracket
            // 25. This new predecessor is a valid slot but the wrong one, so it reverts.
            const wrongNewPred = await tree.indexOf(30n)
            await expect(tree.update(20n, 25n, pred20, wrongNewPred)).to.be.reverted
            expect(await tree.has(20n)).to.equal(true) // all-or-nothing: unchanged
            expect(await tree.has(25n)).to.equal(false)
        })
    })

    describe("randomized cross-check against the reference", () => {
        it("stays root-identical across interleaved inserts, removes and updates", async () => {
            const tree = await deployTree()
            const ref = newReference()
            const present = new Set<bigint>()

            // Deterministic LCG (no Math.random, for reproducibility).
            let seed = 123456789n
            const rand = (n: bigint) => {
                seed = (seed * 1103515245n + 12345n) % 2147483648n
                return seed % n
            }

            for (let step = 0; step < 60; step += 1) {
                const arr = [...present]
                const roll = rand(10n)

                if (present.size === 0 || roll < 6n) {
                    const v = rand(1000n) + 1n
                    if (present.has(v)) continue
                    await insertBoth(tree, ref, v)
                    present.add(v)
                } else if (roll < 8n) {
                    const v = arr[Number(rand(BigInt(arr.length)))]
                    await removeBoth(tree, ref, v)
                    present.delete(v)
                } else {
                    const v = arr[Number(rand(BigInt(arr.length)))]
                    const nv = rand(1000n) + 1n
                    if (present.has(nv)) continue
                    await updateBoth(tree, ref, v, nv)
                    present.delete(v)
                    present.add(nv)
                }

                await expectRootMatchesReference(tree, ref)
                expect(await tree.size()).to.equal(BigInt(present.size))
                expect(await walkList(tree)).to.deep.equal([...present].sort((a, b) => (a < b ? -1 : 1)))
            }
        })
    })
})
