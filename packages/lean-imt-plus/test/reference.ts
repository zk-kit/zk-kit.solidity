// The Solidity tree is tested in lockstep against the TypeScript reference
// implementation published as `@zk-kit/lean-imt-plus` (the single source of truth
// for the construction). It uses the SAME Poseidon hashes (3-input leaf, 2-input
// node) and the SAME physical layout (sentinel at index 0, append-on-insert,
// tombstone-on-remove), so after every mutation the two roots must match.
export { LeanIMTPlus } from "@zk-kit/lean-imt-plus"
export type { LeanIMTPlusHashFunctions, LeanIMTPlusProof, LeanIMTPlusLeaf } from "@zk-kit/lean-imt-plus"
