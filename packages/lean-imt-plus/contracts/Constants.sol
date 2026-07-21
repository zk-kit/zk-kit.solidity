// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @dev The BN254 (alt_bn128) scalar field order. Every value stored in the tree,
/// as well as every hash output, is an element of this field, so all inputs must
/// be strictly less than it. This is the same field used by the LeanIMT and by
/// most Poseidon-based zero-knowledge circuits.
uint256 constant SNARK_SCALAR_FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

/// @dev Domain-separation tag mixed into every leaf commitment as the third input
/// of the 3-input leaf hash. Together with the differing hash arity (3 inputs for
/// leaves, 2 inputs for internal nodes) it guarantees a leaf commitment can never
/// collide with an internal-node hash, closing a second-preimage attack in which
/// an internal node is repackaged as a leaf (or vice versa).
uint256 constant TAG_LEAF = 1;
