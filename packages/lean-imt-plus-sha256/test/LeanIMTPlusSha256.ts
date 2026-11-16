import { expect } from "chai"
import { createHash } from "crypto"
import { LeanIMTPlus, type LeanIMTPlusHashFunctions } from "./reference"
import { deployTree, findLowLeafIndex, findPredecessorIndex, toProofStruct, refProofToStruct } from "./helpers"

// The contract runs in lockstep with the `@zk-kit/lean-imt-plus` reference (same hashes,
// same layout): roots must match after every mutation, and proofs are cross-verified.

const MAX_UINT256 = (1n << 256n) - 1n

/** 32-byte big-endian encoding of a uint256. */
function be32(x: bigint): Buffer {
    return Buffer.from(x.toString(16).padStart(64, "0"), "hex")
}

/** Full (untruncated) SHA-256 of the concatenated 32-byte big-endian words. */
function sha256Words(...words: bigint[]): bigint {
    const digest = createHash("sha256")
        .update(Buffer.concat(words.map(be32)))
        .digest("hex")
    return BigInt(`0x${digest}`)
}

// Root after inserting [10, 25, 7, 3, 41, 18] into an empty tree (also in the README).
const TEST_VECTOR_ROOT = 0xd6cdf7216f379c8564e8eb285e9529e5df7e206cff0fdbe98df072518bed4e17n

// leaf = sha256(value || nextValue || TAG_LEAF), node = sha256(left || right)
const hashes: LeanIMTPlusHashFunctions<bigint> = {
    leaf: (value, nextValue, tag) => sha256Words(value, nextValue, tag),
    internal: (left, right) => sha256Words(left, right)
}

const newReference = () => new LeanIMTPlus<bigint>(hashes)

describe("LeanIMTPlusSha256 (Solidity)", () => {
    // Applies a mutation to both the contract and the reference.
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

        it("reverts on zero and duplicate values", async () => {
            const tree = await deployTree()
            await (await tree.insert(5n, 0n)).wait()

            await expect(tree.insert(0n, 0n)).to.be.reverted
            await expect(tree.insert(5n, await findLowLeafIndex(tree, 5n))).to.be.reverted
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
            // A tombstone is never a valid low leaf.
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

            // Same values in the same order give the same layout, so the indices are reusable.
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
            // 25's low leaf is 20, not the sentinel, so the batch reverts.
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
            // Random batches, cross-checked against a per-value loop and the reference.
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

                // The loop tree's low-leaf indices are valid for the batch tree too.
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

    describe("full 256-bit values", () => {
        const BIG = [MAX_UINT256, MAX_UINT256 - 1n, 1n << 255n, 1n << 254n, 1n]

        it("inserts, removes and updates values up to 2^256 - 1, matching the reference", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of BIG) {
                await insertBoth(tree, ref, v)
                await expectRootMatchesReference(tree, ref)
            }
            expect(await walkList(tree)).to.deep.equal([...BIG].sort((a, b) => (a < b ? -1 : 1)))

            await removeBoth(tree, ref, 1n << 255n)
            await expectRootMatchesReference(tree, ref)
            await updateBoth(tree, ref, MAX_UINT256 - 1n, (1n << 255n) + 7n)
            await expectRootMatchesReference(tree, ref)
        })

        it("verifies membership and non-membership proofs for full-width values", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of BIG) await insertBoth(tree, ref, v)

            for (const v of BIG) {
                const proof = refProofToStruct(ref.generateProof(v))
                expect(proof.proofType).to.equal(0)
                expect(await tree.verifyProof(proof)).to.equal(true)
            }
            // Absent values between the inserted ones.
            for (const absent of [(1n << 255n) + 1n, MAX_UINT256 - 2n, 2n]) {
                const proof = refProofToStruct(ref.generateProof(absent))
                expect(proof.proofType).to.equal(1)
                expect(await tree.verifyProof(proof)).to.equal(true)
            }
        })

        it("rejects a proof whose leaf fields were altered (every bit is hashed)", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 20n, 30n]) await insertBoth(tree, ref, v)
            const proof = refProofToStruct(ref.generateProof(20n))
            // Every bit is hashed, so flipping the top bit breaks the proof.
            const highBit = 1n << 255n
            expect(
                await tree.verifyProof(toProofStruct(proof, { leafNextValue: proof.leafNextValue ^ highBit }))
            ).to.equal(false)
            expect(
                await tree.verifyProof(toProofStruct(proof, { value: 20n ^ highBit, leafValue: 20n ^ highBit }))
            ).to.equal(false)
        })
    })

    describe("proof structural validation", () => {
        // A tree with a non-trivial sibling path, plus its reference.
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
            // Proof for 25 (low leaf 20, next 30); 35 fails the upper bound.
            const proof = refProofToStruct(ref.generateProof(25n))
            expect(proof.proofType).to.equal(1)
            const bad = toProofStruct(proof, { value: 35n })
            expect(await tree.verifyProofStatic(bad)).to.equal(false)
        })

        it("rejects a non-membership proof whose low leaf is a tombstone (index != 0)", async () => {
            const { tree } = await seedTree()
            // A value-0 leaf at a non-zero index must hit the tombstone replay guard.
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

        it("depth stays 0 while the tree holds at most one leaf and grows with it", async () => {
            const tree = await deployTree()
            const ref = newReference()
            expect(await tree.depth()).to.equal(0n) // empty tree

            await insertBoth(tree, ref, 10n) // sentinel + one leaf => 2 leaves
            expect(await tree.depth()).to.equal(1n)

            // ceil(log2(leavesCount)): 6 leaves (sentinel + 5) => depth 3.
            for (const v of [20n, 30n, 40n, 50n]) await insertBoth(tree, ref, v)
            expect(await tree.leavesCount()).to.equal(6n)
            expect(await tree.depth()).to.equal(3n)
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
            // Absent value, so the old == new check is the one that reverts.
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
            // After unlinking 20, 25's low leaf is 10, not 30.
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

    describe("hash encoding (known answers for other implementations)", () => {
        it("commits a single-value tree as sha256(leaf0 || leaf1) with 96-byte leaf messages", async () => {
            // Computed without the reference: leaves [{0, 42}, {42, 0}].
            const tree = await deployTree()
            await (await tree.insert(42n, 0n)).wait()
            const leaf0 = sha256Words(0n, 42n, 1n)
            const leaf1 = sha256Words(42n, 0n, 1n)
            expect(await tree.root()).to.equal(sha256Words(leaf0, leaf1))
        })

        it("matches a fixed test vector", async () => {
            const tree = await deployTree()
            const ref = newReference()
            for (const v of [10n, 25n, 7n, 3n, 41n, 18n]) await insertBoth(tree, ref, v)
            expect(await tree.root()).to.equal(TEST_VECTOR_ROOT)
        })
    })
})
