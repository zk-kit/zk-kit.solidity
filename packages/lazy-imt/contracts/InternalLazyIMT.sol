// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {MAX_DEPTH} from "./Constants.sol";

struct LazyIMTData {
    uint40 maxIndex;
    uint40 numberOfLeaves;
    mapping(uint256 => uint256) elements;
}

library InternalLazyIMT {
    uint40 internal constant MAX_INDEX = (1 << 32) - 1;

    function _init(LazyIMTData storage self, uint8 depth) internal {
        require(depth <= MAX_DEPTH, "LazyIMT: Tree too large");
        self.maxIndex = uint40((1 << depth) - 1);
        self.numberOfLeaves = 0;
    }

    function _reset(LazyIMTData storage self) internal {
        self.numberOfLeaves = 0;
    }

    function _indexForElement(uint8 level, uint40 index) internal pure returns (uint40) {
        // calculate a unique index to store all hashes of the tree sparsely in self.elements
        return MAX_INDEX * level + index;
    }

    function _insert(
        LazyIMTData storage self,
        uint256 leaf,
        function(uint256[2] memory) view returns (uint256) hasher,
        uint256 hasherLimit
    ) internal {
        uint40 index = self.numberOfLeaves;
        require(leaf < hasherLimit, "LazyIMT: leaf must be < hasherLimit");
        require(index < self.maxIndex, "LazyIMT: tree is full");

        self.numberOfLeaves = index + 1;

        uint256 hash = leaf;

        for (uint8 i = 0; ; ) {
            self.elements[_indexForElement(i, index)] = hash;
            // it's a left element so we don't hash until there's a right element
            if (index & 1 == 0) break;
            uint40 elementIndex = _indexForElement(i, index - 1);
            hash = hasher([self.elements[elementIndex], hash]);
            unchecked {
                index >>= 1;
                i++;
            }
        }
    }

    function _update(
        LazyIMTData storage self,
        uint256 leaf,
        uint40 index,
        function(uint256[2] memory) view returns (uint256) hasher,
        uint256 hasherLimit
    ) internal {
        require(leaf < hasherLimit, "LazyIMT: leaf must be < hasherLimit");
        uint40 numberOfLeaves = self.numberOfLeaves;
        require(index < numberOfLeaves, "LazyIMT: leaf must exist");

        uint256 hash = leaf;

        for (uint8 i = 0; true; ) {
            self.elements[_indexForElement(i, index)] = hash;
            uint256 levelCount = numberOfLeaves >> (i + 1);
            if (levelCount <= index >> 1) break;
            if (index & 1 == 0) {
                uint40 elementIndex = _indexForElement(i, index + 1);
                hash = hasher([hash, self.elements[elementIndex]]);
            } else {
                uint40 elementIndex = _indexForElement(i, index - 1);
                hash = hasher([self.elements[elementIndex], hash]);
            }
            unchecked {
                index >>= 1;
                i++;
            }
        }
    }

    function _root(
        LazyIMTData storage self,
        function(uint256[2] memory) view returns (uint256) hasher,
        function(uint8) pure returns (uint256) _defaultZero
    ) internal view returns (uint256) {
        // this will always short circuit if self.numberOfLeaves == 0
        uint40 numberOfLeaves = self.numberOfLeaves;
        // dynamically determine a depth
        uint8 depth = 1;
        while (uint40(2) ** uint40(depth) < numberOfLeaves) {
            depth++;
        }
        return _root(self, numberOfLeaves, depth, hasher, _defaultZero);
    }

    function _root(
        LazyIMTData storage self,
        uint8 depth,
        function(uint256[2] memory) view returns (uint256) hasher,
        function(uint8) pure returns (uint256) _defaultZero
    ) internal view returns (uint256) {
        require(depth > 0, "LazyIMT: depth must be > 0");
        require(depth <= MAX_DEPTH, "LazyIMT: depth must be <= MAX_DEPTH");
        uint40 numberOfLeaves = self.numberOfLeaves;
        require(uint40(2) ** uint40(depth) >= numberOfLeaves, "LazyIMT: ambiguous depth");
        return _root(self, numberOfLeaves, depth, hasher, _defaultZero);
    }

    // Here it's assumed that the depth value is valid. If it is either 0 or > 2^8-1
    // this function will panic.
    function _root(
        LazyIMTData storage self,
        uint40 numberOfLeaves,
        uint8 depth,
        function(uint256[2] memory) view returns (uint256) hasher,
        function(uint8) pure returns (uint256) _defaultZero
    ) internal view returns (uint256) {
        require(depth <= MAX_DEPTH, "LazyIMT: depth must be <= MAX_DEPTH");
        // this should always short circuit if self.numberOfLeaves == 0
        if (numberOfLeaves == 0) return _defaultZero(depth);
        uint256[] memory levels = new uint256[](depth + 1);
        _levels(self, numberOfLeaves, depth, levels, hasher, _defaultZero);
        return levels[depth];
    }

    function _levels(
        LazyIMTData storage self,
        uint40 numberOfLeaves,
        uint8 depth,
        uint256[] memory levels,
        function(uint256[2] memory) view returns (uint256) hasher,
        function(uint8) pure returns (uint256) _defaultZero
    ) internal view {
        require(depth <= MAX_DEPTH, "LazyIMT: depth must be <= MAX_DEPTH");
        require(numberOfLeaves > 0, "LazyIMT: number of leaves must be > 0");
        // this should always short circuit if self.numberOfLeaves == 0
        uint40 index = numberOfLeaves - 1;

        if (index & 1 == 0) {
            levels[0] = self.elements[_indexForElement(0, index)];
        } else {
            levels[0] = _defaultZero(0);
        }

        for (uint8 i = 0; i < depth; ) {
            if (index & 1 == 0) {
                levels[i + 1] = hasher([levels[i], _defaultZero(i)]);
            } else {
                uint256 levelCount = (numberOfLeaves) >> (i + 1);
                if (levelCount > index >> 1) {
                    uint256 parent = self.elements[_indexForElement(i + 1, index >> 1)];
                    levels[i + 1] = parent;
                } else {
                    uint256 sibling = self.elements[_indexForElement(i, index - 1)];
                    levels[i + 1] = hasher([sibling, levels[i]]);
                }
            }
            unchecked {
                index >>= 1;
                i++;
            }
        }
    }

    function _merkleProofElements(
        LazyIMTData storage self,
        uint40 index,
        uint8 depth,
        function(uint256[2] memory) view returns (uint256) hasher,
        function(uint8) pure returns (uint256) _defaultZero
    ) internal view returns (uint256[] memory) {
        uint40 numberOfLeaves = self.numberOfLeaves;
        require(index < numberOfLeaves, "LazyIMT: leaf must exist");

        // targetDepth = log2_floor(numberOfLeaves)
        uint8 targetDepth = 1;
        {
            uint40 val = 2;
            while (val < numberOfLeaves) {
                val <<= 1;
                targetDepth++;
            }
        }
        require(depth >= targetDepth, "LazyIMT: proof depth");
        // pass depth -1 because we don't need the root value
        uint256[] memory _elements = new uint256[](depth);
        _levels(self, numberOfLeaves, targetDepth - 1, _elements, hasher, _defaultZero);

        // unroll the bottom entry of the tree because it will never need to
        // be pulled from _levels
        if (index & 1 == 0) {
            if (index + 1 >= numberOfLeaves) {
                _elements[0] = _defaultZero(0);
            } else {
                _elements[0] = self.elements[_indexForElement(0, index + 1)];
            }
        } else {
            _elements[0] = self.elements[_indexForElement(0, index - 1)];
        }
        index >>= 1;

        for (uint8 i = 1; i < depth; ) {
            uint256 currentLevelCount = numberOfLeaves >> i;
            if (index & 1 == 0) {
                // if the element is an uncomputed edge node we'll use the value set
                // from _levels above
                // otherwise set as usual below
                if (index + 1 < currentLevelCount) {
                    _elements[i] = self.elements[_indexForElement(i, index + 1)];
                } else if (((numberOfLeaves - 1) >> i) <= index) {
                    _elements[i] = _defaultZero(i);
                }
            } else {
                _elements[i] = self.elements[_indexForElement(i, index - 1)];
            }
            unchecked {
                index >>= 1;
                i++;
            }
        }
        return _elements;
    }
}
