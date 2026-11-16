// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @dev Leaf tag: `leaf = sha256(value || nextValue || TAG_LEAF)`. Leaves (96 bytes)
/// and nodes (64 bytes) are already separated by length; the tag keeps the encoding
/// aligned with the Poseidon LeanIMT+.
uint256 constant TAG_LEAF = 1;
