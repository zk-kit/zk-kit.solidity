import { LeanIMT as JSLeanIMT } from "@zk-kit/lean-imt"
import { expect } from "chai"
import { createHash } from "crypto"
import { run } from "hardhat"
import { LeanIMTSha256, LeanIMTSha256Test } from "../typechain-types"

/** 32-byte big-endian encoding of `x`. */
const be32 = (x: bigint) => Buffer.from(x.toString(16).padStart(64, "0"), "hex")

/** `sha256(left || right)`, matching the contract's node hash. */
const sha256 = (left: bigint, right: bigint) =>
    BigInt(
        `0x${createHash("sha256")
            .update(Buffer.concat([be32(left), be32(right)]))
            .digest("hex")}`
    )

// Root of `insertMany([10, 25, 7, 3, 41, 18])`, computed independently with Python hashlib.
const TEST_VECTOR_ROOT = BigInt("0xaf3c78d12ab0c160d1fc36e9560f0a1c43d5fd9a5f4040b6eb8a3039059cd7f4")

describe("LeanIMTSha256", () => {
    const SNARK_SCALAR_FIELD = BigInt("21888242871839275222246405745257275088548364400416034343698204186575808495617")
    const MAX_UINT256 = (1n << 256n) - 1n
    let leanIMTTest: LeanIMTSha256Test
    let leanIMT: LeanIMTSha256
    let jsLeanIMT: JSLeanIMT

    beforeEach(async () => {
        const { library, contract } = await run("deploy:imt-sha256-test", { logs: false })

        leanIMTTest = contract
        leanIMT = library
        jsLeanIMT = new JSLeanIMT(sha256)
    })

    describe("# hash", () => {
        it("Should hash nodes as sha256(left || right)", async () => {
            // sha256 of 64 zero-padded bytes encoding [1, 2], computed independently.
            await leanIMTTest.insertMany([1, 2])

            expect(await leanIMTTest.root()).to.equal(sha256(1n, 2n))
            expect(sha256(1n, 2n)).to.equal(
                BigInt("0xd6ba9329f8932c12192b37849f772104d20048f76434a3290512d9d814e4116f")
            )
        })

        it("Should match the test vector", async () => {
            await leanIMTTest.insertMany([10, 25, 7, 3, 41, 18])

            expect(await leanIMTTest.root()).to.equal(TEST_VECTOR_ROOT)
        })
    })

    describe("# insert", () => {
        it("Should insert a leaf greater than SNARK_SCALAR_FIELD", async () => {
            jsLeanIMT.insert(SNARK_SCALAR_FIELD)
            jsLeanIMT.insert(MAX_UINT256)

            await leanIMTTest.insert(SNARK_SCALAR_FIELD)
            await leanIMTTest.insert(MAX_UINT256)

            const root = await leanIMTTest.root()

            expect(root).to.equal(jsLeanIMT.root)
        })

        it("Should not insert a leaf if it is 0", async () => {
            const leaf = 0

            const transaction = leanIMTTest.insert(leaf)

            await expect(transaction).to.be.revertedWithCustomError(leanIMT, "LeafCannotBeZero")
        })

        it("Should insert a leaf", async () => {
            jsLeanIMT.insert(BigInt(1))

            await leanIMTTest.insert(1)

            const root = await leanIMTTest.root()

            expect(root).to.equal(jsLeanIMT.root)
        })

        it("Should not insert a leaf if it was already inserted before", async () => {
            await leanIMTTest.insert(1)

            const transaction = leanIMTTest.insert(1)

            await expect(transaction).to.be.revertedWithCustomError(leanIMT, "LeafAlreadyExists")
        })

        it("Should insert 10 leaves", async () => {
            for (let i = 0; i < 10; i += 1) {
                jsLeanIMT.insert(BigInt(i + 1))

                await leanIMTTest.insert(i + 1)

                const root = await leanIMTTest.root()

                expect(root).to.equal(jsLeanIMT.root)
            }
        })
    })

    describe("# insertMany", () => {
        it("Should insert leaves greater than SNARK_SCALAR_FIELD", async () => {
            const elems = [SNARK_SCALAR_FIELD, SNARK_SCALAR_FIELD + 1n, MAX_UINT256]

            jsLeanIMT.insertMany(elems)
            await leanIMTTest.insertMany(elems)

            const root = await leanIMTTest.root()
            expect(root).to.equal(jsLeanIMT.root)
        })

        it("Should not insert a leaf if it is 0", async () => {
            const leaf = 0

            const transaction = leanIMTTest.insertMany([leaf])

            await expect(transaction).to.be.revertedWithCustomError(leanIMT, "LeafCannotBeZero")
        })
        it("Should not insert an empty list of leaves", async () => {
            await expect(leanIMTTest.insertMany([])).to.be.revertedWithCustomError(leanIMT, "NoLeavesToInsert")

            await leanIMTTest.insert(1)

            await expect(leanIMTTest.insertMany([])).to.be.revertedWithCustomError(leanIMT, "NoLeavesToInsert")
        })
        it("Should not insert a leaf if it was already inserted before", async () => {
            await leanIMTTest.insert(1)

            const transaction = leanIMTTest.insertMany([1])

            await expect(transaction).to.be.revertedWithCustomError(leanIMT, "LeafAlreadyExists")
        })
        it("Should not insert duplicated leaves in the same batch", async () => {
            const transaction = leanIMTTest.insertMany([1, 2, 1])

            await expect(transaction).to.be.revertedWithCustomError(leanIMT, "LeafAlreadyExists")
        })
        it("Should insert a leaf", async () => {
            jsLeanIMT.insert(BigInt(1))

            await leanIMTTest.insertMany([1])

            const root = await leanIMTTest.root()

            expect(root).to.equal(jsLeanIMT.root)
        })
        it("Should insert 10 leaves", async () => {
            const elems: bigint[] = []
            for (let i = 0; i < 10; i += 1) {
                elems.push(BigInt(i + 1))
            }

            jsLeanIMT.insertMany(elems)
            await leanIMTTest.insertMany(elems)

            const root = await leanIMTTest.root()
            expect(root).to.equal(jsLeanIMT.root)
        })
        it("Should insert many leaves when the tree is not empty", async () => {
            jsLeanIMT.insert(BigInt(1))

            await leanIMTTest.insert(BigInt(1))

            const elems: bigint[] = []
            for (let i = 1; i < 10; i += 1) {
                elems.push(BigInt(i + 1))
            }

            jsLeanIMT.insertMany(elems)
            await leanIMTTest.insertMany(elems)

            const root = await leanIMTTest.root()
            expect(root).to.equal(jsLeanIMT.root)
        })
        it("Should match single inserts for every batch split", async () => {
            const elems: bigint[] = []
            for (let i = 0; i < 17; i += 1) {
                elems.push(BigInt(i + 1))
            }

            for (let split = 0; split <= elems.length; split += 1) {
                const { contract } = await run("deploy:imt-sha256-test", { logs: false })
                const js = new JSLeanIMT(sha256)

                if (split > 0) {
                    await contract.insertMany(elems.slice(0, split))
                    js.insertMany(elems.slice(0, split))
                }
                if (split < elems.length) {
                    await contract.insertMany(elems.slice(split))
                    js.insertMany(elems.slice(split))
                }

                expect(await contract.root()).to.equal(js.root)
            }
        })
    })

    describe("# update", () => {
        it("Should not update a leaf if the leaf does not exist", async () => {
            const transaction = leanIMTTest.update(2, 1, [1, 2, 3, 4])

            await expect(transaction).to.be.revertedWithCustomError(leanIMT, "LeafDoesNotExist")
        })

        it("Should update a leaf if that's the only leaf in the tree", async () => {
            await leanIMTTest.insert(1)

            jsLeanIMT.insert(BigInt(1))
            jsLeanIMT.update(0, BigInt(2))

            const { siblings } = jsLeanIMT.generateProof(0)

            await leanIMTTest.update(1, 2, siblings)

            const root = await leanIMTTest.root()

            expect(root).to.equal(jsLeanIMT.root)
        })

        it("Should update a leaf if there's more than 1 leaf in the tree", async () => {
            await leanIMTTest.insert(1)
            await leanIMTTest.insert(2)

            jsLeanIMT.insertMany([BigInt(1), BigInt(2)])
            jsLeanIMT.update(0, BigInt(3))

            const { siblings } = jsLeanIMT.generateProof(0)

            await leanIMTTest.update(1, 3, siblings)

            const root = await leanIMTTest.root()

            expect(root).to.equal(jsLeanIMT.root)
        })

        it("Should update a leaf to a value greater than SNARK_SCALAR_FIELD", async () => {
            await leanIMTTest.insertMany([1, 2, 3])

            jsLeanIMT.insertMany([BigInt(1), BigInt(2), BigInt(3)])
            jsLeanIMT.update(1, MAX_UINT256)

            const { siblings } = jsLeanIMT.generateProof(1)

            await leanIMTTest.update(2, MAX_UINT256, siblings)

            expect(await leanIMTTest.root()).to.equal(jsLeanIMT.root)
            expect(await leanIMTTest.indexOf(MAX_UINT256)).to.equal(1)
        })

        it("Should not update a leaf if the siblings are wrong", async () => {
            await leanIMTTest.insert(1)
            await leanIMTTest.insert(2)

            jsLeanIMT.insertMany([BigInt(1), BigInt(2)])
            jsLeanIMT.update(0, BigInt(3))

            const { siblings } = jsLeanIMT.generateProof(0)

            siblings[0] = BigInt(3)

            const transaction = leanIMTTest.update(1, 3, siblings)

            await expect(transaction).to.be.revertedWithCustomError(leanIMT, "WrongSiblingNodes")
        })

        it("Should not update a leaf if the siblings are wrong and the leaf index is odd", async () => {
            await leanIMTTest.insertMany([1, 2, 3])

            jsLeanIMT.insertMany([BigInt(1), BigInt(2), BigInt(3)])
            jsLeanIMT.update(1, BigInt(4))

            const { siblings } = jsLeanIMT.generateProof(1)

            siblings[1] = BigInt(5)

            const transaction = leanIMTTest.update(2, 4, siblings)

            await expect(transaction).to.be.revertedWithCustomError(leanIMT, "WrongSiblingNodes")
        })

        it("Should update 6 leaves", async () => {
            for (let i = 0; i < 6; i += 1) {
                jsLeanIMT.insert(BigInt(i + 1))

                await leanIMTTest.insert(i + 1)
            }

            for (let i = 0; i < 6; i += 1) {
                jsLeanIMT.update(i, BigInt(i + 7))

                const { siblings } = jsLeanIMT.generateProof(i)

                await leanIMTTest.update(i + 1, i + 7, siblings)

                const root = await leanIMTTest.root()

                expect(root).to.equal(jsLeanIMT.root)
            }
        })

        it("Should not update a leaf that was removed", async () => {
            await leanIMTTest.insertMany([1, 2])
            jsLeanIMT.insertMany([BigInt(1), BigInt(2)])

            jsLeanIMT.update(1, BigInt(0))

            const { siblings } = jsLeanIMT.generateProof(1)

            await leanIMTTest.remove(2, siblings)

            jsLeanIMT.update(1, BigInt(3))

            const { siblings: newSiblings } = jsLeanIMT.generateProof(1)

            const transaction = leanIMTTest.update(2, 3, newSiblings)

            await expect(transaction).to.be.revertedWithCustomError(leanIMT, "LeafDoesNotExist")
        })
        it("Should not update a leaf if the new value already exists", async () => {
            await leanIMTTest.insert(1)
            await leanIMTTest.insert(2)

            jsLeanIMT.insertMany([BigInt(1), BigInt(2)])
            jsLeanIMT.update(0, BigInt(2))

            const { siblings } = jsLeanIMT.generateProof(0)

            const transaction = leanIMTTest.update(1, 2, siblings)

            await expect(transaction).to.be.revertedWithCustomError(leanIMT, "LeafAlreadyExists")
        })
        it("Should maintain correct tree state after multiple updates and inserts", async () => {
            for (let i = 0; i < 5; i += 1) {
                jsLeanIMT.insert(BigInt(i + 1))
                await leanIMTTest.insert(i + 1)
            }

            for (let i = 0; i < 3; i += 1) {
                jsLeanIMT.update(i, BigInt(i + 10))
                const { siblings } = jsLeanIMT.generateProof(i)
                await leanIMTTest.update(i + 1, i + 10, siblings)
            }

            for (let i = 5; i < 8; i += 1) {
                jsLeanIMT.insert(BigInt(i + 1))
                await leanIMTTest.insert(i + 1)
            }

            const root = await leanIMTTest.root()
            expect(root).to.equal(jsLeanIMT.root)
        })
    })

    describe("# remove", () => {
        it("Should remove a leaf", async () => {
            await leanIMTTest.insert(1)
            await leanIMTTest.insert(2)
            await leanIMTTest.insert(3)

            jsLeanIMT.insertMany([BigInt(1), BigInt(2), BigInt(3)])
            jsLeanIMT.update(2, BigInt(0))

            const { siblings } = jsLeanIMT.generateProof(2)

            await leanIMTTest.remove(3, siblings)

            const root = await leanIMTTest.root()

            expect(root).to.equal(jsLeanIMT.root)
        })

        it("Should remove 10 leaf", async () => {
            for (let i = 0; i < 10; i += 1) {
                jsLeanIMT.insert(BigInt(i + 1))

                await leanIMTTest.insert(i + 1)
            }

            for (let i = 0; i < 10; i += 1) {
                jsLeanIMT.update(i, BigInt(0))

                const { siblings } = jsLeanIMT.generateProof(i)

                await leanIMTTest.remove(i + 1, siblings)

                const root = await leanIMTTest.root()

                expect(root).to.equal(jsLeanIMT.root)
            }
        })

        it("Should insert new leaves after removing some", async () => {
            await leanIMTTest.insertMany([1, 2, 3, 4, 5])
            jsLeanIMT.insertMany([1n, 2n, 3n, 4n, 5n])

            for (const index of [1, 3]) {
                jsLeanIMT.update(index, 0n)
                const { siblings } = jsLeanIMT.generateProof(index)
                await leanIMTTest.remove(index + 1, siblings)
            }

            await leanIMTTest.insert(6)
            jsLeanIMT.insert(6n)
            await leanIMTTest.insertMany([7, 8, 9])
            jsLeanIMT.insertMany([7n, 8n, 9n])

            expect(await leanIMTTest.root()).to.equal(jsLeanIMT.root)
        })
    })

    describe("# has", () => {
        it("Should return true because the node is in the tree", async () => {
            await leanIMTTest.insert(1)

            const hasLeaf = await leanIMTTest.has(1)

            expect(hasLeaf).to.equal(true)
        })

        it("Should return false because the node is not the tree", async () => {
            const hasLeaf = await leanIMTTest.has(2)

            expect(hasLeaf).to.equal(false)
        })

        it("Should return false if the leaf is 0", async () => {
            await leanIMTTest.insertMany([1, 2])
            jsLeanIMT.insertMany([BigInt(1), BigInt(2)])

            jsLeanIMT.update(1, BigInt(0))

            const { siblings } = jsLeanIMT.generateProof(1)

            await leanIMTTest.remove(2, siblings)

            const hasLeaf = await leanIMTTest.has(0)

            expect(hasLeaf).to.equal(false)
        })
    })
    describe("# indexOf", () => {
        it("Should return the index of a leaf", async () => {
            await leanIMTTest.insert(1)

            const index = await leanIMTTest.indexOf(1)

            expect(index).to.equal(0)
        })

        it("Should return the indices of the leaves", async () => {
            await leanIMTTest.insertMany([1, 2])

            const index1 = await leanIMTTest.indexOf(1)
            const index2 = await leanIMTTest.indexOf(2)

            expect(index1).to.equal(0)
            expect(index2).to.equal(1)
        })

        it("Should throw a custom error if the leaf does not exist", async () => {
            await leanIMTTest.insertMany([1, 2])

            const transaction = leanIMTTest.indexOf(3)

            await expect(transaction).to.be.revertedWithCustomError(leanIMT, "LeafDoesNotExist")
        })
    })

    describe("# root", () => {
        it("Should return 0 for an empty tree", async () => {
            expect(await leanIMTTest.root()).to.equal(0)
        })

        it("Should return the tree root", async () => {
            jsLeanIMT.insert(BigInt(1))

            await leanIMTTest.insert(1)

            const root = await leanIMTTest.root()

            expect(root).to.equal(jsLeanIMT.root)
        })
    })

    describe("# randomized", () => {
        it("Should match a rebuild-from-leaves reference across random operations", async () => {
            // Deterministic PRNG (mulberry32) so failures are reproducible.
            let seed = 0x5eed
            const rand = () => {
                seed = (seed + 0x6d2b79f5) | 0
                let t = seed
                t = Math.imul(t ^ (t >>> 15), t | 1)
                t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
                return ((t ^ (t >>> 14)) >>> 0) / 4294967296
            }
            const randomValue = () => {
                let v = 0n
                for (let i = 0; i < 8; i += 1) v = (v << 32n) | BigInt(Math.floor(rand() * 2 ** 32))
                return v === 0n ? 1n : v
            }

            // Reference: the whole tree is rebuilt from `leaves` after every operation.
            const leaves: bigint[] = []
            const levels = () => {
                const out = [leaves]
                while (out[out.length - 1].length > 1) {
                    const level = out[out.length - 1]
                    const next: bigint[] = []
                    for (let i = 0; i < level.length; i += 2) {
                        next.push(i + 1 < level.length ? sha256(level[i], level[i + 1]) : level[i])
                    }
                    out.push(next)
                }
                return out
            }
            const siblingsOf = (index: number) => {
                const all = levels()
                const siblings: bigint[] = []
                for (let level = 0; level < all.length - 1; level += 1) {
                    const sibling = all[level][index ^ 1]
                    if (sibling !== undefined) siblings.push(sibling)
                    index >>= 1
                }
                return siblings
            }

            for (let step = 0; step < 80; step += 1) {
                const op = rand()
                const activeIndices = leaves.flatMap((leaf, i) => (leaf !== 0n ? [i] : []))

                if (op < 0.3 || activeIndices.length === 0) {
                    const v = randomValue()
                    leaves.push(v)
                    await leanIMTTest.insert(v)
                } else if (op < 0.5) {
                    const batch = Array.from({ length: 1 + Math.floor(rand() * 6) }, randomValue)
                    leaves.push(...batch)
                    await leanIMTTest.insertMany(batch)
                } else if (op < 0.75) {
                    const index = activeIndices[Math.floor(rand() * activeIndices.length)]
                    const oldLeaf = leaves[index]
                    const newLeaf = randomValue()
                    const siblings = siblingsOf(index)
                    leaves[index] = newLeaf
                    await leanIMTTest.update(oldLeaf, newLeaf, siblings)
                } else {
                    const index = activeIndices[Math.floor(rand() * activeIndices.length)]
                    const oldLeaf = leaves[index]
                    const siblings = siblingsOf(index)
                    leaves[index] = 0n
                    await leanIMTTest.remove(oldLeaf, siblings)
                }

                const all = levels()
                expect(await leanIMTTest.root()).to.equal(all[all.length - 1][0])
            }
        })
    })
})
